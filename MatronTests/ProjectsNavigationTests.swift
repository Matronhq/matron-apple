import XCTest
import MatronModels
@testable import Matron

@MainActor
final class ProjectsNavigationTests: XCTestCase {
    func testAProjectCardPushesTheProjectPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleProjectsHome(.openProject("pj_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"])
        nav.handleProjectsHome(.openProject("pj_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"], "a double tap never stacks two pages")
    }

    func testAMissionRowPushesTheMissionPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleProjectsHome(.openProject("pj_1"))
        nav.handleProjectsHome(.openMission("ms_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1"])
    }

    func testTheHostHandlesNewProjectAndMove() {
        let nav = AppShellNavigation()
        nav.handleProjectsHome(.newProject)
        nav.handleProjectsHome(.moveMission(missionID: "ms_1", projectID: "pj_1"))
        XCTAssertEqual(nav.missionsPath, [])
    }

    /// A mission page on a chat stack opens its project on the Projects tab.
    func testOpenProjectFromAnotherTabSwitchesToProjects() {
        let nav = AppShellNavigation()
        nav.tab = .conversations
        nav.chatPath = ["c1", "mission/ms_1"]
        nav.openProject("pj_1")
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"])
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1"], "the chat stack is left where it was")
    }

    func testOpenProjectIsInertWithoutMissions() {
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.openProject("pj_1")
        XCTAssertEqual(nav.missionsPath, [])
        XCTAssertNotEqual(nav.tab, .missions)
    }

    func testProjectRouteIsARouteNotAChat() {
        XCTAssertEqual(ProjectRoute(pathValue: "project/pj_1")?.id, "pj_1")
        XCTAssertTrue(isAnyPathPrefixedRoute("project/pj_1"))
        XCTAssertNil(ProjectRoute(pathValue: "mission/ms_1"))
    }
}
