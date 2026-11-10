import XCTest
import MatronDesignSystem
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
        state.openStory("pj_a")
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

    /// ⌘R and coming back to the app re-read the timeline only while
    /// Projects shows it: not a mission page over it, not today's home.
    func testRefreshesTheTimelineOnlyWhileProjectsShowsIt() {
        XCTAssertTrue(MacTimelineNav.refreshesTimeline(nav: .missions, timelineShown: true, selectedMissionID: nil))
        XCTAssertFalse(MacTimelineNav.refreshesTimeline(nav: .missions, timelineShown: false, selectedMissionID: nil))
        XCTAssertFalse(MacTimelineNav.refreshesTimeline(nav: .missions, timelineShown: true, selectedMissionID: "mi_1"))
        XCTAssertFalse(MacTimelineNav.refreshesTimeline(nav: .decisions, timelineShown: true, selectedMissionID: nil))
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

    /// While the timeline is shown, every way of opening a project lands on
    /// its page over the timeline: a project selected by the shell (a chip,
    /// a link, search) is that page's place, never today's project page.
    func testPlace_aSelectedProjectIsTheStoryWhileTheTimelineIsShown() {
        XCTAssertEqual(place(timeline: .init(place: week, story: nil), projectID: "pj_a"),
                       MacPlace(detail: .timeline(place: week, story: "pj_a", section: nil)))
        // The shell's own selection wins over a story left open under it.
        XCTAssertEqual(place(timeline: .init(place: .quiet, story: "pj_b"), projectID: "pj_a"),
                       MacPlace(detail: .timeline(place: .quiet, story: "pj_a", section: nil)))
        // Before the first week has loaded, too.
        XCTAssertEqual(place(timeline: .init(place: nil, story: nil), projectID: "pj_a"),
                       MacPlace(detail: .timeline(place: nil, story: "pj_a", section: nil)))
    }

    /// With the timeline hidden (the switch off, or an older journal), a
    /// selected project is today's project page.
    func testPlace_aSelectedProjectIsTodaysPageWhileTheTimelineIsHidden() {
        XCTAssertEqual(place(timeline: nil, projectID: "pj_a"), MacPlace(detail: .project(id: "pj_a")))
    }

    /// A mission page wins over a project either way.
    func testPlace_aMissionPageKeepsItsPlace() {
        XCTAssertEqual(place(timeline: .init(place: week, story: "pj_a"), missionID: "ms_1", projectID: "pj_a"),
                       MacPlace(detail: .mission(id: "ms_1")))
        XCTAssertEqual(place(timeline: nil, missionID: "ms_1", projectID: "pj_a"),
                       MacPlace(detail: .mission(id: "ms_1")))
    }

    /// A section of the project page is part of the place, and only of a
    /// place with a project open.
    func testPlace_carriesTheOpenSection() {
        XCTAssertEqual(place(timeline: .init(place: week, story: "pj_a", section: .files)),
                       MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files)))
        XCTAssertEqual(place(timeline: .init(place: week, story: nil, section: .history), projectID: "pj_a"),
                       MacPlace(detail: .timeline(place: week, story: "pj_a", section: .history)))
        XCTAssertEqual(place(timeline: .init(place: week, story: nil, section: .files)),
                       MacPlace(detail: .timeline(place: week, story: nil, section: nil)))
        XCTAssertEqual(MacPlace(detail: .timeline(place: week, story: "pj_a", section: .missions)).nav, .missions)
    }

    /// Opening a project drops the section the last one was left on;
    /// opening a section keeps the project.
    func testState_aNewStoryStartsOnItsPage() async {
        let state = MacTimelineState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        state.openStory("pj_a")
        state.storySection = .files
        XCTAssertEqual(state.placeInput, .init(place: week, story: "pj_a", section: .files))
        state.openStory("pj_b")
        XCTAssertEqual(state.placeInput, .init(place: week, story: "pj_b", section: nil))
        state.openStory("pj_b", section: .history)
        XCTAssertEqual(state.placeInput, .init(place: week, story: "pj_b", section: .history))
        state.openStory(nil)
        XCTAssertEqual(state.placeInput, .init(place: week, story: nil, section: nil))
        state.storySection = .missions
        state.reset()
        XCTAssertNil(state.storySection)
    }

    /// The shell's refresh is counted, so an open project's page reads
    /// itself again with the timeline under it.
    func testState_aRefreshIsCountedForTheOpenProjectsPage() async {
        let state = MacTimelineState()
        XCTAssertEqual(state.refreshCount, 0)
        await state.refresh()
        await state.refresh()
        XCTAssertEqual(state.refreshCount, 2)
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

    /// Back and Forward cover the sections: each is a visit, and both
    /// restore the section they recorded.
    func testRecord_aSectionIsAVisitAndBackAndForwardRestoreIt() {
        let history = MacNavigationHistory()
        let weekPlace = MacPlace(detail: .timeline(place: week, story: nil))
        let page = MacPlace(detail: .timeline(place: week, story: "pj_a", section: nil))
        let files = MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files))
        let mission = MacPlace(detail: .mission(id: "ms_1"))
        history.visit(weekPlace)
        MacChatListView.record(page, in: history)
        MacChatListView.record(files, in: history)
        MacChatListView.record(mission, in: history)
        XCTAssertEqual(history.back, [weekPlace, page, files])
        XCTAssertEqual(history.goBack(), files)
        XCTAssertEqual(history.goBack(), page)
        XCTAssertEqual(history.goForward(), files)
    }

    /// A section's own back row is a step back when the page is where the
    /// reader came from, so Forward reopens the section.
    func testRecord_aSectionsBackRowIsAStepBack() {
        let history = MacNavigationHistory()
        let page = MacPlace(detail: .timeline(place: week, story: "pj_a", section: nil))
        let files = MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files))
        history.visit(page)
        MacChatListView.record(files, in: history)
        MacChatListView.record(page, in: history)
        XCTAssertEqual(history.current, page)
        XCTAssertEqual(history.back, [])
        XCTAssertEqual(history.forward, [files])
    }

    /// A section reached some other way (a restored place with nothing
    /// behind it) closes onto its page as a new visit.
    func testRecord_aSectionsBackRowWithoutThePageBehindItIsAVisit() {
        let history = MacNavigationHistory()
        let page = MacPlace(detail: .timeline(place: week, story: "pj_a", section: nil))
        let files = MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files))
        history.visit(files)
        MacChatListView.record(page, in: history)
        XCTAssertEqual(history.back, [files])
        XCTAssertEqual(history.current, page)
    }

    func testClosesSection_onlyFromASectionToItsOwnPage() {
        let page = MacPlace(detail: .timeline(place: week, story: "pj_a", section: nil))
        let files = MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files))
        XCTAssertTrue(MacTimelineNav.closesSection(from: files, to: page))
        XCTAssertFalse(MacTimelineNav.closesSection(from: page, to: files))
        XCTAssertFalse(MacTimelineNav.closesSection(from: files, to: MacPlace(detail: .timeline(place: week, story: "pj_b"))))
        XCTAssertFalse(MacTimelineNav.closesSection(from: files, to: MacPlace(detail: .timeline(place: .quiet, story: "pj_a"))))
        XCTAssertFalse(MacTimelineNav.closesSection(from: files, to: MacPlace(detail: .timeline(place: week, story: nil))))
    }

    /// A project opened before the journal answered is today's page for a
    /// moment, then the new one: the same place filling in, so Back never
    /// lands on a place that turns straight back into this one.
    func testRecord_todaysPageTurningIntoTheStoryIsNotANewVisit() {
        let history = MacNavigationHistory()
        let chat = MacPlace(detail: .conversation(id: "c1", pane: nil))
        history.visit(chat)
        MacChatListView.record(MacPlace(detail: .project(id: "pj_a")), in: history)
        MacChatListView.record(MacPlace(detail: .timeline(place: nil, story: "pj_a")), in: history)
        MacChatListView.record(MacPlace(detail: .timeline(place: week, story: "pj_a")), in: history)
        XCTAssertEqual(history.current, MacPlace(detail: .timeline(place: week, story: "pj_a")))
        XCTAssertEqual(history.back, [chat])
    }

    func testFillsIn_onlyTheSamePlace() {
        let story = MacPlace(detail: .timeline(place: week, story: "pj_a"))
        XCTAssertTrue(MacTimelineNav.fillsIn(from: MacPlace(detail: .project(id: "pj_a")), to: story))
        XCTAssertFalse(MacTimelineNav.fillsIn(from: MacPlace(detail: .project(id: "pj_b")), to: story))
        XCTAssertFalse(MacTimelineNav.fillsIn(from: MacPlace(detail: .mission(id: nil)), to: story))
        XCTAssertFalse(MacTimelineNav.fillsIn(from: MacPlace(detail: .timeline(place: week, story: nil)), to: story),
                       "a card opening its project is a move")
        XCTAssertFalse(MacTimelineNav.fillsIn(from: MacPlace(detail: .timeline(place: .quiet, story: "pj_a")), to: story))
        XCTAssertFalse(MacTimelineNav.fillsIn(from: nil, to: story))
        // A section is never a fill-in of today's page.
        XCTAssertFalse(MacTimelineNav.fillsIn(from: MacPlace(detail: .project(id: "pj_a")),
                                              to: MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files))))
        // The first week arriving under an open section keeps it.
        XCTAssertTrue(MacTimelineNav.fillsIn(from: MacPlace(detail: .timeline(place: nil, story: "pj_a", section: .files)),
                                             to: MacPlace(detail: .timeline(place: week, story: "pj_a", section: .files))))
    }

    // MARK: The project page

    /// A journal without the project-page route: today's project page, in
    /// whatever section the place names.
    func testProjectContent_anOlderJournalFallsBackToTodaysPage() {
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: false, isMissing: false, isUnsupported: true,
                                                     loadFailed: false, section: nil), .todaysPage)
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: false, isMissing: false, isUnsupported: true,
                                                     loadFailed: true, section: .files), .todaysPage)
    }

    func testProjectContent_thePageThenItsSections() {
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: true, isMissing: false, isUnsupported: false,
                                                     loadFailed: false, section: nil), .summary)
        for section in ProjectSection.allCases {
            XCTAssertEqual(MacTimelineNav.projectContent(hasPage: true, isMissing: false, isUnsupported: false,
                                                         loadFailed: false, section: section), .section(section))
        }
        // A page already on screen stays through a failed re-read.
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: true, isMissing: false, isUnsupported: false,
                                                     loadFailed: true, section: nil), .summary)
    }

    func testProjectContent_missingFailedAndLoading() {
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: false, isMissing: true, isUnsupported: false,
                                                     loadFailed: false, section: .history), .missing)
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: false, isMissing: false, isUnsupported: false,
                                                     loadFailed: true, section: nil), .loadFailed)
        XCTAssertEqual(MacTimelineNav.projectContent(hasPage: false, isMissing: false, isUnsupported: false,
                                                     loadFailed: false, section: nil), .loading)
    }

    /// A picture opens the image viewer, a video the player, anything else
    /// where it was posted.
    func testFileOpening() {
        XCTAssertEqual(MacTimelineNav.fileOpening(file("image/png")), .picture)
        XCTAssertEqual(MacTimelineNav.fileOpening(file("video/mp4")), .video)
        XCTAssertEqual(MacTimelineNav.fileOpening(file("Video/QuickTime")), .video)
        XCTAssertEqual(MacTimelineNav.fileOpening(file("application/pdf")), .source)
        XCTAssertEqual(MacTimelineNav.fileOpening(file(nil)), .source)
    }

    /// The viewer steps through the project's pictures only, each once.
    func testPictureBlobIDs() {
        let files = [file("image/png", blob: "b1"), file("video/mp4", blob: "b2"), file("image/jpeg", blob: "b3"),
                     file("image/png", blob: "b1", seq: 9), file("text/plain", blob: "b4")]
        XCTAssertEqual(MacTimelineNav.pictureBlobIDs(files), ["b1", "b3"])
    }

    func testRename_saveIsOffWhileTheNameIsEmpty() {
        XCTAssertTrue(MacProjectRenameSheet.canSave("Promo launch"))
        XCTAssertFalse(MacProjectRenameSheet.canSave(""))
        XCTAssertFalse(MacProjectRenameSheet.canSave("  \n"))
    }

    private func file(_ contentType: String?, blob: String = "b1", seq: Int64 = 1) -> ProjectFile {
        ProjectFile(blobID: blob, name: "a file", contentType: contentType,
                    source: .chat(convoID: "c1", seq: seq), postedAt: nil)
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
    func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList { throw JournalAPIError.notFound }
    func timelineProject(_ id: String) async throws -> TimelineProjectPage { throw JournalAPIError.notFound }
    func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?) { throw JournalAPIError.notFound }
}
