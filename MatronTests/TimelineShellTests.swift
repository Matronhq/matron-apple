import XCTest
import SwiftUI
import MatronJournal
import MatronModels
import MatronViewModels
@testable import Matron

/// The Projects timeline on iPad and iPhone, behind the `projects.timeline`
/// flag: with it on and the journal answering, the iPad lists the weeks
/// beside Projects and the iPhone's Projects root is the week page;
/// otherwise both keep the Projects home they have today.
@MainActor
final class TimelineShellTests: XCTestCase {
    // MARK: Layout

    func testFlagOff_keepsTodaysSidebarAndRoot() {
        let state = TimelineShellState()
        XCTAssertNil(state.projectsShown(flagOn: false) { XCTFail("built with the flag off"); return Self.viewModel() })
        XCTAssertNil(state.viewModel, "nothing asks the journal")
        XCTAssertFalse(state.isShown)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: [], timelineShown: state.isShown),
                       .conversations)
        XCTAssertEqual(SplitShellRule.sidebarWidth(listing: .conversations), SplitShellRule.sidebarWidth)
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: true, timelineShown: state.isShown), .home)
    }

    func testFlagOnAndSupported_selectsTheTimelineSidebarAndThePhoneRoot() async {
        let state = TimelineShellState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        XCTAssertTrue(state.isShown)
        XCTAssertEqual(SplitShellRule.sidebarList(for: .missions, missionsPath: [], timelineShown: state.isShown),
                       .timeline)
        XCTAssertEqual(SplitShellRule.sidebarWidth(listing: .timeline), SplitShellRule.sidebarWidth(for: .decisions),
                       "as wide as For you")
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: true, timelineShown: state.isShown), .timeline)
    }

    func testUnsupportedOrNotYetAnswered_fallsBack() async {
        let state = TimelineShellState()
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
    }

    /// A journal without `/projects` keeps the missions dashboard, whatever the timeline.
    func testAnOldJournalKeepsTheMissionsDashboard() {
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: false, timelineShown: false), .legacy)
        XCTAssertEqual(ProjectsTabRoot.content(projectsSupported: nil, timelineShown: false), .home)
    }

    func testTheFlagIsTheDefaultsKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TimelineShellTests"))
        defaults.removePersistentDomain(forName: "TimelineShellTests")
        defer { defaults.removePersistentDomain(forName: "TimelineShellTests") }
        XCTAssertFalse(TimelineShellState.flagOn(defaults))
        defaults.set(true, forKey: "projects.timeline")
        XCTAssertTrue(TimelineShellState.flagOn(defaults))
    }

    // MARK: Reads

    func testFlagOn_buildsOnce_loadsTheCounts_andALaterVisitReReads() async {
        let state = TimelineShellState()
        let timeline = StubTimeline()
        var built = 0
        let build = {
            built += 1
            return Self.viewModel(timeline)
        }
        await state.projectsShown(flagOn: true, build: build)?.value
        XCTAssertEqual(state.place, .week("2026-11-02"))
        XCTAssertEqual(state.viewModel?.quiet?.total, 3, "the counts load with the timeline")
        XCTAssertEqual(state.viewModel?.long?.total, 4)
        await state.projectsShown(flagOn: true, build: build)?.value
        XCTAssertEqual(built, 1)
        XCTAssertEqual(timeline.weeksReads, 2, "a later visit re-reads")
        XCTAssertEqual(timeline.quietReads, 2, "and its counts")
    }

    /// An old journal's 404 is not asked again on every visit.
    func testALaterVisitToAnUnsupportedJournalReadsNothing() async {
        let state = TimelineShellState()
        let timeline = StubTimeline(supported: false)
        await state.projectsShown(flagOn: true) { Self.viewModel(timeline) }?.value
        XCTAssertNil(state.projectsShown(flagOn: true) { XCTFail("built twice"); return Self.viewModel() })
        XCTAssertEqual(timeline.weeksReads, 1)
        XCTAssertEqual(timeline.quietReads, 0, "no counts for a journal without the timeline")
    }

    /// Pull to refresh re-reads the page and the counts.
    func testRefreshReReadsThePageAndTheCounts() async {
        let state = TimelineShellState()
        let timeline = StubTimeline()
        await state.projectsShown(flagOn: true) { Self.viewModel(timeline) }?.value
        await state.refresh()
        XCTAssertEqual(timeline.weeksReads, 2)
        XCTAssertEqual(timeline.quietReads, 2)
    }

    // MARK: iPhone

    /// The iPhone's week page stays under a pushed list: the week it shows
    /// is the last one picked, while the view model reads the list.
    func testThePhonesWeekIsTheLastOnePicked() async {
        let state = TimelineShellState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        XCTAssertEqual(state.week, "2026-11-02", "the newest week first")
        state.select(.week("2026-10-26"))
        XCTAssertEqual(state.week, "2026-10-26")
        state.select(.finished)
        XCTAssertEqual(state.place, .finished)
        XCTAssertEqual(state.week, "2026-10-26")
    }

    func testTheWeekPickerNamesTheWeeks() {
        let date = Date(timeIntervalSince1970: 0)
        let weeks = ["2026-11-02", "2026-10-26", "2026-10-19"].map {
            TimelineWeekSummary(week: $0, start: date, end: date, sentence: "", moved: 1)
        }
        XCTAssertEqual(TimelinePhoneRoot.weekChoices(weeks).map(\.title), ["This week", "Last week", "19 – 25 Oct"])
        XCTAssertEqual(TimelinePhoneRoot.weekChoices(weeks).map(\.week), ["2026-11-02", "2026-10-26", "2026-10-19"])
    }

    /// The week page never shows another week's cards.
    func testTheWeekPageShowsOnlyTheChosenWeek() {
        let loaded = StubTimeline.week("2026-11-02")
        XCTAssertEqual(TimelinePlacePage<EmptyView>.shownWeek(loaded, for: .week("2026-11-02")), loaded)
        XCTAssertNil(TimelinePlacePage<EmptyView>.shownWeek(loaded, for: .week("2026-10-26")))
        XCTAssertNil(TimelinePlacePage<EmptyView>.shownWeek(loaded, for: .quiet))
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
/// one without the timeline routes. Counts its reads.
private final class StubTimeline: TimelineProviding, @unchecked Sendable {
    private let supported: Bool
    private let lock = NSLock()
    private var weeks = 0
    private var quiet = 0

    init(supported: Bool = true) { self.supported = supported }

    var weeksReads: Int { lock.withLock { weeks } }
    var quietReads: Int { lock.withLock { quiet } }

    static func week(_ key: String) -> TimelineWeek {
        TimelineWeek(week: key, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0), final: true)
    }

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        lock.withLock { weeks += 1 }
        guard supported else { throw JournalAPIError.notFound }
        let date = Date(timeIntervalSince1970: 0)
        return (["2026-11-02", "2026-10-26"].map { TimelineWeekSummary(week: $0, start: date, end: date, sentence: "", moved: 1) },
                nil)
    }
    func timelineWeek(_ week: String) async throws -> TimelineWeek { Self.week(week) }
    func wentQuiet() async throws -> StalledList {
        lock.withLock { quiet += 1 }
        return StalledList(total: 3, rows: [])
    }
    func openLong() async throws -> StalledList { StalledList(total: 4, rows: []) }
    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        ([], nil)
    }
}
