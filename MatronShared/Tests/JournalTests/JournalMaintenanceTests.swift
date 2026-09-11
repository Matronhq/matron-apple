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
        /// Bugbot round 2 (A): actually tracked now, not stubbed to
        /// constants, so `contains`/`eventCount` can prove a removal
        /// happened rather than just recording that `removeAll` was called.
        private var _indexed: Set<String> = []
        var removed: [[String]] { lock.lock(); defer { lock.unlock() }; return _removed }
        /// Awaited inside `removeAll` — the suspension point the `stop()`
        /// test needs in order to hold a sweep open.
        var beforeRemoveAll: (@Sendable () async -> Void)?
        /// Set by a test to make `removeAll` throw — Bugbot A scenario 3: a
        /// failed search removal must leave the search-retention watermark
        /// untouched so the next pass retries the same seqs.
        var removeAllError: Error?

        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
            lock.lock(); _indexed.insert(eventID); lock.unlock()
        }
        func indexBatch(_ entries: [SearchIndexEntry]) async throws {
            lock.lock(); for entry in entries { _indexed.insert(entry.eventID) }; lock.unlock()
        }
        func remove(eventID: String) async throws {
            lock.lock(); _indexed.remove(eventID); lock.unlock()
        }
        func removeAll(eventIDs: [String]) async throws {
            await beforeRemoveAll?()
            if let removeAllError { throw removeAllError }
            lock.lock()
            _removed.append(eventIDs)
            for id in eventIDs { _indexed.remove(id) }
            lock.unlock()
        }
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
        func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] { [] }
        func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] { [] }
        func eventCount(roomID: String) async throws -> Int {
            lock.lock(); defer { lock.unlock() }; return _indexed.count
        }
        func contains(eventID: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }; return _indexed.contains(eventID)
        }
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

    // MARK: - Launch hold (Bugbot High, follow-up fix)

    /// `start()`'s own schedule already delays its first tick by
    /// `firstRunDelay`, but nothing previously stopped an app-foreground
    /// hook (`runIfDue()`, called with no delay of its own) from racing
    /// ahead of it — and on the very first launch the scene goes
    /// inactive → active immediately. Without a hold, a due store (fresh
    /// upgrade, no stored `maintenance_last_run`) would run the first,
    /// possibly history-sized pass right on the launch path.
    func testStartArmsALaunchHoldThatBlocksAnImmediateRunIfDue() async throws {
        let store = SpyStore() // no lastRun: due immediately
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.start()
        await maintenance.runIfDue(now: t0)
        XCTAssertNil(store.lastRunStamp,
                     "an app-foreground hook landing right at launch must not run a pass during the hold")
        await maintenance.stop()
    }

    /// Catch-up finishing is the signal the launch path is over, so
    /// `runAfterCatchUp()` may run a due pass even while still inside the
    /// hold window.
    func testRunAfterCatchUpRunsDuringTheHold() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.start()
        await maintenance.runAfterCatchUp()
        XCTAssertEqual(store.lastRunStamp, t0, "catch-up completing lets a due pass run early")
        await maintenance.stop()
    }

    /// Once `now` reaches the hold's expiry, `runIfDue` behaves normally
    /// again with no need for `runAfterCatchUp`.
    func testRunIfDueRunsOnceTheHoldExpires() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.start()
        let delay = TimeInterval(JournalMaintenance.firstRunDelay.components.seconds)
        let afterHold = t0.addingTimeInterval(delay + 1)
        await maintenance.runIfDue(now: afterHold)
        XCTAssertEqual(store.lastRunStamp, afterHold, "the hold has expired — a due pass runs normally")
        await maintenance.stop()
    }

    func testRetiredSeqsAreRemovedFromTheSearchIndexInOneBatch() async throws {
        let store = SpyStore()
        // Bugbot round 2 (A): search removal is driven by the INDEPENDENT
        // `pendingSearchRetirements` watermark, not `applyRetention`'s
        // return value — see `JournalMaintenance.run`.
        store.pendingSearchResult = (seqs: [11, 12, 13], cutoff: t0)
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(search.removed, [["11", "12", "13"]],
                       "search rows are keyed by String(seq) — see JournalSyncEngine.indexForSearch")
        XCTAssertEqual(store.searchRetirementCutoffs, [t0],
                       "a successful removal must advance the search-retention watermark")
    }

    func testNothingRetiredMeansNoSearchWrite() async throws {
        let store = SpyStore()
        store.pendingSearchResult = (seqs: [], cutoff: t0)
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertTrue(search.removed.isEmpty)
        XCTAssertEqual(store.searchRetirementCutoffs, [t0],
                       "an empty pass still records the watermark so it isn't rescanned every tick")
    }

    /// Bugbot round 2 (A): search retirement now runs off its OWN watermark
    /// (`pendingSearchRetirements` / `recordSearchRetirement`), independent
    /// of `applyRetention`'s return value — a real store still proves the
    /// end-to-end wiring: a >30-day live-log row is found by the pending
    /// scan and reaches `search.removeAll` in the very first pass,
    /// regardless of whether `applyRetention`'s own rewrite ran before or
    /// after it (the two watermarks are unrelated; R9's retention-first
    /// order is retained purely for disk hygiene — see `run`'s doc comment
    /// — not because search correctness depends on it any more).
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

    /// I1: `stop()` cancels the in-flight pass (`inFlight?.cancel()`) before
    /// awaiting it, so a pass interrupted while suspended in `removeAll`
    /// must still let `stop()` block until the pass task actually finishes
    /// — but the finish is now via the `Task.isCancelled` guards in
    /// `run(now:)`, not a normal completion, so neither
    /// `recordSearchRetirement` nor `recordMaintenanceRun` runs.
    func testStopAwaitsTheInFlightSweep() async throws {
        let store = SpyStore()
        store.pendingSearchResult = (seqs: [7], cutoff: t0)
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
        XCTAssertNil(store.lastRunStamp,
                     "the pass was cancelled — it must not buy itself a quiet interval it did not earn")
        XCTAssertTrue(store.searchRetirementCutoffs.isEmpty,
                      "the pass was cancelled before recordSearchRetirement — the watermark must not advance")
    }

    /// I1: on a real store, cancelling mid-pass must leave the search
    /// retention watermark exactly where it was before the pass started —
    /// the pending seq must still be pending for the next (uninterrupted)
    /// pass to find and retire.
    func testStopDuringAPassLeavesTheSearchRetentionWatermarkAtItsPreScanValue() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.insertHistory([liveLogToolOutputEvent(seq: 1)], now: Date(timeIntervalSince1970: 2))
        let laterNow = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)
        let preScan = try store.pendingSearchRetirements(now: laterNow)
        XCTAssertEqual(preScan.seqs, [1], "precondition: the seq is pending retirement")

        let search = RecordingSearch()
        let gate = Gate()
        search.beforeRemoveAll = { await gate.wait() }
        let maintenance = JournalMaintenance(store: store, search: search, now: { laterNow })

        let pass = Task { await maintenance.runIfDue() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(try store.maintenanceLastRun(), "precondition: the pass has not finished")

        // `stop()` awaits the cancelled pass, and the pass is parked inside
        // `removeAll` until the gate opens — run them concurrently rather
        // than opening the gate only after `stop()` returns, or this
        // deadlocks.
        let stopping = Task { await maintenance.stop() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        await stopping.value
        await pass.value

        XCTAssertNil(try store.maintenanceLastRun(),
                     "an interrupted pass must not stamp maintenance_last_run")
        let postStop = try store.pendingSearchRetirements(now: laterNow)
        XCTAssertEqual(postStop.seqs, [1],
                       "the search retention watermark did not advance past its pre-scan value")
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

    // MARK: - Bugbot round 2 (PR #212)

    private func liveLogToolOutputEvent(seq: Int64) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: 1),
                     sender: "agent:dev-2", type: JournalEventType.toolOutput,
                     payloadData: try! JSONSerialization.data(withJSONObject: [
                        "command": "make test", "live_log": true, "snippet": "out",
                     ] as [String: Any]))
    }

    /// A (High): "search removal is never retried." With no search
    /// attached, a pass must skip search retirement ENTIRELY — leaving
    /// `search_retention_ts` untouched — rather than advancing the
    /// watermark past rows nothing ever removed from an index.
    func testWithNoSearchAttachedAPassLeavesTheSearchWatermarkUntouchedAndTheSeqComesBackNextCall() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.insertHistory([liveLogToolOutputEvent(seq: 1)], now: Date(timeIntervalSince1970: 2))
        let laterNow = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)

        let maintenance = JournalMaintenance(store: store, search: nil, now: { laterNow })
        await maintenance.runIfDue()

        let pending = try store.pendingSearchRetirements(now: laterNow)
        XCTAssertEqual(pending.seqs, [1],
                       "nothing removed it from an index this pass never had a reference to")
    }

    /// A (High): after `attachSearch` resolves the index (the iOS
    /// locked-background-launch path), the very next pass removes the
    /// pending seqs and advances the watermark so a further pass has
    /// nothing left to retire.
    func testAfterAttachSearchAPassRemovesThePendingSeqsAndAdvancesTheWatermark() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.insertHistory([liveLogToolOutputEvent(seq: 1)], now: Date(timeIntervalSince1970: 2))
        let laterNow = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)
        let search = RecordingSearch()
        try await search.index(roomID: "c1", eventID: "1", sender: "agent:dev-2",
                               timestamp: Date(timeIntervalSince1970: 1), body: "out")

        let maintenance = JournalMaintenance(store: store, search: nil, now: { laterNow })
        await maintenance.attachSearch(search)
        await maintenance.runIfDue()

        XCTAssertEqual(search.removed, [["1"]])
        let stillIndexed = try await search.contains(eventID: "1")
        XCTAssertFalse(stillIndexed, "removeAll must have actually removed it from the index")
        let remainingCount = try await search.eventCount(roomID: "c1")
        XCTAssertEqual(remainingCount, 0)

        let pending = try store.pendingSearchRetirements(now: laterNow)
        XCTAssertTrue(pending.seqs.isEmpty,
                      "the watermark must have advanced — a further pass has nothing pending")
    }

    /// A (High): a search whose `removeAll` throws must leave the
    /// search-retention watermark untouched, and the SAME seq must come
    /// back and succeed on the next pass once the failure clears.
    func testASearchRemovalFailureLeavesTheWatermarkUntouchedAndRetriesNextPass() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.insertHistory([liveLogToolOutputEvent(seq: 1)], now: Date(timeIntervalSince1970: 2))
        let laterNow = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)
        let search = RecordingSearch()
        search.removeAllError = SpyStore.Boom()

        let maintenance = JournalMaintenance(store: store, search: search, now: { laterNow })
        await maintenance.runIfDue()

        XCTAssertTrue(search.removed.isEmpty, "the throwing removal must not have recorded a batch")
        var pending = try store.pendingSearchRetirements(now: laterNow)
        XCTAssertEqual(pending.seqs, [1], "a failed pass must not advance the watermark")

        search.removeAllError = nil
        // The failed pass never stamped `maintenance_last_run`, so this
        // retry does not need to wait out the hour — same rule as
        // `testAFailedSweepIsNotStampedAndIsRetriedNextTick`.
        await maintenance.runIfDue(now: laterNow.addingTimeInterval(60))

        XCTAssertEqual(search.removed, [["1"]], "the retry must succeed against the same seq")
        pending = try store.pendingSearchRetirements(now: laterNow.addingTimeInterval(60))
        XCTAssertTrue(pending.seqs.isEmpty, "the watermark must now be advanced")
    }

    /// B (Medium): "stop does not fence later sweeps." Once `stop()` has
    /// returned, `runIfDue` and `start()` must be permanent no-ops — a
    /// still-live sync engine reaching `.running` again (or anything else
    /// holding this instance) must not be able to open a brand new pass
    /// against a store that sign-out is about to wipe. `stop()` itself must
    /// also be idempotent.
    func testRunIfDueAndStartAfterStopPerformNoSweepAndStopIsIdempotent() async throws {
        let store = SpyStore()
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })

        await maintenance.stop()
        await maintenance.stop() // idempotent: must not hang or throw

        await maintenance.runIfDue()
        XCTAssertTrue(store.purgeCalls.isEmpty, "no sweep may run after stop()")
        XCTAssertTrue(store.retentionCalls.isEmpty)
        XCTAssertTrue(search.removed.isEmpty, "search must be untouched after stop()")
        XCTAssertNil(store.lastRunStamp)

        // `start()` must not resurrect the schedule either — there is no
        // "unstop"; a new sign-in builds a new `JournalMaintenance`.
        await maintenance.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.purgeCalls.isEmpty, "start() after stop() must not arm a new schedule")
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
    private var _pendingSearchCalls: [Date] = []
    private var _searchRetirementCutoffs: [Date] = []
    var retentionResult: [Int64] = []
    var purgeError: Error?
    /// Bugbot round 2 (A): what `pendingSearchRetirements` hands back — the
    /// old `retentionResult`-feeds-search wiring is gone, so a test that
    /// wants `JournalMaintenance` to see pending seqs sets this instead.
    var pendingSearchResult: (seqs: [Int64], cutoff: Date) = ([], Date(timeIntervalSince1970: 0))
    var pendingSearchError: Error?

    init(lastRun: Date? = nil) { _lastRun = lastRun }

    var purgeCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _purgeCalls }
    var retentionCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _retentionCalls }
    var callOrder: [String] { lock.lock(); defer { lock.unlock() }; return _callOrder }
    var lastRunStamp: Date? { lock.lock(); defer { lock.unlock() }; return _lastRun }
    var pendingSearchCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _pendingSearchCalls }
    var searchRetirementCutoffs: [Date] { lock.lock(); defer { lock.unlock() }; return _searchRetirementCutoffs }

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
    func pendingSearchRetirements(now: Date) throws -> (seqs: [Int64], cutoff: Date) {
        if let pendingSearchError { throw pendingSearchError }
        lock.lock(); _pendingSearchCalls.append(now); _callOrder.append("pendingSearchRetirements"); lock.unlock()
        return pendingSearchResult
    }
    func recordSearchRetirement(upTo cutoff: Date) throws {
        lock.lock(); _searchRetirementCutoffs.append(cutoff); _callOrder.append("recordSearchRetirement"); lock.unlock()
    }
}
