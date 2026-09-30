import UIKit
import MatronChat
import MatronViewModels
@testable import Matron

/// A `ChatTimelineController` in a real window over a real `ChatViewModel`
/// fed by `LiveTimelineFixture`.
@MainActor
final class TimelineHarness {
    let service = LiveTimelineFixture()
    let viewModel: ChatViewModel
    let strip: SubChatStripViewModel
    let bridge = ChatTimelineBridge()
    private(set) var controller: ChatTimelineController
    let window: UIWindow
    let cache: TimelineMeasureCache
    /// Test-only floor under every precompute batch (see
    /// `TimelineHeightProvider.precomputeDelayNanoseconds`) — held across
    /// `remount()` so a room-reopen test keeps the same timing knob.
    private let precomputeDelayNanosecondsForTesting: UInt64
    private let environment: TimelineHostedEnvironment

    init(roomID: String = "!timeline-\(UUID().uuidString):test",
         size: CGSize = CGSize(width: 393, height: 700), attach: Bool = true,
         cache: TimelineMeasureCache = .shared, precomputeDelayNanosecondsForTesting: UInt64 = 0,
         environment: TimelineHostedEnvironment = TimelineHostedEnvironment()) {
        self.cache = cache
        self.precomputeDelayNanosecondsForTesting = precomputeDelayNanosecondsForTesting
        self.environment = environment
        viewModel = TimelineFixtures.viewModel(service, roomID: roomID)
        strip = SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: roomID)
        controller = ChatTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                            actions: .inert, environment: environment,
                                            cache: cache,
                                            precomputeDelayNanosecondsForTesting: precomputeDelayNanosecondsForTesting)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if attach { self.attach() }
    }

    func attach() {
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// Room reopen: a fresh controller over the same (cached) view model.
    func remount() {
        controller.tearDown()
        controller = ChatTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                            actions: .inert, environment: environment,
                                            cache: cache,
                                            precomputeDelayNanosecondsForTesting: precomputeDelayNanosecondsForTesting)
        attach()
    }

    func start(with items: [TimelineItem]) async throws {
        service.emit(items)
        _ = await viewModel.start()
        try await settle()
    }

    func emit(_ items: [TimelineItem]) async throws {
        service.emit(items)
        try await waitUntil { self.viewModel.items == items }
        try await settle()
    }

    /// Until the controller shows exactly the view model's current window.
    func settle(timeout: TimeInterval = 3) async throws {
        try await waitUntil(timeout: timeout) {
            var seen = Set<String>()
            let expected = self.viewModel.windowedRows.map(TimelineRowContentBuilder.anchorID(for:))
                .filter { seen.insert($0).inserted }
            return self.controller.appliedRowIDs == expected && !self.controller.hasPendingWork
        }
    }

    var collectionView: UICollectionView { controller.collectionView }
    var maxOffset: CGFloat { max(0, collectionView.contentSize.height - collectionView.bounds.height) }

    /// A user drag to `y` that settles there.
    func drag(to y: CGFloat) {
        controller.scrollViewWillBeginDragging(collectionView)
        collectionView.contentOffset = CGPoint(x: 0, y: y)
        controller.scrollViewDidEndDecelerating(collectionView)
    }

    /// A row's top edge relative to the viewport's top edge.
    func onScreenY(_ id: String) -> CGFloat? {
        guard let index = controller.scrollModel.index(of: id) else { return nil }
        return controller.scrollModel.rowMinY(at: index) - collectionView.contentOffset.y
    }
}
