import XCTest
@testable import MatronJournal

/// Outbox table semantics (offline send queue). The outbox holds text
/// sends that couldn't be delivered yet; rows survive relaunch AND the
/// `snapshot_required` mirror wipe (a replay-gap wipe must not eat the
/// user's unsent messages). Delivery confirmation deletes a row when the
/// own-text journal frame lands (`outboxDeleteFirstMatching`).
final class JournalOutboxStoreTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    /// An own-text journal event whose timestamp derives from `seq`
    /// (seq seconds → seq*1000 ms), so tests can position it before or
    /// after an outbox row's `createdAt`.
    private func ownText(_ seq: Int64, body: String, sender: String = "user:dan") -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: "text",
                     payloadData: Data(#"{"body":"\#(body)"}"#.utf8))
    }

    func testInsertHistoryConfirmsPostSnapshotOutboxRow() throws {
        // After a snapshot_required wipe the cursor jumps past the
        // confirming frames — the history refill must confirm attempted
        // rows instead, or delivered sends stay queued forever.
        let store = try makeStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "hello",
                               now: Date(timeIntervalSince1970: 1))
        try store.outboxMarkAttempt(localID: "A")
        try store.insertHistory([ownText(2, body: "hello")]) // ts after the row
        XCTAssertTrue(try store.outboxRows(convoID: "c1").isEmpty)
    }

    func testOldHistoryEventDoesNotConfirmFreshSend() throws {
        // An identical body sent LONG AGO and replayed by pagination must
        // not eat a fresh queued send: a confirming event can't predate
        // its own row.
        let store = try makeStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "hello",
                               now: Date(timeIntervalSince1970: 5))
        try store.outboxMarkAttempt(localID: "A")
        try store.insertHistory([ownText(1, body: "hello")]) // ts before the row
        XCTAssertEqual(try store.outboxRows(convoID: "c1").map(\.localID), ["A"])
    }

    func testInsertHistoryFromOtherSenderKeepsOutboxRow() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "hello",
                               now: Date(timeIntervalSince1970: 1))
        try store.outboxMarkAttempt(localID: "A")
        try store.insertHistory([ownText(2, body: "hello", sender: "agent:a")])
        XCTAssertEqual(try store.outboxRows(convoID: "c1").map(\.localID), ["A"])
    }

    func testInsertAndFetchPendingFIFO() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "first",
                               now: Date(timeIntervalSince1970: 1))
        try store.outboxInsert(localID: "b", convoID: "c1", body: "second",
                               now: Date(timeIntervalSince1970: 2))
        try store.outboxInsert(localID: "c", convoID: "c2", body: "third",
                               now: Date(timeIntervalSince1970: 3))
        let pending = try store.outboxPending()
        XCTAssertEqual(pending.map(\.localID), ["a", "b", "c"], "flush order is FIFO by creation")
        XCTAssertEqual(pending.map(\.state), [.queued, .queued, .queued])
        XCTAssertEqual(pending.first?.attempts, 0)
    }

    func testInsertSameLocalIDIsIdempotent() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        XCTAssertEqual(try store.outboxPending().count, 1)
    }

    func testMarkAttemptIncrements() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        try store.outboxMarkAttempt(localID: "a")
        try store.outboxMarkAttempt(localID: "a")
        XCTAssertEqual(try store.outboxPending().first?.attempts, 2)
    }

    func testMarkFailedAndRequeue() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        try store.outboxMarkFailed(localID: "a", error: "rejected")
        let failed = try XCTUnwrap(try store.outboxRows(convoID: "c1").first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.lastError, "rejected")
        // Failed rows are NOT part of the automatic flush set…
        XCTAssertTrue(try store.outboxPending().isEmpty)
        // …until an explicit requeue (tap-to-retry) puts them back.
        try store.outboxRequeue(localID: "a")
        XCTAssertEqual(try store.outboxPending().map(\.localID), ["a"])
    }

    func testDeleteFirstMatchingPrefersOldestAttemptedRow() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "old", convoID: "c1", body: "same",
                               now: Date(timeIntervalSince1970: 1))
        try store.outboxInsert(localID: "new", convoID: "c1", body: "same",
                               now: Date(timeIntervalSince1970: 2))
        try store.outboxMarkAttempt(localID: "old")
        try store.outboxMarkAttempt(localID: "new")
        // Delivery confirmation for identical bodies retires the OLDEST
        // attempted copy (FIFO, mirrors echo retirement).
        XCTAssertEqual(try store.outboxDeleteFirstMatching(convoID: "c1", body: "same"), "old")
        XCTAssertEqual(try store.outboxRows(convoID: "c1").map(\.localID), ["new"])
    }

    func testDeleteFirstMatchingIgnoresUnattemptedRows() throws {
        let store = try makeStore()
        // Never-attempted rows can't be the row a journal frame confirms —
        // deleting one would silently eat a message that was never sent
        // (e.g. same body sent from another device while this one queued).
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        XCTAssertNil(try store.outboxDeleteFirstMatching(convoID: "c1", body: "hi"))
        XCTAssertEqual(try store.outboxRows(convoID: "c1").count, 1)
    }

    func testDeleteFirstMatchingScopedToConvoAndBody() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        try store.outboxMarkAttempt(localID: "a")
        XCTAssertNil(try store.outboxDeleteFirstMatching(convoID: "c2", body: "hi"))
        XCTAssertNil(try store.outboxDeleteFirstMatching(convoID: "c1", body: "other"))
        XCTAssertEqual(try store.outboxDeleteFirstMatching(convoID: "c1", body: "hi"), "a")
    }

    func testWipePreservesOutbox() throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "agent:dev-2", type: "text",
            payloadData: try JSONSerialization.data(withJSONObject: ["body": "hi"])))
        try store.outboxInsert(localID: "a", convoID: "c1", body: "queued", now: Date())
        try store.wipe()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertTrue(try store.events(convoID: "c1").isEmpty)
        XCTAssertEqual(try store.outboxPending().map(\.localID), ["a"],
                       "snapshot_required wipe must not eat unsent messages")
    }

    func testWipeOutboxClears() throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "queued", now: Date())
        try store.wipeOutbox()
        XCTAssertTrue(try store.outboxPending().isEmpty)
    }

    func testOutboxStreamEmitsOnChange() async throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        var iterator = store.outboxStream(convoID: "c1").makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.localID), ["a"])
        try store.outboxInsert(localID: "b", convoID: "c1", body: "again", now: Date())
        var latest = await iterator.next()
        // ValueObservation may coalesce; take the next emission(s) until
        // the insert shows up (bounded by the iterator design: one change
        // pending → at most one more next()).
        if latest?.count == 1 { latest = await iterator.next() }
        XCTAssertEqual(latest?.map(\.localID), ["a", "b"])
    }

    func testOutboxStreamScopedToConvo() async throws {
        let store = try makeStore()
        try store.outboxInsert(localID: "a", convoID: "c1", body: "hi", now: Date())
        try store.outboxInsert(localID: "x", convoID: "c2", body: "other", now: Date())
        var iterator = store.outboxStream(convoID: "c1").makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.localID), ["a"])
    }
}
