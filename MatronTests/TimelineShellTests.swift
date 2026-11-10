import XCTest
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
@testable import Matron

/// The Projects timeline on iPad and iPhone, behind the `projects.timeline`
/// flag: with it on and the journal answering, the iPad lists the weeks
/// beside Projects and the iPhone's Projects root is the week page;
/// otherwise both keep the Projects home they have today. The state's reads
/// and what a place shows are shared and tested in MatronShared
/// (`TimelineHostStateTests`); this pins the iOS layout and navigation.
@MainActor
final class TimelineShellTests: XCTestCase {
    // MARK: Layout

    func testFlagOff_keepsTodaysSidebarAndRoot() {
        let state = TimelineHostState()
        XCTAssertNil(state.projectsShown(flagOn: false) { XCTFail("built with the flag off"); return Self.viewModel() })
        XCTAssertNil(state.viewModel, "nothing asks the journal")
        XCTAssertFalse(state.isShown)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: [], timelineShown: state.isShown),
                       .conversations)
        XCTAssertEqual(SplitShellRule.sidebarWidth(listing: .conversations), SplitShellRule.sidebarWidth)
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: true, timelineShown: state.isShown), .home)
    }

    func testFlagOnAndSupported_selectsTheTimelineSidebarAndThePhoneRoot() async {
        let state = TimelineHostState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        XCTAssertTrue(state.isShown)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: [], timelineShown: state.isShown),
                       .timeline)
        XCTAssertEqual(SplitShellRule.sidebarWidth(listing: .timeline), SplitShellRule.sidebarWidth(for: .decisions),
                       "as wide as For you")
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: true, timelineShown: state.isShown), .timeline)
    }

    func testUnsupportedOrNotYetAnswered_fallsBack() async {
        let state = TimelineHostState()
        let task = state.projectsShown(flagOn: true) { Self.viewModel(StubTimeline(supported: false)) }
        XCTAssertFalse(state.isShown, "not shown before the journal answers")
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: true, timelineShown: state.isShown), .home)
        await task?.value
        XCTAssertEqual(state.viewModel?.isSupported, false)
        XCTAssertFalse(state.isShown)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: [], timelineShown: state.isShown),
                       .conversations)
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: true, timelineShown: state.isShown), .home)
    }

    /// The timeline changes only the Projects page's list: Memories, which
    /// rides the same stack, and the other pages keep theirs.
    func testTheTimelineSidebarIsOnlyBesideProjects() {
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: [MemoriesRoute.list], timelineShown: true),
                       .conversations)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: ["story/pj_a"], timelineShown: true),
                       .timeline)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .decisions, missionsPath: [], timelineShown: true), .decisions)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .search, missionsPath: [], timelineShown: true), .search)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .conversations, missionsPath: [], timelineShown: true),
                       .conversations)
        // The same rule starts a timeline visit.
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.projectsPageShown)
        nav.openMemories()
        XCTAssertFalse(nav.projectsPageShown)
        nav.tab = .conversations
        XCTAssertFalse(nav.projectsPageShown)
    }

    /// A journal without `/projects` keeps the missions dashboard, whatever the timeline.
    func testAnOldJournalKeepsTheMissionsDashboard() {
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: false, timelineShown: false), .legacy)
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: nil, timelineShown: false), .home)
    }

    // MARK: iPhone

    /// With the week page as the root, the toolbar keeps Memories (the
    /// week picker is the title's menu); New project and the Ask stay with
    /// today's home and dashboard.
    func testTheWeekPageToolbarKeepsOnlyMemories() {
        XCTAssertEqual(ProjectsTabRoot.toolbarButtons(content: .timeline, canCreateProject: true, canAskCoordinator: true,
                                                      hasMemories: true), [.memories])
        XCTAssertEqual(ProjectsTabRoot.toolbarButtons(content: .home, canCreateProject: true, canAskCoordinator: true,
                                                      hasMemories: true), [.newProject, .ask, .memories])
        XCTAssertEqual(ProjectsTabRoot.toolbarButtons(content: .legacy, canCreateProject: false, canAskCoordinator: true,
                                                      hasMemories: true), [.ask, .memories])
        XCTAssertEqual(ProjectsTabRoot.toolbarButtons(content: .home, canCreateProject: false, canAskCoordinator: false,
                                                      hasMemories: false), [])
    }

    /// The iPhone's week page stays under a pushed list: it shows the last
    /// week picked while the view model reads the list.
    func testThePhonesWeekPageIsTheLastWeekPicked() async {
        let state = TimelineHostState()
        XCTAssertNil(TimelinePhoneRoot.place(state))
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        XCTAssertEqual(TimelinePhoneRoot.place(state), .week("2026-11-02"))
        state.select(.week("2026-10-26"))
        state.select(.finished)
        XCTAssertEqual(TimelinePhoneRoot.place(state), .week("2026-10-26"))
    }

    func testTheWeekPickerNamesTheWeeks() {
        let date = Date(timeIntervalSince1970: 0)
        let weeks = ["2026-11-02", "2026-10-26", "2026-10-19"].map {
            TimelineWeekSummary(week: $0, start: date, end: date, sentence: "", moved: 1)
        }
        XCTAssertEqual(TimelinePhoneRoot.weekChoices(weeks).map(\.title), ["This week", "Last week", "19 – 25 Oct"])
        XCTAssertEqual(TimelinePhoneRoot.weekChoices(weeks).map(\.week), ["2026-11-02", "2026-10-26", "2026-10-19"])
    }

    // MARK: Routes

    func testTheTimelinesPagesAreRoutesNotChats() throws {
        XCTAssertEqual(ProjectStoryRoute(id: "pj_a").pathValue, "story/pj_a")
        XCTAssertEqual(ProjectStoryRoute(pathValue: "story/pj_a")?.id, "pj_a")
        XCTAssertNil(ProjectRoute(pathValue: "story/pj_a"))
        for place in [TimelinePlace.projects, .quiet, .long, .finished] {
            let value = try XCTUnwrap(TimelineListRoute(place: place)).pathValue
            XCTAssertEqual(TimelineListRoute(pathValue: value)?.place, place)
            XCTAssertTrue(isAnyPathPrefixedRoute(value), value)
        }
        XCTAssertNil(TimelineListRoute(place: .week("2026-11-02")), "a week is the root, never pushed")
        XCTAssertNil(TimelineListRoute(pathValue: "timeline/elsewhere")?.place)
        XCTAssertTrue(isAnyPathPrefixedRoute("story/pj_a"))
    }

    /// A section of a project's page carries the project and the section.
    func testASectionRouteRoundTripsItsPath() {
        for section in ProjectSection.allCases {
            let route = ProjectSectionRoute(projectID: "pj_a", section: section)
            XCTAssertEqual(route.pathValue, "story-section/\(section.rawValue)/pj_a")
            XCTAssertEqual(ProjectSectionRoute(pathValue: route.pathValue), route)
            XCTAssertTrue(isAnyPathPrefixedRoute(route.pathValue), route.pathValue)
            XCTAssertNil(ProjectStoryRoute(pathValue: route.pathValue), "not the page itself")
            XCTAssertNil(ProjectRoute(pathValue: route.pathValue))
        }
        // A project id keeps whatever it holds.
        XCTAssertEqual(ProjectSectionRoute(pathValue: "story-section/files/pj/a")?.projectID, "pj/a")
        for junk in ["story-section/", "story-section/files", "story-section/files/", "story-section/elsewhere/pj_a",
                     "story-section//pj_a", "story/pj_a", "project/pj_a", "pj_a"] {
            XCTAssertNil(ProjectSectionRoute(pathValue: junk), junk)
        }
    }

    /// Whichever route carries it, a stack entry names a project's page or
    /// one of its sections.
    func testAProjectPageTargetReadsEveryProjectRoute() {
        XCTAssertEqual(ProjectPageTarget(pathValue: "project/pj_a"), ProjectPageTarget(projectID: "pj_a", section: nil))
        XCTAssertEqual(ProjectPageTarget(pathValue: "story/pj_a"), ProjectPageTarget(projectID: "pj_a", section: nil))
        XCTAssertEqual(ProjectPageTarget(pathValue: "story-section/history/pj_a"),
                       ProjectPageTarget(projectID: "pj_a", section: .history))
        for other in ["mission/ms_1", "item/it_1", "timeline/quiet", "story-section/elsewhere/pj_a", "c1", ""] {
            XCTAssertNil(ProjectPageTarget(pathValue: other), other)
        }
    }

    /// The page a stack entry shows, on every stack: the new page (or its
    /// section) only while the timeline is shown, else the project page
    /// there is today, whatever route was pushed before the answer came.
    func testAProjectShowsItsNewPageOnlyWhileTheTimelineIsShown() throws {
        let page = try XCTUnwrap(ProjectPageTarget(pathValue: "project/pj_a"))
        let story = try XCTUnwrap(ProjectPageTarget(pathValue: "story/pj_a"))
        let files = try XCTUnwrap(ProjectPageTarget(pathValue: "story-section/files/pj_a"))
        XCTAssertEqual(page.page(timelineShown: true), .summary(section: nil))
        XCTAssertEqual(story.page(timelineShown: true), .summary(section: nil))
        XCTAssertEqual(files.page(timelineShown: true), .summary(section: .files))
        for target in [page, story, files] {
            XCTAssertEqual(target.page(timelineShown: false), .todaysPage)
        }
    }

    /// Where a merged project's page goes: either of its two reads can
    /// say the project moved, and both lead to the one surviving project.
    /// Reads made for another project say nothing about this page.
    func testEitherReadOfAMergedProjectLeadsToTheSurvivor() {
        typealias Host = TimelineStoryHost
        XCTAssertNil(Host.redirectTarget(pageProjectID: "pj_1", readsBuiltFor: "pj_1", summaryRedirect: nil,
                                         detailProjectID: "pj_1"))
        XCTAssertNil(Host.redirectTarget(pageProjectID: "pj_1", readsBuiltFor: "pj_1", summaryRedirect: nil,
                                         detailProjectID: nil), "nothing read yet")
        XCTAssertEqual(Host.redirectTarget(pageProjectID: "pj_1", readsBuiltFor: "pj_1", summaryRedirect: "pj_2",
                                           detailProjectID: "pj_1"), "pj_2", "the page read says so")
        XCTAssertEqual(Host.redirectTarget(pageProjectID: "pj_1", readsBuiltFor: "pj_1", summaryRedirect: nil,
                                           detailProjectID: "pj_2"), "pj_2", "the project's own read says so")
        XCTAssertEqual(Host.redirectTarget(pageProjectID: "pj_1", readsBuiltFor: "pj_1", summaryRedirect: "pj_2",
                                           detailProjectID: "pj_2"), "pj_2")
        XCTAssertEqual(Host.redirectTarget(pageProjectID: "pj_1", readsBuiltFor: "pj_1", summaryRedirect: "pj_3",
                                           detailProjectID: "pj_2"), "pj_3", "the journal's answer first")
        XCTAssertNil(Host.redirectTarget(pageProjectID: "pj_2", readsBuiltFor: "pj_2", summaryRedirect: "pj_2",
                                         detailProjectID: "pj_2"), "already there")
        // A screen reused for another project, before its own reads begin.
        XCTAssertNil(Host.redirectTarget(pageProjectID: "pj_5", readsBuiltFor: "pj_1", summaryRedirect: "pj_2",
                                         detailProjectID: "pj_2"))
        XCTAssertNil(Host.redirectTarget(pageProjectID: "pj_5", readsBuiltFor: nil, summaryRedirect: nil,
                                         detailProjectID: "pj_1"))
    }

    /// What the new page draws: a journal without the project-page route
    /// shows the project page it has, before anything else.
    func testAJournalWithoutThePageRouteFallsBackToTodaysPage() {
        typealias Host = TimelineStoryHost
        XCTAssertEqual(Host.content(hasPage: false, isMissing: false, isUnsupported: true, loadFailed: false, section: nil),
                       .todaysPage)
        XCTAssertEqual(Host.content(hasPage: false, isMissing: false, isUnsupported: true, loadFailed: true,
                                    section: .files), .todaysPage)
        XCTAssertEqual(Host.content(hasPage: true, isMissing: false, isUnsupported: false, loadFailed: false, section: nil),
                       .summary)
        XCTAssertEqual(Host.content(hasPage: true, isMissing: false, isUnsupported: false, loadFailed: false,
                                    section: .history), .section(.history))
        // A failed re-read keeps the page on screen.
        XCTAssertEqual(Host.content(hasPage: true, isMissing: false, isUnsupported: false, loadFailed: true, section: nil),
                       .summary)
        XCTAssertEqual(Host.content(hasPage: false, isMissing: true, isUnsupported: false, loadFailed: false, section: nil),
                       .missing)
        XCTAssertEqual(Host.content(hasPage: false, isMissing: false, isUnsupported: false, loadFailed: true, section: nil),
                       .loadFailed)
        XCTAssertEqual(Host.content(hasPage: false, isMissing: false, isUnsupported: false, loadFailed: false,
                                    section: .missions), .loading)
    }

    /// A picture opens the image viewer over the project's pictures, a
    /// video the player, anything else where it was posted.
    func testHowAFileOfTheFilesSectionOpens() {
        let picture = Self.file(1, blob: "b1", type: "image/png")
        let again = Self.file(2, blob: "b1", type: "image/png")
        let video = Self.file(3, blob: "b2", type: "Video/MP4")
        let other = Self.file(4, blob: "b3", type: "application/pdf")
        let untyped = Self.file(5, blob: "b4", type: nil)
        let second = Self.file(6, blob: "b5", type: "image/jpeg")
        XCTAssertEqual(TimelineStoryHost.fileOpening(picture), .picture)
        XCTAssertEqual(TimelineStoryHost.fileOpening(video), .video)
        XCTAssertEqual(TimelineStoryHost.fileOpening(other), .source)
        XCTAssertEqual(TimelineStoryHost.fileOpening(untyped), .source)
        XCTAssertEqual(TimelineStoryHost.pictureBlobIDs([picture, video, again, other, untyped, second]), ["b1", "b5"],
                       "the grid's order, a picture attached twice once")
    }

    func testOpeningAStoryOrAListTwiceStacksItOnce() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.pushTimelinePage(ProjectStoryRoute(id: "pj_a").pathValue)
        nav.pushTimelinePage(ProjectStoryRoute(id: "pj_a").pathValue)
        XCTAssertEqual(nav.missionsPath, ["story/pj_a"])
        let files = ProjectSectionRoute(projectID: "pj_a", section: .files).pathValue
        nav.pushTimelinePage(files)
        nav.pushTimelinePage(files)
        XCTAssertEqual(nav.missionsPath, ["story/pj_a", "story-section/files/pj_a"], "a section is one level down")
    }

    // MARK: iPhone, all projects

    /// The week page's foot rows: all projects first, then "Worth a look".
    func testThePhoneRootOffersAllProjects() throws {
        XCTAssertEqual(TimelinePhoneRoot.footPlaces(showsAllProjects: true), [.projects, .quiet, .long, .finished])
        XCTAssertEqual(TimelinePhoneRoot.worthALookPlaces, [.quiet, .long, .finished])
        for place in TimelinePhoneRoot.footPlaces(showsAllProjects: true) {
            XCTAssertNotNil(TimelineListRoute(place: place), "\(place) pushes a list")
        }
        XCTAssertEqual(AppShellView.timelineListTitle(.projects), "All projects")
        XCTAssertEqual(AppShellView.timelineListTitle(.quiet), "Went quiet")
    }

    /// A journal without the all-projects list: only "Worth a look".
    func testThePhoneRootOffersNoAllProjectsWithoutTheList() {
        XCTAssertEqual(TimelinePhoneRoot.footPlaces(showsAllProjects: false), [.quiet, .long, .finished])
    }

    private static func file(_ seq: Int64, blob: String, type: String?) -> ProjectFile {
        ProjectFile(blobID: blob, contentType: type, source: .chat(convoID: "c1", seq: seq), postedAt: nil)
    }

    private static func viewModel(_ timeline: StubTimeline = StubTimeline()) -> TimelineViewModel {
        TimelineViewModel(timeline: timeline, askCoordinator: { _ in })
    }
}

/// A journal with two weeks and both stalled lists, or (`supported: false`)
/// one without the timeline routes.
private final class StubTimeline: TimelineProviding, @unchecked Sendable {
    private let supported: Bool

    init(supported: Bool = true) { self.supported = supported }

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        guard supported else { throw JournalAPIError.notFound }
        let date = Date(timeIntervalSince1970: 0)
        return (["2026-11-02", "2026-10-26"].map { TimelineWeekSummary(week: $0, start: date, end: date, sentence: "", moved: 1) },
                nil)
    }
    func timelineWeek(_ week: String) async throws -> TimelineWeek {
        TimelineWeek(week: week, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0), final: true)
    }
    func wentQuiet() async throws -> StalledList { StalledList(total: 3, rows: []) }
    func openLong() async throws -> StalledList { StalledList(total: 4, rows: []) }
    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        ([], nil)
    }
    func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList { throw JournalAPIError.notFound }
    func timelineProject(_ id: String) async throws -> TimelineProjectPage { throw JournalAPIError.notFound }
    func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?) { throw JournalAPIError.notFound }
}
