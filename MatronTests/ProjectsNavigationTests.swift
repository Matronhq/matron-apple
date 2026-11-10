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

    /// A tapped `matron://project/<n>` link: pushed on the stack of the tab
    /// it was tapped in, so Back returns to where the link sat.
    func testAProjectLinkOpensOnTheProjectsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["project/pj_1", "mission/ms_1"]
        nav.openPageLink(.project(id: "pj_2"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1", "project/pj_2"])

        nav.tab = .conversations
        nav.chatPath = ["c1"]
        nav.openPageLink(.project(id: "pj_3"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1", "project/pj_3"])
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1", "project/pj_2"], "Projects is left alone")
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

    /// A mission page on a chat stack opens its project on that same stack,
    /// so Back returns to the mission page rather than the Projects tab
    /// coming forward with no way back.
    func testOpenProjectFromAnotherTabPushesWhereTheUserIs() {
        let nav = AppShellNavigation()
        nav.tab = .conversations
        nav.chatPath = ["c1", "mission/ms_1"]
        nav.missionsPath = ["project/pj_9"]
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1", "project/pj_1"], "Back pops to the mission page")
        XCTAssertEqual(nav.missionsPath, ["project/pj_9"], "the Projects stack is left where it was")
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1", "project/pj_1"], "a double tap never stacks two")
    }

    func testOpenProjectIsInertWithoutMissions() {
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.openPageLink(.project(id: "pj_1"))
        XCTAssertEqual(nav.missionsPath, [])
        XCTAssertEqual(nav.chatPath, [])
        XCTAssertNotEqual(nav.tab, .missions)
    }

    // MARK: With the timeline shown

    /// With the Projects switch on and a journal that has the timeline,
    /// every way of opening a project pushes its new page, never today's.
    func testWithTheTimelineShownAProjectOpensItsNewPage() {
        let nav = AppShellNavigation()
        nav.projectsOpenAsStories = true
        nav.tab = .missions
        nav.handleProjectsHome(.openProject("pj_1"))
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"])
        nav.handleProjectsHome(.openProject("pj_1"))
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
        XCTAssertFalse(every.contains { ProjectRoute(pathValue: $0) != nil }, "today's project page is never pushed")
    }

    /// The mission page's project chip is still a breadcrumb: the page
    /// below is popped back to, past its sections and what they opened.
    func testWithTheTimelineShownAProjectAlreadyOnTheStackIsPoppedBackTo() {
        let nav = AppShellNavigation()
        nav.projectsOpenAsStories = true
        nav.tab = .missions
        nav.missionsPath = ["story/pj_1", "story-section/missions/pj_1", "mission/ms_1"]
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1"])

        // A page pushed before the journal answered is the same page.
        nav.missionsPath = ["project/pj_1", "mission/ms_1"]
        nav.pushProject("pj_1")
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"], "no second copy of the project")

        nav.missionsPath = ["story/pj_1", "story-section/missions/pj_1", "mission/ms_1"]
        nav.pushProject("pj_2")
        XCTAssertEqual(nav.missionsPath, ["story/pj_1", "story-section/missions/pj_1", "mission/ms_1", "story/pj_2"])
    }

    /// Switch off, or a journal without the timeline: today's page, as before.
    func testWithTheTimelineHiddenAProjectOpensTodaysPage() {
        let nav = AppShellNavigation()
        XCTAssertFalse(nav.projectsOpenAsStories, "off until the shell says the timeline is shown")
        nav.tab = .missions
        nav.pushProject("pj_1")
        nav.openPageLink(.project(id: "pj_2"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "project/pj_2"])
        XCTAssertEqual(AppShellNavigation.projectRoute("pj_1", asStory: false), "project/pj_1")
        XCTAssertEqual(AppShellNavigation.projectRoute("pj_1", asStory: true), "story/pj_1")
    }

    /// A project on any stack has the shell ask for the timeline, so a
    /// project opened from a chat needs no visit to Projects first.
    func testAProjectPageOnAnyStackIsNoticed() {
        let nav = AppShellNavigation()
        XCTAssertFalse(nav.showsAProjectPage)
        nav.chatPath = ["c1", "mission/ms_1", "item/it_1"]
        nav.missionsPath = ["timeline/quiet", MemoriesRoute.list]
        XCTAssertFalse(nav.showsAProjectPage)
        nav.chatPath = ["c1", "project/pj_1"]
        XCTAssertTrue(nav.showsAProjectPage)
        nav.chatPath = []
        for value in ["project/pj_1", "story/pj_1", "story-section/files/pj_1"] {
            for tab in [AppTab.coordinator, .decisions, .conversations, .missions, .search] {
                nav.setPath([value], on: tab)
                XCTAssertTrue(nav.showsAProjectPage, "\(value) on \(tab)")
                nav.setPath([], on: tab)
                XCTAssertFalse(nav.showsAProjectPage)
            }
        }
    }

    func testProjectRouteIsARouteNotAChat() {
        XCTAssertEqual(ProjectRoute(pathValue: "project/pj_1")?.id, "pj_1")
        XCTAssertTrue(isAnyPathPrefixedRoute("project/pj_1"))
        XCTAssertNil(ProjectRoute(pathValue: "mission/ms_1"))
    }
}
