import XCTest
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// A `TimelineService` whose snapshots the test pushes live (`emit`), so the
/// view model behaves exactly as with the journal: first snapshot returns
/// `start()`, later ones commit (coalesced ≤ 250ms).
final class LiveTimelineFixture: TimelineService, @unchecked Sendable {
    private let stream: AsyncThrowingStream<[TimelineItem], Error>
    private let continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream<[TimelineItem], Error>.makeStream()
    }

    func emit(_ items: [TimelineItem]) { continuation.yield(items) }

    func items() -> AsyncThrowingStream<[TimelineItem], Error> { stream }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

final class NoMediaFixture: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

final class NoChildrenChatFixture: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

enum TimelineFixtures {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Item ids are numeric strings — journal seqs — so `focus(seq:)` works.
    static func text(_ index: Int, own: Bool = false, body: String? = nil) -> TimelineItem {
        TimelineItem(id: "\(index)", sender: own ? "@me:s" : "matron",
                     timestamp: base.addingTimeInterval(TimeInterval(index * 60)),
                     kind: .text(body: body ?? "Message \(index). "
                                    + String(repeating: "Lorem ipsum dolor sit amet. ", count: index % 4 + 1),
                                 formattedHTML: nil),
                     isOwn: own)
    }

    static func streaming(_ ref: String, body: String) -> TimelineItem {
        TimelineItem(id: "eph:\(ref)", sender: "agent", timestamp: base.addingTimeInterval(1_000_000),
                     kind: .text(body: body, formattedHTML: nil), isOwn: false)
    }

    static func activity(_ label: String) -> TimelineItem {
        TimelineItem(id: "activity", sender: "agent", timestamp: base.addingTimeInterval(2_000_000),
                     kind: .activityIndicator(label: label), isOwn: false)
    }

    static func conversation(_ count: Int) -> [TimelineItem] {
        (1...count).map { text($0, own: $0 % 5 == 0) }
    }

    @MainActor
    static func viewModel(_ service: LiveTimelineFixture, roomID: String = "!timeline:test") -> ChatViewModel {
        ChatViewModel(roomID: roomID, timeline: service, media: NoMediaFixture())
    }
}

/// Spins the main run loop (display links, dispatch) until `condition`.
@MainActor
func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

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

    init(roomID: String = "!timeline-\(UUID().uuidString):test",
         size: CGSize = CGSize(width: 393, height: 700), attach: Bool = true,
         cache: TimelineMeasureCache = .shared, precomputeDelayNanosecondsForTesting: UInt64 = 0) {
        self.cache = cache
        self.precomputeDelayNanosecondsForTesting = precomputeDelayNanosecondsForTesting
        viewModel = TimelineFixtures.viewModel(service, roomID: roomID)
        strip = SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: roomID)
        controller = ChatTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                            actions: .inert, environment: TimelineHostedEnvironment(),
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
                                            actions: .inert, environment: TimelineHostedEnvironment(),
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
