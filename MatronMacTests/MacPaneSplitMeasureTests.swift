#if os(macOS) && DEBUG
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
}

/// With the tasks pane open the chat column sits in an
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
                          "\(count) width-less row measurements for one appended message")
    }

    /// Control: without the split there is no per-pane hosting view.
    func test_newMessage_withPaneClosed_doesNotProbeTheWholeTranscript() async throws {
        let count = try await widthlessMeasurementsOnAppend(paneOpen: false)
        XCTAssertLessThan(count, Self.rowCount)
    }

    /// The widths the pane frames ask for: the chat column's ideal is
    /// whatever the side pane's minimum leaves, never less than its own
    /// minimum. (`HSplitView` decides the opening split itself.)
    func test_chatColumnIdealWidth_leavesTheSidePaneItsMinimum() {
        XCTAssertEqual(MacChatView.chatColumnIdealWidth(in: 1000), 1000 - MacChatView.sidePaneMinWidth)
        XCTAssertEqual(MacChatView.chatColumnIdealWidth(in: 600), MacChatView.chatColumnMinWidth)
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
            paneRoute: .constant(paneOpen ? .items(path: []) : nil), chatTitle: "Chat")
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // ARC owns the window; the probe is process-wide, so a hosting view
        // left alive by this test would count against the next one.
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)

        // The mount arrives in more than one burst (the chat's entry
        // settle window), later on a loaded machine: wait for the last row
        // and then for the measurements to stop before counting.
        let mounted = await Self.spin(until: { Self.text(containing: "row \(Self.rowCount)", in: window.contentView) },
                                      timeout: 20)
        XCTAssertTrue(mounted, "sanity: the transcript mounted")
        await Self.waitForQuiescence()
        if paneOpen {
            XCTAssertNotNil(Self.find(NSSplitView.self, in: window.contentView) as NSView?,
                            "sanity: the pane split is what got laid out")
        }

        SelectableMessageTextProbe.widthlessMeasurements = 0
        timeline.push(PushableTimeline.rows(Self.rowCount + 1))
        let appended = await Self.spin(until: { Self.text(containing: "row \(Self.rowCount + 1)", in: window.contentView) },
                                       timeout: 20)
        XCTAssertTrue(appended, "the appended row must reach the view, or a count of 0 proves nothing")
        await Self.waitForQuiescence()
        return SelectableMessageTextProbe.widthlessMeasurements
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    /// Whether a mounted text view shows `text` (a row's first line).
    private static func text(containing text: String, in view: NSView?) -> Bool {
        guard let view else { return false }
        if let textView = view as? NSTextView, textView.string.contains(text) { return true }
        return view.subviews.contains { Self.text(containing: text, in: $0) }
    }

    /// Runs the main run loop in 50 ms passes until `condition` holds, or
    /// `timeout` seconds pass; whether it held.
    private static func spin(until condition: () -> Bool, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pass()
        }
        return condition()
    }

    /// Waits until no row has been measured for `quietPasses` consecutive
    /// 50 ms passes (at most `timeout` seconds).
    private static func waitForQuiescence(quietPasses: Int = 10, timeout: Double = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last = SelectableMessageTextProbe.measurements
        var quiet = 0
        while quiet < quietPasses, Date() < deadline {
            await pass()
            let now = SelectableMessageTextProbe.measurements
            quiet = now == last ? quiet + 1 : 0
            last = now
        }
    }

    private static func pass() async {
        await Task.yield()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
#endif
