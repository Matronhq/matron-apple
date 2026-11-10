import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// A scripted `TimelineProviding`: pages keyed by `before`, per-call counters,
/// and gates that hold a call (by key) until the test releases it. A gate
/// holds the first call that arrives at its key; the result is read before
/// the hold, so a held call returns what was scripted when it started.
private final class FakeTimeline: TimelineProviding, @unchecked Sendable {
    private struct State {
        var weekPages: [String?: (weeks: [TimelineWeekSummary], nextBefore: String?)] = [:]
        var weekDetails: [String: TimelineWeek] = [:]
        var quiet = StalledList(total: 0, rows: [])
        var long = StalledList(total: 0, rows: [])
        var finishedPages: [String?: (rows: [FinishedProject], nextBefore: String?)] = [:]
        var weeksError: Error?
        var weekError: Error?
        var failsLists = false
        var weeksCalls: [String?] = []
        var weekCalls: [String] = []
        var quietCalls = 0
        var longCalls = 0
        var finishedCalls: [String?] = []
        var projectPages: [String?: TimelineProjectList] = [:]
        var projectsError: Error?
        var projectsCalls: [String?] = []
        var gated: Set<String> = []
        var held: [String: CheckedContinuation<Void, Never>] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    private func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    private func write(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

    var weekPages: [String?: (weeks: [TimelineWeekSummary], nextBefore: String?)] {
        get { read(\.weekPages) } set { write { $0.weekPages = newValue } }
    }
    var weekDetails: [String: TimelineWeek] { get { read(\.weekDetails) } set { write { $0.weekDetails = newValue } } }
    var quiet: StalledList { get { read(\.quiet) } set { write { $0.quiet = newValue } } }
    var long: StalledList { get { read(\.long) } set { write { $0.long = newValue } } }
    var finishedPages: [String?: (rows: [FinishedProject], nextBefore: String?)] {
        get { read(\.finishedPages) } set { write { $0.finishedPages = newValue } }
    }
    var weeksError: Error? { get { read(\.weeksError) } set { write { $0.weeksError = newValue } } }
    var weekError: Error? { get { read(\.weekError) } set { write { $0.weekError = newValue } } }
    /// The went-quiet and open-a-long-time reads throw.
    var failsLists: Bool { get { read(\.failsLists) } set { write { $0.failsLists = newValue } } }
    var weeksCalls: [String?] { read(\.weeksCalls) }
    var weekCalls: [String] { read(\.weekCalls) }
    var quietCalls: Int { read(\.quietCalls) }
    var longCalls: Int { read(\.longCalls) }
    var finishedCalls: [String?] { read(\.finishedCalls) }
    /// All-projects pages by `before`; a page not scripted answers 404, as
    /// a journal without the route does.
    var projectPages: [String?: TimelineProjectList] {
        get { read(\.projectPages) } set { write { $0.projectPages = newValue } }
    }
    /// What every all-projects read throws, when set.
    var projectsError: Error? { get { read(\.projectsError) } set { write { $0.projectsError = newValue } } }
    var projectsCalls: [String?] { read(\.projectsCalls) }

    // MARK: Gates

    /// Hold the next call at `key` ("weeks:<before>", "week:<key>", "quiet", "long", "finished:<before>", "projects:<before>").
    func gate(_ key: String) { write { $0.gated.insert(key) } }

    func waitUntilHeld(_ key: String) async {
        while read({ $0.held[key] == nil }) { await Task.yield() }
    }

    func release(_ key: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            state.gated.remove(key)
            return state.held.removeValue(forKey: key)
        }
        continuation?.resume()
    }

    private func holdIfGated(_ key: String) async {
        guard lock.withLock({ state.gated.remove(key) != nil }) else { return }
        await withCheckedContinuation { continuation in write { $0.held[key] = continuation } }
    }

    // MARK: TimelineProviding

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        let (page, failure) = lock.withLock { () -> ((weeks: [TimelineWeekSummary], nextBefore: String?), Error?) in
            state.weeksCalls.append(before)
            return (state.weekPages[before] ?? ([], nil), state.weeksError)
        }
        await holdIfGated("weeks:\(before ?? "nil")")
        if let failure { throw failure }
        return page
    }

    func timelineWeek(_ week: String) async throws -> TimelineWeek {
        let (detail, failure) = lock.withLock { () -> (TimelineWeek?, Error?) in
            state.weekCalls.append(week)
            return (state.weekDetails[week], state.weekError)
        }
        await holdIfGated("week:\(week)")
        if let failure { throw failure }
        guard let detail else { throw JournalAPIError.notFound }
        return detail
    }

    func wentQuiet() async throws -> StalledList {
        let (list, fails) = lock.withLock { () -> (StalledList, Bool) in state.quietCalls += 1; return (state.quiet, state.failsLists) }
        await holdIfGated("quiet")
        if fails { throw JournalAPIError.forbidden }
        return list
    }

    func openLong() async throws -> StalledList {
        let (list, fails) = lock.withLock { () -> (StalledList, Bool) in state.longCalls += 1; return (state.long, state.failsLists) }
        await holdIfGated("long")
        if fails { throw JournalAPIError.forbidden }
        return list
    }

    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        let page = lock.withLock { () -> (rows: [FinishedProject], nextBefore: String?) in
            state.finishedCalls.append(before)
            return state.finishedPages[before] ?? ([], nil)
        }
        await holdIfGated("finished:\(before ?? "nil")")
        return page
    }

    func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList {
        let (page, failure) = lock.withLock { () -> (TimelineProjectList?, Error?) in
            state.projectsCalls.append(before)
            return (state.projectPages[before], state.projectsError)
        }
        await holdIfGated("projects:\(before ?? "nil")")
        if let failure { throw failure }
        guard let page else { throw JournalAPIError.notFound }
        return page
    }

    func timelineProject(_ id: String) async throws -> TimelineProjectPage { throw JournalAPIError.notFound }
    func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?) { throw JournalAPIError.notFound }
}

@MainActor
final class TimelineViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(_ week: String) -> TimelineWeekSummary {
        TimelineWeekSummary(week: week, start: now, end: now, sentence: "Week \(week)", moved: 1)
    }

    private func detail(_ week: String) -> TimelineWeek {
        TimelineWeek(week: week, start: now, end: now, final: true, lede: "Lede \(week)")
    }

    private func project(_ n: Int) -> TimelineProjectRef { TimelineProjectRef(id: "pj_\(n)", num: n, title: "Project \(n)") }

    private func make() -> (TimelineViewModel, FakeTimeline, AskLog) {
        let fake = FakeTimeline()
        fake.weekPages[nil] = ([summary("2026-11-02"), summary("2026-10-26")], "2026-10-26")
        fake.weekPages["2026-10-26"] = ([summary("2026-10-19")], nil)
        fake.weekDetails = ["2026-11-02": detail("2026-11-02"), "2026-10-26": detail("2026-10-26"),
                            "2026-10-19": detail("2026-10-19")]
        let log = AskLog()
        let now = self.now
        let vm = TimelineViewModel(timeline: fake, askCoordinator: { await log.add($0) }, now: { now })
        return (vm, fake, log)
    }

    func testStartLoadsWeeksAndTheCurrentWeek() async {
        let (vm, fake, _) = make()
        XCTAssertNil(vm.place)
        XCTAssertNil(vm.isSupported)
        await vm.start()
        XCTAssertEqual(vm.weeks.map(\.week), ["2026-11-02", "2026-10-26"])
        XCTAssertEqual(vm.place, .week("2026-11-02"))
        XCTAssertEqual(vm.week?.week, "2026-11-02")
        XCTAssertEqual(vm.isSupported, true)
        XCTAssertNil(vm.error)
        XCTAssertEqual(fake.weekCalls, ["2026-11-02"])
    }

    func testSelectingAWeekLoadsIt() async {
        let (vm, fake, _) = make()
        await vm.start()
        await vm.select(.week("2026-10-26"))
        XCTAssertEqual(vm.place, .week("2026-10-26"))
        XCTAssertEqual(vm.week?.week, "2026-10-26")
        XCTAssertEqual(fake.weekCalls, ["2026-11-02", "2026-10-26"])
    }

    func testQuietLoadsOnceAndCachesUntilRefresh() async {
        let (vm, fake, _) = make()
        fake.quiet = StalledList(total: 1, rows: [StalledProject(project: project(1))])
        await vm.start()
        await vm.select(.quiet)
        await vm.select(.week("2026-11-02"))
        await vm.select(.quiet)
        XCTAssertEqual(vm.place, .quiet)
        XCTAssertEqual(vm.quiet?.total, 1)
        XCTAssertEqual(fake.quietCalls, 1)
        await vm.refresh()
        XCTAssertEqual(fake.quietCalls, 2, "refresh reloads the place it is on")
        XCTAssertEqual(fake.weeksCalls, [nil, nil])
    }

    func testRefreshOffTheListDropsItsCache() async {
        let (vm, fake, _) = make()
        await vm.start()
        await vm.select(.long)
        await vm.select(.week("2026-11-02"))
        await vm.refresh()
        XCTAssertEqual(fake.longCalls, 1, "not on the list: refresh does not fetch it")
        await vm.select(.long)
        XCTAssertEqual(fake.longCalls, 2, "but the next visit re-reads it")
    }

    func testUnsupportedJournalFallsBack() async {
        let (vm, fake, _) = make()
        fake.weeksError = JournalAPIError.notFound
        await vm.start()
        XCTAssertEqual(vm.isSupported, false)
        XCTAssertNil(vm.place)
        XCTAssertNil(vm.error)
        XCTAssertTrue(fake.weekCalls.isEmpty)
    }

    func testOtherWeeksFailureSetsErrorAndLeavesSupportUnchanged() async {
        let (vm, fake, _) = make()
        fake.weeksError = JournalAPIError.rateLimited
        await vm.start()
        XCTAssertNil(vm.isSupported)
        XCTAssertEqual(vm.error, JournalAPIError.rateLimited.localizedDescription)
        fake.weeksError = nil
        await vm.start()
        XCTAssertEqual(vm.isSupported, true)
        XCTAssertNil(vm.error)
        fake.weeksError = JournalAPIError.transport("offline")
        await vm.refresh()
        XCTAssertEqual(vm.isSupported, true, "a transient failure after support is known keeps it")
        XCTAssertNotNil(vm.error)
    }

    func testLoadEarlierWeeksAppendsAndStopsWhenExhausted() async {
        let (vm, fake, _) = make()
        await vm.start()
        XCTAssertTrue(vm.hasEarlierWeeks)
        await vm.loadEarlierWeeks()
        XCTAssertEqual(vm.weeks.map(\.week), ["2026-11-02", "2026-10-26", "2026-10-19"])
        XCTAssertFalse(vm.hasEarlierWeeks)
        await vm.loadEarlierWeeks()
        XCTAssertEqual(fake.weeksCalls, [nil, "2026-10-26"], "no third request once nextBefore is nil")
    }

    func testFailedWeekLoadSetsErrorAndKeepsThePreviousWeek() async {
        let (vm, fake, _) = make()
        await vm.start()
        fake.weekError = JournalAPIError.transport("offline")
        await vm.select(.week("2026-10-26"))
        XCTAssertEqual(vm.week?.week, "2026-11-02")
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.place, .week("2026-10-26"))
    }

    func testFinishedPagesThroughLoadMore() async {
        let (vm, fake, _) = make()
        let finish = { (n: Int) in FinishedProject(project: self.project(n), finishedAt: self.now) }
        fake.finishedPages[nil] = ([finish(1), finish(2)], "cursor")
        fake.finishedPages["cursor"] = ([finish(3)], nil)
        await vm.start()
        await vm.select(.finished)
        XCTAssertEqual(vm.finished.map(\.project.num), [1, 2])
        XCTAssertTrue(vm.hasMoreFinished)
        await vm.loadMoreFinished()
        XCTAssertEqual(vm.finished.map(\.project.num), [1, 2, 3])
        XCTAssertFalse(vm.hasMoreFinished)
        await vm.loadMoreFinished()
        await vm.select(.week("2026-11-02"))
        await vm.select(.finished)
        XCTAssertEqual(fake.finishedCalls, [nil, "cursor"], "cached; no extra requests")
    }

    // MARK: - Race guards

    /// Lets queued main-actor work run (a task that would reach a gate or return).
    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    func testALateWeekResultDoesNotReplaceTheWeekSelectedSince() async {
        let (vm, fake, _) = make()
        await vm.start()
        fake.gate("week:2026-10-26")
        let slow = Task { await vm.select(.week("2026-10-26")) }
        await fake.waitUntilHeld("week:2026-10-26")
        await vm.select(.week("2026-10-19"))
        fake.release("week:2026-10-26")
        await slow.value
        XCTAssertEqual(vm.place, .week("2026-10-19"))
        XCTAssertEqual(vm.week?.week, "2026-10-19", "the earlier request finishing last must not win")
    }

    func testPagingDuringAFirstPageReloadIsRefused() async {
        let (vm, fake, _) = make()
        await vm.start()
        // The reload brings a shifted first page; the stale cursor's page would duplicate its tail.
        fake.weekPages[nil] = ([summary("2026-11-09"), summary("2026-11-02"), summary("2026-10-26"), summary("2026-10-19")], nil)
        fake.gate("weeks:nil")
        fake.gate("weeks:2026-10-26")
        let reload = Task { await vm.refresh() }
        await fake.waitUntilHeld("weeks:nil")
        let paging = Task { await vm.loadEarlierWeeks() }
        await settle()
        fake.release("weeks:nil")
        await reload.value
        fake.release("weeks:2026-10-26")
        await paging.value
        XCTAssertEqual(vm.weeks.map(\.week), ["2026-11-09", "2026-11-02", "2026-10-26", "2026-10-19"])
        XCTAssertEqual(fake.weeksCalls, [nil, nil], "no page was requested off the old cursor")
    }

    func testAPageFetchedBeforeARefreshIsDropped() async {
        let (vm, fake, _) = make()
        await vm.start()
        fake.gate("weeks:2026-10-26")
        let paging = Task { await vm.loadEarlierWeeks() }
        await fake.waitUntilHeld("weeks:2026-10-26")
        fake.weekPages[nil] = ([summary("2026-11-09"), summary("2026-11-02"), summary("2026-10-26"), summary("2026-10-19")], nil)
        await vm.refresh()
        fake.release("weeks:2026-10-26")
        await paging.value
        XCTAssertEqual(vm.weeks.map(\.week), ["2026-11-09", "2026-11-02", "2026-10-26", "2026-10-19"], "no duplicate tail")
    }

    func testPagingFinishedDuringAReloadIsRefused() async {
        let (vm, fake, _) = make()
        let finish = { (n: Int) in FinishedProject(project: self.project(n), finishedAt: self.now) }
        fake.finishedPages[nil] = ([finish(1), finish(2)], "cursor")
        fake.finishedPages["cursor"] = ([finish(3)], nil)
        await vm.start()
        await vm.select(.finished)
        fake.finishedPages[nil] = ([finish(1), finish(2), finish(3)], nil)
        fake.gate("finished:nil")
        fake.gate("finished:cursor")
        let reload = Task { await vm.refresh() }
        await fake.waitUntilHeld("finished:nil")
        let paging = Task { await vm.loadMoreFinished() }
        await settle()
        fake.release("finished:nil")
        await reload.value
        fake.release("finished:cursor")
        await paging.value
        XCTAssertEqual(vm.finished.map(\.project.num), [1, 2, 3])
        XCTAssertEqual(fake.finishedCalls, [nil, nil])
    }

    func testAFinishedPageFetchedBeforeARefreshIsDropped() async {
        let (vm, fake, _) = make()
        let finish = { (n: Int) in FinishedProject(project: self.project(n), finishedAt: self.now) }
        fake.finishedPages[nil] = ([finish(1), finish(2)], "cursor")
        fake.finishedPages["cursor"] = ([finish(3)], nil)
        await vm.start()
        await vm.select(.finished)
        fake.gate("finished:cursor")
        let paging = Task { await vm.loadMoreFinished() }
        await fake.waitUntilHeld("finished:cursor")
        fake.finishedPages[nil] = ([finish(1), finish(2), finish(3)], nil)
        await vm.refresh()
        fake.release("finished:cursor")
        await paging.value
        XCTAssertEqual(vm.finished.map(\.project.num), [1, 2, 3])
    }

    func testAQuietResultFromBeforeARefreshIsNeitherShownNorCached() async {
        let (vm, fake, _) = make()
        fake.quiet = StalledList(total: 1, rows: [StalledProject(project: project(1))])
        await vm.start()
        fake.gate("quiet")
        let slow = Task { await vm.select(.quiet) }
        await fake.waitUntilHeld("quiet")
        await vm.select(.week("2026-11-02"))
        fake.quiet = StalledList(total: 2, rows: [])
        await vm.refresh()
        fake.release("quiet")
        await slow.value
        XCTAssertNil(vm.quiet, "the pre-refresh result is dropped")
        await vm.select(.quiet)
        XCTAssertEqual(fake.quietCalls, 2, "and not marked fresh, so the next visit re-reads")
        XCTAssertEqual(vm.quiet?.total, 2)
    }

    func testALongResultFromBeforeARefreshDoesNotOverwriteTheReload() async {
        let (vm, fake, _) = make()
        fake.long = StalledList(total: 1, rows: [StalledProject(project: project(1))])
        await vm.start()
        fake.gate("long")
        let slow = Task { await vm.select(.long) }
        await fake.waitUntilHeld("long")
        fake.long = StalledList(total: 2, rows: [])
        await vm.refresh()
        XCTAssertEqual(vm.long?.total, 2)
        fake.release("long")
        await slow.value
        XCTAssertEqual(vm.long?.total, 2, "the late pre-refresh result must not win")
    }

    func testAskAboutSendsTheExactMessage() async {
        let (vm, _, log) = make()
        // The formatter picks the unit: 19 days reads as "2 weeks ago".
        await vm.ask(about: StalledProject(project: project(7), lastMovedAt: now.addingTimeInterval(-19 * 86_400)))
        await vm.ask(about: StalledProject(project: project(7), lastMovedAt: now.addingTimeInterval(-3 * 86_400)))
        let sent = await log.messages
        XCTAssertEqual(sent, ["What should we do with the project “Project 7”? It last moved 2 weeks ago.",
                              "What should we do with the project “Project 7”? It last moved 3 days ago."])
    }

    func testAskAboutAProjectThatNeverMoved() async {
        let (vm, _, log) = make()
        await vm.ask(about: StalledProject(project: project(8)))
        let sent = await log.messages
        XCTAssertEqual(sent, ["What should we do with the project “Project 8”? It hasn't moved yet."])
    }

    func testAskFailureSurfacesAsError() async {
        let fake = FakeTimeline()
        let vm = TimelineViewModel(timeline: fake, askCoordinator: { _ in throw JournalAPIError.forbidden })
        await vm.ask(about: StalledProject(project: project(1)))
        XCTAssertEqual(vm.error, JournalAPIError.forbidden.localizedDescription)
    }

    func testLoadCountsReadsBothListsSoTheSidebarHasTheirTotals() async {
        let (vm, fake, _) = make()
        fake.quiet = StalledList(total: 5, rows: [StalledProject(project: project(1))])
        fake.long = StalledList(total: 7, rows: [StalledProject(project: project(2))])
        await vm.start()
        XCTAssertNil(vm.quiet)
        await vm.loadCounts()
        XCTAssertEqual(vm.quiet?.total, 5)
        XCTAssertEqual(vm.long?.total, 7)
        await vm.select(.quiet)
        await vm.select(.long)
        XCTAssertEqual(fake.quietCalls, 1, "a visit after the counts reads nothing again")
        XCTAssertEqual(fake.longCalls, 1)
        await vm.loadCounts()
        XCTAssertEqual(fake.quietCalls, 1, "fresh lists are not re-read")
        await vm.refresh()
        await vm.loadCounts()
        XCTAssertEqual(fake.quietCalls, 2, "after a refresh the counts re-read")
        XCTAssertEqual(fake.longCalls, 2)
    }

    func testCountsFromBeforeARefreshAreDropped() async {
        let (vm, fake, _) = make()
        fake.quiet = StalledList(total: 1, rows: [])
        await vm.start()
        fake.gate("quiet")
        let counts = Task { await vm.loadCounts() }
        await fake.waitUntilHeld("quiet")
        await vm.refresh()
        fake.release("quiet")
        await counts.value
        XCTAssertNil(vm.quiet, "the pre-refresh counts are dropped")
        XCTAssertNil(vm.long)
    }

    func testAFailedCountReadStaysQuiet() async {
        let fake = FakeTimeline()
        let vm = TimelineViewModel(timeline: fake, askCoordinator: { _ in })
        fake.failsLists = true
        await vm.loadCounts()
        XCTAssertNil(vm.quiet)
        XCTAssertNil(vm.error, "a count is a hint: no alert")
    }

    /// The Ask has gone whatever the lists say next: a refresh keeps the
    /// row saying so (a new session drops the whole view model).
    func testASuccessfulAskMarksTheRowAcrossARefresh() async {
        let (vm, _, _) = make()
        await vm.start()
        await vm.ask(about: StalledProject(project: project(3)))
        XCTAssertEqual(vm.askedProjectIDs, ["pj_3"])
        await vm.refresh()
        XCTAssertEqual(vm.askedProjectIDs, ["pj_3"])
    }

    /// Finished has no page until its first read lands: then its rows,
    /// or none at all, which is a page too.
    func testFinishedIsLoadedOnceItsFirstReadLands() async {
        let (vm, fake, _) = make()
        await vm.start()
        XCTAssertFalse(vm.hasLoadedFinished)
        XCTAssertEqual(vm.content(for: .finished), .loading)
        fake.gate("finished:nil")
        let visit = Task { await vm.select(.finished) }
        await fake.waitUntilHeld("finished:nil")
        XCTAssertEqual(vm.content(for: .finished), .loading, "still reading")
        fake.release("finished:nil")
        await visit.value
        XCTAssertTrue(vm.hasLoadedFinished)
        XCTAssertEqual(vm.content(for: .finished), .finished([], hasMore: false))
        XCTAssertTrue(vm.hasContent(for: .finished), "an empty list is a page")
    }

    func testAFailedAskDoesNotMarkTheRow() async {
        let vm = TimelineViewModel(timeline: FakeTimeline(), askCoordinator: { _ in throw JournalAPIError.forbidden })
        await vm.ask(about: StalledProject(project: project(3)))
        XCTAssertEqual(vm.askedProjectIDs, [])
    }

    /// Two refreshes read the same week at once and the older answers
    /// last: the newer read stays on screen.
    func testAnOlderReadOfTheSameWeekDoesNotReplaceANewerOne() async {
        let (vm, fake, _) = make()
        await vm.start()
        fake.weekDetails["2026-11-02"] = TimelineWeek(week: "2026-11-02", start: now, end: now, final: true, lede: "Older")
        fake.gate("week:2026-11-02")
        let older = Task { await vm.refresh() }
        await fake.waitUntilHeld("week:2026-11-02")
        fake.weekDetails["2026-11-02"] = TimelineWeek(week: "2026-11-02", start: now, end: now, final: true, lede: "Newer")
        await vm.refresh()
        XCTAssertEqual(vm.week?.lede, "Newer")
        fake.release("week:2026-11-02")
        await older.value
        XCTAssertEqual(vm.week?.lede, "Newer")
        XCTAssertNil(vm.error)
    }

    /// An older read of the same week that fails after a newer one landed
    /// says nothing: the page has the newer week.
    func testAnOlderFailedReadOfTheSameWeekSetsNoError() async {
        let (vm, fake, _) = make()
        await vm.start()
        fake.weekError = JournalAPIError.forbidden
        fake.gate("week:2026-11-02")
        let older = Task { await vm.refresh() }
        await fake.waitUntilHeld("week:2026-11-02")
        fake.weekError = nil
        await vm.refresh()
        fake.release("week:2026-11-02")
        await older.value
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.week?.week, "2026-11-02")
    }

    // MARK: - All projects

    private func row(_ n: Int) -> TimelineProjectRow { TimelineProjectRow(project: project(n), lastMovedAt: now, openMissions: 1) }

    /// Two pages of three projects: 1 and 2, then 3.
    private func scriptProjects(_ fake: FakeTimeline) {
        fake.projectPages[nil] = TimelineProjectList(total: 3, rows: [row(1), row(2)], nextBefore: "cursor")
        fake.projectPages["cursor"] = TimelineProjectList(total: 3, rows: [row(3)])
    }

    func testSelectingAllProjectsLoadsOnceAndPagesWithNextBefore() async {
        let (vm, fake, _) = make()
        scriptProjects(fake)
        await vm.start()
        XCTAssertNil(vm.allProjects)
        XCTAssertEqual(vm.content(for: .projects), .loading)
        XCTAssertFalse(vm.hasContent(for: .projects))
        await vm.select(.projects)
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2])
        XCTAssertEqual(vm.allProjects?.total, 3)
        XCTAssertTrue(vm.hasMoreProjects)
        XCTAssertTrue(vm.hasContent(for: .projects))
        XCTAssertEqual(vm.content(for: .projects),
                       .projects(TimelineProjectList(total: 3, rows: [row(1), row(2)], nextBefore: "cursor"), hasMore: true))
        await vm.loadMoreProjects()
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2, 3])
        XCTAssertEqual(vm.allProjects?.total, 3)
        XCTAssertFalse(vm.hasMoreProjects)
        XCTAssertEqual(vm.content(for: .projects),
                       .projects(TimelineProjectList(total: 3, rows: [row(1), row(2), row(3)]), hasMore: false))
        await vm.loadMoreProjects()
        await vm.select(.week("2026-11-02"))
        await vm.select(.projects)
        XCTAssertEqual(fake.projectsCalls, [nil, "cursor"], "cached; no extra requests")
        await vm.refresh()
        XCTAssertEqual(fake.projectsCalls, [nil, "cursor", nil], "a refresh on the list re-reads its first page")
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2])
    }

    func testAFailedAllProjectsReadSetsError() async {
        let (vm, _, _) = make()
        await vm.start()
        await vm.select(.projects)
        XCTAssertNil(vm.allProjects)
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.content(for: .projects), .failed)
    }

    /// A read called off is not a failure to tell the reader about.
    func testACancelledAllProjectsReadSetsNoError() async {
        let (vm, fake, _) = make()
        scriptProjects(fake)
        await vm.start()
        fake.projectsError = JournalAPIError.transport("cancelled")
        await vm.select(.projects)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.content(for: .projects), .loading)
        fake.projectsError = nil
        await vm.select(.week("2026-11-02"))
        await vm.select(.projects)
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2], "the next visit reads it")
        fake.projectsError = JournalAPIError.transport("cancelled")
        await vm.loadMoreProjects()
        XCTAssertNil(vm.error)
        XCTAssertTrue(vm.hasMoreProjects, "the page can be asked for again")
    }

    func testPagingAllProjectsDuringAReloadIsRefused() async {
        let (vm, fake, _) = make()
        scriptProjects(fake)
        await vm.start()
        await vm.select(.projects)
        fake.projectPages[nil] = TimelineProjectList(total: 3, rows: [row(1), row(2), row(3)])
        fake.gate("projects:nil")
        fake.gate("projects:cursor")
        let reload = Task { await vm.refresh() }
        await fake.waitUntilHeld("projects:nil")
        let paging = Task { await vm.loadMoreProjects() }
        await settle()
        fake.release("projects:nil")
        await reload.value
        fake.release("projects:cursor")
        await paging.value
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2, 3])
        XCTAssertEqual(fake.projectsCalls, [nil, nil], "no page was requested off the old cursor")
    }

    func testAnAllProjectsPageFetchedBeforeARefreshIsDropped() async {
        let (vm, fake, _) = make()
        scriptProjects(fake)
        await vm.start()
        await vm.select(.projects)
        fake.gate("projects:cursor")
        let paging = Task { await vm.loadMoreProjects() }
        await fake.waitUntilHeld("projects:cursor")
        fake.projectPages[nil] = TimelineProjectList(total: 3, rows: [row(1), row(2), row(3)])
        await vm.refresh()
        fake.release("projects:cursor")
        await paging.value
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2, 3], "no duplicate tail")
        XCTAssertFalse(vm.hasMoreProjects)
    }

    func testLoadCountsReadsTheFirstAllProjectsPageForTheSidebar() async {
        let (vm, fake, _) = make()
        scriptProjects(fake)
        await vm.start()
        await vm.loadCounts()
        XCTAssertEqual(vm.allProjects?.total, 3)
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2])
        await vm.select(.projects)
        await vm.loadCounts()
        XCTAssertEqual(fake.projectsCalls, [nil], "a visit after the counts, and fresh counts, read nothing again")
        await vm.loadMoreProjects()
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2, 3], "the counts' page pages on")
        await vm.refresh()
        await vm.loadCounts()
        XCTAssertEqual(fake.projectsCalls, [nil, "cursor", nil], "after a refresh the counts re-read")
        XCTAssertEqual(vm.allProjects?.rows.map(\.project.num), [1, 2])
    }

    func testAnAllProjectsCountFromBeforeARefreshIsDropped() async {
        let (vm, fake, _) = make()
        scriptProjects(fake)
        await vm.start()
        fake.gate("projects:nil")
        let counts = Task { await vm.loadCounts() }
        await fake.waitUntilHeld("projects:nil")
        await vm.refresh()
        fake.release("projects:nil")
        await counts.value
        XCTAssertNil(vm.allProjects, "the pre-refresh count is dropped")
    }

    func testCountsOnAJournalWithoutAllProjectsStayQuiet() async {
        let (vm, fake, _) = make()
        fake.quiet = StalledList(total: 5, rows: [])
        await vm.start()
        await vm.loadCounts()
        XCTAssertNil(vm.allProjects)
        XCTAssertNil(vm.error, "a count is a hint: no alert")
        XCTAssertEqual(vm.quiet?.total, 5, "the other counts still land")
    }

    func testFlagKey() {
        XCTAssertEqual(TimelineViewModel.flagKey, "projects.timeline")
    }
}

private actor AskLog {
    private(set) var messages: [String] = []
    func add(_ message: String) { messages.append(message) }
}
