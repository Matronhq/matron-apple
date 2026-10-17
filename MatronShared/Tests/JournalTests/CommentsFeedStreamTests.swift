import Foundation
import GRDB
import MatronModels
import XCTest
@testable import MatronJournal

/// `commentsStream(itemID:)` with `usesChangeFeed` on: the thread read
/// once, then kept current from the feed's comment rows.
class CommentsFeedStreamTests: XCTestCase {
    /// `CommentsFeedStreamPoolTests` runs the whole suite again on a pool.
    class var writerKind: StoreWriterKind { .queue }

    private func makeStore(metrics: StoreMetrics = StoreMetrics()) throws -> JournalStore {
        try makeTestStore(Self.writerKind, metrics: metrics, usesChangeFeed: true)
    }

    private func comment(_ id: String, item: String = "i1", body: String = "hi", at seconds: TimeInterval = 1_900_000_000) -> TrackerComment {
        TrackerComment(id: id, itemID: item, author: .user, body: body, createdAt: Date(timeIntervalSince1970: seconds))
    }

    private func threadReads(_ metrics: StoreMetrics) -> Int {
        metrics.drain().observations.first { $0.name == "commentsFeed" }?.fires ?? 0
    }

    private func settle(_ store: JournalStore) async throws {
        try await store.db.writeWithoutTransaction { _ in }
        try await Task.sleep(for: .milliseconds(150))
    }

    func testTheThreadIsDeliveredInOrderThenEachChangeToIt() async throws {
        let store = try makeStore()
        try store.replaceComments(itemID: "i1", [comment("b", at: 2), comment("a", at: 2), comment("c", at: 1)])
        let thread = ThreadRecorder(store.commentsStream(itemID: "i1"))
        defer { thread.cancel() }
        try await waitUntil { thread.count == 1 }
        XCTAssertEqual(thread.last?.map(\.id), ["c", "a", "b"], "created_at, then id")
        XCTAssertEqual(thread.last, try store.comments(itemID: "i1"))

        try store.insertComments([comment("d", at: 3)])
        try await waitUntil { thread.count == 2 }
        XCTAssertEqual(thread.last?.map(\.id), ["c", "a", "b", "d"])

        try store.insertComments([comment("a", body: "edited", at: 2)])
        try await waitUntil { thread.count == 3 }
        XCTAssertEqual(thread.last?.first { $0.id == "a" }?.body, "edited")
        XCTAssertEqual(thread.last, try store.comments(itemID: "i1"))
    }

    /// A comment on another item reads nothing and delivers nothing.
    func testACommentOnAnotherItemCausesNoReadAndNoDelivery() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        try store.replaceComments(itemID: "i1", [comment("a")])
        let thread = ThreadRecorder(store.commentsStream(itemID: "i1"))
        defer { thread.cancel() }
        try await waitUntil { thread.count == 1 }
        XCTAssertEqual(threadReads(metrics), 1, "the snapshot")

        try store.replaceComments(itemID: "i2", [comment("x", item: "i2"), comment("y", item: "i2")])
        try store.insertComments([comment("z", item: "i3")])
        try await settle(store)
        XCTAssertEqual(thread.count, 1)
        XCTAssertEqual(threadReads(metrics), 0)

        try store.insertComments([comment("b")])
        try await waitUntil { thread.count == 2 }
        XCTAssertEqual(threadReads(metrics), 0, "its own comments come from the feed's rows, not a read")
    }

    /// `wipeItems()` resets the comments: the thread is read again.
    func testAResetReloadsTheThread() async throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        try store.replaceComments(itemID: "i1", [comment("a")])
        let thread = ThreadRecorder(store.commentsStream(itemID: "i1"))
        defer { thread.cancel() }
        try await waitUntil { thread.count == 1 }
        _ = threadReads(metrics)

        try store.wipeItems()
        try await waitUntil { thread.count == 2 }
        XCTAssertEqual(thread.last, [])
        XCTAssertEqual(threadReads(metrics), 1)

        try store.replaceComments(itemID: "i1", [comment("b")])
        try await waitUntil { thread.last?.map(\.id) == ["b"] }
    }

    /// A rowid handed from one of this item's comments to another item's
    /// takes the comment off this thread.
    func testAReusedRowidLeavesTheThread() async throws {
        let store = try makeStore()
        try store.replaceComments(itemID: "i1", [comment("a", at: 1), comment("b", at: 2)])
        let thread = ThreadRecorder(store.commentsStream(itemID: "i1"))
        defer { thread.cancel() }
        try await waitUntil { thread.count == 1 }

        let other = ItemCommentRecord(comment("other", item: "i2"))
        try await store.db.write { db in
            try db.execute(sql: "DELETE FROM item_comment WHERE rowid = (SELECT MAX(rowid) FROM item_comment)")
            try other.insert(db)
        }
        try await waitUntil { thread.count == 2 }
        XCTAssertEqual(thread.last?.map(\.id), ["a"])
    }

    /// After every commit of the random item sequence, the thread of each
    /// of a few items settles on `comments(itemID:)`.
    func testTheThreadSettlesOnAFreshReadAfterEveryCommit() async throws {
        for seed in UInt64(1)...3 {
            let store = try makeStore()
            var writes = RandomItemWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            let items = Array(RandomItemWrites.itemIDs.prefix(4))
            let threads = items.map { ThreadRecorder(store.commentsStream(itemID: $0)) }
            defer { threads.forEach { $0.cancel() } }
            for step in 0..<300 {
                let what = try writes.step()
                for (item, thread) in zip(items, threads) {
                    let expected = try store.comments(itemID: item)
                    let clock = ContinuousClock()
                    let deadline = clock.now + .seconds(5)
                    while thread.last != expected, clock.now < deadline {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard thread.last == expected else {
                        return XCTFail("seed \(seed) step \(step) (\(what)): \(item) thread diverged")
                    }
                }
            }
        }
    }

    /// With the flag off, `commentsStream` is still the value observation.
    func testWithTheFlagOffTheStreamIsTheValueObservation() async throws {
        let metrics = StoreMetrics()
        let store = try makeTestStore(Self.writerKind, metrics: metrics, usesChangeFeed: false)
        try store.replaceComments(itemID: "i1", [comment("a")])
        let thread = ThreadRecorder(store.commentsStream(itemID: "i1"))
        defer { thread.cancel() }
        try await waitUntil { thread.count == 1 }
        let report = metrics.drain().observations
        XCTAssertNotNil(report.first { $0.name == "commentsStream" })
        XCTAssertNil(report.first { $0.name == "commentsFeed" })
    }
}

final class CommentsFeedStreamPoolTests: CommentsFeedStreamTests {
    override class var writerKind: StoreWriterKind { .pool }
}

/// Collects a comments stream's deliveries.
final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [[TrackerComment]] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<[TrackerComment]>) {
        task = Task { [weak self] in
            for await thread in stream {
                guard let self else { return }
                self.lock.withLock { self.threads.append(thread) }
            }
        }
    }

    var count: Int { lock.withLock { threads.count } }
    var last: [TrackerComment]? { lock.withLock { threads.last } }

    func cancel() { task?.cancel() }
}
