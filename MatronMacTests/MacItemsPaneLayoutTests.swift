#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// A timeline that yields three rows and keeps its stream open, so the
/// chat column lays out with real (short) content rather than the
/// settled-empty placeholder.
private final class ThreeRowTimeline: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield((1...3).map {
                TimelineItem(id: "\($0)", sender: "agent:box",
                             timestamp: Date(timeIntervalSince1970: Double($0)),
                             kind: .text(body: "row \($0)", formattedHTML: nil), isOwn: false)
            })
        }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { true }
    func markAsRead() async throws {}
}

/// A timeline whose rows arrive AFTER the view has mounted and laid out —
/// what a real conversation switch looks like (the store read lands a beat
/// after `MacChatListView` mounts the fresh `MacChatView`). The transcript
/// is empty while the split first sizes itself.
private final class LateRowsTimeline: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                continuation.yield((1...40).map {
                    TimelineItem(id: "\($0)", sender: "agent:box",
                                 timestamp: Date(timeIntervalSince1970: Double($0)),
                                 kind: .text(body: "row \($0)\nsecond line\nthird line", formattedHTML: nil),
                                 isOwn: false)
                })
            }
            continuation.onTermination = { _ in task.cancel() }
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

/// Drives a real conversation switch: `MacChatListView` keys `MacChatView`
/// by `.id(convoID)`, so a switch tears the old view down and mounts a fresh
/// one into the same slot. A plain `HStack` stands in for the app's
/// `NavigationSplitView`: the bug reproduces without it. The sidebar is narrow
/// and the window 1000 pt wide because the CI runner's screen clamps windows to
/// 1024 pt: a wider sidebar left the chat area under `sideBySideMinWidth`, so
/// the pane took over the detail area and no composer was mounted.
@MainActor @Observable
private final class SwitchModel {
    var convoID: String
    init(convoID: String) { self.convoID = convoID }
}

private struct SwitchHarness: View {
    let model: SwitchModel
    let chat: (String) -> MacChatView

    var body: some View {
        HStack(spacing: 0) {
            Text("side").frame(width: 100)
            chat(model.convoID).id(model.convoID)
        }
    }
}

/// Item #76: with the tasks pane open, a freshly mounted chat (what a
/// conversation switch produces — `MacChatListView` keys `MacChatView` by
/// id) laid out with its column bunched at the top of the window: rows,
/// then the composer, then blank space below. The column must fill the
/// window's height, which puts the composer at the bottom.
@MainActor
final class MacItemsPaneLayoutTests: XCTestCase {
    /// Held so `tearDown()` can stop the session's background maintenance
    /// sweeper (review Major: a leaked `JournalMaintenance` 10 s timer
    /// otherwise outlives the test method and can fire against the shared
    /// `MATRON_APP_SUPPORT_OVERRIDE` directory after a later test deletes
    /// or recreates the store there). See
    /// `AppDependencies.stopMaintenanceForTests()`.
    private var deps: AppDependencies!

    override func tearDown() async throws {
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    func test_chatColumnFillsWindowHeight_whenPaneIsOpenOnMount() async throws {
        try await assertComposerAtBottom(timeline: ThreeRowTimeline())
    }

    /// The reported shape, and the only one that reproduces (a plain mount
    /// with late rows lays out fine): pane open, user switches conversation.
    /// Reproduced 2026-09-17 with an instrumented build — the split is
    /// NSSplitView-backed and takes its height from its children's IDEAL
    /// height, not the proposal. The fresh column mounts with an empty
    /// transcript, so that ideal is ~250 pt; the split adopts it and does
    /// not regrow when the rows land.
    func test_chatColumnFillsWindowHeight_afterConversationSwitch_withPaneOpen() async throws {
        deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        let timelines: [String: TimelineService] = ["c1": ThreeRowTimeline(), "c2": LateRowsTimeline()]
        var parts: [String: (ChatViewModel, ComposerViewModel, SubChatStripViewModel)] = [:]
        for (id, timeline) in timelines {
            parts[id] = (ChatViewModel(roomID: id, timeline: timeline, media: NoMedia()),
                         ComposerViewModel(roomID: id, timeline: timeline, commands: []),
                         SubChatStripViewModel(chat: NoChat(), parentConvoID: id))
        }
        let model = SwitchModel(convoID: "c1")
        let root = SwitchHarness(model: model) { id in
            let (chatVM, composerVM, stripVM) = parts[id]!
            return MacChatView(
                viewModel: chatVM, composerVM: composerVM, stripViewModel: stripVM,
                subChatProvider: { _ in (chatVM, stripVM) },
                itemsPaneOpen: .constant(true), chatTitle: "Chat \(id)")
        }
        .environment(\.appDependencies, deps)
        .environment(\.currentSession, session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        await Self.spin(seconds: 2)

        model.convoID = "c2"
        await Self.spin(seconds: 4)

        // Assert on the split itself: bunched, it is ~250 pt tall in a 700 pt
        // window. Where the short split lands (top or bottom) depends on the
        // host, so the composer's position is not a reliable signal here.
        let split = try XCTUnwrap(Self.find(NSSplitView.self, in: window.contentView),
                                  "the chat area must be wide enough for the side-by-side split; hierarchy:\n\(Self.dump(window.contentView))")
        XCTAssertGreaterThan(split.frame.height, 600,
                             "split height \(split.frame.height): after a switch the pane split should still fill the 700 pt window (item #76)")
        XCTAssertNotNil(Self.find(ComposerTextView.self, in: split), "the composer must be mounted beside the pane")
        window.orderOut(nil)
    }

    private static func spin(seconds: Double) async {
        for _ in 0..<Int(seconds / 0.05) {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func assertComposerAtBottom(
        timeline: TimelineService, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let chatVM = ChatViewModel(roomID: "c1", timeline: timeline, media: NoMedia())
        let composerVM = ComposerViewModel(roomID: "c1", timeline: timeline, commands: [])
        let stripVM = SubChatStripViewModel(chat: NoChat(), parentConvoID: "c1")
        deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        let view = MacChatView(
            viewModel: chatVM, composerVM: composerVM, stripViewModel: stripVM,
            subChatProvider: { _ in (chatVM, stripVM) },
            itemsPaneOpen: .constant(true), chatTitle: "Chat")
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        for _ in 0..<60 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let composer = try XCTUnwrap(Self.find(ComposerTextView.self, in: window.contentView),
                                     "the composer must be mounted beside the pane", file: file, line: line)
        let inWindow = composer.convert(composer.bounds, to: nil)
        // AppKit y grows upward: a composer at the bottom of a 700pt
        // window has a small minY; a mid-window composer means the column
        // collapsed to its content height.
        XCTAssertLessThan(inWindow.minY, 150,
                          "composer minY \(inWindow.minY): the chat column should fill the window (item #76)",
                          file: file, line: line)
        XCTAssertNotNil(Self.find(NSSplitView.self, in: window.contentView) as NSView?,
                        "sanity: the pane branch (an HSplitView) is what got laid out", file: file, line: line)
        window.orderOut(nil)
    }

    private static func dump(_ view: NSView?, depth: Int = 0) -> String {
        guard let view, depth < 12 else { return "" }
        let line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame)\n"
        return line + view.subviews.map { dump($0, depth: depth + 1) }.joined()
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }
}
#endif
