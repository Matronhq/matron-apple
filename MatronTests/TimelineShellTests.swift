import XCTest
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
        for place in [TimelinePlace.quiet, .long, .finished] {
            let value = try XCTUnwrap(TimelineListRoute(place: place)).pathValue
            XCTAssertEqual(TimelineListRoute(pathValue: value)?.place, place)
            XCTAssertTrue(isAnyPathPrefixedRoute(value), value)
        }
        XCTAssertNil(TimelineListRoute(place: .week("2026-11-02")), "a week is the root, never pushed")
        XCTAssertNil(TimelineListRoute(pathValue: "timeline/elsewhere")?.place)
        XCTAssertTrue(isAnyPathPrefixedRoute("story/pj_a"))
    }

    func testOpeningAStoryOrAListTwiceStacksItOnce() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.pushTimelinePage(ProjectStoryRoute(id: "pj_a").pathValue)
        nav.pushTimelinePage(ProjectStoryRoute(id: "pj_a").pathValue)
        XCTAssertEqual(nav.missionsPath, ["story/pj_a"])
        nav.pushProject("pj_a")
        XCTAssertEqual(nav.missionsPath, ["story/pj_a", "project/pj_a"], "All details goes on top of the story")
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
}
