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

/// Item #76: with the tasks pane open, a freshly mounted chat (what a
/// conversation switch produces — `MacChatListView` keys `MacChatView` by
/// id) laid out with its column bunched at the top of the window: rows,
/// then the composer, then blank space below. The column must fill the
/// window's height, which puts the composer at the bottom.
@MainActor
final class MacItemsPaneLayoutTests: XCTestCase {
    func test_chatColumnFillsWindowHeight_whenPaneIsOpenOnMount() async throws {
        let timeline = ThreeRowTimeline()
        let chatVM = ChatViewModel(roomID: "c1", timeline: timeline, media: NoMedia())
        let composerVM = ComposerViewModel(roomID: "c1", timeline: timeline, commands: [])
        let stripVM = SubChatStripViewModel(chat: NoChat(), parentConvoID: "c1")
        let deps = AppDependencies()
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
                                     "the composer must be mounted beside the pane")
        let inWindow = composer.convert(composer.bounds, to: nil)
        // AppKit y grows upward: a composer at the bottom of a 700pt
        // window has a small minY; a mid-window composer means the column
        // collapsed to its content height.
        XCTAssertLessThan(inWindow.minY, 150,
                          "composer minY \(inWindow.minY): the chat column should fill the window (item #76)")
        XCTAssertNotNil(Self.find(NSSplitView.self, in: window.contentView) as NSView?,
                        "sanity: the pane branch (an HSplitView) is what got laid out")
        window.orderOut(nil)
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
