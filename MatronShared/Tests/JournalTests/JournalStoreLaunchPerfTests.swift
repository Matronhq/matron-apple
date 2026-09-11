import GRDB
import XCTest
@testable import MatronJournal

/// Launch-performance work (spec 2026-09-10): the v11 migration, the
/// write-path columns that replace the read path's event sub-queries, and
/// the watermarked background sweeps. Kept in its own file so the diff
/// against `JournalStoreTests` stays readable.
final class JournalStoreLaunchPerfTests: XCTestCase {
    func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    /// `ts` is `seq` seconds after the epoch, exactly like
    /// `JournalStoreTests.event` — so a test can make a row arbitrarily
    /// "old" relative to an injected `now` without wall-clock flake.
    func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
               type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// A temp-file database frozen at `v10` with raw rows hand-inserted —
    /// the only way to prove what v11 does to state that predates it.
    /// Mirrors `JournalStoreTests.seedPreBackfillDatabase`, which freezes at
    /// v6 for the v7 summary backfill.
    func seedPreV11Database(at url: URL, conversations: [String], events: [JournalEvent]) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try JournalStore.migrator().migrate(dbQueue, upTo: "v10")
        try dbQueue.write { db in
            for id in conversations {
                try db.execute(
                    sql: "INSERT INTO conversation(id, title, session_state, last_seq, snippet, created_at) VALUES(?, ?, 'running', 0, '', 0)",
                    arguments: [id, "T-\(id)"])
            }
            for e in events {
                try db.execute(
                    sql: "INSERT INTO event(seq, convo_id, ts, sender, type, payload) VALUES(?, ?, ?, ?, ?, ?)",
                    arguments: [e.seq, e.convoID, Int64(e.ts.timeIntervalSince1970 * 1000),
                                e.sender, e.type, e.payloadData])
            }
        }
    }

    func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("journal.sqlite")
    }

    // MARK: v11

    func testV11CreatesTheTypeTSIndex() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: [], events: [])
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let names: [String] = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list('event')").map { $0["name"] }
        }
        XCTAssertTrue(names.contains("event_type_ts"),
                      "the sweep's covering index is missing: \(names)")
        let columns: [String] = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_info('event_type_ts')").map { $0["name"] }
        }
        XCTAssertEqual(columns, ["type", "ts"], "column order decides whether the range scan works")
    }

    func testV11BackfillsLastMessageTypeAndExpiredSnippetFromStoredEvents() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: ["c1", "c2", "c3"], events: [
            // c1: newest message-type row is a live-log tool_output.
            event(1, convo: "c1", type: JournalEventType.text),
            event(2, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "make test", "live_log": true, "snippet": "out"]),
            // A non-message frame after it must not win the "last message" race.
            event(3, convo: "c1", type: JournalEventType.readMarker, payload: ["up_to_seq": 2]),
            // c2: newest message-type row is plain text.
            event(4, convo: "c2", type: JournalEventType.toolOutput,
                  payload: ["command": "ls", "live_log": true]),
            event(5, convo: "c2", type: JournalEventType.text, payload: ["body": "after"]),
            // c3: no message-type event at all.
            event(6, convo: "c3", type: JournalEventType.sessionStatus, payload: ["state": "idle"]),
        ])

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let rows = try store.dbQueue.read { db in
            try ConversationRecord.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(rows[0].lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(rows[0].expiredSnippet, "$ make test")
        XCTAssertEqual(rows[1].lastMessageType, JournalEventType.text)
        XCTAssertNil(rows[1].expiredSnippet, "only tool_output gets a command stub")
        XCTAssertNil(rows[2].lastMessageType, "no message-type event means no last message type")
        XCTAssertNil(rows[2].expiredSnippet)
    }

    /// A tool_output with no `live_log` and no `expired` flag keeps its real
    /// snippet forever (offloaded/legacy payloads — pinned by
    /// `JournalStoreTests.testPurgeLeavesYoungAndNonLiveLogRows`), so it
    /// must NOT get a command stub: the stub is what the read path
    /// substitutes, and substituting it here would start hiding snippets
    /// the TTL never applied to.
    func testV11LeavesExpiredSnippetNilForNonLiveLogToolOutput() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: ["c1"], events: [
            event(1, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "legacy", "snippet": "kept"]),
        ])
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertNil(row.expiredSnippet)
    }

    /// A server-tombstoned row (`expired: true`, snippet already gone) is
    /// exactly the case the column exists for: the list has nothing but the
    /// command to show.
    func testV11BackfillsExpiredSnippetForAlreadyTombstonedToolOutput() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: ["c1"], events: [
            event(1, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "make build", "expired": true]),
        ])
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.expiredSnippet, "$ make build")
    }

    // MARK: Write path keeps the columns current

    func testApplyOneMaintainsLastMessageColumns() throws {
        let store = try makeStore()
        let fresh = Date(timeIntervalSince1970: 10)
        try store.applyJournal(event(1, type: JournalEventType.text), now: fresh)
        var row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.text)
        XCTAssertNil(row.expiredSnippet)

        try store.applyJournal(event(2, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: fresh)
        row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(row.expiredSnippet, "$ make test")
        XCTAssertEqual(row.snippet, "out", "the live preview is still the real output while it is fresh")

        // A bookkeeping frame is not a message: the columns must not move.
        try store.applyJournal(event(3, sender: "user:dan", type: JournalEventType.readMarker,
                                     payload: ["up_to_seq": 2]), now: fresh)
        row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(row.expiredSnippet, "$ make test")
    }

    /// The insert-time half of the watermark contract: a row that is already
    /// past a cutoff when it lands is stored tombstoned, so the sweeps can
    /// skip everything below their watermark and still be right.
    func testApplyOneTombstonesAnAlreadyStaleToolOutputAtInsert() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true,
                                               "snippet": "out", "blob_ref": "b1"]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first)
        XCTAssertNil(stored.payload["snippet"], "a stale live log must land already tombstoned")
        XCTAssertEqual(stored.payload["expired"] as? Bool, true)
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.expiredSnippet, "$ make test")
    }

    /// Fix round 1, M1: `Self.snippet(type:payload:)` has no `tool_output`
    /// case, so once the row lands already-tombstoned (payload's `snippet`
    /// key stripped) it falls to the generic default and reads the now-nil
    /// `payload["snippet"]`, producing the literal placeholder `"[tool_
    /// output]"` in `conversation.snippet` on disk. Reads the row directly
    /// off the DB (not through `conversations(now:)`), because the read-time
    /// TTL override would mask the bug — `applyReadTimeSnippetTTL` always
    /// fires for a row whose `lastActivityTS` is already past the cutoff, so
    /// the garbage would never actually render, only sit on disk waiting for
    /// a future reader that doesn't go through the read path.
    func testApplyOneStoresCommandStubNotPlaceholderForAlreadyStaleToolOutput() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.snippet, "$ make test",
                       "an already-stale tool_output must store the command stub, not the [tool_output] placeholder")
    }

    /// Reviewer nit carried from Task 2 (`EventTombstone` R2): an ALREADY
    /// absent `blob_ref` must stay absent through insert-time tombstoning,
    /// not gain a `null` entry it never had. `EventTombstone.rewrite` only
    /// nulls the key when it is present; this pins that the insert path
    /// (not just the pure function) preserves that distinction.
    func testApplyOneLeavesAbsentBlobRefAbsentAtInsert() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first)
        XCTAssertNil(stored.payload["snippet"])
        XCTAssertEqual(stored.payload["expired"] as? Bool, true)
        XCTAssertNil(stored.payload["blob_ref"], "no blob_ref key was ever present; tombstoning must not add one")
        XCTAssertFalse(stored.payload.keys.contains("blob_ref"),
                       "an absent key must stay absent, not become an explicit null")
    }

    func testApplyOneTombstonesAPastRetentionDiffAtInsert() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.diff,
                                     payload: ["file_path": "/w/A.swift", "diff": "+ a", "added": 1]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600))
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first)
        XCTAssertNil(stored.payload["diff"])
        XCTAssertEqual(stored.payload["expired"] as? Bool, true)
        XCTAssertEqual(stored.payload["file_path"] as? String, "/w/A.swift")
    }

    func testInsertHistoryRecomputesTheColumnsAndTombstones() throws {
        let store = try makeStore()
        let fresh = Date(timeIntervalSince1970: 10)
        try store.applyJournal(event(5, type: JournalEventType.text, payload: ["body": "newest"]), now: fresh)

        // Backfill lands OLDER rows: `last_seq` does not move, so the columns
        // can only stay right if insertHistory recomputes them.
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "live_log": true, "snippet": "out"]),
        ], now: fresh)
        var row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.text, "seq 5 is still the newest message")
        XCTAssertNil(row.expiredSnippet)

        // Now a backfilled row that IS the newest message-type row, and old
        // enough to arrive tombstoned.
        try store.insertHistory([
            event(6, type: JournalEventType.toolOutput,
                  payload: ["command": "backfilled", "live_log": true, "snippet": "out"]),
        ], now: Date(timeIntervalSince1970: 6).addingTimeInterval(25 * 3600))
        row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(row.expiredSnippet, "$ backfilled")
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first { $0.seq == 6 })
        XCTAssertNil(stored.payload["snippet"])
    }

    // MARK: Read path is columns only

    /// The pin that matters: delete every `event` row, then read the list.
    /// If the TTL still needed a sub-query the override would vanish.
    func testReadTimeTTLDerivesFromColumnsWithoutReadingEvents() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 2))
        try store.dbQueue.write { db in try db.execute(sql: "DELETE FROM event") }

        let fresh = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(60))
        XCTAssertEqual(fresh.first?.snippet, "out", "inside the TTL the real output still shows")
        let stale = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        XCTAssertEqual(stale.first?.snippet, "$ make test",
                       "the TTL override must come from the columns, not from an event sub-query")
    }

    func testReadTimeTTLIgnoresConversationsWhoseNewestMessageIsNotToolOutput() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.text, payload: ["body": "hello"]),
                               now: Date(timeIntervalSince1970: 2))
        let stale = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(48 * 3600))
        XCTAssertEqual(stale.first?.snippet, "hello")
    }

    /// The chat-list observation used to re-run its whole fetch on every
    /// applied frame because the TTL sub-queries read `event`. Rewriting an
    /// `event` payload in a way that WOULD have changed the old derived
    /// snippet must now deliver nothing; the following `conversation` write
    /// proves the stream is still alive rather than merely quiet.
    func testConversationsStreamNoLongerTracksTheEventTable() async throws {
        let store = try makeStore()
        // Newest message is a tool_output with NO live_log: `expired_snippet`
        // is nil, so the list shows the real snippet under the new rules —
        // while the old read path would have started substituting
        // "$ make test" the moment `live_log` appeared in the payload.
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 2))

        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.first?.snippet, "out")

        // `await`ed: GRDB's sync `write` overload is `@_disfavoredOverload`
        // (SR-15150), so inside this `async throws` test the async overload
        // wins resolution and must be awaited — same queue, same semantics.
        try await store.dbQueue.write { db in
            let payload = try JSONSerialization.data(withJSONObject: [
                "command": "make test", "snippet": "out", "live_log": true,
            ] as [String: Any])
            try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = 1", arguments: [payload])
        }
        // Sleep so the two commits cannot coalesce into one notification,
        // which would mask a regression (same guard as
        // `testEventsStreamSuppressesOtherConversationCommits`).
        try await Task.sleep(for: .milliseconds(150))
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET title = 'renamed' WHERE id = 'c1'")
        }

        let next = await iterator.next()
        XCTAssertEqual(next?.first?.title, "renamed",
                       "the event-payload write delivered a value — the list fetch still reads `event`")
    }
}
