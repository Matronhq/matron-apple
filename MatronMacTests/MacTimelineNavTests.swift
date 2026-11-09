import XCTest
import MatronJournal
import MatronModels
import MatronViewModels
@testable import MatronMac

/// The Projects timeline on the Mac, behind the `projects.timeline` flag:
/// with it on and the journal answering, Projects gets a list column and
/// its places join the Back/Forward history; otherwise Projects stays as
/// it is today. The state's reads and what a place shows are shared and
/// tested in MatronShared (`TimelineHostStateTests`); this pins the Mac's
/// layout and history.
@MainActor
final class MacTimelineNavTests: XCTestCase {
    private let week = TimelinePlace.week("2026-11-02")

    // MARK: Layout

    func testFlagOff_projectsStayFullWidth() {
        let state = MacTimelineState()
        XCTAssertNil(state.projectsShown(flagOn: false) { XCTFail("built with the flag off"); return Self.viewModel() })
        let shown = state.isShown
        XCTAssertFalse(shown)
        XCTAssertNil(state.placeInput)
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions, timelineShown: shown))
        XCTAssertEqual(MacChatListView.sidebarWidths(for: .missions, timelineShown: shown).ideal, MacNavColumn.width)
    }

    func testFlagOnAndSupported_projectsGetAListColumnAsWideAsForYou() async {
        let state = MacTimelineState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        let shown = state.isShown
        XCTAssertTrue(shown)
        XCTAssertEqual(state.placeInput, .init(place: week, story: nil))
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

    func testFlagOnButUnsupportedOrNotYetAnswered_keepsTodaysLayout() async {
        let state = MacTimelineState()
        let task = state.projectsShown(flagOn: true) { Self.viewModel(StubTimeline(supported: false)) }
        XCTAssertFalse(state.isShown, "not yet answered")
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions, timelineShown: state.isShown))
        await task?.value
        XCTAssertFalse(state.isShown, "unsupported")
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions, timelineShown: state.isShown))
    }

    /// A new session drops the old one's timeline, and the story open over it.
    func testResetDropsTheTimelineAndTheOpenStory() async {
        let state = MacTimelineState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        state.select(.quiet)
        state.storyProjectID = "pj_a"
        XCTAssertEqual(state.placeInput, .init(place: .quiet, story: "pj_a"))
        state.reset()
        XCTAssertNil(state.viewModel)
        XCTAssertNil(state.storyProjectID)
        XCTAssertNil(state.placeInput)
    }

    /// The timeline changes only the Projects entry.
    func testTheTimelineLeavesTheOtherEntriesAlone() {
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.coordinator, timelineShown: true))
        XCTAssertFalse(MacChatListView.showsNavColumnOnly(.decisions, timelineShown: true))
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

    private static func viewModel(_ timeline: StubTimeline = StubTimeline()) -> TimelineViewModel {
        TimelineViewModel(timeline: timeline, askCoordinator: { _ in })
    }

    private func place(timeline: MacTimelineNav.PlaceInput?, missionID: String? = nil,
                       projectID: String? = nil) -> MacPlace {
        MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: missionID,
                              selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                              selectedProjectID: projectID, timeline: timeline)
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
