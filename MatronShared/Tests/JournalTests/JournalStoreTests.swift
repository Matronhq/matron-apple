import XCTest
@testable import MatronJournal

final class JournalStoreTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
                       type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testApplyAdvancesCursorAndIsIdempotent() throws {
        let store = try makeStore()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertTrue(try store.applyJournal(event(1)))
        XCTAssertTrue(try store.applyJournal(event(2)))
        XCTAssertFalse(try store.applyJournal(event(2)), "replayed frame must be a no-op")
        XCTAssertEqual(store.cursor, 2)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1, 2])
    }

    func testAutoCreatesConversationAndUpdatesSummary() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, payload: ["body": "hello world"]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.id, "c1")
        XCTAssertEqual(convo.lastSeq, 1)
        XCTAssertEqual(convo.snippet, "hello world")
        XCTAssertEqual(convo.unreadCount, 1)
    }

    func testConvoMetaSetsTitleForNewConversation() throws {
        // A conversation first seen over the socket (e.g. one the bridge just
        // created) must pick up its title from the convo_meta frame, not stay
        // blank until a reconnect/snapshot.
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "new1", type: "convo_meta", payload: ["title": "Fresh chat"]))
        let convo = try XCTUnwrap(try store.conversations().first { $0.id == "new1" })
        XCTAssertEqual(convo.title, "Fresh chat")
    }

    func testConvoMetaUpdatesExistingTitleAndIgnoresEmpty() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "c1", type: "convo_meta", payload: ["title": "First"]))
        try store.applyJournal(event(2, convo: "c1", type: "convo_meta", payload: ["title": "Renamed"]))
        XCTAssertEqual(try store.conversations().first?.title, "Renamed")
        // An empty title must not wipe the good one.
        try store.applyJournal(event(3, convo: "c1", type: "convo_meta", payload: ["title": ""]))
        XCTAssertEqual(try store.conversations().first?.title, "Renamed")
    }

    func testConvoMetaDoesNotBumpUnread() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "c1", type: "convo_meta", payload: ["title": "T"]))
        XCTAssertEqual(try store.conversations().first?.unreadCount, 0,
                       "metadata frames are not messages")
    }

    func testConversationExists() throws {
        let store = try makeStore()
        XCTAssertFalse(try store.conversationExists("c1"))
        try store.applyJournal(event(1, convo: "c1"))
        XCTAssertTrue(try store.conversationExists("c1"))
        XCTAssertFalse(try store.conversationExists("other"))
    }

    func testOwnMessagesDoNotBumpUnread() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, sender: "user:dan"))
        XCTAssertEqual(try store.conversations().first?.unreadCount, 0)
    }

    func testReadMarkerRecomputesUnread() throws {
        let store = try makeStore()
        for i: Int64 in 1...5 { try store.applyJournal(event(i)) }
        XCTAssertEqual(try store.conversations().first?.unreadCount, 5)
        try store.applyJournal(event(6, sender: "user:dan", type: "read_marker",
                                     payload: ["convo_id": "c1", "up_to_seq": 4]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.readUpToSeq, 4)
        XCTAssertEqual(convo.unreadCount, 1)
    }

    func testSessionStatusUpdatesStateWithoutUnread() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "session_status", payload: ["state": "waiting"]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.sessionState, "waiting")
        XCTAssertEqual(convo.unreadCount, 0)
    }

    func testColdSnapshotThenHistoryInsert() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 10, snippet: "s", createdAt: 0),
        ], headSeq: 10)
        XCTAssertEqual(store.cursor, 10)
        XCTAssertEqual(try store.conversations().first?.title, "T")
        // history pagination fills older events without touching cursor/unread
        try store.insertHistory([event(8), event(9)])
        XCTAssertEqual(store.cursor, 10)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [8, 9])
        XCTAssertEqual(try store.conversations().first?.unreadCount, 0)
        XCTAssertEqual(try store.minSeq(convoID: "c1"), 8)
    }

    func testRefreshSummariesNeverRegressesLastSeq() throws {
        let store = try makeStore()
        try store.applyJournal(event(5))
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "c1", title: "new title", sessionState: "done",
                            lastSeq: 3, snippet: "old", createdAt: 0),
        ])
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.title, "new title")
        XCTAssertEqual(convo.sessionState, "done")
        XCTAssertEqual(convo.lastSeq, 5, "stale snapshot must not roll back lastSeq")
    }

    func testRefreshSummariesUpdatesLastActivityMonotonically() throws {
        let store = try makeStore()
        try store.applyJournal(event(5)) // sets lastActivityTS from the event's ts
        let applied = try XCTUnwrap(try store.conversations().first?.lastActivityTS)

        // A fresher server last_ts advances the displayed activity time —
        // the "20h ago row hiding 4-minute-old messages" fix.
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 9, snippet: "new", createdAt: 0, lastTS: applied + 60_000),
        ])
        XCTAssertEqual(try store.conversations().first?.lastActivityTS, applied + 60_000)

        // A stale snapshot must not roll it back, and a missing last_ts
        // (older server) must leave it alone.
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 9, snippet: "new", createdAt: 0, lastTS: applied - 60_000),
        ])
        XCTAssertEqual(try store.conversations().first?.lastActivityTS, applied + 60_000)
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 9, snippet: "new", createdAt: 0),
        ])
        XCTAssertEqual(try store.conversations().first?.lastActivityTS, applied + 60_000)
    }

    func testColdSnapshotSeedsLastActivityFromLastTS() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 10, snippet: "s", createdAt: 0, lastTS: 123_000),
        ], headSeq: 10)
        XCTAssertEqual(try store.conversations().first?.lastActivityTS, 123_000)
    }

    func testConversationsStreamYieldsOnChange() async throws {
        let store = try makeStore()
        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        try store.applyJournal(event(1))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.first?.id, "c1")
    }

    func testWipe() throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        try store.wipe()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertEqual(try store.conversations().count, 0)
    }

    func testInsertHistoryRecountsUnread() throws {
        // Paginated history can contain unread messages (e.g. the refill
        // after a snapshot_required wipe). insertHistory must recount, not
        // leave the incremental counter stale (bugbot "History insert
        // skips unread").
        let store = try makeStore()
        try store.applyJournal(event(1))
        try store.applyJournal(event(2, sender: "user:dan", type: "read_marker",
                                     payload: ["convo_id": "c1", "up_to_seq": 1]))
        XCTAssertEqual(try store.conversations().first?.unreadCount, 0)
        // Backfill delivers rows 3–4 from others, above the read marker.
        try store.insertHistory([event(3), event(4)])
        XCTAssertEqual(try store.conversations().first?.unreadCount, 2,
                       "history rows above readUpToSeq must count as unread")
    }

    func testStreamsWorkFromBackgroundThread() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        let first = await Task.detached {
            var iterator = store.conversationsStream().makeAsyncIterator()
            return await iterator.next()
        }.value
        XCTAssertEqual(first?.first?.id, "c1")
    }
}
