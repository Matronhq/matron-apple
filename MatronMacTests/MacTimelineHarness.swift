import XCTest
import AppKit
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import MatronMac

/// A real `ChatViewModel` over `LiveTimelineFixture`, rendered by a real
/// `MacTimelineController` in a real window (plan Task 9).
@MainActor final class MacTimelineHarness {
    let service = LiveTimelineFixture()
    let viewModel: ChatViewModel
    let strip: SubChatStripViewModel
    let bridge = MacTimelineBridge()
    let selection = MessageSelectionController()
    let controller: MacTimelineController
    let window: NSWindow

    init(size: CGSize = CGSize(width: 800, height: 600)) {
        let roomID = "!mac-timeline-\(UUID().uuidString):test"
        viewModel = TimelineFixtures.viewModel(service, roomID: roomID)
        strip = SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: roomID)
        controller = MacTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                           selection: selection, actions: .inert, cache: MacTimelineMeasureCache(countLimit: 4000))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        // Setting `contentViewController` resizes the window to the view's
        // own frame (zero until SwiftUI or a window sizes it): size it back.
        window.setContentSize(size)
        window.orderFront(nil)
        // `finishedTranscript` needs the spans → transcript bridge (Task 10).
        MacChatView.installTranscriptProvider(on: selection, viewModel: viewModel)
    }

    /// First snapshot: `start()` returns after it (same as iOS `TimelineHarness.start(with:)`).
    func start(with items: [TimelineItem]) async throws {
        service.emit(items)
        _ = await viewModel.start()
        try await settle()
    }

    /// Later snapshots commit coalesced (≤ 250 ms).
    func emit(_ items: [TimelineItem]) async throws {
        service.emit(items)
        try await waitUntil { self.viewModel.items == items }
        try await settle()
    }

    /// Until the table shows exactly the view model's current window.
    func settle(timeout: TimeInterval = 3) async throws {
        try await waitUntil(timeout: timeout) {
            var seen = Set<String>()
            let expected = self.viewModel.windowedRows.map(TimelineRowContentBuilder.anchorID(for:))
                .filter { seen.insert($0).inserted }
            return self.controller.session.scrollModel.rows.map(\.id) == expected && !self.controller.hasPendingWork
        }
        controller.view.layoutSubtreeIfNeeded()
    }

    /// Ids are numeric strings (journal seqs) starting at 1, like `TimelineFixtures`, so `focus(seq:)` resolves them.
    func texts(_ n: Int, body: (Int) -> String = { "Message \($0) with a few words in it" }) -> [TimelineItem] {
        (1...n).map { TimelineItem(id: "\($0)", sender: "@bot:s",
                                   timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)),
                                   kind: .text(body: body($0), formattedHTML: nil), isOwn: false, sendState: .sent) }
    }

    var clipY: CGFloat { controller.scrollView.contentView.bounds.origin.y }
    var maxY: CGFloat { controller.session.scrollModel.maxOffsetY }
}
