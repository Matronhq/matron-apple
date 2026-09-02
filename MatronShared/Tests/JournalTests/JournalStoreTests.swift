import GRDB
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

    // MARK: applyJournalBatch (catch-up fast path)

    func testBatchApplyMatchesSingleFrameSemantics() throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        // Batch spanning a duplicate (seq 1), two convos, meta and unread
        // bookkeeping — the returned list must contain exactly the frames
        // that wrote, in order, with the same summary state a frame-by-frame
        // apply would produce.
        let batch = [
            event(1),  // duplicate: seq <= cursor, must be skipped
            event(2, payload: ["body": "two"]),
            event(3, convo: "c2", type: "convo_meta", payload: ["title": "Other"]),
            event(4, convo: "c2", payload: ["body": "four"]),
        ]
        let applied = try store.applyJournalBatch(batch)
        XCTAssertEqual(applied.map(\.seq), [2, 3, 4])
        XCTAssertEqual(store.cursor, 4)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1, 2])
        let c1 = try XCTUnwrap(try store.conversations().first { $0.id == "c1" })
        XCTAssertEqual(c1.snippet, "two")
        XCTAssertEqual(c1.unreadCount, 2)
        let c2 = try XCTUnwrap(try store.conversations().first { $0.id == "c2" })
        XCTAssertEqual(c2.title, "Other")
        XCTAssertEqual(c2.unreadCount, 1)
        XCTAssertEqual(try store.applyJournalBatch(batch).map(\.seq), [],
                       "re-applying the same batch must be a complete no-op")
    }

    func testBatchApplyConfirmsQueuedSendInSameTransaction() throws {
        // The outbox delete must ride inside the batch transaction exactly
        // as it does in the single-frame path — a delivered send's queued
        // row and its confirming event commit together.
        let store = try makeStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "queued hello")
        try store.outboxMarkAttempt(localID: "A") // only attempted rows can be confirmed delivered
        XCTAssertEqual(try store.outboxRows(convoID: "c1").count, 1)
        _ = try store.applyJournalBatch([
            event(1, sender: "user:dan", payload: ["body": "queued hello"]),
        ])
        XCTAssertEqual(try store.outboxRows(convoID: "c1").count, 0,
                       "own-text frame in a batch must confirm the queued send")
    }

    func testBatchApplyIsAllOrNothingOnInjectedFailure() throws {
        let store = try makeStore()
        store.failApplyForTesting = { $0 == 2 }
        XCTAssertThrowsError(try store.applyJournalBatch([event(1), event(2), event(3)]))
        XCTAssertEqual(store.cursor, 0, "failed batch must leave the cursor untouched")
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [],
                       "failed batch must write nothing")
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

    func testEnsureConversationCreatesPlaceholderOnce() throws {
        let store = try makeStore()
        try store.ensureConversation(id: "c-new", title: "New chat")
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.id, "c-new")
        XCTAssertEqual(convo.title, "New chat")
        XCTAssertEqual(convo.sessionState, "running")
        XCTAssertEqual(convo.unreadCount, 0)

        // Never clobbers an existing row — the real convo_meta owns it.
        try store.applyJournal(event(1, convo: "c-new", type: "convo_meta",
                                     payload: ["title": "Real title"]))
        try store.ensureConversation(id: "c-new", title: "New chat")
        let after = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(after.title, "Real title")
        XCTAssertEqual(after.lastSeq, 1)
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

    func testConversationsOrderedByActivityTimeNotJustSeq() throws {
        // A conversation's position in the list must reflect when it last
        // had real activity, not the server's journal sequence numbering.
        // "c-old" has a much higher `lastSeq` (more journal traffic
        // overall, e.g. session_status/read_marker bookkeeping) but its
        // last real message is older than "c-new"'s — "c-new" must sort
        // first.
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c-old", title: "Old", sessionState: "running",
                            lastSeq: 100, snippet: "s", createdAt: 0, lastTS: 1_000),
            ConvoSummaryDTO(id: "c-new", title: "New", sessionState: "running",
                            lastSeq: 5, snippet: "s", createdAt: 0, lastTS: 2_000),
        ], headSeq: 100)
        XCTAssertEqual(try store.conversations().map(\.id), ["c-new", "c-old"],
                       "newer last_activity_ts must sort first even with a lower last_seq")
    }

    func testConversationsWithNullActivityTsSortLastTiebrokenBySeq() throws {
        // A conversation that never got an activity timestamp (e.g. an
        // older server's snapshot omitting `last_ts`, or a row created
        // only via a non-message frame) must fall to the bottom of the
        // list rather than floating above conversations with real recent
        // activity — SQLite sorts NULL last under `DESC`, which is the
        // behavior this test pins. Among null-activity rows, `last_seq`
        // is the tiebreak.
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c-null-high-seq", title: "A", sessionState: "running",
                            lastSeq: 50, snippet: "s", createdAt: 0),
            ConvoSummaryDTO(id: "c-null-low-seq", title: "B", sessionState: "running",
                            lastSeq: 10, snippet: "s", createdAt: 0),
            ConvoSummaryDTO(id: "c-active", title: "C", sessionState: "running",
                            lastSeq: 1, snippet: "s", createdAt: 0, lastTS: 500),
        ], headSeq: 50)
        XCTAssertEqual(try store.conversations().map(\.id),
                       ["c-active", "c-null-high-seq", "c-null-low-seq"],
                       "null last_activity_ts sorts last, tiebroken by last_seq desc")
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

    func testConversationsStreamOrderedByActivityTimeNotJustSeq() async throws {
        // `conversationsStream()` hand-duplicates the `.order(...)` call in
        // `conversations(now:)` rather than sharing it, so a future edit to
        // one query without the other must fail a test — mirrors
        // `testConversationsOrderedByActivityTimeNotJustSeq` but reads
        // through the live stream instead of a one-shot fetch.
        let store = try makeStore()
        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c-old", title: "Old", sessionState: "running",
                            lastSeq: 100, snippet: "s", createdAt: 0, lastTS: 1_000),
            ConvoSummaryDTO(id: "c-new", title: "New", sessionState: "running",
                            lastSeq: 5, snippet: "s", createdAt: 0, lastTS: 2_000),
        ], headSeq: 100)
        let updated = await iterator.next()
        XCTAssertEqual(updated?.map(\.id), ["c-new", "c-old"],
                       "newer last_activity_ts must sort first in the stream too, even with a lower last_seq")
    }

    func testConversationsStreamSuppressesDuplicateDeliveries() async throws {
        // The conversations fetch re-runs on every commit store-wide (its
        // TTL sub-queries read the event table). A commit that doesn't
        // change the visible list — here, traffic in a hidden conversation
        // — must not be delivered downstream.
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "c-visible"))
        try store.applyJournal(event(2, convo: "c-hidden"))
        try store.setHidden(true, convoID: "c-hidden")

        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.id), ["c-visible"])

        // No-op for the visible list, then a real change. If the no-op
        // were delivered, this next() would return the stale duplicate
        // (last_seq still 1) instead of the bumped row. The sleep keeps
        // GRDB from coalescing both commits into one notification, which
        // would let a dedup regression slip past this assert.
        try store.applyJournal(event(3, convo: "c-hidden"))
        try await Task.sleep(for: .milliseconds(150))
        try store.applyJournal(event(4, convo: "c-visible", payload: ["body": "bumped"]))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.first?.id, "c-visible")
        XCTAssertEqual(updated?.first?.lastSeq, 4,
                       "hidden-convo traffic must be deduplicated, not delivered as a stale list")
    }

    // MARK: Windowed events stream + local pagination reads

    func testTailWindowStart() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.tailWindowStart(convoID: "c1", limit: 3), 0,
                       "empty conversation anchors at 0 (observe everything)")
        for seq in 1...5 { try store.applyJournal(event(Int64(seq))) }
        try store.applyJournal(event(6, convo: "c2"))
        XCTAssertEqual(try store.tailWindowStart(convoID: "c1", limit: 3), 3,
                       "anchor is the lowest seq of the newest `limit` rows")
        XCTAssertEqual(try store.tailWindowStart(convoID: "c1", limit: 10), 1,
                       "fewer rows than the window: anchor is the oldest row")
    }

    func testEventsBeforeSeqReturnsAscendingPage() throws {
        let store = try makeStore()
        for seq in 1...6 { try store.applyJournal(event(Int64(seq))) }
        try store.applyJournal(event(7, convo: "c2"))
        let page = try store.events(convoID: "c1", beforeSeq: 5, limit: 3)
        XCTAssertEqual(page.map(\.seq), [2, 3, 4],
                       "page is the newest rows strictly below the bound, ascending")
        XCTAssertEqual(try store.events(convoID: "c1", beforeSeq: 2, limit: 3).map(\.seq), [1])
        XCTAssertEqual(try store.events(convoID: "c1", beforeSeq: 1, limit: 3).map(\.seq), [])
    }

    func testEventsStreamAnchoredAtSinceSeq() async throws {
        let store = try makeStore()
        for seq in 1...4 { try store.applyJournal(event(Int64(seq))) }

        var iterator = store.eventsStream(convoID: "c1", sinceSeq: 3).makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.seq), [3, 4],
                       "rows below the anchor never ride the observation")

        try store.applyJournal(event(5))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.map(\.seq), [3, 4, 5])
    }

    // MARK: Snippet-TTL memo invalidation

    /// `insertHistory` writes event rows without bumping `last_seq`, so it
    /// must drop the TTL memo: a stale conversation whose newest message
    /// arrives via backfill would otherwise keep its cached "no override"
    /// answer and never show the `$ command` snippet.
    func testSnippetTTLMemoInvalidatedByInsertHistory() throws {
        let store = try makeStore()
        // Stale conversation (1970 activity), summary-known head at seq 10,
        // no local events yet — the first read caches "no override".
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 10, snippet: "from-server", createdAt: 0, lastTS: 1_000),
        ], headSeq: 0)
        XCTAssertEqual(try store.conversations().first?.snippet, "from-server")

        // Backfill lands a live-log tool_output as the newest message-type
        // event; `last_seq` is untouched, so only the insertHistory
        // invalidation makes the next read recompute.
        try store.insertHistory([event(9, type: JournalEventType.toolOutput,
                                       payload: ["live_log": true, "command": "make build"])])
        XCTAssertEqual(try store.conversations().first?.snippet, "$ make build",
                       "stale memo served after insertHistory changed the newest message")
    }

    func testSnippetTTLMemoInvalidatedByWipe() throws {
        let store = try makeStore()
        // Stale conversation whose newest message is an unexpired live_log
        // tool_output — the read caches the `$ command` override.
        try store.applyJournal(event(5, type: JournalEventType.toolOutput,
                                     payload: ["live_log": true, "command": "make build"]))
        XCTAssertEqual(try store.conversations().first?.snippet, "$ make build")

        // Wipe, then re-bootstrap the same conversation at the SAME
        // last_seq with no events: the memo key matches, so only the wipe
        // invalidation keeps the stale override from resurfacing.
        try store.wipe()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 5, snippet: "fresh", createdAt: 0, lastTS: 1_000),
        ], headSeq: 5)
        XCTAssertEqual(try store.conversations().first?.snippet, "fresh",
                       "stale memo override survived a mirror wipe")
    }

    func testEventsStreamSuppressesOtherConversationCommits() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1))

        var iterator = store.eventsStream(convoID: "c1", sinceSeq: 0).makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.seq), [1])

        // A frame landing in another conversation re-runs the fetch (the
        // convo_id filter observes the whole table) but must not deliver a
        // duplicate — the next delivered value has to be the c1 change.
        // Sleep so the two commits can't coalesce into one notification
        // (which would mask a dedup regression).
        try store.applyJournal(event(2, convo: "c2"))
        try await Task.sleep(for: .milliseconds(150))
        try store.applyJournal(event(3))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.map(\.seq), [1, 3],
                       "other-convo commit delivered a duplicate snapshot")
    }

    func testWipe() throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        try store.wipe()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertEqual(try store.conversations().count, 0)
    }

    func testNonMessageFramesDoNotBumpLastActivity() throws {
        // Opening a chat echoes a read_marker journal row with a fresh ts;
        // that must not stamp the conversation "active now" in the chat
        // list. Same for session_status / convo_meta bookkeeping frames.
        let store = try makeStore()
        try store.applyJournal(event(1))  // text at ts=1s
        let afterMessage = try XCTUnwrap(try store.conversations().first?.lastActivityTS)
        XCTAssertEqual(afterMessage, 1000)

        try store.applyJournal(event(2, sender: "user:dan", type: "read_marker",
                                     payload: ["convo_id": "c1", "up_to_seq": 1]))
        try store.applyJournal(event(3, type: "session_status", payload: ["state": "waiting"]))
        try store.applyJournal(event(4, type: "convo_meta", payload: ["title": "T"]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.lastActivityTS, 1000,
                       "bookkeeping frames must not fake message activity")
        XCTAssertEqual(convo.lastSeq, 4, "lastSeq still mirrors the server's per-frame bump")
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

    // MARK: Tool-output TTL sweep (protocol.md binding client rules)

    private func toolOutputPayload(snippet: String? = "output text",
                                   command: String = "make test",
                                   liveLog: Bool = true) -> [String: Any] {
        var p: [String: Any] = [
            "message_ref": "toolu_1", "command": command,
            "exit_code": 1, "denied": false, "truncated": false,
            "blob_ref": "blob-1",
        ]
        if liveLog { p["live_log"] = true }
        if let snippet { p["snippet"] = snippet }
        return p
    }

    private func storedPayload(_ store: JournalStore, seq: Int64) throws -> [String: Any] {
        let e = try XCTUnwrap(try store.events(convoID: "c1").first { $0.seq == seq })
        return e.payload
    }

    func testPurgeRewritesStaleLiveLogToTombstone() throws {
        let store = try makeStore()
        // The event helper stamps ts = seq seconds after epoch, so seq 1 is
        // ancient relative to any injected `now` past 1970-01-02.
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload()))
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))

        let payload = try storedPayload(store, seq: 1)
        XCTAssertNil(payload["snippet"])
        XCTAssertEqual(payload["expired"] as? Bool, true)
        XCTAssertTrue(payload["blob_ref"] is NSNull, "tombstone nulls the blob ref")
        XCTAssertEqual(payload["command"] as? String, "make test",
                       "what ran and how it exited survive the purge")
        XCTAssertEqual((payload["exit_code"] as? NSNumber)?.intValue, 1)
    }

    func testPurgeLeavesYoungAndNonLiveLogRows() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload(liveLog: false)))
        try store.applyJournal(event(2, type: "tool_output", payload: toolOutputPayload()))
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 2).addingTimeInterval(23 * 3600))
        XCTAssertNotNil(try storedPayload(store, seq: 2)["snippet"], "still inside the TTL")

        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 2).addingTimeInterval(48 * 3600))
        XCTAssertNotNil(try storedPayload(store, seq: 1)["snippet"],
                        "offloaded/legacy payloads without live_log keep their snippet")
        XCTAssertNil(try storedPayload(store, seq: 2)["snippet"])
    }

    func testPurgeRewritesConvoPreviewWhenPurgedEventIsNewest() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload()))
        // Read-time TTL is wall-clock relative to `now`; pin it inside the
        // window so this precondition reflects "before the sweep AND before
        // the TTL", not the real current date (the event helper stamps
        // seq 1 near the Unix epoch).
        XCTAssertEqual(try store.conversations(now: Date(timeIntervalSince1970: 1)).first?.snippet, "output text",
                       "precondition: the preview leaks the output before the sweep")
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        XCTAssertEqual(try store.conversations().first?.snippet, "$ make test")
    }

    func testPurgeKeepsConvoPreviewWhenNewerMessageExists() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload()))
        try store.applyJournal(event(2, payload: ["body": "later text"]))
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 2).addingTimeInterval(48 * 3600))
        XCTAssertEqual(try store.conversations().first?.snippet, "later text")
    }

    func testPurgeIsIdempotent() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload()))
        let now = Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: now)
        let first = try storedPayload(store, seq: 1)
        try store.purgeExpiredToolOutputSnippets(now: now)
        let second = try storedPayload(store, seq: 1)
        XCTAssertEqual(first.keys.sorted(), second.keys.sorted())
        XCTAssertEqual(second["expired"] as? Bool, true)
    }

    // MARK: Read-time snippet TTL (bugbot: stale list preview beyond 24h)

    func testConversationsAppliesTTLAtReadTimeWithoutPurge() throws {
        // No purge call in this test — the boot-time sweep only runs once,
        // at `JournalStore.init`. An app that stays open past the 24h
        // tool-output TTL must still stop surfacing the expired snippet
        // the next time the conversation list is *read*, not just the
        // next time the store happens to reopen.
        let store = try makeStore()
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload()))
        let fresh = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(1))
        XCTAssertEqual(fresh.first?.snippet, "output text", "precondition: still fresh")

        let stale = try store.conversations(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        XCTAssertEqual(stale.first?.snippet, "$ make test",
                       "read-time TTL must rewrite the preview to the tombstone form, matching the purge sweep")

        // The disk payload itself is untouched — only the sweep persists.
        XCTAssertNotNil(try storedPayload(store, seq: 1)["snippet"],
                        "read-time enforcement must not silently write the tombstone to disk")
    }

    func testConversationsReadTimeTTLLeavesNonLiveLogSnippetsAlone() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload(liveLog: false)))
        let stale = try store.conversations(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(48 * 3600))
        XCTAssertEqual(stale.first?.snippet, "output text",
                       "offloaded/legacy payloads without live_log must not be rewritten")
    }

    func testConversationsReadTimeTTLLeavesTextSnippetsAlone() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, payload: ["body": "hello world"]))
        let stale = try store.conversations(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(48 * 3600))
        XCTAssertEqual(stale.first?.snippet, "hello world",
                       "plain text snippets have no TTL and must render unchanged")
    }

    // MARK: Subagent sub-chats (parent_convo_id)

    func testChildConvoMetaSetsParentAndHidesFromList() throws {
        let store = try makeStore()
        // Parent conversation, plus a child created live via convo_meta
        // carrying parent_convo_id (even titleless, per the bridge contract).
        try store.applyJournal(event(1, convo: "p1", type: "convo_meta", payload: ["title": "Parent"]))
        try store.applyJournal(event(2, convo: "p1:sub:a1", type: "convo_meta",
                                     payload: ["title": "explore repo", "parent_convo_id": "p1"]))
        // The child never appears in the main chat list.
        let listed = try store.conversations()
        XCTAssertEqual(listed.map(\.id), ["p1"], "children are excluded from the chat list")

        // …but it's reachable as a child of its parent.
        let children = try store.children(of: "p1")
        XCTAssertEqual(children.map(\.id), ["p1:sub:a1"])
        XCTAssertEqual(children.first?.title, "explore repo")
        XCTAssertEqual(children.first?.parentConvoID, "p1")
        XCTAssertEqual(try store.parentConvoID(of: "p1:sub:a1"), "p1")
        XCTAssertNil(try store.parentConvoID(of: "p1"))
    }

    func testChildTitallessMetaStillLinksParent() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "p1:sub:a1", type: "convo_meta",
                                     payload: ["parent_convo_id": "p1"]))
        XCTAssertEqual(try store.parentConvoID(of: "p1:sub:a1"), "p1",
                       "a titleless convo_meta must still record the linkage")
        XCTAssertTrue(try store.conversations().isEmpty, "an unlinked-to-list child stays out of the list")
    }

    func testParentConvoIDIsImmutable() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "p1:sub:a1", type: "convo_meta",
                                     payload: ["title": "child", "parent_convo_id": "p1"]))
        // A later convo_meta WITHOUT parent_convo_id must not clear it.
        try store.applyJournal(event(2, convo: "p1:sub:a1", type: "convo_meta",
                                     payload: ["title": "child renamed"]))
        XCTAssertEqual(try store.parentConvoID(of: "p1:sub:a1"), "p1")
        // And a snapshot refresh that omits it (older server) must not clear it.
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "p1:sub:a1", title: "child", sessionState: "running",
                            lastSeq: 2, snippet: "", createdAt: 0),
        ])
        XCTAssertEqual(try store.parentConvoID(of: "p1:sub:a1"), "p1",
                       "a snapshot without parent_convo_id must not repoint/clear a known child")
    }

    func testSnapshotCarriesParentConvoID() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "p1", title: "Parent", sessionState: "running",
                            lastSeq: 5, snippet: "", createdAt: 0, parentConvoID: nil),
            ConvoSummaryDTO(id: "p1:sub:a1", title: "child", sessionState: "done",
                            lastSeq: 6, snippet: "", createdAt: 1, parentConvoID: "p1"),
        ], headSeq: 6)
        XCTAssertEqual(try store.conversations().map(\.id), ["p1"], "child filtered from cold snapshot list")
        let children = try store.children(of: "p1")
        XCTAssertEqual(children.map(\.id), ["p1:sub:a1"])
        XCTAssertEqual(children.first?.sessionState, "done")
    }

    func testChildrenIncludeRunningAndFinishedOrderedByCreation() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "p1:sub:b", title: "second", sessionState: "done",
                            lastSeq: 2, snippet: "", createdAt: 200, parentConvoID: "p1"),
            ConvoSummaryDTO(id: "p1:sub:a", title: "first", sessionState: "running",
                            lastSeq: 1, snippet: "", createdAt: 100, parentConvoID: "p1"),
        ], headSeq: 2)
        let children = try store.children(of: "p1")
        XCTAssertEqual(children.map(\.id), ["p1:sub:a", "p1:sub:b"], "ordered by created_at ascending")
        XCTAssertEqual(children.map(\.sessionState), ["running", "done"], "both states returned so callers can filter")
    }

    func testChildSessionStateTransitionsRunningToDone() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "p1:sub:a1", type: "convo_meta",
                                     payload: ["title": "child", "parent_convo_id": "p1"]))
        XCTAssertEqual(try store.children(of: "p1").first?.sessionState, "running")
        try store.applyJournal(event(2, convo: "p1:sub:a1", type: "session_status",
                                     payload: ["state": "done"]))
        XCTAssertEqual(try store.children(of: "p1").first?.sessionState, "done")
    }

    func testNestedChildrenRecurse() throws {
        let store = try makeStore()
        // A child that itself has a child — parent_convo_id is the child's id.
        try store.applyJournal(event(1, convo: "p1:sub:a", type: "convo_meta",
                                     payload: ["parent_convo_id": "p1"]))
        try store.applyJournal(event(2, convo: "p1:sub:a:sub:b", type: "convo_meta",
                                     payload: ["parent_convo_id": "p1:sub:a"]))
        XCTAssertEqual(try store.children(of: "p1").map(\.id), ["p1:sub:a"])
        XCTAssertEqual(try store.children(of: "p1:sub:a").map(\.id), ["p1:sub:a:sub:b"],
                       "a child's own children come back with no special casing")
        XCTAssertTrue(try store.conversations().isEmpty, "no nested child leaks into the list")
    }

    func testExistingRowsSurviveV2Migration() throws {
        // Migration test: a store opened, populated, closed, then reopened
        // on the same file keeps its rows and defaults parent_convo_id null.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try JournalStore(databaseURL: url, ownSender: "user:dan")
        try first.applyJournal(event(1, convo: "c1", payload: ["body": "survivor"]))

        // Reopen the same file — the migrator runs v2 additively.
        let second = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let convo = try XCTUnwrap(try second.conversations().first)
        XCTAssertEqual(convo.id, "c1")
        XCTAssertEqual(convo.snippet, "survivor", "existing row survives the additive column")
        XCTAssertNil(convo.parentConvoID, "the new column defaults NULL for pre-existing rows")
    }

    func testFileBackedStoreRunsInWALMode() throws {
        // Battery: the live sync path commits one transaction per journal
        // frame; rollback-journal mode paid a create+fsync+delete of the
        // `-journal` sidecar for each. WAL is set in prepareDatabase — the
        // `-wal` sidecar existing after a write proves the mode took.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        try store.applyJournal(event(1, convo: "c1", payload: ["body": "wal probe"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"),
                      "file-backed store must run in WAL journal mode")

        // Reopen: the persistent mode plus a fresh prepareDatabase must not
        // break an existing store.
        let reopened = try JournalStore(databaseURL: url, ownSender: "user:dan")
        XCTAssertEqual(try reopened.conversations().first?.snippet, "wal probe")
    }

    func testChildrenStreamYieldsOnChildCreationAndFinish() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "p1", type: "convo_meta", payload: ["title": "Parent"]))
        var iterator = store.childrenStream(of: "p1").makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        try store.applyJournal(event(2, convo: "p1:sub:a1", type: "convo_meta",
                                     payload: ["title": "child", "parent_convo_id": "p1"]))
        let afterCreate = await iterator.next()
        XCTAssertEqual(afterCreate?.map(\.id), ["p1:sub:a1"])
        XCTAssertEqual(afterCreate?.first?.sessionState, "running")
        try store.applyJournal(event(3, convo: "p1:sub:a1", type: "session_status",
                                     payload: ["state": "done"]))
        let afterFinish = await iterator.next()
        XCTAssertEqual(afterFinish?.first?.sessionState, "done")
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

    // MARK: Snippets

    /// The chat-list snippet must agree with the server's own `snippetOf`
    /// (matron-journal src/journal.js). It did not for the agent-chat consent
    /// card: that payload carries no `description`, so the generic branch
    /// produced a bare "permission: " — meaning the same event read one way
    /// when it arrived live and another when it came back in a snapshot.
    func testAgentChatCardSnippetMatchesTheServer() {
        XCTAssertEqual(
            JournalStore.snippet(type: "permission_request", payload: [
                "kind": "agent_chat", "request": "invite", "room_id": "r",
                "from_name": "dev-2",
            ]),
            "🤝 Agent chat request")
    }

    /// Same disagreement, same fix, for the spawn card — its payload carries
    /// no `description` either.
    func testAgentSpawnCardSnippetMatchesTheServer() {
        XCTAssertEqual(
            JournalStore.snippet(type: "permission_request", payload: [
                "kind": "agent_spawn", "request_id": "spawn-1",
                "task": "Rebase and push", "from_name": "dev-2",
            ]),
            "🤝 Agent spawn request")
    }

    /// A resolution has to retire the card's snippet, or the chat-list row
    /// keeps advertising a settled ask forever. Strings pinned to the
    /// server's own snippetOf (matron-journal src/journal.js).
    func testSpawnOutcomeSnippetsMatchTheServer() {
        let expected = [
            "started": "🚀 Spawned session started",
            "declined": "🚫 Spawn declined",
            "expired": "⌛ Spawn request expired",
            "failed": "❌ Spawn failed",
        ]
        for (outcome, line) in expected {
            XCTAssertEqual(
                JournalStore.snippet(type: "spawn_outcome",
                                     payload: ["request_id": "s", "outcome": outcome]),
                line)
        }
        XCTAssertEqual(
            JournalStore.snippet(type: "spawn_outcome",
                                 payload: ["request_id": "s", "outcome": "conscripted"]),
            "[spawn_outcome]",
            "an outcome this build doesn't know renders as the server's placeholder")
    }

    /// `spawn_outcome` joins the server's MESSAGE_TYPES — it sets the
    /// conversation snippet and bumps unread like the card it retires.
    func testSpawnOutcomeIsAMessageType() {
        XCTAssertTrue(JournalEventType.messageTypes.contains(JournalEventType.spawnOutcome))
    }

    func testOtherPermissionRequestsKeepTheDescriptionSnippet() {
        XCTAssertEqual(
            JournalStore.snippet(type: "permission_request",
                                 payload: ["description": "Allow writing to /etc?"]),
            "permission: Allow writing to /etc?")
    }

    // MARK: Summary TOC entries

    private func summaryEvent(_ seq: Int64, convo: String = "c1") -> JournalEvent {
        event(seq, convo: convo, type: "summary",
              payload: ["toc": "Did thing \(seq)", "detail": "Detail \(seq)", "model": "gpt-5.6-luna"])
    }

    func testSummaryEventPopulatesSummaryEntryTable() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(1))
        _ = try store.applyJournal(summaryEvent(2))
        let entries = try store.summaryEntries(convoID: "c1")
        XCTAssertEqual(entries.map(\.seq), [2])
        XCTAssertEqual(entries[0].toc, "Did thing 2")
        XCTAssertEqual(entries[0].detail, "Detail 2")
    }

    func testSummaryLandsViaBatchAndHistoryPaths() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([event(1), summaryEvent(2)])
        try store.insertHistory([summaryEvent(0)])                  // pagination backfill, older seq
        XCTAssertEqual(try store.summaryEntries(convoID: "c1").map(\.seq), [2, 0]) // newest first
    }

    func testSummaryDoesNotTouchSnippetOrUnread() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(1))                        // text, sets snippet
        let before = try store.conversations().first { $0.id == "c1" }
        _ = try store.applyJournal(summaryEvent(2))
        let after = try store.conversations().first { $0.id == "c1" }
        XCTAssertEqual(after?.snippet, before?.snippet)
        XCTAssertEqual(after?.unreadCount, before?.unreadCount)
    }

    func testWipeClearsSummaryEntries() throws {
        let store = try makeStore()
        _ = try store.applyJournal(summaryEvent(2))
        try store.wipe()
        XCTAssertEqual(try store.summaryEntries(convoID: "c1"), [])
    }

    // MARK: Summary backfill migration (v7)

    /// Builds a journal.sqlite frozen at the v6 schema — the last version
    /// before the v7 summary backfill — with `events` already in the event
    /// mirror, exactly the state of an install that synced its history
    /// before upgrading. Opening a `JournalStore` over the file then runs
    /// only v7. `seed` runs in the same transaction for extra pre-upgrade
    /// rows (e.g. summary entries the live path wrote after v4).
    private func seedPreBackfillDatabase(at url: URL, events: [JournalEvent],
                                         seed: (Database) throws -> Void = { _ in }) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try JournalStore.migrator().migrate(dbQueue, upTo: "v6")
        try dbQueue.write { db in
            for e in events {
                try db.execute(
                    sql: "INSERT INTO event(seq, convo_id, ts, sender, type, payload) VALUES(?, ?, ?, ?, ?, ?)",
                    arguments: [e.seq, e.convoID, Int64(e.ts.timeIntervalSince1970 * 1000),
                                e.sender, e.type, e.payloadData])
            }
            try seed(db)
        }
    }

    func testMigrationBackfillsSummaryEntriesFromStoredEvents() throws {
        // v4 created summary_entry but never scanned events already in the
        // mirror, so an upgrading install showed an empty TOC for every
        // conversation it had synced before the upgrade — until a
        // from-scratch re-sync happened to replay the summary events. v7
        // must fill the table from the stored events on open.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try seedPreBackfillDatabase(at: url, events: [
            event(1),                                                  // non-summary: ignored
            summaryEvent(2),
            summaryEvent(3, convo: "c2"),
            event(4, type: "summary", payload: ["detail": "no toc"]),  // undecodable: skipped, must not abort
        ])

        let upgraded = try JournalStore(databaseURL: url, ownSender: "user:dan")
        XCTAssertEqual(try upgraded.summaryEntries(convoID: "c1").map(\.seq), [2])
        XCTAssertEqual(try upgraded.summaryEntries(convoID: "c2").map(\.seq), [3])

        // A backfilled row must be indistinguishable from what the live
        // ingest path writes for the same event — same conversion, same
        // values.
        let live = try makeStore()
        _ = try live.applyJournal(summaryEvent(2))
        XCTAssertEqual(try upgraded.summaryEntries(convoID: "c1"),
                       try live.summaryEntries(convoID: "c1"))
    }

    func testMigrationBackfillLeavesLiveWrittenEntriesAlone() throws {
        // Installs running a post-v4 build already had the live path
        // writing summary_entry rows; v7 re-scans those same events and
        // must neither duplicate nor overwrite them (insert-or-ignore,
        // exactly like a replayed live frame).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try seedPreBackfillDatabase(at: url, events: [summaryEvent(2)]) { db in
            // Values deliberately differ from what a fresh conversion of
            // summaryEvent(2) would produce, so an overwrite would show.
            try db.execute(
                sql: "INSERT INTO summary_entry(convo_id, seq, toc, detail, created_at) VALUES(?, ?, ?, ?, ?)",
                arguments: ["c1", 2, "Live-written thing", "Live detail", 999])
        }

        let upgraded = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let entries = try upgraded.summaryEntries(convoID: "c1")
        XCTAssertEqual(entries.count, 1, "backfill must not duplicate an existing entry")
        XCTAssertEqual(entries.first?.toc, "Live-written thing",
                       "an entry the live path already wrote wins over the re-derived one")
    }

    func testSnapshotAndConvoMetaRecordTheOwningBox() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "Fix the parser", sessionState: "running",
                            lastSeq: 5, snippet: "", createdAt: 1, agentDeviceID: 7),
            ConvoSummaryDTO(id: "c2", title: "No box", sessionState: "running",
                            lastSeq: 6, snippet: "", createdAt: 1),
        ], headSeq: 6)

        XCTAssertEqual(try store.conversation(id: "c1")?.agentDeviceID, 7)
        XCTAssertNil(try store.conversation(id: "c2")?.agentDeviceID)

        // A later snapshot that omits the field must not clear what we know.
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "c1", title: "Fix the parser", sessionState: "running",
                            lastSeq: 7, snippet: "", createdAt: 1),
        ])
        XCTAssertEqual(try store.conversation(id: "c1")?.agentDeviceID, 7)

        // A live convo_meta teaches the linkage for a convo we have never seen.
        _ = try store.applyJournal(event(8, convo: "c3", type: "convo_meta",
                                         payload: ["title": "Brand new", "agent_device_id": 9]))
        XCTAssertEqual(try store.conversation(id: "c3")?.agentDeviceID, 9)

        // Re-pointing IS allowed: a session resumed on another box legitimately
        // changes owner, unlike parent_convo_id which is immutable.
        _ = try store.applyJournal(event(9, convo: "c3", type: "convo_meta",
                                         payload: ["title": "Brand new", "agent_device_id": 11]))
        XCTAssertEqual(try store.conversation(id: "c3")?.agentDeviceID, 11)
    }

    func testAgentRosterMirrorsSnapshotAndLiveRenames() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.agentNames().isEmpty)

        try store.replaceAgents([AgentDTO(id: 7, name: "dev-y"), AgentDTO(id: 9, name: "dev-z")])
        XCTAssertEqual(try store.agentNames(), [7: "dev-y", 9: "dev-z"])

        // Wholesale replace: a box revoked server-side disappears here too.
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-y")])
        XCTAssertEqual(try store.agentNames(), [7: "dev-y"])

        // An empty list is "this server doesn't say", not "you have no boxes".
        try store.replaceAgents([])
        XCTAssertEqual(try store.agentNames(), [7: "dev-y"])

        // A live rename patches one row without a re-snapshot.
        try store.applyDeviceMeta(id: 7, name: "dev-yellow", tagChar: nil)
        XCTAssertEqual(try store.agentNames(), [7: "dev-yellow"])

        // A rename for a box we have never seen inserts it.
        try store.applyDeviceMeta(id: 12, name: "dev-new", tagChar: nil)
        XCTAssertEqual(try store.agentNames()[12], "dev-new")
    }

    func testAgentTagCharsMirrorSnapshotAndLiveMeta() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a", tagChar: "a"),
                                 AgentDTO(id: 9, name: "dev-b")])
        // Only boxes WITH a tag appear — the map is the override layer, not
        // the roster.
        XCTAssertEqual(try store.agentTagChars(), [7: "a"])

        // A live device_meta sets, changes, and clears; a nil genuinely
        // means "no tag" because the server always sends full meta.
        try store.applyDeviceMeta(id: 9, name: "dev-b", tagChar: "b")
        XCTAssertEqual(try store.agentTagChars(), [7: "a", 9: "b"])
        try store.applyDeviceMeta(id: 7, name: "dev-a", tagChar: nil)
        XCTAssertEqual(try store.agentTagChars(), [9: "b"])
    }

    func testReplaceAgentsPreservesTagsWhenTheServerPredatesThem() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a"), AgentDTO(id: 9, name: "dev-b")])
        try store.seedAgentTagChars([7: "q"])
        // A journal predating tags sends no tag_char key at all
        // (`tagCharKnown == false`) — its wholesale replace must not wipe
        // the migration-seeded letter, or upgraded installs revert to
        // derived letters on the first snapshot after every launch.
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a", tagChar: nil, tagCharKnown: false),
                                 AgentDTO(id: 9, name: "dev-b", tagChar: nil, tagCharKnown: false)])
        XCTAssertEqual(try store.agentTagChars(), [7: "q"])

        // A tag-aware server's explicit nil IS authoritative: cleared.
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a", tagChar: nil)])
        XCTAssertEqual(try store.agentTagChars(), [:])
    }

    func testApplyDeviceMetaPreservesTagWhenTheFrameOmitsIt() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a"), AgentDTO(id: 9, name: "dev-b")])
        try store.seedAgentTagChars([7: "q", 9: "r"])

        // The live path needs the same key-presence rule the snapshot path
        // has: a server predating tags sends `device_meta` with NO `tag_char`
        // key, so its nil means "unknown", not "cleared". Overwriting here
        // let a plain RENAME wipe a migration-seeded letter that the
        // snapshot path had just been taught to protect.
        try store.applyDeviceMeta(id: 7, name: "dev-alpha", tagChar: nil, tagCharKnown: false)
        XCTAssertEqual(try store.agentTagChars()[7], "q")
        XCTAssertEqual(try store.agentNames()[7], "dev-alpha", "the name half still applies")

        // A tag-aware server IS authoritative in both directions: an explicit
        // null clears, and a value sets.
        try store.applyDeviceMeta(id: 9, name: "dev-b", tagChar: nil, tagCharKnown: true)
        XCTAssertNil(try store.agentTagChars()[9])
        try store.applyDeviceMeta(id: 7, name: "dev-alpha", tagChar: "z", tagCharKnown: true)
        XCTAssertEqual(try store.agentTagChars()[7], "z")

        // Insert half: a box this device never snapshotted has no tag to
        // keep, so an unknown-tag frame still creates the row (untagged).
        try store.applyDeviceMeta(id: 42, name: "dev-new", tagChar: nil, tagCharKnown: false)
        XCTAssertEqual(try store.agentNames()[42], "dev-new")
        XCTAssertNil(try store.agentTagChars()[42])
    }

    func testSeedAgentTagCharsFillsOnlyUntaggedKnownBoxes() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a", tagChar: "a"),
                                 AgentDTO(id: 9, name: "dev-b")])
        try store.seedAgentTagChars([7: "x", 9: "y", 42: "z"])
        // 7 keeps the journal-held tag (newer by construction), 9 takes the
        // seed, and 42 — a box the mirror doesn't know — must not become a
        // phantom row without a name.
        XCTAssertEqual(try store.agentTagChars(), [7: "a", 9: "y"])
        XCTAssertEqual(try store.agentNames().keys.sorted(), [7, 9])
    }

    func testAgentRosterStreamDeliversNamesAndTagsInLockstep() async throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-a", tagChar: "a")])
        var iterator = store.agentRosterStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.names, [7: "dev-a"])
        XCTAssertEqual(initial?.tagChars, [7: "a"])

        // One write, one re-fire, both maps current — a tag change must
        // never paint with a stale name set or vice versa.
        try store.applyDeviceMeta(id: 7, name: "dev-alpha", tagChar: "α")
        let updated = await iterator.next()
        XCTAssertEqual(updated?.names, [7: "dev-alpha"])
        XCTAssertEqual(updated?.tagChars, [7: "α"])
    }

    func testAgentNamesStreamRefiresOnRename() async throws {
        // The roster needs an observation of its own: GRDB only re-fires an
        // observation for the tables its fetch actually reads, and
        // `conversationsStream()` never reads `agent` — so a `device_meta`
        // rename has to reach chip labels through this stream instead.
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-y"), AgentDTO(id: 9, name: "dev-z")])
        var iterator = store.agentNamesStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [7: "dev-y", 9: "dev-z"])

        try store.applyDeviceMeta(id: 7, name: "dev-yellow", tagChar: nil)
        let renamed = await iterator.next()
        XCTAssertEqual(renamed, [7: "dev-yellow", 9: "dev-z"])
    }

    // MARK: Room participants (multi-agent room tags)

    func testParticipantsRoundTripAndAbsentNeverClears() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "room", title: "🔗 [ab] a ↔ b", sessionState: "waiting",
                            lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7,
                            participants: [7, 9]),
            ConvoSummaryDTO(id: "solo", title: "solo", sessionState: "running",
                            lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7),
        ], headSeq: 1)
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [7, 9])
        XCTAssertEqual(try store.conversation(id: "solo")?.participantIDs, [],
                       "no key on the wire decodes as no membership, not a crash")

        // A refresh that omits the key must not clear a stored membership —
        // a dissolved room's snapshot omits it, and the last-known tags are
        // still the right tags (same absent-never-clears discipline as
        // agent_device_id)…
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "room", title: "🔗 [ab] a ↔ b", sessionState: "done",
                            lastSeq: 1, snippet: "", createdAt: 1),
        ])
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [7, 9])

        // …while a present array replaces wholesale, growth and shrink alike.
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "room", title: "🔗 [ab] a ↔ b", sessionState: "waiting",
                            lastSeq: 1, snippet: "", createdAt: 1, participants: [7, 9, 12]),
        ])
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [7, 9, 12])
    }

    func testParticipantsLearnedLiveFromConvoMeta() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "room", type: "convo_meta", payload: ["title": "🔗 room"]))
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [])

        // The journal's membership fan is a participants-only convo_meta —
        // it must set the array without touching the title…
        try store.applyJournal(event(2, convo: "room", type: "convo_meta", payload: ["participants": [7, 9]]))
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [7, 9])
        XCTAssertEqual(try store.conversation(id: "room")?.title, "🔗 room")

        // …a later rename meta without the key leaves membership alone…
        try store.applyJournal(event(3, convo: "room", type: "convo_meta", payload: ["title": "renamed"]))
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [7, 9])

        // …and a departure shrinks it wholesale.
        try store.applyJournal(event(4, convo: "room", type: "convo_meta", payload: ["participants": [7]]))
        XCTAssertEqual(try store.conversation(id: "room")?.participantIDs, [7])
    }
}
