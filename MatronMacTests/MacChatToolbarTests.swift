#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Inert `ChatService` stub — the toolbar tests only need a strip VM to
/// exist; its observation is never started.
private final class FakeChatForToolbar: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class MacChatToolbarTests: XCTestCase {

    private func makeStripVM() -> SubChatStripViewModel {
        SubChatStripViewModel(chat: FakeChatForToolbar(), parentConvoID: "p1")
    }

    func testToolbarCarriesTitleAndStatus() {
        let status = SessionStatus(
            model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)])
        let toolbar = MacChatToolbar(
            title: "Chat", status: status,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(toolbar.title, "Chat")
        XCTAssertEqual(toolbar.status?.context?.pct, 27)
        XCTAssertEqual(toolbar.status?.limits?.count, 1)

        // Nil status is valid — header renders the title alone.
        XCTAssertNil(MacChatToolbar(
            title: "Chat", status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {}).status)
    }


    /// The sidebar-toggle button posts `.toggleSidebar` on the command
    /// bus. The toolbar tests the listener side; Task 14e tests the
    /// menu-bar `Button("Toggle Sidebar")` poster side. Verifying the
    /// `Notification.Name` exists and is distinct keeps the contract
    /// explicit before the menu item lands.
    func test_toggleSidebarNotificationName_isWired() {
        let name = Notification.Name.matronCommand(.toggleSidebar)
        XCTAssertEqual(name.rawValue, "chat.matron.command.toggleSidebar")
    }
}
#endif
