import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// A scripted `TimelineProviding`: pages keyed by `before`, per-call counters,
/// and a switch to fail the next call of a route.
private final class FakeTimeline: TimelineProviding, @unchecked Sendable {
    private let lock = NSLock()
    var weekPages: [String?: (weeks: [TimelineWeekSummary], nextBefore: String?)] = [:]
    var weekDetails: [String: TimelineWeek] = [:]
    var quiet = StalledList(total: 0, rows: [])
    var long = StalledList(total: 0, rows: [])
    var finishedPages: [String?: (rows: [FinishedProject], nextBefore: String?)] = [:]
    var weeksError: Error?
    var weekError: Error?
    private(set) var weeksCalls: [String?] = []
    private(set) var weekCalls: [String] = []
    private(set) var quietCalls = 0
    private(set) var longCalls = 0
    private(set) var finishedCalls: [String?] = []

    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        lock.lock(); defer { lock.unlock() }
        weeksCalls.append(before)
        if let weeksError { throw weeksError }
        return weekPages[before] ?? ([], nil)
    }

    func timelineWeek(_ week: String) async throws -> TimelineWeek {
        lock.lock(); defer { lock.unlock() }
        weekCalls.append(week)
        if let weekError { throw weekError }
        guard let detail = weekDetails[week] else { throw JournalAPIError.notFound }
        return detail
    }

    func wentQuiet() async throws -> StalledList {
        lock.lock(); defer { lock.unlock() }
        quietCalls += 1
        return quiet
    }

    func openLong() async throws -> StalledList {
        lock.lock(); defer { lock.unlock() }
        longCalls += 1
        return long
    }

    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        lock.lock(); defer { lock.unlock() }
        finishedCalls.append(before)
        return finishedPages[before] ?? ([], nil)
    }
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

    func testFlagKey() {
        XCTAssertEqual(TimelineViewModel.flagKey, "projects.timeline")
    }
}

private actor AskLog {
    private(set) var messages: [String] = []
    func add(_ message: String) { messages.append(message) }
}
