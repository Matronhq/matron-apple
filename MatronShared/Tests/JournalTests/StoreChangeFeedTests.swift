import GRDB
import os
import XCTest
@testable import MatronJournal

/// `StoreChangeFeed`: one change set per commit that touched `conversation`,
/// resolved to rows on the writer, in commit order, after a snapshot taken
/// in the same writer turn as the registration.
class StoreChangeFeedTests: XCTestCase {
    /// `StoreChangeFeedPoolTests` runs the whole suite again on a pool.
    class var writerKind: StoreWriterKind { .queue }

    private func makeStore(metrics: StoreMetrics = StoreMetrics()) throws -> JournalStore {
        try makeFileStore(Self.writerKind, ownSender: RandomJournalWrites.ownSender, metrics: metrics)
    }

    private func event(_ seq: Int64, convo: String = "c1", type: String = JournalEventType.text,
                       payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: "agent:box-2", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// The whole table, keyed by rowid: what a mirror built from the feed
    /// must equal after every commit.
    private func freshRows(_ store: JournalStore) throws -> [Int64: ConversationRecord] {
        try store.db.read { db in
            Dictionary(uniqueKeysWithValues: try StoreChangeFeed.conversationRows(db))
        }
    }

    /// Subscribes a mirror and waits for its snapshot. Registration is an
    /// async writer turn; any later writer turn runs after it. (A read is
    /// no barrier: on a pool it runs on a reader, beside the writer.)
    private func subscribeMirror(_ store: JournalStore) throws -> (FeedMirror, StoreChangeFeed.Subscription) {
        let mirror = FeedMirror()
        let subscription = store.observeChanges(
            snapshot: { db in try StoreChangeFeed.conversationRows(db) },
            onEvent: mirror.handle,
            onError: { XCTFail("feed error: \($0)") })
        try store.db.writeWithoutTransaction { _ in }
        XCTAssertEqual(mirror.snapshots, 1, "the snapshot is delivered in the registration turn")
        return (mirror, subscription)
    }

    // MARK: The gate

    /// The equivalence property: a mirror built from the snapshot plus
    /// every change set equals a fresh read of the table after every
    /// commit, over a seeded random sequence of the store's real write
    /// APIs. Keyed by rowid, so it also proves deletions and rowid reuse.
    func testMirrorFromSnapshotPlusChangeSetsEqualsAFreshReadAfterEveryCommit() throws {
        for seed in UInt64(1)...6 {
            let store = try makeStore()
            var writes = RandomJournalWrites(store: store, seed: seed)
            // Some rows exist before the subscriber does, so the snapshot
            // half is exercised too.
            for _ in 0..<20 { try writes.step() }
            let (mirror, subscription) = try subscribeMirror(store)
            defer { subscription.cancel() }
            for step in 0..<400 {
                let what = try writes.step()
                let fresh = try freshRows(store)
                guard mirror.rows == fresh else {
                    return XCTFail("seed \(seed) step \(step) (\(what)): mirror diverged from the table")
                }
            }
            XCTAssertGreaterThan(mirror.sets.count, 100, "seed \(seed): the sequence must actually publish")
        }
    }

    // MARK: Edge cases

    /// SQLite's update hook never reports a row that an `OR REPLACE`
    /// conflict deletes, so one such write would leave every index built
    /// on this feed silently stale. The store must not use it. (The
    /// search index's own use lives in its own database, in
    /// `Sources/Search`, which this does not scan.)
    func testNoJournalSourceUsesReplaceConflictResolution() throws {
        let journal = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JournalTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MatronShared
            .appendingPathComponent("Sources/Journal")
        let files = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "found the Journal sources")
        let pattern = try NSRegularExpression(
            pattern: #"\bOR\s+REPLACE\b|\bREPLACE\s+INTO\b|onConflict:\s*\.replace\b|(insert|update):\s*\.replace\b"#,
            options: [.caseInsensitive])
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let line = text[..<Range(match.range, in: text)!.lowerBound].filter { $0 == "\n" }.count + 1
                XCTFail("\(file.lastPathComponent):\(line) uses REPLACE conflict resolution, which the change feed cannot see")
            }
        }
    }

    /// Delete then insert in one transaction can hand the deleted row's
    /// rowid to the new row. Resolution happens after the commit, by
    /// rowid, so the set carries one upsert of the new row for that rowid,
    /// which is what lets an index drop the old key it held there.
    func testRowidReusedInsideOneTransactionIsOneUpsertOfTheNewRow() throws {
        let store = try makeStore()
        try store.ensureConversation(id: "a", title: "A")
        try store.ensureConversation(id: "b", title: "B")
        let (mirror, subscription) = try subscribeMirror(store)
        defer { subscription.cancel() }
        let rowidOfB = try XCTUnwrap(mirror.rows.first { $0.value.id == "b" }?.key)

        try store.db.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = 'b'")
            try db.execute(sql: "INSERT INTO conversation(id, title) VALUES('c', 'C')")
        }

        let set = try XCTUnwrap(mirror.sets.last)
        XCTAssertEqual(mirror.sets.count, 1)
        XCTAssertEqual(set.conversations.upserted[rowidOfB]?.id, "c", "the new row took the old rowid")
        XCTAssertEqual(set.conversations.deleted, [], "a reused rowid is an upsert, not a delete")
        XCTAssertEqual(mirror.rows, try freshRows(store))
    }

    /// The other half of reuse: a key that is deleted and inserted again
    /// in one transaction can land on a NEW rowid. The set reports the old
    /// rowid deleted and the new one upserted.
    func testKeyMovingToANewRowidIsADeleteAndAnUpsert() throws {
        let store = try makeStore()
        try store.ensureConversation(id: "a", title: "A")
        try store.ensureConversation(id: "b", title: "B")
        let (mirror, subscription) = try subscribeMirror(store)
        defer { subscription.cancel() }
        let rowidOfA = try XCTUnwrap(mirror.rows.first { $0.value.id == "a" }?.key)

        try store.db.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = 'a'")
            try db.execute(sql: "INSERT INTO conversation(id, title) VALUES('a', 'A again')")
        }

        let set = try XCTUnwrap(mirror.sets.last)
        XCTAssertEqual(set.conversations.deleted, [rowidOfA])
        XCTAssertEqual(set.conversations.upserted.values.map(\.title), ["A again"])
        XCTAssertEqual(mirror.rows, try freshRows(store))
    }

    func testRollbackPublishesNothing() throws {
        let store = try makeStore()
        try store.ensureConversation(id: "x", title: "X")
        try store.ensureConversation(id: "y", title: "Y")
        let (mirror, subscription) = try subscribeMirror(store)
        defer { subscription.cancel() }
        let rowidOfY = try XCTUnwrap(mirror.rows.first { $0.value.id == "y" }?.key)

        struct Abort: Error {}
        XCTAssertThrowsError(try store.db.write { db in
            try db.execute(sql: "UPDATE conversation SET title = 'never' WHERE id = 'x'")
            try db.execute(sql: "INSERT INTO conversation(id, title) VALUES('ghost', 'Ghost')")
            throw Abort()
        })
        XCTAssertEqual(mirror.sets.count, 0, "a rolled-back transaction publishes nothing")

        // And its pending rowids do not leak into the next commit.
        try store.setMuted(true, convoID: "y")
        XCTAssertEqual(mirror.sets.count, 1)
        XCTAssertEqual(mirror.sets.first.map { Array($0.conversations.upserted.keys) }, [rowidOfY])
        XCTAssertEqual(mirror.sets.first?.conversations.deleted, [])
        XCTAssertEqual(mirror.rows, try freshRows(store))
    }

    func testACommitThatTouchesNoConversationPublishesNothing() throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        let (mirror, subscription) = try subscribeMirror(store)
        defer { subscription.cancel() }

        try store.outboxInsert(localID: "L1", convoID: "c1", body: "queued")
        try store.recordMaintenanceRun(at: Date())
        XCTAssertEqual(mirror.sets.count, 0)

        try store.applyJournal(event(2))
        XCTAssertEqual(mirror.sets.count, 1)
    }

    /// Writers on many threads; the database queue serialises them, and
    /// the change sets must reach the subscriber in that same order:
    /// strictly increasing commit numbers, and a mirror that ends equal
    /// to the table (an out-of-order pair of updates to one row would
    /// leave the older value behind).
    func testChangeSetsArriveInCommitOrderUnderRapidConcurrentCommits() throws {
        let store = try makeStore()
        let (mirror, subscription) = try subscribeMirror(store)
        defer { subscription.cancel() }

        let counter = OSAllocatedUnfairLock(initialState: Int64(0))
        let applied = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<60 {
                let seq = counter.withLock { value -> Int64 in value += 1; return value }
                // Every writer hits the same three rows, so order matters.
                // A frame that reaches the writer after a higher seq is a
                // no-op (seq <= cursor) and commits no conversation change.
                if (try? store.applyJournal(self.event(seq, convo: "c\(i % 3)",
                                                       payload: ["body": "w\(worker) i\(i)"]))) == true {
                    applied.withLock { $0 += 1 }
                }
            }
        }

        let commits = mirror.sets.map(\.commit)
        XCTAssertEqual(commits, commits.sorted())
        XCTAssertEqual(Set(commits).count, commits.count, "commit numbers are strictly increasing")
        XCTAssertEqual(mirror.sets.count, applied.withLock { $0 }, "one change set per applied frame")
        XCTAssertEqual(mirror.rows, try freshRows(store))
    }

    /// Registration and snapshot share one writer turn: every commit is
    /// either in the snapshot or in exactly one later change set, never
    /// both and never neither, even while another thread commits as fast
    /// as it can.
    func testSnapshotAndRegistrationHaveNoGapAndNoDuplicate() throws {
        let store = try makeStore()
        let total = 300
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for i in 1...total {
                if i == 20 { started.signal() }
                try? store.ensureConversation(id: "c\(i)", title: "C\(i)")
            }
            done.signal()
        }
        started.wait()
        let mirror = FeedMirror()
        let subscription = store.observeChanges(
            snapshot: { db in try StoreChangeFeed.conversationRows(db) },
            onEvent: mirror.handle, onError: { XCTFail("feed error: \($0)") })
        defer { subscription.cancel() }
        done.wait()
        try store.db.writeWithoutTransaction { _ in }

        let inSnapshot = Set(mirror.snapshotIDs)
        let inSets = mirror.sets.flatMap { $0.conversations.upserted.values.map(\.id) }
        XCTAssertEqual(inSnapshot.intersection(inSets), [], "no row is both in the snapshot and in a change set")
        XCTAssertEqual(Set(inSets).count, inSets.count, "each later commit is published once")
        XCTAssertEqual(inSnapshot.union(inSets).count, total, "and none is missing")
        XCTAssertEqual(mirror.rows, try freshRows(store))
    }

    /// `wipe()` clears the table wholesale: the feed reports a reset rather
    /// than a few thousand deletions, and a snapshot subscriber is handed
    /// a fresh snapshot, read on the writer right after that commit.
    func testWipePublishesAResetAndTheSubscriberGetsAFreshSnapshot() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "a"))
        try store.applyJournal(event(2, convo: "b"))
        let raw = FeedRecorder()
        let rawSubscription = store.changeFeed.subscribe(raw.handle)
        defer { rawSubscription.cancel() }
        let (mirror, subscription) = try subscribeMirror(store)
        defer { subscription.cancel() }

        try store.wipe()

        XCTAssertEqual(raw.sets.count, 1)
        XCTAssertEqual(raw.sets.first?.isReset, true)
        XCTAssertEqual(raw.sets.first?.conversations.upserted.count, 0)
        XCTAssertEqual(raw.sets.first?.conversations.deleted.count, 0)
        XCTAssertEqual(mirror.snapshots, 2, "a reset hands the subscriber a new snapshot")
        XCTAssertEqual(mirror.rows, [:])

        try store.applyJournal(event(3, convo: "c"))
        XCTAssertEqual(mirror.rows, try freshRows(store))
    }

    /// A rolled-back wipe leaves no reset behind for the next commit.
    func testRolledBackResetIsDropped() throws {
        let store = try makeStore()
        let raw = FeedRecorder()
        let rawSubscription = store.changeFeed.subscribe(raw.handle)
        defer { rawSubscription.cancel() }

        struct Abort: Error {}
        XCTAssertThrowsError(try store.db.write { db in
            store.changeFeed.markReset()
            throw Abort()
        })
        try store.applyJournal(event(1))
        XCTAssertEqual(raw.sets.map(\.isReset), [false])
    }

    /// With nobody subscribed the feed resolves nothing: the writer pays
    /// no query per commit for a feed no one reads.
    func testWithoutSubscribersTheFeedRunsNoQuery() throws {
        let metrics = StoreMetrics()
        let store = try makeStore(metrics: metrics)
        try store.applyJournal(event(1))
        XCTAssertNil(metrics.drain().observations.first { $0.name == "storeChangeFeed" })

        let (_, subscription) = try subscribeMirror(store)
        try store.applyJournal(event(2))
        let fed = metrics.drain().observations.first { $0.name == "storeChangeFeed" }
        XCTAssertEqual(fed?.fires, 1)
        XCTAssertEqual(fed?.rows, 1)

        subscription.cancel()
        try store.applyJournal(event(3))
        XCTAssertNil(metrics.drain().observations.first { $0.name == "storeChangeFeed" },
                     "a cancelled subscription stops the resolution")
    }

    /// Repeated feed failures back off: 1 s, doubling, capped at 30 s, and
    /// a delivered snapshot starts the count again.
    func testResubscribeBackoffDoublesToACapAndResetsOnSuccess() {
        var backoff = ResubscribeBackoff()
        let delays = (0..<8).map { _ in backoff.recordFailure() }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(backoff.consecutiveFailures, 8)
        backoff.recordSuccess()
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertEqual(backoff.recordFailure(), 1)
    }

    /// The `AsyncStream` form: the snapshot first, then one element per
    /// commit, in order.
    func testChangesStreamYieldsTheSnapshotThenEachCommit() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "a"))
        let received = OSAllocatedUnfairLock(initialState: [StoreFeedEvent<[String]>]())
        let consumer = Task {
            for await element in store.changes(snapshot: { db in try StoreChangeFeed.conversationRows(db).map(\.1.id) }) {
                received.withLock { $0.append(element) }
            }
        }
        defer { consumer.cancel() }
        try await waitUntil { received.withLock { $0.count } == 1 }

        try store.applyJournal(event(2, convo: "b"))
        try store.applyJournal(event(3, convo: "a", type: JournalEventType.sessionStatus, payload: ["state": "done"]))
        try await waitUntil { received.withLock { $0.count } == 3 }

        let events = received.withLock { $0 }
        guard events.count == 3,
              case .snapshot(let ids) = events[0],
              case .changes(let first) = events[1],
              case .changes(let second) = events[2]
        else { return XCTFail("a snapshot, then the change sets: \(events)") }
        XCTAssertEqual(ids, ["a"])
        XCTAssertEqual(first.conversations.upserted.values.map(\.id), ["b"])
        XCTAssertEqual(second.conversations.upserted.values.map(\.sessionState), ["done"])
        XCTAssertLessThan(first.commit, second.commit)
    }
}

final class StoreChangeFeedPoolTests: StoreChangeFeedTests {
    override class var writerKind: StoreWriterKind { .pool }
}

/// Polls `condition` until it holds, failing (not hanging) after `timeout`.
func waitUntil(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            XCTFail("condition not met within \(timeout)", file: file, line: line)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Applies feed events to a rowid-keyed mirror of `conversation`. Events
/// arrive on the writer, synchronously inside the commit, so the mirror is
/// current by the time the write call returns.
final class FeedMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [Int64: ConversationRecord] = [:]
    private var _sets: [StoreChangeSet] = []
    private var _snapshots = 0
    private var _snapshotIDs: [String] = []

    var rows: [Int64: ConversationRecord] { lock.withLock { _rows } }
    var sets: [StoreChangeSet] { lock.withLock { _sets } }
    var snapshots: Int { lock.withLock { _snapshots } }
    var snapshotIDs: [String] { lock.withLock { _snapshotIDs } }

    func handle(_ event: StoreFeedEvent<[(Int64, ConversationRecord)]>) {
        lock.withLock {
            switch event {
            case .snapshot(let rows):
                _snapshots += 1
                _rows = Dictionary(uniqueKeysWithValues: rows)
                _snapshotIDs = rows.map(\.1.id)
            case .changes(let set):
                _sets.append(set)
                for rowid in set.conversations.deleted { _rows[rowid] = nil }
                for (rowid, row) in set.conversations.upserted { _rows[rowid] = row }
            }
        }
    }
}

/// Records the raw change sets a plain feed subscriber receives.
final class FeedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sets: [StoreChangeSet] = []
    var sets: [StoreChangeSet] { lock.withLock { _sets } }

    func handle(_ db: Database, _ set: StoreChangeSet) {
        lock.withLock { _sets.append(set) }
    }
}
