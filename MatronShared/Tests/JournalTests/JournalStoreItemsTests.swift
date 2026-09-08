import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreItemsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }
    private func item(_ id: String, num: Int, kind: ItemKind = .task, convo: String = "c1", awaiting: ItemAwaiting? = .agent,
                      state: ItemState = .open, rank: Double = 1024, updated: TimeInterval = 1) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, awaiting: awaiting, rank: rank, title: "T\(num)",
                    originConvoID: convo, updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testMigrationV9CreatesTables() throws {
        let store = try makeStore()
        let names = try store.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        XCTAssertTrue(names.contains("item")); XCTAssertTrue(names.contains("item_comment")); XCTAssertTrue(names.contains("item_outbox"))
    }

    func testUpsertRoundTripsAndScopes() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1), item("it_2", num: 2, kind: .question, convo: "c2", awaiting: .user)])
        XCTAssertEqual(try store.item(id: "it_1")?.title, "T1")
        XCTAssertEqual(try store.items(scope: .convo("c2")).map(\.id), ["it_2"])
        XCTAssertEqual(try store.items(scope: .all).count, 2)
        try store.upsertItems([item("it_1", num: 1, state: .closed, updated: 5)])
        XCTAssertEqual(try store.item(id: "it_1")?.state, .closed)
        XCTAssertEqual(try store.itemsMaxUpdatedAt(), Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try store.needsUserCounts(), ["c2": 1])
    }

    func testCommentsReplaceWholesale() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a"),
                                                   TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "b")])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "b2")])
        let rows = try store.dbQueue.read { db in try ItemCommentRecord.fetchAll(db) }
        XCTAssertEqual(rows.map(\.id), ["ic_2"]); XCTAssertEqual(rows.first?.body, "b2")
    }

    func testItemsStreamFiresOnUpsert() async throws {
        let store = try makeStore()
        let stream = store.itemsStream(scope: .convo("c1"))
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.count, 0)
        try store.upsertItems([item("it_1", num: 1)])
        let second = await it.next()
        XCTAssertEqual(second?.map(\.id), ["it_1"])
    }

    func testOutboxLifecycle() throws {
        let store = try makeStore()
        let rec = ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{\"body\":\"x\"}", createdAt: 1, attempts: 0, lastError: nil)
        try store.itemOutboxInsert(rec)
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"])
        try store.itemOutboxMarkAttempt(localID: "L1", error: "offline")
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.attempts, 1)
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.lastError, "offline")
        try store.itemOutboxDelete(localID: "L1")
        XCTAssertTrue(try store.itemOutboxPending().isEmpty)
    }

    func testWipeItemsClearsAllThree() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a")])
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{}", createdAt: 1, attempts: 0, lastError: nil))
        try store.wipeItems()
        XCTAssertTrue(try store.items(scope: .all).isEmpty)
        XCTAssertTrue(try store.itemOutboxPending().isEmpty)
    }

    /// Controller ruling (fix round 2): `wipe()` is the `snapshot_required`
    /// replay-gap path, NOT the sign-out path — it must clear the tracker
    /// cache (item, item_comment; both are refetched) but must NOT touch
    /// `item_outbox`, exactly like it already leaves the text-message
    /// `outbox` alone. Eating unsent tracker comments/creates on a replay
    /// gap would be the same bug as eating unsent chat messages.
    func testFullWipeClearsCacheButKeepsItemOutbox() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a")])
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{}", createdAt: 1, attempts: 0, lastError: nil))
        try store.wipe()
        XCTAssertTrue(try store.items(scope: .all).isEmpty)
        let commentCount = try store.dbQueue.read { db in try ItemCommentRecord.fetchCount(db) }
        XCTAssertEqual(commentCount, 0)
        // The unsent comment's outbox row must survive a replay-gap wipe.
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"])
    }

    /// `wipeOutbox()` is the sign-out path (paired with `wipe()` in
    /// `AppDependencies.signOut()`) and must clear `item_outbox` alongside
    /// the text-message `outbox` — the next signed-in account must not
    /// inherit (or send) the previous user's queued tracker comments/creates.
    func testWipeOutboxClearsItemOutbox() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{}", createdAt: 1, attempts: 0, lastError: nil))
        try store.wipeOutbox()
        XCTAssertTrue(try store.itemOutboxPending().isEmpty)
    }

    func testCommentStatusSnapshotRoundTrips() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        let from = TrackerItem.StatusSnapshot(state: .open, resolution: nil, awaiting: .agent)
        let to = TrackerItem.StatusSnapshot(state: .closed, resolution: .done, awaiting: nil)
        let statusComment = TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, kind: .status, body: "",
                                           statusFrom: from, statusTo: to)
        let plainComment = TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: "just a comment")
        try store.replaceComments(itemID: "it_1", [statusComment, plainComment])

        let comments = try store.dbQueue.read { db in try ItemCommentRecord.fetchAll(db) }.map(\.comment)
        let readStatus = comments.first { $0.id == "ic_1" }
        let readPlain = comments.first { $0.id == "ic_2" }

        XCTAssertEqual(readStatus?.kind, .status)
        XCTAssertEqual(readStatus?.statusFrom, from)
        XCTAssertEqual(readStatus?.statusTo, to)

        XCTAssertEqual(readPlain?.kind, .comment)
        XCTAssertNil(readPlain?.statusFrom)
        XCTAssertNil(readPlain?.statusTo)
    }
}
