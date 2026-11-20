import XCTest
import MatronModels
@testable import Matron

@MainActor
final class ProjectsNavigationTests: XCTestCase {
    func testAProjectCardPushesTheProjectPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"])
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"], "a double tap never stacks two pages")
    }

    func testAMissionRowPushesTheMissionPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.pushProject("pj_1")
        nav.pushMission("ms_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1"])
    }

    /// Review I1: a mission page's project chip is a breadcrumb — when
    /// that project is already below on the stack, go back to it rather
    /// than stack a second copy of its page.
    func testPushingAProjectAlreadyOnTheStackPopsBackToIt() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["story/pj_1", "mission/ms_1"]
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"])

        nav.missionsPath = ["story/pj_1", "mission/ms_1", "story/pj_2", "mission/ms_2"]
        nav.pushProject("pj_2")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1", "story/pj_2"],
                       "pops to the nearest copy, keeping what sits beneath it")

        nav.missionsPath = ["story/pj_1", "mission/ms_1"]
        nav.pushProject("pj_3")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1", "story/pj_3"],
                       "a project not on the stack still pushes")
    }

    /// A tapped `matron://mission/<n>` link: the page pushes onto the stack
    /// of the tab the link was tapped in, and never twice.
    func testAMissionLinkPushesOntoTheCurrentTabsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["story/pj_1"]
        nav.openPageLink(.mission(id: "ms_1"))
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1"])
        nav.openPageLink(.mission(id: "ms_1"))
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1"], "a double tap never stacks two pages")

        nav.tab = .conversations
        nav.chatPath = ["c1"]
        nav.openPageLink(.mission(id: "ms_2"))
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_2"])
        XCTAssertEqual(nav.tab, .conversations, "Back returns to the chat the link sat in")
    }

    /// A tapped `matron://project/<n>` link: pushed on the stack of the tab
    /// it was tapped in, so Back returns to where the link sat.
    func testAProjectLinkOpensOnTheProjectsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["story/pj_1", "mission/ms_1"]
        nav.openPageLink(.project(id: "pj_2"))
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1", "story/pj_2"])

        nav.tab = .conversations
        nav.chatPath = ["c1"]
        nav.openPageLink(.project(id: "pj_3"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1", "story/pj_3"])
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "mission/ms_1", "story/pj_2"], "Projects is left alone")
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

    /// A mission page on a chat stack opens its project on that same stack,
    /// so Back returns to the mission page rather than the Projects tab
    /// coming forward with no way back.
    func testOpenProjectFromAnotherTabPushesWhereTheUserIs() {
        let nav = AppShellNavigation()
        nav.tab = .conversations
        nav.chatPath = ["c1", "mission/ms_1"]
        nav.missionsPath = ["story/pj_9"]
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1", "story/pj_1"], "Back pops to the mission page")
        XCTAssertEqual(nav.missionsPath, ["story/pj_9"], "the Projects stack is left where it was")
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1", "story/pj_1"], "a double tap never stacks two")
    }

    func testOpenProjectIsInertWithoutMissions() {
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.missionsPath, [])
        XCTAssertEqual(nav.chatPath, [])
        XCTAssertNotEqual(nav.tab, .missions)
    }

    // MARK: Project pages

    /// Every way of opening a project pushes its page (`story/`), never
    /// the `project/` route a link names.
    func testAProjectOpensItsPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"])
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"], "a double tap never stacks two pages")
        nav.pushProject("pj_2")
        nav.openPageLink(.project(id: "pj_3"))
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "story/pj_2", "story/pj_3"])

        // A link in a chat, a mission page's chip on another tab's stack.
        nav.tab = .conversations
        nav.chatPath = ["c1", "mission/ms_1"]
        nav.openPageLink(.project(id: "pj_4"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1", "story/pj_4"], "Back pops to the mission page")
        for tab in [AppTab.decisions, .search, .coordinator] {
            nav.pushProject("pj_5", on: tab)
            XCTAssertEqual(nav.path(of: tab), ["story/pj_5"], "\(tab)")
        }
        let every = nav.missionsPath + nav.chatPath + nav.decisionsPath + nav.searchPath + nav.coordinatorPath
        XCTAssertFalse(every.contains { ProjectRoute(pathValue: $0) != nil }, "a link's route is never pushed")
    }

    /// The mission page's project chip is still a breadcrumb: the page
    /// below is popped back to, past its sections and what they opened.
    func testAProjectAlreadyOnTheStackIsPoppedBackTo() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["story/pj_1", "story-section/missions/pj_1", "mission/ms_1"]
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"])

        // A page pushed by its link's route is the same page.
        nav.missionsPath = ["project/pj_1", "mission/ms_1"]
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"], "no second copy of the project")

        nav.missionsPath = ["story/pj_1", "story-section/missions/pj_1", "mission/ms_1"]
        nav.pushProject("pj_2")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "story-section/missions/pj_1", "mission/ms_1", "story/pj_2"])
    }

    /// A project merged into another while its page is open: the page's
    /// entry, and any section of it above, become the surviving project's,
    /// in place. Back still leads where it led, and nothing else moves.
    func testAMergedProjectsPageBecomesTheSurvivingProjects() {
        typealias Target = ProjectPageTarget
        XCTAssertEqual(Target.stack(["story/pj_1"], following: "pj_1", to: "pj_2"), ["story/pj_2"])
        XCTAssertEqual(Target.stack(["timeline/quiet", "story/pj_1", "story-section/history/pj_1"],
                                    following: "pj_1", to: "pj_2"),
                       ["timeline/quiet", "story/pj_2", "story-section/history/pj_2"], "the section follows its page")
        XCTAssertEqual(Target.stack(["c1", "project/pj_1"], following: "pj_1", to: "pj_2"), ["c1", "project/pj_2"],
                       "a page pushed by its link's route is the same page")
        XCTAssertEqual(Target.stack(["story/pj_3", "mission/ms_1", "story/pj_1", "mission/ms_2"],
                                    following: "pj_1", to: "pj_2"),
                       ["story/pj_3", "mission/ms_1", "story/pj_2", "mission/ms_2"], "other pages stay as they are")
        XCTAssertEqual(Target.stack(["story/pj_2", "story/pj_1"], following: "pj_1", to: "pj_2"), ["story/pj_2"],
                       "never two copies of one page in a row")
        XCTAssertEqual(Target.stack(["story/pj_2", "mission/ms_1", "story/pj_1"], following: "pj_1", to: "pj_2"),
                       ["story/pj_2", "mission/ms_1", "story/pj_2"])
        let untouched = ["story/pj_3", "story-section/files/pj_3", "mission/pj_1", "pj_1"]
        XCTAssertEqual(Target.stack(untouched, following: "pj_1", to: "pj_2"), untouched,
                       "only a project's page or section names it")
        XCTAssertEqual(Target.stack(["story/pj_1"], following: "pj_1", to: "pj_1"), ["story/pj_1"])
        XCTAssertEqual(Target.stack(["story/pj_1", "story/pj_2"], following: "pj_1", to: "pj_2"), ["story/pj_2"],
                       "the survivor's own page after the merged one is not a second copy")
        XCTAssertEqual(Target.stack(["project/pj_1", "story/pj_2"], following: "pj_1", to: "pj_2"), ["project/pj_2"],
                       "either route form of one page counts as the same page")
    }

    /// The same through the shell's own stack: said twice (each of the
    /// page's two reads can say it), the second changes nothing.
    func testFollowingAMergeOnTheProjectsStackIsSaidOnce() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.pushProject("pj_1")
        nav.setPath(ProjectPageTarget.stack(nav.missionsPath, following: "pj_1", to: "pj_2"), on: .missions)
        XCTAssertEqual(nav.missionsPath, ["story/pj_2"])
        nav.setPath(ProjectPageTarget.stack(nav.missionsPath, following: "pj_1", to: "pj_2"), on: .missions)
        XCTAssertEqual(nav.missionsPath, ["story/pj_2"])
        nav.pushProject("pj_2")
        XCTAssertEqual(nav.missionsPath, ["story/pj_2"], "the surviving project is the page on the stack")
    }

    func testProjectRouteIsARouteNotAChat() {
        XCTAssertEqual(ProjectRoute(pathValue: "project/pj_1")?.id, "pj_1")
        XCTAssertTrue(isAnyPathPrefixedRoute("project/pj_1"))
        XCTAssertNil(ProjectRoute(pathValue: "mission/ms_1"))
    }
}
