import Foundation
import GRDB
import os
import XCTest
@testable import MatronJournal

/// `JournalStore.eventTailStream(convoID:sinceSeq:)`: the open timeline's
/// tail from the change feed. The same rows as `eventsStream`, read only
/// when a commit wrote this conversation's events.
class EventTailStreamTests: XCTestCase {
    /// `EventTailStreamPoolTests` runs the whole suite again on a pool.
    class var writerKind: StoreWriterKind { .queue }

    private func makeStore(metrics: StoreMetrics = StoreMetrics()) throws -> JournalStore {
        try makeTestStore(Self.writerKind, ownSender: RandomJournalWrites.ownSender, metrics: metrics)
    }

    private func event(_ seq: Int64, convo: String = "c1", type: String = JournalEventType.text,
                       ts: Date? = nil, payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: ts ?? Date(timeIntervalSince1970: 1_900_000_000 + Double(seq)),
                     sender: "agent:box-2", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private func tailFetches(_ metrics: StoreMetrics) -> Int {
        metrics.drain().observations.first { $0.name == "eventTail" }?.fires ?? 0
    }

    private func fresh(_ store: JournalStore, convo: String = "c1", since: Int64 = 0) throws -> [JournalEvent] {
        try store.db.read { db in
            try EventTailState.request(convoID: convo, sinceSeq: since).fetchAll(db).map(\.journalEvent)
        }
    }

    /// Lets every pending delivery land: a write barrier for the feed's
    /// listener, then a moment for the reader. Used only to prove that
    /// nothing more arrives.
    private func settle(_ store: JournalStore) async throws {
        try await store.db.writeWithoutTransaction { _ in }
        try await Task.sleep(for: .milliseconds(150))
    }

    func testTheFirstDeliveryIsTheTailEvenWhenEmpty() async throws {
        let store = try makeStore()
        let empty = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { empty.cancel() }
        try await waitUntil { empty.count == 1 }
        XCTAssertEqual(empty.last?.events, [])

        try store.applyJournal(event(1))
        try store.applyJournal(event(2, convo: "c2"))
        let full = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { full.cancel() }
        try await waitUntil { full.count == 1 }
        XCTAssertEqual(full.last?.events.map(\.seq), [1])
    }

    /// The point of it: a frame in another conversation reads nothing and
    /// delivers nothing; a frame in this one is one fetch.
    func testAForeignFrameCostsNoFetchAndAnOwnFrameOne() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        try store.applyJournal(event(1))
        let tail = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { tail.cancel() }
        try await waitUntil { tail.count == 1 }
        XCTAssertEqual(tailFetches(metrics), 1, "the first read")

        for seq in Int64(2)...20 { try store.applyJournal(event(seq, convo: "c2")) }
        try await settle(store)
        XCTAssertEqual(tailFetches(metrics), 0, "nineteen frames elsewhere, no read")
        XCTAssertEqual(tail.count, 1, "and no delivery")

        try store.applyJournal(event(21))
        try await waitUntil { tail.count == 2 }
        XCTAssertEqual(tail.last?.events.map(\.seq), [1, 21])
        XCTAssertEqual(tail.last?.rewrittenSeqs, [])
        XCTAssertEqual(tailFetches(metrics), 1)
    }

    /// Rows inserted below the anchor (a history page) are not the tail's,
    /// and cost it nothing.
    func testRowsBelowTheAnchorAreNotTheTails() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        try store.applyJournal(event(10))
        let tail = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 10))
        defer { tail.cancel() }
        try await waitUntil { tail.count == 1 }
        _ = tailFetches(metrics)

        try store.insertHistory([event(3), event(4)])
        try await settle(store)
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tailFetches(metrics), 0)
    }

    /// A seq already delivered that the store rewrites in place comes
    /// again, with its new row, named in `rewrittenSeqs`.
    func testARetentionRewriteOfASeenSeqIsDeliveredAsRewritten() async throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        try store.applyJournal(event(1, type: JournalEventType.toolOutput, ts: old,
                                     payload: ["command": "make", "output": "long log"]), now: old)
        try store.applyJournal(event(2))
        let tail = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { tail.cancel() }
        try await waitUntil { tail.count == 1 }
        let before = try XCTUnwrap(tail.last?.events.first)

        XCTAssertEqual(try store.applyRetention(now: old.addingTimeInterval(40 * 24 * 3600)), [1])

        try await waitUntil { tail.count == 2 }
        let update = try XCTUnwrap(tail.last)
        XCTAssertEqual(update.rewrittenSeqs, [1])
        XCTAssertNotEqual(update.events.first, before)
        XCTAssertEqual(update.events, try fresh(store))
    }

    /// The 24 h tool-output sweep is a rewrite too.
    func testATombstoneSweepOfASeenSeqIsDeliveredAsRewritten() async throws {
        let store = try makeStore()
        let then = Date(timeIntervalSince1970: 1_900_000_000)
        try store.applyJournal(event(1, type: JournalEventType.toolOutput, ts: then,
                                     payload: ["command": "make", "snippet": "building…", "live_log": true]), now: then)
        let tail = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { tail.cancel() }
        try await waitUntil { tail.count == 1 }

        try store.purgeExpiredToolOutputSnippets(now: then.addingTimeInterval(2 * 24 * 3600))

        try await waitUntil { tail.count == 2 }
        XCTAssertEqual(tail.last?.rewrittenSeqs, [1])
        XCTAssertEqual(tail.last?.events, try fresh(store))
    }

    /// An archive purge deletes the held rows: dropped without a read.
    func testAPurgeDropsTheHeldRowsWithoutAFetch() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        _ = try store.applyJournalBatch([event(1), event(2, convo: "c2"), event(3)])
        try store.setArchived(["c1"], archived: true)
        let tail = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { tail.cancel() }
        try await waitUntil { tail.count == 1 }
        _ = tailFetches(metrics)

        XCTAssertEqual(try store.purgeArchivedHistory(["c1"]), ["c1"])

        try await waitUntil { tail.count == 2 }
        XCTAssertEqual(tail.last?.events, [])
        XCTAssertEqual(tailFetches(metrics), 0)
    }

    /// A reset (`wipe()`) reads the whole tail again.
    func testAWipeReloadsTheTail() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        try store.applyJournal(event(1))
        let tail = TailRecorder(store.eventTailStream(convoID: "c1", sinceSeq: 0))
        defer { tail.cancel() }
        try await waitUntil { tail.count == 1 }
        _ = tailFetches(metrics)

        try store.wipe()
        try await waitUntil { tail.count == 2 }
        XCTAssertEqual(tail.last?.events, [])
        XCTAssertEqual(tailFetches(metrics), 1, "one read of the whole tail")

        try store.insertHistory([event(5), event(6)])
        try await waitUntil { tail.last?.events.map(\.seq) == [5, 6] }
    }

    /// The equivalence: after every commit of the random journal sequence
    /// (frames, batches, history pages, the sweeps, retention, wipes) plus
    /// a purge every twenty steps, the tail delivered for each of a few
    /// conversations settles on a fresh read of it. Each conversation has
    /// two tails: its whole history, and one anchored among the live
    /// frames, which history pages land below.
    func testTheTailSettlesOnAFreshReadAfterEveryCommit() async throws {
        var sawRewrite = false
        for seed in UInt64(1)...3 {
            let store = try makeStore()
            var writes = RandomJournalWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            let convos = Array(RandomJournalWrites.convoIDs.prefix(3))
            let watched = convos.flatMap { convo in [(convo, Int64(0)), (convo, Int64(1_000_010))] }
            let tails = watched.map { TailRecorder(store.eventTailStream(convoID: $0.0, sinceSeq: $0.1)) }
            defer { tails.forEach { $0.cancel() } }
            for step in 0..<150 {
                var what = try writes.step()
                if step % 20 == 19 {
                    let purged = try store.purgeArchivedHistory(RandomJournalWrites.convoIDs + RandomJournalWrites.quietIDs)
                    what += ", then purgeArchivedHistory \(purged.count)"
                }
                for ((convo, since), tail) in zip(watched, tails) {
                    let expected = try fresh(store, convo: convo, since: since)
                    let clock = ContinuousClock()
                    let deadline = clock.now + .seconds(5)
                    while tail.last?.events != expected, clock.now < deadline {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard tail.last?.events == expected else {
                        return XCTFail("seed \(seed) step \(step) (\(what)): \(convo) tail from \(since) \(tail.last?.events.map(\.seq) ?? []) != \(expected.map(\.seq))")
                    }
                    sawRewrite = sawRewrite || tail.sawRewrite
                }
            }
        }
        XCTAssertTrue(sawRewrite, "some delivered row was rewritten in place")
    }
}

final class EventTailStreamPoolTests: EventTailStreamTests {
    override class var writerKind: StoreWriterKind { .pool }
}

/// Collects a tail stream's deliveries.
final class TailRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var tails: [EventTail] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<EventTail>) {
        task = Task { [weak self] in
            for await tail in stream {
                guard let self else { return }
                self.lock.withLock { self.tails.append(tail) }
            }
        }
    }

    var count: Int { lock.withLock { tails.count } }
    var last: EventTail? { lock.withLock { tails.last } }
    var sawRewrite: Bool { lock.withLock { tails.contains { !$0.rewrittenSeqs.isEmpty } } }

    func cancel() { task?.cancel() }
}
