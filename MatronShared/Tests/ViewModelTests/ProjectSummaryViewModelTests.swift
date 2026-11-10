import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// A scripted `TimelineProviding` for one project's page: the page and the
/// all-projects probe each answer what the test set (nothing set is a
/// 404), history pages are keyed by `before`.
private final class FakeProjectTimeline: TimelineProviding, @unchecked Sendable {
    private struct State {
        var page: Result<TimelineProjectPage, Error> = .failure(JournalAPIError.notFound)
        var list: Result<TimelineProjectList, Error> = .failure(JournalAPIError.notFound)
        var historyPages: [String?: (weeks: [TimelineHistoryWeek], nextBefore: String?)] = [:]
        var historyError: Error?
        var pageCalls: [String] = []
        var listCalls: [Int?] = []
        var historyCalls: [String] = []
    }

    private let lock = NSLock()
    private var state = State()

    var page: Result<TimelineProjectPage, Error> {
        get { lock.withLock { state.page } } set { lock.withLock { state.page = newValue } }
    }
    var list: Result<TimelineProjectList, Error> {
        get { lock.withLock { state.list } } set { lock.withLock { state.list = newValue } }
    }
    var historyPages: [String?: (weeks: [TimelineHistoryWeek], nextBefore: String?)] {
        get { lock.withLock { state.historyPages } } set { lock.withLock { state.historyPages = newValue } }
    }
    var historyError: Error? {
        get { lock.withLock { state.historyError } } set { lock.withLock { state.historyError = newValue } }
    }
    var pageCalls: [String] { lock.withLock { state.pageCalls } }
    /// The `limit` of each all-projects read.
    var listCalls: [Int?] { lock.withLock { state.listCalls } }
    /// "<project id>:<before>" per history read.
    var historyCalls: [String] { lock.withLock { state.historyCalls } }

    func timelineProject(_ id: String) async throws -> TimelineProjectPage {
        try lock.withLock { state.pageCalls.append(id); return state.page }.get()
    }

    func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList {
        try lock.withLock { state.listCalls.append(limit); return state.list }.get()
    }

    func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?) {
        let (page, failure) = lock.withLock { () -> ((weeks: [TimelineHistoryWeek], nextBefore: String?), Error?) in
            state.historyCalls.append("\(id):\(before ?? "nil")")
            return (state.historyPages[before] ?? ([], nil), state.historyError)
        }
        if let failure { throw failure }
        return page
    }

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) { ([], nil) }
    func timelineWeek(_ week: String) async throws -> TimelineWeek { throw JournalAPIError.notFound }
    func wentQuiet() async throws -> StalledList { StalledList(total: 0, rows: []) }
    func openLong() async throws -> StalledList { StalledList(total: 0, rows: []) }
    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) { ([], nil) }
}

@MainActor
final class ProjectSummaryViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let promo = TimelineProjectRef(id: "pj_promo", num: 4, title: "Promo launch")

    private func page(sentence: String = "The launch page is live.", mergedFrom: String? = nil) -> TimelineProjectPage {
        TimelineProjectPage(project: promo, isLive: true, sentence: sentence, weeks: 3, missionsOpen: 2,
                            mergedFromID: mergedFrom)
    }

    private func week(_ key: String) -> TimelineHistoryWeek {
        TimelineHistoryWeek(week: key, start: now, end: now, sentence: "Week \(key)")
    }

    private func make(id: String = "pj_promo") -> (ProjectSummaryViewModel, FakeProjectTimeline) {
        let fake = FakeProjectTimeline()
        fake.page = .success(page())
        fake.list = .success(TimelineProjectList(total: 1, rows: [TimelineProjectRow(project: promo)]))
        return (ProjectSummaryViewModel(projectID: id, timeline: fake), fake)
    }

    func testStartLoadsThePage() async {
        let (vm, fake) = make()
        XCTAssertNil(vm.page)
        await vm.start()
        XCTAssertEqual(vm.page, page())
        XCTAssertEqual(fake.pageCalls, ["pj_promo"])
        XCTAssertFalse(vm.isMissing)
        XCTAssertFalse(vm.isUnsupported)
        XCTAssertNil(vm.redirectedTo)
        XCTAssertNil(vm.error)
        XCTAssertEqual(fake.listCalls, [], "a page that loads needs no probe")
        XCTAssertEqual(fake.historyCalls, [], "the history waits to be asked for")
    }

    func testLoadHistoryAppendsAndStopsAtNil() async {
        let (vm, fake) = make()
        fake.historyPages[nil] = ([week("2026-11-02"), week("2026-10-26")], "2026-10-26")
        fake.historyPages["2026-10-26"] = ([week("2026-10-19")], nil)
        await vm.start()
        XCTAssertFalse(vm.hasMoreHistory)
        await vm.loadHistory()
        XCTAssertEqual(vm.history.map(\.week), ["2026-11-02", "2026-10-26"])
        XCTAssertTrue(vm.hasMoreHistory)
        await vm.loadMoreHistory()
        XCTAssertEqual(vm.history.map(\.week), ["2026-11-02", "2026-10-26", "2026-10-19"])
        XCTAssertFalse(vm.hasMoreHistory)
        await vm.loadMoreHistory()
        XCTAssertEqual(fake.historyCalls, ["pj_promo:nil", "pj_promo:2026-10-26"], "nothing is read past the last page")
    }

    func testAFailedHistoryReadSetsErrorAndKeepsWhatLoaded() async {
        let (vm, fake) = make()
        fake.historyPages[nil] = ([week("2026-11-02")], "2026-11-02")
        await vm.start()
        await vm.loadHistory()
        fake.historyError = JournalAPIError.forbidden
        await vm.loadMoreHistory()
        XCTAssertEqual(vm.history.map(\.week), ["2026-11-02"])
        XCTAssertTrue(vm.hasMoreHistory, "the page can be asked for again")
        XCTAssertEqual(vm.error, JournalAPIError.forbidden.localizedDescription)
    }

    func testAPageNotFoundWhileTheListWorksIsMissing() async {
        let (vm, fake) = make()
        fake.page = .failure(JournalAPIError.notFound)
        await vm.start()
        XCTAssertTrue(vm.isMissing)
        XCTAssertFalse(vm.isUnsupported)
        XCTAssertNil(vm.page)
        XCTAssertNil(vm.error)
        XCTAssertEqual(fake.listCalls, [1], "the probe asks for one row")
    }

    /// A journal without the project-page routes: the host shows the
    /// project page it had before.
    func testPageRouteMissingFallsBack() async {
        let (vm, fake) = make()
        fake.page = .failure(JournalAPIError.notFound)
        fake.list = .failure(JournalAPIError.notFound)
        await vm.start()
        XCTAssertTrue(vm.isUnsupported)
        XCTAssertFalse(vm.isMissing)
        XCTAssertNil(vm.page)
        XCTAssertNil(vm.error)
    }

    func testAPageNotFoundWithAProbeThatFailsOtherwiseSetsError() async {
        let (vm, fake) = make()
        fake.page = .failure(JournalAPIError.notFound)
        fake.list = .failure(JournalAPIError.forbidden)
        await vm.start()
        XCTAssertFalse(vm.isUnsupported, "nothing says the journal lacks the route")
        XCTAssertFalse(vm.isMissing, "nor that the project is gone")
        XCTAssertEqual(vm.error, JournalAPIError.forbidden.localizedDescription)
    }

    func testAMergedPageRedirects() async {
        let (vm, fake) = make(id: "pj_old")
        fake.page = .success(page(mergedFrom: "pj_old"))
        fake.historyPages[nil] = ([week("2026-11-02")], nil)
        await vm.start()
        XCTAssertEqual(vm.redirectedTo, "pj_promo")
        XCTAssertEqual(vm.page?.project.id, "pj_promo")
        XCTAssertFalse(vm.isMissing)
        await vm.loadHistory()
        await vm.refresh()
        XCTAssertEqual(fake.pageCalls, ["pj_old", "pj_promo"], "later reads ask for the project it became")
        XCTAssertEqual(fake.historyCalls, ["pj_promo:nil", "pj_promo:nil"])
        XCTAssertEqual(vm.redirectedTo, "pj_promo", "the redirect stays said")
    }

    func testAFailedRefreshKeepsThePreviousPageAndSetsError() async {
        let (vm, fake) = make()
        await vm.start()
        fake.page = .failure(JournalAPIError.forbidden)
        await vm.refresh()
        XCTAssertEqual(vm.page, page())
        XCTAssertEqual(vm.error, JournalAPIError.forbidden.localizedDescription)
        fake.page = .success(page(sentence: "Tickets are on sale."))
        await vm.refresh()
        XCTAssertEqual(vm.page?.sentence, "Tickets are on sale.")
        XCTAssertNil(vm.error, "a read that works clears the error")
    }

    func testRefreshRereadsTheHistoryOnceItWasAskedFor() async {
        let (vm, fake) = make()
        fake.historyPages[nil] = ([week("2026-11-02")], "2026-11-02")
        fake.historyPages["2026-11-02"] = ([week("2026-10-26")], nil)
        await vm.start()
        await vm.refresh()
        XCTAssertEqual(fake.historyCalls, [], "no history was on screen")
        await vm.loadHistory()
        await vm.loadMoreHistory()
        fake.historyPages[nil] = ([week("2026-11-09"), week("2026-11-02")], "2026-11-02")
        await vm.refresh()
        XCTAssertEqual(vm.history.map(\.week), ["2026-11-09", "2026-11-02"], "the first page replaces the list")
        XCTAssertTrue(vm.hasMoreHistory)
    }

    /// A read called off (the screen left, a newer read began) is not a
    /// failure to tell the reader about.
    func testACancelledPageReadSetsNoError() async {
        let (vm, fake) = make()
        await vm.start()
        fake.page = .failure(JournalAPIError.transport("cancelled"))
        await vm.refresh()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.page, page(), "the page stays")
        fake.page = .failure(CancellationError())
        await vm.refresh()
        XCTAssertNil(vm.error)
    }

    func testACancelledProbeSetsNoError() async {
        let (vm, fake) = make()
        fake.page = .failure(JournalAPIError.notFound)
        fake.list = .failure(JournalAPIError.transport("cancelled"))
        await vm.start()
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isMissing, "nothing was learnt")
        XCTAssertFalse(vm.isUnsupported)
    }

    func testACancelledHistoryReadSetsNoError() async {
        let (vm, fake) = make()
        fake.historyPages[nil] = ([week("2026-11-02")], "2026-11-02")
        await vm.start()
        await vm.loadHistory()
        fake.historyError = JournalAPIError.transport("cancelled")
        await vm.loadMoreHistory()
        XCTAssertNil(vm.error)
        await vm.loadHistory()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.history.map(\.week), ["2026-11-02"], "what loaded stays")
        XCTAssertTrue(vm.hasMoreHistory)
    }

    /// A read that fails while its task is cancelled says nothing either,
    /// whatever the error.
    func testAReadFailingInACancelledTaskSetsNoError() async {
        let (vm, fake) = make()
        fake.page = .failure(JournalAPIError.forbidden)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await vm.start()
        }
        await task.value
        XCTAssertNil(vm.error)
    }

    func testAProjectGoneOnRefreshIsMissing() async {
        let (vm, fake) = make()
        await vm.start()
        fake.page = .failure(JournalAPIError.notFound)
        await vm.refresh()
        XCTAssertTrue(vm.isMissing)
    }
}
