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
}
