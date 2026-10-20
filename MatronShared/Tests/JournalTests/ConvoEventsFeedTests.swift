import Foundation
import GRDB
import XCTest
@testable import MatronJournal

/// `JournalStore.convoEventsFeedStream(convoID:query:)`: some of one
/// conversation's events, read from the change feed only when a commit
/// wrote that conversation's events, and then only the seqs it wrote.
class ConvoEventsFeedTests: XCTestCase {
    /// `ConvoEventsFeedPoolTests` runs the whole suite again on a pool.
    class var writerKind: StoreWriterKind { .queue }

    private let query = JournalStore.queuedReleaseEventsQuery

    private func makeStore(metrics: StoreMetrics = StoreMetrics()) throws -> JournalStore {
        try makeTestStore(Self.writerKind, metrics: metrics, usesChangeFeed: true)
    }

    private func card(_ seq: Int64, convo: String = "c1") -> JournalEvent {
        event(seq, convo: convo, type: JournalEventType.prompt,
              payload: ["kind": "queued_release", "prompt_id": "pr_\(seq)", "item": ["item_id": "it_1", "comment_id": "ic_\(seq)"]])
    }

    private func frame(_ seq: Int64, convo: String = "c1") -> JournalEvent {
        event(seq, convo: convo, type: JournalEventType.text, payload: ["body": "hi"])
    }

    private func event(_ seq: Int64, convo: String, type: String, payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: 1_900_000_000 + Double(seq)),
                     sender: "agent:box-2", type: type, payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private func fetches(_ metrics: StoreMetrics) -> Int {
        metrics.drain().observations.first { $0.name == "queuedReleaseEventsStream" }?.fires ?? 0
    }

    /// What the value observation would deliver now.
    private func fresh(_ store: JournalStore, convo: String = "c1") throws -> [JournalEvent] {
        try store.db.read { db in try query.fetch(db, convoID: convo).sorted { $0.seq < $1.seq } }
    }

    private func settle(_ store: JournalStore) async throws {
        try await store.db.writeWithoutTransaction { _ in }
        try await Task.sleep(for: .milliseconds(150))
    }

    func testTheFirstDeliveryIsTheRowsEvenWhenEmpty() async throws {
        let store = try makeStore()
        let empty = RowsRecorder(store.convoEventsFeedStream(convoID: "c1", query: query))
        defer { empty.cancel() }
        try await waitUntil { empty.count == 1 }
        XCTAssertEqual(empty.last, [])

        _ = try store.applyJournalBatch([card(1), frame(2), card(3, convo: "c2")])
        let full = RowsRecorder(store.convoEventsFeedStream(convoID: "c1", query: query))
        defer { full.cancel() }
        try await waitUntil { full.count == 1 }
        XCTAssertEqual(full.last?.map(\.seq), [1])
    }

    /// The point of it: frames elsewhere read nothing; a frame in this
    /// conversation reads only its own seq, and delivers only if it matched.
    func testAForeignFrameReadsNothingAndAnOwnFrameReadsOnlyItsSeq() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        _ = try store.applyJournalBatch((1...200).map { card(Int64($0)) })
        let rows = RowsRecorder(store.convoEventsFeedStream(convoID: "c1", query: query))
        defer { rows.cancel() }
        try await waitUntil { rows.count == 1 }
        XCTAssertEqual(rows.last?.count, 200)
        XCTAssertEqual(fetches(metrics), 1, "the first read")

        for seq in Int64(201)...220 { try store.applyJournal(frame(seq, convo: "c2")) }
        try await settle(store)
        XCTAssertEqual(fetches(metrics), 0, "twenty frames elsewhere, no read")

        try store.applyJournal(frame(221))
        try await settle(store)
        XCTAssertEqual(rows.count, 1, "an own frame that is not a card delivers nothing")
        XCTAssertEqual(metrics.drain().observations.first { $0.name == "queuedReleaseEventsStream" }?.rows, 0,
                       "and its read returned no rows")

        try store.applyJournal(card(222))
        try await waitUntil { rows.count == 2 }
        XCTAssertEqual(rows.last?.count, 201)
        XCTAssertEqual(rows.last, try fresh(store))
    }

    /// A held row rewritten so it no longer matches leaves; a deleted one
    /// leaves without a read.
    func testARewriteThatNoLongerMatchesAndADeletionDropTheRow() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        _ = try store.applyJournalBatch([card(1), card(2), card(3)])
        let rows = RowsRecorder(store.convoEventsFeedStream(convoID: "c1", query: query))
        defer { rows.cancel() }
        try await waitUntil { rows.count == 1 }

        try await store.db.write { db in
            try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = 2",
                           arguments: [try JSONSerialization.data(withJSONObject: ["body": "gone"])])
        }
        try await waitUntil { rows.last?.map(\.seq) == [1, 3] }

        _ = fetches(metrics)
        try await store.db.write { db in try db.execute(sql: "DELETE FROM event WHERE seq = 3") }
        try await waitUntil { rows.last?.map(\.seq) == [1] }
        XCTAssertEqual(fetches(metrics), 0)
    }

    /// A reset (`wipe()`) reads every row again.
    func testAWipeReloads() async throws {
        let store = try makeStore()
        try store.applyJournal(card(1))
        let rows = RowsRecorder(store.convoEventsFeedStream(convoID: "c1", query: query))
        defer { rows.cancel() }
        try await waitUntil { rows.count == 1 }

        try store.wipe()
        try await waitUntil { rows.last == [] }
        try store.insertHistory([card(5), frame(6)])
        try await waitUntil { rows.last?.map(\.seq) == [5] }
    }

    /// More seqs in one commit than SQLite binds in one statement.
    func testABigBatchIsReadInChunks() async throws {
        let store = try makeStore()
        let rows = RowsRecorder(store.convoEventsFeedStream(convoID: "c1", query: query))
        defer { rows.cancel() }
        try await waitUntil { rows.count == 1 }

        _ = try store.applyJournalBatch((1...1_500).map { $0 % 3 == 0 ? card(Int64($0)) : frame(Int64($0)) })
        try await waitUntil { rows.last?.count == 500 }
        XCTAssertEqual(rows.last, try fresh(store))
    }
}

final class ConvoEventsFeedPoolTests: ConvoEventsFeedTests {
    override class var writerKind: StoreWriterKind { .pool }
}

final class RowsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [[JournalEvent]] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<[JournalEvent]>) {
        task = Task { [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.lock.withLock { self.deliveries.append(rows) }
            }
        }
    }

    var count: Int { lock.withLock { deliveries.count } }
    var last: [JournalEvent]? { lock.withLock { deliveries.last } }

    func cancel() { task?.cancel() }
}
