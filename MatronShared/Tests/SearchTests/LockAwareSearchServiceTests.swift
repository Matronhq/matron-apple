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
        ids.map { SearchIndexEntry(roomID: "c1", eventID: String($0), sender: "agent:dev-2",
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
                                          overflowRecovery: { recoveries.increment() })
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

    func testByteCapDropsOverflow() async throws {
        let lock = Lock()
        let index = RecordingIndex()
        let recoveries = Counter()
        let gate = LockAwareSearchService(base: index, isProtectedDataAvailable: { lock.available },
                                          maxPendingBodyBytes: 10,
                                          overflowRecovery: { recoveries.increment() })
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
