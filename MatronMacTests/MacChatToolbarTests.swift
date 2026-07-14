#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

@MainActor
final class MacChatToolbarTests: XCTestCase {

    func testToolbarCarriesTitleAndStatus() {
        let status = SessionStatus(
            model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)])
        let toolbar = MacChatToolbar(title: "Chat", status: status)
        XCTAssertEqual(toolbar.title, "Chat")
        XCTAssertEqual(toolbar.status?.context?.pct, 27)
        XCTAssertEqual(toolbar.status?.limits?.count, 1)

        // Nil status is valid — header renders the title alone.
        XCTAssertNil(MacChatToolbar(title: "Chat", status: nil).status)
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
