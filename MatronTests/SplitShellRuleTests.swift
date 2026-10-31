import XCTest
import SwiftUI
@testable import Matron

/// iPad layout: which shell a window gets, how the split shell's detail
/// stacks keep the page chosen in the sidebar, and when the tracker sits
/// beside the chat.
@MainActor
final class SplitShellRuleTests: XCTestCase {
    func test_splitShell_onlyOnAnIPadAtRegularWidthWithRoom() {
        XCTAssertTrue(SplitShellRule.usesSplitShell(isPad: true, horizontalSizeClass: .regular, width: 820))
        XCTAssertTrue(SplitShellRule.usesSplitShell(isPad: true, horizontalSizeClass: .regular, width: 1366))
        // Every iPhone keeps the tab bar, even a large one in landscape.
        XCTAssertFalse(SplitShellRule.usesSplitShell(isPad: false, horizontalSizeClass: .regular, width: 956))
        // A compact Split View or Slide Over window keeps it too.
        XCTAssertFalse(SplitShellRule.usesSplitShell(isPad: true, horizontalSizeClass: .compact, width: 820))
        // Regular but too narrow for the sidebar and a readable chat.
        XCTAssertFalse(SplitShellRule.usesSplitShell(isPad: true, horizontalSizeClass: .regular, width: 690))
        XCTAssertFalse(SplitShellRule.usesSplitShell(isPad: true, horizontalSizeClass: nil, width: 1180))
    }

    func test_keepingRoot_stopsAPopAtTheChosenPage() {
        XCTAssertEqual(SplitShellRule.keepingRoot([], old: ["a", "b"]), ["a"])
        XCTAssertEqual(SplitShellRule.keepingRoot(["a"], old: ["a", "b"]), ["a"])
        XCTAssertEqual(SplitShellRule.keepingRoot(["c"], old: ["a"]), ["c"])
        XCTAssertEqual(SplitShellRule.keepingRoot([], old: []), [])
    }

    func test_sidebar_isWiderForTheCardLists() {
        XCTAssertEqual(SplitShellRule.sidebarWidth(for: .conversations), SplitShellRule.sidebarWidth)
        XCTAssertEqual(SplitShellRule.sidebarWidth(for: .decisions), SplitShellRule.wideSidebarWidth)
        XCTAssertEqual(SplitShellRule.sidebarWidth(for: .search), SplitShellRule.wideSidebarWidth)
    }

    func test_trackerAlongside_onlyInTheSplitShellWhenItFits() {
        let fits = ChatPagerModel.trackerPaneWidth + ChatPagerModel.minChatWidthBesideTracker
        XCTAssertTrue(ChatPagerModel.showsTrackerAlongside(inSplitShell: true, width: fits, paneHidden: false))
        XCTAssertFalse(ChatPagerModel.showsTrackerAlongside(inSplitShell: true, width: fits - 1, paneHidden: false))
        XCTAssertFalse(ChatPagerModel.showsTrackerAlongside(inSplitShell: false, width: 2000, paneHidden: false))
        XCTAssertFalse(ChatPagerModel.showsTrackerAlongside(inSplitShell: true, width: 2000, paneHidden: true))
    }
}
