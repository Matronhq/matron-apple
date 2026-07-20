#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Pins the sidebar column's `navigationSplitViewColumnWidth` plumbing.
/// On macOS 26 `.toolbar(removing: .sidebarToggle)` applied OUTSIDE the
/// width modifier masks it entirely (sidebar falls to the ~140pt system
/// default), so the modifier order in `MacChatListView.body` is
/// load-bearing — this test fails if the mask returns.
@MainActor
final class MacSidebarWidthTests: XCTestCase {
    func test_sidebarColumn_honoursIdealWidthOnFirstLayout() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let summaries = (0..<12).map {
            ChatSummary(id: "!\($0):s", title: "Chat number \($0)", bot: bot,
                        lastActivity: .now.addingTimeInterval(Double(-$0) * 3600),
                        unreadCount: 0)
        }
        let vm = ChatListViewModel(chat: WidthFakeChatActions(snapshots: [summaries]))
        let view = MacChatListView(viewModel: vm)
            .frame(minWidth: 800, minHeight: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.orderFront(nil)

        for _ in 0..<40 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        guard let split = Self.findSplitView(in: window.contentView) else {
            XCTFail("no NSSplitView found")
            return
        }
        let sidebarWidth = split.arrangedSubviews.first?.frame.width ?? 0
        XCTAssertEqual(sidebarWidth, 450, accuracy: 1,
                       "sidebar should open at the 450pt ideal")
        let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
        let sidebarItem = try XCTUnwrap(controller.splitViewItems.first)
        XCTAssertEqual(sidebarItem.minimumThickness, 260, accuracy: 1)
        XCTAssertEqual(sidebarItem.maximumThickness, 600, accuracy: 1)
        window.orderOut(nil)
    }

    private static func findSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let found = findSplitView(in: sub) { return found }
        }
        return nil
    }
}

private final class WidthFakeChatActions: ChatService, @unchecked Sendable {
    private let snapshots: [[ChatSummary]]
    init(snapshots: [[ChatSummary]]) { self.snapshots = snapshots }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}
#endif
