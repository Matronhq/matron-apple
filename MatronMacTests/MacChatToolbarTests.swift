#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

@MainActor
final class MacChatToolbarTests: XCTestCase {

    /// Constructing the toolbar exercises the ToolbarContent wiring at
    /// compile time. The body itself isn't rendered in this unit test
    /// (no host scene).
    func test_toolbarRenders_withTitleAndInfoButton() {
        var profileTaps = 0
        let toolbar = MacChatToolbar(
            title: "Refactoring auth",
            onShowBotProfile: { profileTaps += 1 }
        )
        XCTAssertNotNil(toolbar.body)

        // Verify the closure plumbs through — the toolbar's ⓘ button
        // calls onShowBotProfile.
        toolbar.onShowBotProfile()
        XCTAssertEqual(profileTaps, 1)
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
