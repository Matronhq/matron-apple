import GRDB
import XCTest
@testable import MatronSearch

/// `LockAwareSearchService`: nothing reaches the index file while protected
/// data is unavailable (a page-in of the locked `NSFileProtectionComplete`
/// file is a SIGBUS, not an error). Indexing is buffered and flushed on
/// unlock; everything else throws for its caller's retry.
final class LockAwareSearchServiceTests: XCTestCase {
    /// Mutable protected-data flag the gate reads from its actor.
    private final class Lock: @unchecked Sendable {
        private let lock = NSLock()
        private var _available = true
        var available: Bool {
            get { lock.withLock { _available } }
            set { lock.withLock { _available = newValue } }
        }
    }

    /// Records every batch that reaches the index and can refuse writes the
    /// way a suspended or interrupted GRDB database does.
    private actor RecordingIndex: SearchService {
        var batches: [[String]] = []
        var removed: [[String]] = []
        var refuseWrites: DatabaseError?
        var wipes = 0

        func setRefuseWrites(_ error: DatabaseError?) { refuseWrites = error }

        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
            try await indexBatch([SearchIndexEntry(roomID: roomID, eventID: eventID, sender: sender,
                                                   timestamp: timestamp, body: body)])
        }
        func indexBatch(_ entries: [SearchIndexEntry]) async throws {
            if let refuseWrites { throw refuseWrites }
            batches.append(entries.map(\.eventID))
        }
        func remove(eventID: String) async throws { removed.append([eventID]) }
        func removeAll(eventIDs: [String]) async throws { removed.append(eventIDs) }
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
        func wipe() async throws { wipes += 1 }
        func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
        func backfillComplete(roomID: String) async throws -> Bool { false }
        func backfillOldestEventID(roomID: String) async throws -> String? { nil }
        func resetBackfill() async throws {}
        func eventCount(roomID: String) async throws -> Int { 0 }
        func contains(eventID: String) async throws -> Bool { false }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func increment() { lock.withLock { _count += 1 } }
    }

    private func entries(_ ids: [Int], body: String = "hello") -> [SearchIndexEntry] {
        ids.map { SearchIndexEntry(roomID: "c1", eventID: String($0), sender: "agent:box-2",
                                   timestamp: Date(timeIntervalSince1970: Double($0)), body: body) }
    }

    func testIndexingWhileLockedIsBufferedAndFlushedInOrderOnUnlock() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })

        lock.available = false
        try await gate.indexBatch(entries([1, 2]))
        try await gate.index(roomID: "c1", eventID: "3", sender: "s", timestamp: Date(), body: "b")
        let whileLocked = await index.batches
        XCTAssertEqual(whileLocked, [], "nothing may reach the index while locked")
        let pendingWhileLocked = await gate.pendingCount
        XCTAssertEqual(pendingWhileLocked, 3)

        // A flush attempted while still locked is a no-op.
        await gate.flushPending()
        let stillNothing = await index.batches
        XCTAssertEqual(stillNothing, [])

        lock.available = true
        await gate.flushPending()
        let flushed = await index.batches
        XCTAssertEqual(flushed.flatMap { $0 }, ["1", "2", "3"])
        let pendingAfter = await gate.pendingCount
        XCTAssertEqual(pendingAfter, 0)
    }

    func testLiveWritesQueueBehindBufferedOnesInsteadOfOvertakingThem() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })
        lock.available = false
        try await gate.indexBatch(entries([1]))
        // Unlocked, but the flush trigger has not fired yet: the next live
        // write must not land ahead of the buffered one — it drains it.
        lock.available = true
        try await gate.indexBatch(entries([2]))
        let batches = await index.batches
        XCTAssertEqual(batches.flatMap { $0 }, ["1", "2"])
    }

    func testUnlockedWritesPassStraightThrough() async throws {
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { true })
        try await gate.indexBatch(entries([1, 2]))
        let batches = await index.batches
        XCTAssertEqual(batches, [["1", "2"]])
    }

    func testFlushWritesInChunks() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })
        lock.available = false
        let total = LockAwareSearchService.flushChunkSize + 7
        try await gate.indexBatch(entries(Array(1...total)))
        lock.available = true
        await gate.flushPending()
        let sizes = await index.batches.map(\.count)
        XCTAssertEqual(sizes, [LockAwareSearchService.flushChunkSize, 7])
    }

    func testEntryCapDropsOverflowAndRunsRecoveryOnceAfterTheFlush() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let recoveries = Counter()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available },
                                          maxPendingEntries: 3,
                                          overflowRecovery: { recoveries.increment(); return true })
        lock.available = false
        try await gate.indexBatch(entries([1, 2]))
        try await gate.indexBatch(entries([3, 4])) // would make 4 > 3: dropped whole
        try await gate.indexBatch(entries([5]))
        XCTAssertEqual(recoveries.count, 0, "recovery waits until the buffer has been written")

        lock.available = true
        await gate.flushPending()
        let flushed = await index.batches.flatMap { $0 }
        XCTAssertEqual(flushed, ["1", "2", "5"])
        XCTAssertEqual(recoveries.count, 1)

        await gate.flushPending()
        XCTAssertEqual(recoveries.count, 1, "one overflow, one recovery")
    }

    func testFailedRecoveryKeepsTheDropCountAndRetriesOnTheNextFlush() async throws {
        // The backfill reset can itself be refused (locked again, suspended
        // database). Losing the recovery then would leave the dropped head
        // entries unsearchable until some unrelated reset.
        let lock = Lock()
        let index = RecordingIndex()
        let attempts = Counter()
        let succeed = Lock()
        succeed.available = false
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available },
                                          maxPendingEntries: 1,
                                          overflowRecovery: { attempts.increment(); return succeed.available })
        lock.available = false
        try await gate.indexBatch(entries([1, 2])) // over the cap: dropped
        lock.available = true
        await gate.flushPending()
        XCTAssertEqual(attempts.count, 1)
        await gate.flushPending()
        XCTAssertEqual(attempts.count, 2, "a failed recovery must be retried")
        succeed.available = true
        await gate.flushPending()
        XCTAssertEqual(attempts.count, 3)
        await gate.flushPending()
        XCTAssertEqual(attempts.count, 3, "a successful recovery clears the claim")
    }

    /// An index whose writes block until released, so the buffer can be
    /// edited while a flush is suspended mid-write.
    private actor GatedIndex: SearchService {
        var batches: [[String]] = []
        /// Order in which writes reached the index.
        var log: [String] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var blockNext = true
        private var arrived: CheckedContinuation<Void, Never>?

        func waitUntilBlocked() async {
            if gate != nil { return }
            await withCheckedContinuation { arrived = $0 }
        }
        func release() {
            gate?.resume()
            gate = nil
        }
        func indexBatch(_ entries: [SearchIndexEntry]) async throws {
            if blockNext {
                blockNext = false
                await withCheckedContinuation { continuation in
                    gate = continuation
                    arrived?.resume()
                    arrived = nil
                }
            }
            batches.append(entries.map(\.eventID))
            log.append("batch")
        }
        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
        func remove(eventID: String) async throws {}
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
        func wipe() async throws { log.append("wipe") }
        func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
        func backfillComplete(roomID: String) async throws -> Bool { false }
        func backfillOldestEventID(roomID: String) async throws -> String? { nil }
        func resetBackfill() async throws {}
        func eventCount(roomID: String) async throws -> Int { 0 }
        func contains(eventID: String) async throws -> Bool { false }
    }

    func testBufferEditedDuringAFlushWriteIsNotMisTrimmed() async throws {
        // A removal purges the buffer while a flush is suspended in its
        // write. The flush must not then `removeFirst(chunk.count)` from a
        // buffer whose positions shifted — that would silently drop entries
        // that were never written.
        let lock = Lock()
        let index = GatedIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })
        lock.available = false
        try await gate.indexBatch(entries([1, 2, 3]))
        lock.available = true

        let flush = Task { await gate.flushPending() }
        await index.waitUntilBlocked()        // chunk [1,2,3] is mid-write
        try await gate.removeAll(eventIDs: ["1"]) // buffer is now [2,3]
        try await gate.indexBatch(entries([4])) // queued behind: [2,3,4]
        await index.release()
        await flush.value

        let written = await index.batches
        XCTAssertEqual(written.first, ["1", "2", "3"])
        XCTAssertEqual(Set(written.flatMap { $0 }), ["1", "2", "3", "4"],
                       "entry 4 must still be written after the edited buffer is re-drained")
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// CodeRabbit "Fence wipe() behind all in-flight index writes": the
    /// actor re-enters while a write is suspended in the index, and both
    /// calls hop off it before GRDB enqueues them — so without a barrier a
    /// sign-out wipe could land BEFORE an index write issued earlier, and
    /// that write would restore the wiped account's rows.
    func testWipeWaitsForInFlightWritesAndDropsWritesDuringIt() async throws {
        let index = GatedIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { true })

        let write = Task { try await gate.indexBatch(entries([1])) }
        await index.waitUntilBlocked()        // the old account's write is mid-flight
        let wipe = Task { try await gate.wipe() }
        try await Task.sleep(for: .milliseconds(100))
        let early = await index.log
        XCTAssertEqual(early, [], "the wipe must not reach the index ahead of the in-flight write")

        // Arrives while the wipe waits: belongs to the account being wiped.
        try await gate.indexBatch(entries([2]))

        await index.release()
        try await write.value
        try await wipe.value
        let log = await index.log
        XCTAssertEqual(log, ["batch", "wipe"])
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0, "a write that arrived during the wipe must not survive it")

        try await gate.indexBatch(entries([3]))
        let after = await index.log
        XCTAssertEqual(after, ["batch", "wipe", "batch"], "writes resume once the wipe is done")
    }

    func testByteCapDropsOverflow() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let recoveries = Counter()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available },
                                          maxPendingBodyBytes: 10,
                                          overflowRecovery: { recoveries.increment(); return true })
        lock.available = false
        try await gate.indexBatch(entries([1], body: "12345678"))
        try await gate.indexBatch(entries([2], body: "12345"))
        lock.available = true
        await gate.flushPending()
        let flushed = await index.batches.flatMap { $0 }
        XCTAssertEqual(flushed, ["1"])
        XCTAssertEqual(recoveries.count, 1)
    }

    func testEverythingButIndexingThrowsWhileLocked() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })
        lock.available = false
        let calls: [(String, () async throws -> Void)] = [
            ("query", { _ = try await gate.query("x", limit: 5) }),
            ("queryGrouped", { _ = try await gate.queryGrouped("x", limit: 5) }),
            ("roomQuery", { _ = try await gate.query("x", roomID: "c1", limit: 5) }),
            ("remove", { try await gate.remove(eventID: "1") }),
            ("removeAll", { try await gate.removeAll(eventIDs: ["1"]) }),
            ("wipe", { try await gate.wipe() }),
            ("recordBackfillProgress", {
                try await gate.recordBackfillProgress(roomID: "c1", indexedCount: 1, oldestEventID: nil, complete: true)
            }),
            ("backfillComplete", { _ = try await gate.backfillComplete(roomID: "c1") }),
            ("backfillOldestEventID", { _ = try await gate.backfillOldestEventID(roomID: "c1") }),
            ("resetBackfill", { try await gate.resetBackfill() }),
            ("eventCount", { _ = try await gate.eventCount(roomID: "c1") }),
            ("contains", { _ = try await gate.contains(eventID: "1") }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) must throw while locked")
            } catch {
                XCTAssertEqual(error as? SearchIndexUnavailable, .protectedDataUnavailable, name)
            }
        }
        let removed = await index.removed
        let wipes = await index.wipes
        XCTAssertEqual(removed, [])
        XCTAssertEqual(wipes, 0)
    }

    func testRemovalPurgesBufferedCopiesSoAFlushCannotResurrectThem() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })
        lock.available = false
        try await gate.indexBatch(entries([1, 2, 3]))
        // The retention sweep's removal must wait (it throws and retries),
        // but the buffered rows it names must not come back afterwards.
        do { try await gate.removeAll(eventIDs: ["2"]) } catch {}
        lock.available = true
        await gate.flushPending()
        let flushed = await index.batches.flatMap { $0 }
        XCTAssertEqual(flushed, ["1", "3"])
    }

    func testWipeDropsTheBuffer() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available })
        lock.available = false
        try await gate.indexBatch(entries([1, 2]))
        lock.available = true
        try await gate.wipe()
        await gate.flushPending()
        let batches = await index.batches
        let wipes = await index.wipes
        XCTAssertEqual(batches, [], "a wiped account's buffered rows must not be written")
        XCTAssertEqual(wipes, 1)
    }

    func testInterruptedWriteFallsBackToTheBufferAndFlushesOnResume() async throws {
        // What an in-flight write gets when the lock warning interrupts it,
        // or when GRDB suspension refuses it.
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { true })
        await index.setRefuseWrites(DatabaseError(resultCode: .SQLITE_INTERRUPT))
        try await gate.indexBatch(entries([1]))
        await index.setRefuseWrites(DatabaseError(resultCode: .SQLITE_ABORT, message: "Database is suspended"))
        try await gate.indexBatch(entries([2])) // queues behind 1; the drain is refused too
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 2, "refused entries must be kept, not lost")

        await index.setRefuseWrites(nil)
        await gate.flushPending()
        let flushed = await index.batches.flatMap { $0 }
        XCTAssertEqual(flushed, ["1", "2"])
    }

    func testNonTransientWriteErrorStillThrowsWhenUnlocked() async throws {
        let index = RecordingIndex()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { true })
        await index.setRefuseWrites(DatabaseError(resultCode: .SQLITE_CORRUPT))
        do {
            try await gate.indexBatch(entries([1]))
            XCTFail("a corrupt index is not a reason to buffer")
        } catch {
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_CORRUPT)
        }
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testLockWarningInterruptsTheInFlightWrite() {
        let interrupts = Counter()
        let gate = LockAwareSearchService(base: RecordingIndex(), isProtectedDataAvailable: { false },
                                          interruptInFlight: { interrupts.increment() })
        gate.protectedDataWillBecomeUnavailable()
        XCTAssertEqual(interrupts.count, 1, "synchronous: the interrupt must not wait for an actor hop")
    }

    /// CodeRabbit "Close search admission before interrupting the queue": a
    /// write that passed the gate's actor-side check just before the lock
    /// warning could reach GRDB after the interrupt and page the locked file
    /// in. The index now re-checks on its own queue; the refused write goes
    /// back to the buffer. Modelled with the gate still reading "available"
    /// (its check already passed) while the on-queue admission says no.
    func testWriteRefusedByTheOnQueueAdmissionIsBufferedNotWritten() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("admission-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let admission = Lock()
        let live = try SearchServiceLive.open(databaseURL: url, admission: { admission.available })
        let gate = LockAwareSearchService(base: live, isProtectedDataAvailable: { true })

        admission.available = false
        try await gate.indexBatch(entries([1], body: "raced message"))
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 1, "the refused write is kept for the flush, not lost or thrown")
        do {
            _ = try await live.query("raced", limit: 10)
            XCTFail("reads are refused on the queue too")
        } catch {
            XCTAssertEqual(error as? SearchIndexUnavailable, .protectedDataUnavailable)
        }

        admission.available = true
        await gate.flushPending()
        let hits = try await live.query("raced", limit: 10)
        XCTAssertEqual(hits.map(\.id), ["1"])
    }

    /// End to end against the real GRDB index: nothing is written while
    /// locked, and after the unlock flush the rows are searchable.
    func testRealIndexReceivesBufferedRowsOnlyAfterUnlock() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lock-aware-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let live = try SearchServiceLive.open(databaseURL: url)
        let lock = Lock()
        let gate = LockAwareSearchService(base: live, isProtectedDataAvailable: { lock.available },
                                          interruptInFlight: { live.interrupt() })
        lock.available = false
        try await gate.indexBatch(entries([1, 2], body: "pocketed message"))
        let beforeUnlock = try await live.query("pocketed", limit: 10)
        XCTAssertEqual(beforeUnlock.count, 0)

        lock.available = true
        await gate.flushPending()
        let hits = try await gate.query("pocketed", limit: 10)
        XCTAssertEqual(Set(hits.map(\.id)), ["1", "2"])
    }
}
