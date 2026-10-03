import XCTest
@testable import Matron

/// The one-tap way out of a deep stack (mission 7047): the tab bar is
/// hidden under anything pushed, so several pages deep there must be a
/// way back to the tab's root that is not one Back per page.
@MainActor
final class StackExitTests: XCTestCase {
    func test_offeredFromTheSecondPushedPageOn() {
        XCTAssertFalse(StackExit.isOffered(depth: 0), "the root has the tab bar")
        XCTAssertFalse(StackExit.isOffered(depth: 1), "one page deep, Back already leads to the root")
        XCTAssertTrue(StackExit.isOffered(depth: 2))
        XCTAssertTrue(StackExit.isOffered(depth: 7))
    }

    func test_label_namesTheTab() {
        XCTAssertEqual(StackExit.label(rootName: "Projects"), "Back to Projects")
    }

    /// What the button does, through the same setter the stack bindings
    /// use: the stack it is on empties, the tab stays, and the other
    /// stacks keep their pages.
    func test_clearingADeepStack_landsOnThatTabsRoot_andLeavesTheOthers() {
        for tab in AppTab.allCases {
            let nav = AppShellNavigation()
            nav.coordinatorConvoID = "!coord:s"
            for other in AppTab.allCases where other != tab {
                nav.setPath(["!\(other):s", "item/it_\(other)"], on: other)
            }
            nav.tab = tab
            nav.setPath(["!a:s", "mission/m1", "!b:s", "item/it_1", "!c:s"], on: tab)

            nav.setPath([], on: tab)

            XCTAssertEqual(nav.tab, tab)
            XCTAssertEqual(nav.path(of: tab), [])
            XCTAssertTrue(nav.isAtRoot, "the tab bar shows at the root")
            for other in AppTab.allCases where other != tab {
                XCTAssertEqual(nav.path(of: other), ["!\(other):s", "item/it_\(other)"])
            }
        }
    }

    /// SwiftUI bar items are not readable from a unit-test host (see
    /// `CoordinatorTabViewTests`), so this pins the source contract: each
    /// of the four stacks states the exit on its destinations, exactly
    /// once, so no pushed page is without it.
    func test_everyStackStatesTheExitOnItsDestinations() throws {
        let stacks = [
            ("Matron/App/AppShellView.swift", ["Decisions", "Projects"]),
            ("Matron/Features/ChatList/ChatListView.swift", ["Conversations"]),
            ("Matron/Features/Coordinator/CoordinatorTabView.swift", ["the Coordinator"]),
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (file, names) in stacks {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let destinations = source.components(separatedBy: ".navigationDestination(for:").count - 1
            XCTAssertEqual(destinations, names.count, "\(file): a new stack destination needs the exit too")
            for name in names {
                let exit = ".leadsBackToTheRoot(named: \"\(name)\")"
                XCTAssertEqual(source.components(separatedBy: exit).count - 1, 1, "\(file): \(name)")
            }
        }
    }
}
