import XCTest
import MatronModels
@testable import Matron

/// Spec 2026-09-28 §3.1 / §3.8: every dashboard tap routes through
/// `AppShellNavigation.handleDashboard`.
@MainActor
final class MissionsDashboardNavigationTests: XCTestCase {
    func testACardPushesTheMissionPageOnTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleDashboard(.openMission("ms_1"))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1"])
        nav.handleDashboard(.openMission("ms_1"))
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1"], "a double tap never stacks two pages")
    }

    /// Mission 7047: the chat is pushed onto the Missions stack, so Back
    /// returns to the dashboard.
    func testASessionOpensItsChatOnTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleDashboard(.openSession("c1"))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["c1"])
        XCTAssertEqual(nav.chatPath, [])
    }

    /// The Coordinator can be on a mission; its chat belongs to its tab.
    func testTheCoordinatorsSessionSelectsTheCoordinatorTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "c-coord"
        nav.tab = .missions
        nav.handleDashboard(.openSession("c-coord"))
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, [])
    }

    func testANeedsYouRowPushesTheItemOnTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleDashboard(.openItem("it_1"))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["item/it_1"])
        nav.handleDashboard(.openItem("it_1"))
        XCTAssertEqual(nav.missionsPath, ["item/it_1"], "a double tap never stacks two item pages")
    }

    /// A mission page's item row goes through the same push.
    func testPushingTheSameItemTwiceStacksOnePage() {
        let nav = AppShellNavigation()
        nav.pushMission("ms_1")
        nav.pushMissionItem("it_1")
        nav.pushMissionItem("it_1")
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1", "item/it_1"])
        nav.pushMissionItem("it_2")
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1", "item/it_1", "item/it_2"], "a different item still pushes")
    }
}
