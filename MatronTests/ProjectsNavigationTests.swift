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

    /// Review I1: a mission page's project chip is a breadcrumb — when
    /// that project is already below on the stack, go back to it rather
    /// than stack a second copy of its page.
    func testPushingAProjectAlreadyOnTheStackPopsBackToIt() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["project/pj_1", "mission/ms_1"]
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"])

        nav.missionsPath = ["project/pj_1", "mission/ms_1", "project/pj_2", "mission/ms_2"]
        nav.pushProject("pj_2")
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1", "project/pj_2"],
                       "pops to the nearest copy, keeping what sits beneath it")

        nav.missionsPath = ["project/pj_1", "mission/ms_1"]
        nav.pushProject("pj_3")
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1", "project/pj_3"],
                       "a project not on the stack still pushes")
    }

    /// A tapped `matron://mission/<n>` link: the page pushes onto the stack
    /// of the tab the link was tapped in, and never twice.
    func testAMissionLinkPushesOntoTheCurrentTabsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["project/pj_1"]
        nav.openPageLink(.mission(id: "ms_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1"])
        nav.openPageLink(.mission(id: "ms_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1"], "a double tap never stacks two pages")

        nav.tab = .conversations
        nav.chatPath = ["c1"]
        nav.openPageLink(.mission(id: "ms_2"))
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_2"])
        XCTAssertEqual(nav.tab, .conversations, "Back returns to the chat the link sat in")
    }

    /// A tapped `matron://project/<n>` link: pushed on the Projects stack,
    /// and from any other tab the Projects tab comes forward on it.
    func testAProjectLinkOpensOnTheProjectsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["project/pj_1", "mission/ms_1"]
        nav.openPageLink(.project(id: "pj_2"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1", "project/pj_2"])

        nav.tab = .conversations
        nav.chatPath = ["c1"]
        nav.openPageLink(.project(id: "pj_3"))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["project/pj_3"])
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    func testPageLinksDoNothingWithoutMissionSupport() {
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.chatPath = ["c1"]
        nav.openPageLink(.mission(id: "ms_1"))
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.chatPath, ["c1"])
        XCTAssertEqual(nav.missionsPath, [])
        XCTAssertEqual(nav.tab, .conversations)
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
