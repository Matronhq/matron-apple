import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// The shells' timeline state and what a place shows, shared by the Mac,
/// iPad and iPhone hosts.
@MainActor
final class TimelineHostStateTests: XCTestCase {
    // MARK: Visits

    func testTheFlagIsTheDefaultsKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TimelineHostStateTests"))
        defaults.removePersistentDomain(forName: "TimelineHostStateTests")
        defer { defaults.removePersistentDomain(forName: "TimelineHostStateTests") }
        XCTAssertFalse(TimelineHostState.flagOn(defaults))
        defaults.set(true, forKey: "projects.timeline")
        XCTAssertTrue(TimelineHostState.flagOn(defaults))
    }

    /// Flag off: no view model, so nothing asks the journal.
    func testFlagOff_buildsNoViewModel() {
        let state = TimelineHostState()
        XCTAssertNil(state.projectsShown(flagOn: false) { XCTFail("built with the flag off"); return Self.viewModel() })
        XCTAssertNil(state.viewModel)
        XCTAssertFalse(state.isShown)
    }

    func testFlagOn_buildsOnce_showsOnceTheJournalAnswers_andLoadsTheCounts() async {
        let state = TimelineHostState()
        let timeline = StubTimeline()
        var built = 0
        let build = {
            built += 1
            return Self.viewModel(timeline)
        }
        let first = state.projectsShown(flagOn: true, build: build)
        XCTAssertFalse(state.isShown, "not shown until the journal answers")
        await first?.value
        XCTAssertTrue(state.isShown)
        XCTAssertEqual(state.place, .week("2026-11-02"))
        XCTAssertEqual(state.viewModel?.quiet?.total, 3, "the counts load with the timeline")
        XCTAssertEqual(state.viewModel?.long?.total, 4)
        await state.projectsShown(flagOn: true, build: build)?.value
        XCTAssertEqual(built, 1)
        XCTAssertEqual(timeline.weeksReads, 2, "a later visit re-reads")
        XCTAssertEqual(timeline.quietReads, 2, "and its counts")
    }

    /// An old journal's 404 is not asked again on every visit, and its
    /// lists are never asked for counts.
    func testAJournalWithoutTheTimelineIsAskedOnce_andNeverForCounts() async {
        let state = TimelineHostState()
        let timeline = StubTimeline(supported: false)
        await state.projectsShown(flagOn: true) { Self.viewModel(timeline) }?.value
        XCTAssertEqual(state.viewModel?.isSupported, false)
        XCTAssertFalse(state.isShown)
        XCTAssertNil(state.projectsShown(flagOn: true) { XCTFail("built twice"); return Self.viewModel() })
        await state.refresh()
        XCTAssertEqual(timeline.weeksReads, 1)
        XCTAssertEqual(timeline.quietReads, 0)
    }

    /// The journal lost the timeline routes since the last read: the
    /// refresh that finds out asks for no counts.
    func testARefreshThatFindsThe404AsksForNoCounts() async {
        let state = TimelineHostState()
        let timeline = StubTimeline()
        await state.projectsShown(flagOn: true) { Self.viewModel(timeline) }?.value
        XCTAssertEqual(timeline.quietReads, 1)
        timeline.supported = false
        await state.refresh()
        XCTAssertEqual(state.viewModel?.isSupported, false)
        XCTAssertEqual(timeline.quietReads, 1)
    }

    func testRefreshReReadsThePageAndTheCounts() async {
        let state = TimelineHostState()
        let timeline = StubTimeline()
        await state.projectsShown(flagOn: true) { Self.viewModel(timeline) }?.value
        await state.refresh()
        XCTAssertEqual(timeline.weeksReads, 2)
        XCTAssertEqual(timeline.quietReads, 2)
    }

    /// Back onto an older week before the view model existed (after an
    /// account switch): that week, not the newest, is read and shown.
    func testAPlacePickedBeforeTheViewModelExistsIsTheOneLoaded() async {
        let state = TimelineHostState()
        state.select(.week("2026-10-26"))
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        XCTAssertEqual(state.viewModel?.place, .week("2026-10-26"))
        XCTAssertEqual(state.viewModel?.week?.week, "2026-10-26")
    }

    /// The week page under a list (the iPhone's root) is the last week picked.
    func testTheWeekIsTheLastOnePicked() async {
        let state = TimelineHostState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        XCTAssertEqual(state.week, "2026-11-02", "the newest week first")
        state.select(.week("2026-10-26"))
        XCTAssertEqual(state.week, "2026-10-26")
        state.select(.finished)
        XCTAssertEqual(state.place, .finished)
        XCTAssertEqual(state.week, "2026-10-26")
    }

    func testResetForgetsTheOldSession() async {
        let state = TimelineHostState()
        await state.projectsShown(flagOn: true) { Self.viewModel() }?.value
        state.select(.week("2026-10-26"))
        state.reset()
        XCTAssertNil(state.viewModel)
        XCTAssertNil(state.selection)
        XCTAssertNil(state.week)
    }

    // MARK: Places

    /// The week page never shows another week's cards.
    func testShownWeekIsOnlyTheChosenWeek() {
        let loaded = StubTimeline.week("2026-11-02")
        XCTAssertEqual(TimelineViewModel.shownWeek(loaded, for: .week("2026-11-02")), loaded)
        XCTAssertNil(TimelineViewModel.shownWeek(loaded, for: .week("2026-10-26")))
        XCTAssertNil(TimelineViewModel.shownWeek(loaded, for: .quiet))
        XCTAssertNil(TimelineViewModel.shownWeek(nil, for: .week("2026-11-02")))
    }

    func testContent_followsWhatHasLoaded() async {
        let timeline = StubTimeline()
        let vm = Self.viewModel(timeline)
        XCTAssertEqual(vm.content(for: .week("2026-11-02")), .loading)
        await vm.start()
        XCTAssertEqual(vm.content(for: .week("2026-11-02")), .week(StubTimeline.week("2026-11-02"), sentence: "Moved."))
        XCTAssertEqual(vm.content(for: .week("2026-10-26")), .loading, "another week waits for its own read")
        XCTAssertEqual(vm.content(for: .quiet), .loading)
        await vm.loadCounts()
        XCTAssertEqual(vm.content(for: .quiet), .quiet(StalledList(total: 3, rows: [])))
        XCTAssertEqual(vm.content(for: .long), .long(StalledList(total: 4, rows: [])))
        XCTAssertEqual(vm.content(for: .finished), .loading, "not read yet")
        XCTAssertEqual(vm.content(for: nil), .loading, "weeks listed but none chosen")
        vm.error = "offline"
        XCTAssertEqual(vm.content(for: .week("2026-10-26")), .failed)
        XCTAssertEqual(vm.content(for: .finished), .failed, "nothing read to keep over the failure")
        XCTAssertEqual(vm.content(for: .quiet), .quiet(StalledList(total: 3, rows: [])), "a loaded list stays")
        vm.error = nil
        await vm.select(.finished)
        XCTAssertEqual(vm.content(for: .finished), .finished([], hasMore: false), "read, and empty")
    }

    func testContent_noWeeksIsNothingYet() async {
        let vm = Self.viewModel(StubTimeline(weeks: []))
        await vm.start()
        XCTAssertNil(vm.place)
        XCTAssertEqual(vm.content(for: nil), .nothingYet)
    }

    /// Only the place being read says its error, and only over a page on screen.
    func testShowsError_onlyOnThePlaceBeingReadWithAPage() async {
        let vm = Self.viewModel()
        await vm.start()
        vm.error = "Ask failed"
        XCTAssertTrue(vm.showsError(on: .week("2026-11-02")))
        XCTAssertFalse(vm.showsError(on: .week("2026-10-26")), "no page there: the retry says it")
        await vm.loadCounts()
        await vm.select(.quiet)
        vm.error = "Ask failed"
        XCTAssertTrue(vm.showsError(on: .quiet))
        XCTAssertFalse(vm.showsError(on: .week("2026-11-02")), "the week under the list stays quiet")
    }

    func testImageBlobIDs_areTheChosenWeeksPicturesWithoutVideos() async {
        let vm = Self.viewModel()
        await vm.start()
        XCTAssertEqual(vm.imageBlobIDs(for: .week("2026-11-02")), ["bl_photo"])
        XCTAssertEqual(vm.imageBlobIDs(for: .week("2026-10-26")), [])
        XCTAssertEqual(vm.imageBlobIDs(for: .quiet), [])
    }

    private static func viewModel(_ timeline: StubTimeline = StubTimeline()) -> TimelineViewModel {
        TimelineViewModel(timeline: timeline, askCoordinator: { _ in })
    }
}

/// A journal with two weeks (each with a picture and a video) and both
/// stalled lists, or (`supported: false`) one without the timeline routes.
/// Counts its reads.
private final class StubTimeline: TimelineProviding, @unchecked Sendable {
    private let weekKeys: [String]
    private let lock = NSLock()
    private var weeks = 0
    private var quiet = 0
    private var routes: Bool

    init(supported: Bool = true, weeks: [String] = ["2026-11-02", "2026-10-26"]) {
        self.routes = supported
        self.weekKeys = weeks
    }

    /// Whether the journal answers the timeline routes (false: 404).
    var supported: Bool {
        get { lock.withLock { routes } }
        set { lock.withLock { routes = newValue } }
    }

    var weeksReads: Int { lock.withLock { weeks } }
    var quietReads: Int { lock.withLock { quiet } }

    static func week(_ key: String) -> TimelineWeek {
        let project = TimelineProjectRef(id: "pj_a", num: 1, title: "Alpha")
        let other = TimelineProjectRef(id: "pj_b", num: 2, title: "Beta")
        return TimelineWeek(
            week: key, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0), final: true,
            stories: [
                TimelineStory(project: project, media: TimelineMedia(blobID: "bl_photo", contentType: "image/png", name: "a.png")),
                TimelineStory(project: other, media: TimelineMedia(blobID: "bl_clip", contentType: "video/mp4", name: "b.mp4")),
            ])
    }

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        lock.withLock { weeks += 1 }
        guard supported else { throw JournalAPIError.notFound }
        let date = Date(timeIntervalSince1970: 0)
        return (weekKeys.map { TimelineWeekSummary(week: $0, start: date, end: date, sentence: "Moved.", moved: 1) }, nil)
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
    func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList { throw JournalAPIError.notFound }
    func timelineProject(_ id: String) async throws -> TimelineProjectPage { throw JournalAPIError.notFound }
    func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?) { throw JournalAPIError.notFound }
}
