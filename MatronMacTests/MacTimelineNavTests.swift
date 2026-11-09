import XCTest
import MatronJournal
import MatronModels
import MatronViewModels
@testable import MatronMac

/// The Projects timeline on the Mac, behind the `projects.timeline` flag:
/// with it on and the journal answering, Projects gets a list column and
/// its places join the Back/Forward history; otherwise Projects stays as
/// it is today.
@MainActor
final class MacTimelineNavTests: XCTestCase {
    private let week = TimelinePlace.week("2026-11-02")

    // MARK: Layout

    func testFlagOff_projectsStayFullWidth() {
        let shown = MacTimelineNav.isShown(flagOn: false, isSupported: true)
        XCTAssertFalse(shown)
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions, timelineShown: shown))
        XCTAssertEqual(MacChatListView.sidebarWidths(for: .missions, timelineShown: shown).ideal, MacNavColumn.width)
    }

    func testFlagOnAndSupported_projectsGetAListColumnAsWideAsForYou() {
        let shown = MacTimelineNav.isShown(flagOn: true, isSupported: true)
        XCTAssertTrue(shown)
        XCTAssertFalse(MacChatListView.showsNavColumnOnly(.missions, timelineShown: shown))
        let projects = MacChatListView.sidebarWidths(for: .missions, timelineShown: shown)
        let decisions = MacChatListView.sidebarWidths(for: .decisions)
        XCTAssertEqual(projects.min, decisions.min)
        XCTAssertEqual(projects.ideal, decisions.ideal)
        XCTAssertEqual(projects.max, decisions.max)
        XCTAssertFalse(MacChatListView.headerCarriesNavigation(nav: .missions, timelineShown: shown,
                                                               columnVisibility: .automatic),
                       "the list column's toolbar carries Back/Forward")
    }

    func testFlagOnButUnsupportedOrNotYetAnswered_keepsTodaysLayout() {
        for supported in [false, nil] as [Bool?] {
            let shown = MacTimelineNav.isShown(flagOn: true, isSupported: supported)
            XCTAssertFalse(shown)
            XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions, timelineShown: shown))
        }
    }

    /// The timeline changes only the Projects entry.
    func testTheTimelineLeavesTheOtherEntriesAlone() {
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.coordinator, timelineShown: true))
        XCTAssertFalse(MacChatListView.showsNavColumnOnly(.decisions, timelineShown: true))
    }

    func testTheFlagIsTheDefaultsKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacTimelineNavTests"))
        defaults.removePersistentDomain(forName: "MacTimelineNavTests")
        defer { defaults.removePersistentDomain(forName: "MacTimelineNavTests") }
        XCTAssertFalse(MacTimelineNav.flagOn(defaults))
        defaults.set(true, forKey: "projects.timeline")
        XCTAssertTrue(MacTimelineNav.flagOn(defaults))
    }

    /// Flag off: no view model, so nothing asks the journal.
    func testFlagOff_buildsNoViewModel() {
        let state = MacTimelineState()
        var built = 0
        let task = state.projectsShown(flagOn: false) {
            built += 1
            return TimelineViewModel(timeline: StubTimeline(), askCoordinator: { _ in })
        }
        XCTAssertNil(task)
        XCTAssertEqual(built, 0)
        XCTAssertNil(state.viewModel)
        XCTAssertFalse(state.isShown)
    }

    func testFlagOn_buildsTheViewModelOnce_andShowsOnceTheJournalAnswers() async {
        let state = MacTimelineState()
        let timeline = StubTimeline()
        var built = 0
        let build = {
            built += 1
            return TimelineViewModel(timeline: timeline, askCoordinator: { _ in })
        }
        let first = state.projectsShown(flagOn: true, build: build)
        XCTAssertFalse(state.isShown, "not shown until the journal answers")
        await first?.value
        XCTAssertTrue(state.isShown)
        XCTAssertEqual(state.place, .week("2026-11-02"))
        XCTAssertEqual(state.viewModel?.quiet?.total, 3, "the sidebar's counts load with the timeline")
        XCTAssertEqual(state.viewModel?.long?.total, 4)
        await state.projectsShown(flagOn: true, build: build)?.value
        XCTAssertEqual(built, 1)
        XCTAssertEqual(timeline.weeksReads, 2, "a later visit re-reads")
    }

    /// An old journal's 404 is not asked again on every visit.
    func testALaterVisitToAnUnsupportedJournalReadsNothing() async {
        let state = MacTimelineState()
        let timeline = StubTimeline(supported: false)
        await state.projectsShown(flagOn: true) { TimelineViewModel(timeline: timeline, askCoordinator: { _ in }) }?.value
        XCTAssertEqual(state.viewModel?.isSupported, false)
        XCTAssertNil(state.projectsShown(flagOn: true) { XCTFail("built twice"); return state.viewModel! })
        XCTAssertEqual(timeline.weeksReads, 1)
    }

    /// Back onto an older week before the view model existed (after an
    /// account switch): that week, not the newest, is read and shown.
    func testAPlacePickedBeforeTheViewModelExistsIsTheOneLoaded() async {
        let state = MacTimelineState()
        state.select(.week("2026-10-26"))
        await state.projectsShown(flagOn: true) { TimelineViewModel(timeline: StubTimeline(), askCoordinator: { _ in }) }?.value
        XCTAssertEqual(state.viewModel?.place, .week("2026-10-26"))
        XCTAssertEqual(state.viewModel?.week?.week, "2026-10-26")
    }

    /// The week page shows the loaded week only when it is the selected
    /// one: a click on another week shows progress until that week arrives.
    func testTheWeekPageNeverShowsAnotherWeeksCards() {
        let loaded = StubTimeline.week("2026-11-02")
        XCTAssertEqual(MacTimelinePlaceView.shownWeek(loaded, for: .week("2026-11-02")), loaded)
        XCTAssertNil(MacTimelinePlaceView.shownWeek(loaded, for: .week("2026-10-26")))
        XCTAssertNil(MacTimelinePlaceView.shownWeek(loaded, for: .quiet))
        XCTAssertNil(MacTimelinePlaceView.shownWeek(nil, for: .week("2026-11-02")))
    }

    // MARK: Places

    func testTheTimelinePlaceIsAProjectsPlace() {
        XCTAssertEqual(MacPlace(detail: .timeline(place: .quiet, story: nil)).nav, .missions)
        XCTAssertNil(MacPlace(detail: .timeline(place: .quiet, story: "pj_a")).displayedConversationID)
    }

    func testPlace_carriesTheSelectedPlaceAndTheOpenStory() {
        XCTAssertEqual(place(timeline: .init(place: week, story: nil)),
                       MacPlace(detail: .timeline(place: week, story: nil)))
        XCTAssertEqual(place(timeline: .init(place: .quiet, story: "pj_a")),
                       MacPlace(detail: .timeline(place: .quiet, story: "pj_a")))
    }

    /// "All details" is today's project page, and a mission page wins over both.
    func testPlace_allDetailsAndMissionPagesKeepTheirPlaces() {
        XCTAssertEqual(place(timeline: .init(place: week, story: "pj_a"), projectID: "pj_a"),
                       MacPlace(detail: .project(id: "pj_a")))
        XCTAssertEqual(place(timeline: .init(place: week, story: "pj_a"), missionID: "ms_1", projectID: "pj_a"),
                       MacPlace(detail: .mission(id: "ms_1")))
    }

    func testPlace_withoutTheTimelineIsTodaysHome() {
        XCTAssertEqual(place(timeline: nil), MacPlace(detail: .mission(id: nil)))
    }

    /// The home before the journal answered, or the timeline before its
    /// first week loaded, turns into the timeline in place: Back from the
    /// first week goes where the user was before Projects.
    func testRecord_theHomeTurningIntoTheTimelineIsNotANewVisit() {
        let history = MacNavigationHistory()
        let chat = MacPlace(detail: .conversation(id: "c1", pane: nil))
        history.visit(chat)
        MacChatListView.record(MacPlace(detail: .mission(id: nil)), in: history)
        MacChatListView.record(MacPlace(detail: .timeline(place: nil, story: nil)), in: history)
        MacChatListView.record(MacPlace(detail: .timeline(place: week, story: nil)), in: history)
        XCTAssertEqual(history.current, MacPlace(detail: .timeline(place: week, story: nil)))
        XCTAssertEqual(history.back, [chat])
    }

    func testRecord_movesInsideTheTimelineAreVisits() {
        let history = MacNavigationHistory()
        let first = MacPlace(detail: .timeline(place: week, story: nil))
        history.visit(first)
        MacChatListView.record(MacPlace(detail: .timeline(place: .quiet, story: nil)), in: history)
        MacChatListView.record(MacPlace(detail: .timeline(place: .quiet, story: "pj_a")), in: history)
        MacChatListView.record(MacPlace(detail: .project(id: "pj_a")), in: history)
        XCTAssertEqual(history.back, [first, MacPlace(detail: .timeline(place: .quiet, story: nil)),
                                      MacPlace(detail: .timeline(place: .quiet, story: "pj_a"))])
        XCTAssertEqual(history.goBack(), MacPlace(detail: .timeline(place: .quiet, story: "pj_a")))
    }

    private func place(timeline: MacTimelineNav.PlaceInput?, missionID: String? = nil,
                       projectID: String? = nil) -> MacPlace {
        MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: missionID,
                              selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                              selectedProjectID: projectID, timeline: timeline)
    }
}

/// A journal with two weeks and both stalled lists, or (`supported: false`)
/// one without the timeline routes. Counts its weeks-list reads.
private final class StubTimeline: TimelineProviding, @unchecked Sendable {
    private let supported: Bool
    private let lock = NSLock()
    private var reads = 0

    init(supported: Bool = true) { self.supported = supported }

    var weeksReads: Int { lock.withLock { reads } }

    static func week(_ key: String) -> TimelineWeek {
        TimelineWeek(week: key, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0), final: true)
    }

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        lock.withLock { reads += 1 }
        guard supported else { throw JournalAPIError.notFound }
        let date = Date(timeIntervalSince1970: 0)
        return (["2026-11-02", "2026-10-26"].map { TimelineWeekSummary(week: $0, start: date, end: date, sentence: "", moved: 1) },
                nil)
    }
    func timelineWeek(_ week: String) async throws -> TimelineWeek { Self.week(week) }
    func wentQuiet() async throws -> StalledList { StalledList(total: 3, rows: []) }
    func openLong() async throws -> StalledList { StalledList(total: 4, rows: []) }
    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        ([], nil)
    }
}
