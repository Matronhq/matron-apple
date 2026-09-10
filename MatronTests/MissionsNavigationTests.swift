import XCTest
@testable import Matron

@MainActor
final class MissionsNavigationTests: XCTestCase {
    func testTabOrderIsCoordinatorMissionsDecisionsConversations() {
        XCTAssertEqual(AppTab.allCases, [.coordinator, .missions, .decisions, .conversations])
    }

    /// Both routes ride the one `PathPrefixedRoute` round-trip, and their
    /// prefixes are disjoint — which is what lets a single `[String]` stack
    /// carry conversations, items and missions and decode them by trying
    /// each route in turn.
    func testPathPrefixedRoutesRoundTripAndRejectEachOther() {
        XCTAssertEqual(MissionRoute(id: "ms_1").pathValue, "mission/ms_1")
        XCTAssertEqual(MissionRoute(pathValue: "mission/ms_1"), MissionRoute(id: "ms_1"))
        XCTAssertEqual(ItemRoute(id: "it_1").pathValue, "item/it_1")
        XCTAssertEqual(ItemRoute(pathValue: "item/it_1"), ItemRoute(id: "it_1"))

        XCTAssertNil(MissionRoute(pathValue: "ms_1"), "a bare conversation id is not a mission route")
        XCTAssertNil(ItemRoute(pathValue: "cv_1"), "nor an item route")
        XCTAssertNil(MissionRoute(pathValue: "mission/"), "an empty id is not a route")
        XCTAssertNil(ItemRoute(pathValue: "item/"))
        XCTAssertNil(MissionRoute(pathValue: "item/it_1"), "an item route is not a mission route")
        XCTAssertNil(ItemRoute(pathValue: "mission/ms_1"), "and a mission route is not an item route")
    }

    func testOpenMissionSelectsTheTabAndReplacesItsPath() {
        let nav = AppShellNavigation()
        nav.missionsPath = ["mission/ms_old", "item/it_1"]
        nav.openMission("ms_1")
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1"])
    }

    func testPushMissionAppendsWithoutChangingTheTab() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.openMission("ms_1")
        nav.pushMission("ms_2")
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1", "mission/ms_2"])
    }

    /// A milestone tap hands off to Conversations and pushes, exactly as a
    /// Decisions origin link does — so Back returns to the mission page.
    func testOpenConversationFromMissionsSwitchesTabThenPushes() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.openConversation(fromMissions: "c1")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1"])
        // Idempotent on the same target.
        nav.openConversation(fromMissions: "c1")
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    /// The coordinator conversation always goes to its own tab, whoever
    /// asked — otherwise two `ChatView`s share one cached view model.
    func testOpenConversationFromMissionsRoutesTheCoordinatorToItsTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "c-coord"
        nav.openConversation(fromMissions: "c-coord")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
        XCTAssertEqual(nav.chatPath, [])
    }

    func testSwipeAtRootWalksTheNewBarOrder() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.swipeRoot(translation: .init(width: -120, height: 5)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: .init(width: 120, height: 5)))
        XCTAssertEqual(nav.tab, .missions)
    }

    func testIsAtRootCoversTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.isAtRoot)
        nav.pushMission("ms_1")
        XCTAssertFalse(nav.isAtRoot)
    }
}
