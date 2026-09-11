import XCTest
@testable import MatronJournal
import MatronSearch

/// Scheduling and sequencing of the background sweeper. The cadence is
/// driven entirely through `runIfDue(now:)` with an injected clock — the
/// 10 s / 60 min timers in `start()` are a thin wrapper around it, so no
/// test has to sleep.
final class JournalMaintenanceTests: XCTestCase {
    /// Conforms to the WHOLE protocol: `eventCount(roomID:)` and
    /// `contains(eventID:)` are requirements with no extension default
    /// (`MatronShared/Sources/Search/SearchService.swift:62,65`), so omitting
    /// them would not compile — compare `InMemorySearchService` in
    /// `SearchBackfillCoordinatorTests`, which implements both.
    private final class RecordingSearch: SearchService, @unchecked Sendable {
        private let lock = NSLock()
        private var _removed: [[String]] = []
        var removed: [[String]] { lock.lock(); defer { lock.unlock() }; return _removed }
        /// Awaited inside `removeAll` — the suspension point the `stop()`
        /// test needs in order to hold a sweep open.
        var beforeRemoveAll: (@Sendable () async -> Void)?

        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
        func indexBatch(_ entries: [SearchIndexEntry]) async throws {}
        func remove(eventID: String) async throws {}
        func removeAll(eventIDs: [String]) async throws {
            await beforeRemoveAll?()
            lock.lock(); _removed.append(eventIDs); lock.unlock()
        }
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
        func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] { [] }
        func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] { [] }
        func eventCount(roomID: String) async throws -> Int { 0 }
        func contains(eventID: String) async throws -> Bool { false }
        func wipe() async throws {}
        func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
        func backfillComplete(roomID: String) async throws -> Bool { true }
        func backfillOldestEventID(roomID: String) async throws -> String? { nil }
        func resetBackfill() async throws {}
    }

    /// One-shot suspension point: `wait()` parks until `open()` resumes it.
    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// Lets a test ask "has that `await` returned yet?" without racing.
    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstRunSweepsWhenNothingHasEverRun() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(store.purgeCalls, [t0])
        XCTAssertEqual(store.retentionCalls, [t0])
        XCTAssertEqual(store.callOrder, ["retention", "purge"], "R9: retention sweeps first")
        XCTAssertEqual(store.lastRunStamp, t0, "a completed sweep stamps maintenance_last_run")
    }

    func testASecondRunInsideTheHourDoesNothing() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        await maintenance.runIfDue(now: t0.addingTimeInterval(59 * 60))
        XCTAssertEqual(store.purgeCalls.count, 1, "the hourly cadence is the whole point of the watermark")
    }

    func testARunPastTheHourSweepsAgain() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        let later = t0.addingTimeInterval(61 * 60)
        await maintenance.runIfDue(now: later)
        XCTAssertEqual(store.purgeCalls, [t0, later])
    }

    /// The foreground path: a process that starts with a stamp older than an
    /// hour sweeps immediately rather than waiting out a timer.
    func testAStaleStoredStampSweepsOnTheFirstForegroundCheck() async throws {
        let store = SpyStore(lastRun: t0.addingTimeInterval(-2 * 3600))
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(store.purgeCalls, [t0])
    }

    func testAFreshStoredStampSkipsTheFirstRun() async throws {
        let store = SpyStore(lastRun: t0.addingTimeInterval(-10 * 60))
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertTrue(store.purgeCalls.isEmpty,
                      "a launch ten minutes after the last sweep must not re-sweep")
    }

    func testRetiredSeqsAreRemovedFromTheSearchIndexInOneBatch() async throws {
        let store = SpyStore()
        store.retentionResult = [11, 12, 13]
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(search.removed, [["11", "12", "13"]],
                       "search rows are keyed by String(seq) — see JournalSyncEngine.indexForSearch")
    }

    func testNothingRetiredMeansNoSearchWrite() async throws {
        let store = SpyStore()
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertTrue(search.removed.isEmpty)
    }

    /// R9, the ordering that makes spec goal D actually happen. Retention
    /// must run FIRST: the 24 h sweep's first-pass range is `(0, now − 24 h]`,
    /// which contains every >30-day row, and `EventTombstone.apply` gives
    /// those the retention rewrite — so if the 24 h sweep ran first,
    /// `applyRetention` would find them already tombstoned, return no seqs,
    /// and their search rows would live forever.
    func testRetentionRunsFirstSoItsSeqsReachTheSearchIndex() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let fresh = Date(timeIntervalSince1970: 2)
        try store.insertHistory([
            JournalEvent(seq: 1, convoID: "c1", ts: Date(timeIntervalSince1970: 1),
                         sender: "agent:dev-2", type: JournalEventType.toolOutput,
                         payloadData: try JSONSerialization.data(withJSONObject: [
                            "command": "make test", "live_log": true, "snippet": "out",
                         ] as [String: Any])),
        ], now: fresh)

        let search = RecordingSearch()
        let maintenance = JournalMaintenance(
            store: store, search: search,
            now: { Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600) })
        await maintenance.runIfDue()

        XCTAssertEqual(search.removed, [["1"]],
                       "a >30-day live-log row must come back in the retention seqs on the first pass")
    }

    func testStopAwaitsTheInFlightSweep() async throws {
        let store = SpyStore()
        store.retentionResult = [7]
        let search = RecordingSearch()
        let gate = Gate()
        search.beforeRemoveAll = { await gate.wait() }
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })

        let pass = Task { await maintenance.runIfDue() }
        // Let the pass reach the suspension inside `removeAll`.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(store.lastRunStamp, "precondition: the pass has not finished")

        let stopped = Flag()
        let stopping = Task { await maintenance.stop(); await stopped.set() }
        try await Task.sleep(for: .milliseconds(50))
        let returnedEarly = await stopped.isSet
        XCTAssertFalse(returnedEarly,
                       "stop() returned while a sweep was still suspended — sign-out would wipe under it")

        await gate.open()
        await stopping.value
        await pass.value
        XCTAssertEqual(store.lastRunStamp, t0, "stop() must not return until the pass completes")
    }

    /// A failed sweep must not stamp `maintenance_last_run`: the next tick
    /// has to retry, and nothing about a failure may block the app.
    func testAFailedSweepIsNotStampedAndIsRetriedNextTick() async throws {
        let store = SpyStore()
        store.purgeError = SpyStore.Boom()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertNil(store.lastRunStamp)

        store.purgeError = nil
        let later = t0.addingTimeInterval(60)
        await maintenance.runIfDue(now: later)
        XCTAssertEqual(store.lastRunStamp, later, "the retry does not wait out the hour")
    }
}

/// Plain (non-actor) recorder: `MaintenanceSweeping` is synchronous and
/// throwing, which an actor cannot satisfy without hops, and every call
/// lands on the maintenance actor's single executor anyway.
final class SpyStore: MaintenanceSweeping, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    private var _purgeCalls: [Date] = []
    private var _retentionCalls: [Date] = []
    private var _callOrder: [String] = []
    private var _lastRun: Date?
    var retentionResult: [Int64] = []
    var purgeError: Error?

    init(lastRun: Date? = nil) { _lastRun = lastRun }

    var purgeCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _purgeCalls }
    var retentionCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _retentionCalls }
    var callOrder: [String] { lock.lock(); defer { lock.unlock() }; return _callOrder }
    var lastRunStamp: Date? { lock.lock(); defer { lock.unlock() }; return _lastRun }

    func purgeExpiredToolOutputSnippets(now: Date) throws {
        if let purgeError { throw purgeError }
        lock.lock(); _purgeCalls.append(now); _callOrder.append("purge"); lock.unlock()
    }
    func applyRetention(now: Date) throws -> [Int64] {
        lock.lock(); _retentionCalls.append(now); _callOrder.append("retention"); lock.unlock()
        return retentionResult
    }
    func maintenanceLastRun() throws -> Date? { lastRunStamp }
    func recordMaintenanceRun(at date: Date) throws {
        lock.lock(); _lastRun = date; lock.unlock()
    }
}
