#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronDesignSystem
import MatronChat
import MatronModels
import MatronViewModels

/// A timeline the test can push new snapshots into after the view mounted.
private final class PushableTimeline: TimelineService, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation?
    private var pending: [TimelineItem]?

    static func rows(_ count: Int) -> [TimelineItem] {
        (1...count).map {
            TimelineItem(id: "\($0)", sender: "agent:box",
                         timestamp: Date(timeIntervalSince1970: Double($0)),
                         kind: .text(body: "row \($0)\nsecond line of the message", formattedHTML: nil),
                         isOwn: false)
        }
    }

    func push(_ items: [TimelineItem]) {
        if let continuation { continuation.yield(items) } else { pending = items }
    }

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            if let pending { continuation.yield(pending) }
        }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { true }
    func markAsRead() async throws {}
}

private final class NoMedia: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

private final class NoChat: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

/// Item #1264: with the tasks pane open the chat column sits in an
/// `HSplitView` pane, and that pane's hosting view asks the column for its
/// minimum, ideal and maximum size on every layout pass. Unless the column's
/// frame answers those itself, the eager transcript answers by measuring
/// every row without a usable width. Live samples showed 64–72% of
/// multi-second main-thread stalls in exactly that path. Measured before the
/// fix: one appended message cost ~2,400 such measurements over 60 rows.
@MainActor
final class MacPaneSplitMeasureTests: XCTestCase {
    private static let rowCount = 60
    private var deps: AppDependencies!

    override func tearDown() async throws {
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    /// A probe of the whole transcript costs at least one measurement per
    /// row, so staying under the row count proves no such pass ran. (A
    /// handful remain from the new row's own first layout.)
    func test_newMessage_withPaneOpen_doesNotProbeTheWholeTranscript() async throws {
        let count = try await widthlessMeasurementsOnAppend(paneOpen: true)
        XCTAssertLessThan(count, Self.rowCount,
                          "\(count) width-less row measurements for one appended message (item #1264)")
    }

    /// Control: without the split there is no per-pane hosting view.
    func test_newMessage_withPaneClosed_doesNotProbeTheWholeTranscript() async throws {
        let count = try await widthlessMeasurementsOnAppend(paneOpen: false)
        XCTAssertLessThan(count, Self.rowCount)
    }

    private func widthlessMeasurementsOnAppend(paneOpen: Bool) async throws -> Int {
        let timeline = PushableTimeline()
        timeline.push(PushableTimeline.rows(Self.rowCount))
        let chatVM = ChatViewModel(roomID: "c1", timeline: timeline, media: NoMedia())
        let composerVM = ComposerViewModel(roomID: "c1", timeline: timeline, commands: [])
        let stripVM = SubChatStripViewModel(chat: NoChat(), parentConvoID: "c1")
        deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        let view = MacChatView(
            viewModel: chatVM, composerVM: composerVM, stripViewModel: stripVM,
            subChatProvider: { _ in (chatVM, stripVM) },
            itemsPaneOpen: .constant(paneOpen), chatTitle: "Chat")
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        await Self.spin(seconds: 3)
        if paneOpen {
            XCTAssertNotNil(Self.find(NSSplitView.self, in: window.contentView) as NSView?,
                            "sanity: the pane split is what got laid out")
        }

        SelectableMessageTextProbe.widthlessMeasurements = 0
        timeline.push(PushableTimeline.rows(Self.rowCount + 1))
        await Self.spin(seconds: 2)
        let appendCount = SelectableMessageTextProbe.widthlessMeasurements
        window.orderOut(nil)
        return appendCount
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    private static func spin(seconds: Double) async {
        for _ in 0..<Int(seconds / 0.05) {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
#endif
