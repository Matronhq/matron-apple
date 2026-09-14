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

    /// Item #115: `[#65](matron://item/65)` resolves the tapped NUMBER to a
    /// local item id before the app navigates.
    func testItemByNumberFindsTheItemAndMissesCleanly() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1), item("it_65", num: 65, convo: "c2")])
        XCTAssertEqual(try store.item(num: 65)?.id, "it_65")
        XCTAssertEqual(try store.item(num: 65)?.title, "T65")
        XCTAssertEqual(try store.item(num: 1)?.id, "it_1")
        XCTAssertNil(try store.item(num: 999), "an item this device has never synced must miss, not throw")
        XCTAssertNil(try store.item(num: 0))
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

    /// Fix wave, item A: `insertComments` is an upsert (`save`), not a
    /// `replaceComments`-style delete-then-insert — it must leave existing
    /// rows for the same item alone.
    func testInsertCommentsUpsertsWithoutDeletingExisting() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a")])
        try store.insertComments([TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "b")])
        let rows = try store.dbQueue.read { db in try ItemCommentRecord.fetchAll(db) }
        XCTAssertEqual(Set(rows.map(\.id)), ["ic_1", "ic_2"], "ic_1 survives — insertComments doesn't delete existing rows")

        // Idempotent: inserting the same id again with new content upserts, not duplicates.
        try store.insertComments([TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "b-edited")])
        let rows2 = try store.dbQueue.read { db in try ItemCommentRecord.fetchAll(db) }
        XCTAssertEqual(rows2.count, 2)
        XCTAssertEqual(rows2.first { $0.id == "ic_2" }?.body, "b-edited")
    }

    /// Fix wave, item C: feeds `ItemsPanelViewModel.pendingCreates`. Each
    /// insert is awaited-through one at a time (rather than firing both
    /// writes before reading) — `ValueObservation` tracks the whole
    /// `item_outbox` table region, so a "comment" row insert still
    /// triggers a recomputation (and its own stream emission); asserting
    /// on that emission too pins the "comment rows are filtered out"
    /// behaviour, not just the final state.
    func testItemOutboxCreatesStreamOnlyYieldsCreateRows() async throws {
        let store = try makeStore()
        let stream = store.itemOutboxCreatesStream()
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.count, 0)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{}", createdAt: 1, attempts: 0, lastError: nil))
        let afterComment = await it.next()
        XCTAssertEqual(afterComment?.count, 0, "a comment-op row must not appear in the creates-only stream")
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L2", itemID: nil, op: "create", payloadJSON: "{}", createdAt: 2, attempts: 0, lastError: nil))
        let afterCreate = await it.next()
        XCTAssertEqual(afterCreate?.map(\.localID), ["L2"], "only the create row is yielded")
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

    func testCommitOutboxResultIsOneWrite() throws {
        let store = try makeStore()
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: nil, op: "create", payloadJSON: "{}", createdAt: 1, attempts: 0, lastError: nil))
        let comment = TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "hi")
        try store.commitOutboxResult(item: item("it_1", num: 1), comment: comment, deletingLocalID: "L1")
        XCTAssertEqual(try store.item(id: "it_1")?.num, 1)
        XCTAssertEqual(try store.dbQueue.read { db in try ItemCommentRecord.fetchCount(db) }, 1)
        XCTAssertTrue(try store.itemOutboxPending().isEmpty)
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

    /// Fix round 1 (CRITICAL #1/#2): the per-scope refresh watermark lives
    /// in `meta`, keyed independently per scope. `wipeItems()` clearing the
    /// cache without also clearing these would let a subsequent refresh
    /// believe it's still caught up on data that no longer exists locally.
    func testItemsWatermarkIsPerScopeAndClearedByWipeItems() throws {
        let store = try makeStore()
        XCTAssertNil(try store.itemsWatermark(scope: .all))
        XCTAssertNil(try store.itemsWatermark(scope: .convo("c1")))

        try store.setItemsWatermark(Date(timeIntervalSince1970: 100), scope: .all)
        try store.setItemsWatermark(Date(timeIntervalSince1970: 50), scope: .convo("c1"))
        XCTAssertEqual(try store.itemsWatermark(scope: .all), Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try store.itemsWatermark(scope: .convo("c1")), Date(timeIntervalSince1970: 50))
        // A different convo's key must not collide with "c1"'s.
        XCTAssertNil(try store.itemsWatermark(scope: .convo("c2")))

        try store.setItemsWatermark(Date(timeIntervalSince1970: 200), scope: .all)
        XCTAssertEqual(try store.itemsWatermark(scope: .all), Date(timeIntervalSince1970: 200), "re-setting overwrites, not accumulates")

        try store.wipeItems()
        XCTAssertNil(try store.itemsWatermark(scope: .all))
        XCTAssertNil(try store.itemsWatermark(scope: .convo("c1")))
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
        try store.setItemsWatermark(Date(timeIntervalSince1970: 100), scope: .all)
        try store.wipe()
        XCTAssertTrue(try store.items(scope: .all).isEmpty)
        let commentCount = try store.dbQueue.read { db in try ItemCommentRecord.fetchCount(db) }
        XCTAssertEqual(commentCount, 0)
        // The unsent comment's outbox row must survive a replay-gap wipe.
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"])
        // `wipe()` does a blanket `DELETE FROM meta` (fix round 1): the
        // watermark must not survive either, or the next refresh would
        // believe it's caught up on a mirror that was just cleared.
        XCTAssertNil(try store.itemsWatermark(scope: .all))
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

    /// Item #114: the origin label names the box as well as the
    /// conversation, e.g. "dev-mac · Missions plan", so a tracker row or
    /// the item-detail origin button reads as "which box, which chat"
    /// rather than just the chat title.
    func testConversationOriginLabelsNameTheBox() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-mac"), AgentDTO(id: 9, name: "")])
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "Missions plan", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7),
            ConvoSummaryDTO(id: "c2", title: "No box", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1),
            ConvoSummaryDTO(id: "c3", title: "", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7),
            ConvoSummaryDTO(id: "c4", title: "Empty agent name", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 9),
        ], headSeq: 1)

        let labels = try store.conversationOriginLabels()
        XCTAssertEqual(labels["c1"], "dev-mac \u{00B7} Missions plan", "box present names the box")
        XCTAssertEqual(labels["c2"], "No box", "no agent on the conversation falls back to the title alone")
        XCTAssertNil(labels["c3"], "an empty title is omitted from the map, box or not")
        XCTAssertEqual(labels["c4"], "Empty agent name", "an agent row with an empty name falls back to the title alone")

        XCTAssertEqual(try store.conversationOriginLabel(id: "c1"), "dev-mac \u{00B7} Missions plan")
        XCTAssertEqual(try store.conversationOriginLabel(id: "c2"), "No box")
        XCTAssertNil(try store.conversationOriginLabel(id: "c3"), "empty title is nil from the single-id lookup too")
        XCTAssertNil(try store.conversationOriginLabel(id: "c4-does-not-exist"), "unknown id is nil")
    }
}
