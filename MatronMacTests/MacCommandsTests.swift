#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

/// Verifies the menu-bar command bus: distinct `Notification.Name`s per
/// case, and round-trip post → observe through `NotificationCenter.default`.
/// Tasks 14c + 14d landed `.refresh` and `.toggleSidebar`; this test
/// pins the full Phase-2 set landed in Task 14e.
final class MacCommandsTests: XCTestCase {

    /// All known commands map to distinct, non-empty notification names.
    /// Loops over `allCases` so adding a new case (Phase 3+) automatically
    /// joins the test surface.
    func test_notificationNames_areDistinct_andProperlyNamespaced() {
        let names = Set(MatronCommand.allCases.map { Notification.Name.matronCommand($0).rawValue })
        XCTAssertEqual(names.count, MatronCommand.allCases.count, "duplicate notification names across MatronCommand cases")
        for name in names {
            XCTAssertTrue(name.hasPrefix("chat.matron.command."), "name \(name) missing namespace prefix")
        }
    }

    /// All Phase-2 cases are present. Pin explicitly so a careless rename
    /// or removal trips a clear failure (the menu-bar struct depends on
    /// each name).
    func test_allCases_includes_phase2_set() {
        let triggers: [MatronCommand] = [
            .newChat, .signOut, .findInChat, .slashCommand,
            .toggleSidebar, .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .verifyDevice, .showRecoveryKey, .refresh,
        ]
        for trigger in triggers {
            XCTAssertTrue(MatronCommand.allCases.contains(trigger), "missing \(trigger)")
        }
    }

    /// Posting a `.newChat` notification reaches a registered observer.
    /// This is the round-trip contract `MacChatView` (and Phase-3 views)
    /// rely on when wiring `.onReceive(...matronCommand(.case))`.
    func test_post_newChat_notifiesObserver() {
        let exp = expectation(description: "newChat observed")
        let observer = NotificationCenter.default.addObserver(
            forName: .matronCommand(.newChat), object: nil, queue: nil
        ) { _ in exp.fulfill() }
        NotificationCenter.default.post(name: .matronCommand(.newChat), object: nil)
        wait(for: [exp], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    /// `ChatCommands` is a `Commands` struct — instantiation alone is
    /// proof the menu-bar surface compiles. The actual menu items are
    /// validated by hand on first launch (no public hook to introspect a
    /// `CommandGroup`'s child buttons in unit tests).
    func test_chatCommands_compiles() {
        _ = ChatCommands()
    }
}
#endif
