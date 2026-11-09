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
        state.projectsShown(flagOn: false) {
            built += 1
            return TimelineViewModel(timeline: NeverTimeline(), askCoordinator: { _ in })
        }
        XCTAssertEqual(built, 0)
        XCTAssertNil(state.viewModel)
        XCTAssertFalse(state.isShown)
    }

    func testFlagOn_buildsTheViewModelOnce() {
        let state = MacTimelineState()
        var built = 0
        let build = {
            built += 1
            return TimelineViewModel(timeline: NeverTimeline(), askCoordinator: { _ in })
        }
        state.projectsShown(flagOn: true, build: build)
        state.projectsShown(flagOn: true, build: build)
        XCTAssertEqual(built, 1)
        XCTAssertNotNil(state.viewModel)
        XCTAssertFalse(state.isShown, "not shown until the journal answers")
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

/// A timeline that is never asked: building the view model makes no read.
private struct NeverTimeline: TimelineProviding {
    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        throw CancellationError()
    }
    func timelineWeek(_ week: String) async throws -> TimelineWeek { throw CancellationError() }
    func wentQuiet() async throws -> StalledList { throw CancellationError() }
    func openLong() async throws -> StalledList { throw CancellationError() }
    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        throw CancellationError()
    }
}
