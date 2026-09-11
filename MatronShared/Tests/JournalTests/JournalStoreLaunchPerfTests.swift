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
               type: String = "text", payload: [String: Any] = ["body": "hi"],
               ts: Date? = nil) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: ts ?? Date(timeIntervalSince1970: Double(seq)),
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
        // `ts` deliberately recent (not the usual epoch-relative seconds):
        // this test is pinning the v11 BACKFILL's behaviour in isolation,
        // and `JournalStore.init`'s boot-time sweep runs at the real wall
        // clock right after the backfill. An epoch-1970 `ts` would also be
        // >30 days stale by that real clock, so the boot sweep's accepted,
        // documented over-enforcement (R17: the boot-time 24h sweep also
        // performs 30-day retention until Task 6 reorders it) would rewrite
        // this row a second time and mask what the backfill alone produced.
        try seedPreV11Database(at: url, conversations: ["c1"], events: [
            event(1, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "legacy", "snippet": "kept"],
                  ts: Date().addingTimeInterval(-3600)),
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

    /// Fix round 2 (Bugbot PR #212): `convo.snippet` is derived from the
    /// ORIGINAL wire payload, not the stored (possibly tombstoned) one — an
    /// arrival past its cutoff behaves exactly like a row that expires
    /// LATER, in place, where the purge no longer rewrites `snippet`
    /// (Step 6) and `applyReadTimeSnippetTTL` is what hides it at read time.
    /// Reads the row directly off the DB (not through `conversations(now:)`)
    /// so the read-time override can't mask a regression here. `expired_
    /// snippet` still comes from the stored payload — it's what the
    /// read-time TTL substitutes IN.
    func testApplyOneStoresOriginalSnippetForAlreadyStaleToolOutput() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.snippet, "out",
                       "conversation.snippet keeps the ORIGINAL output — in-place-expiry parity")
        XCTAssertEqual(row.expiredSnippet, "$ make test", "the stub still lands in expired_snippet")
    }

    /// Bugbot (PR #212), the case round 1 missed: `diff` is also in
    /// `messageTypes`, and `Self.snippet` has no `diff` case either — but
    /// `diff` has NO read-time override at all (`applyReadTimeSnippetTTL`
    /// is `tool_output`-only), so a round-1-style fix that read `convo.
    /// snippet` from the STORED (tombstoned) payload would show `"[diff]"`
    /// forever, not just transiently. Deriving from the original payload
    /// fixes this the same way as the tool_output case.
    func testApplyOneStoresOriginalSnippetForAlreadyPastRetentionDiff() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.diff,
                                     payload: ["file_path": "/w/A.swift", "diff": "+ a", "snippet": "A.swift +1"]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600))
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.snippet, "A.swift +1", "a diff keeps its original preview, never the [diff] placeholder")

        let stored = try XCTUnwrap(try store.events(convoID: "c1").first)
        XCTAssertNil(stored.payload["diff"])
        XCTAssertNil(stored.payload["snippet"])
        XCTAssertEqual(stored.payload["expired"] as? Bool, true)
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

    // MARK: Watermarked sweeps

    private func rawPayload(_ store: JournalStore, seq: Int64) throws -> [String: Any] {
        let data: Data = try XCTUnwrap(try store.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM event WHERE seq = ?", arguments: [seq])
        })
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    private func watermark(_ store: JournalStore, key: String) throws -> Int64? {
        try store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func testPurgeRecordsItsWatermarkAndTheSecondSweepSkipsThatRange() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 1)
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true,
                                               "snippet": "out", "blob_ref": "b1"]),
                               now: insertAt)
        let sweepAt = Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: sweepAt)
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"])
        XCTAssertEqual(try watermark(store, key: "snippet_ttl_ts"),
                       Int64(sweepAt.timeIntervalSince1970 * 1000) - Int64(24 * 3600 * 1000))

        // Put an un-tombstoned payload back under the watermark by hand. A
        // second sweep must not see it — that is what "incremental" means,
        // and the insert paths are what guarantee no real row can be there.
        try store.dbQueue.write { db in
            let payload = try JSONSerialization.data(withJSONObject: [
                "command": "make test", "live_log": true, "snippet": "back",
            ] as [String: Any])
            try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = 1", arguments: [payload])
        }
        try store.purgeExpiredToolOutputSnippets(now: sweepAt.addingTimeInterval(60))
        XCTAssertEqual(try rawPayload(store, seq: 1)["snippet"] as? String, "back",
                       "the second sweep rescanned a range its watermark had already covered")
    }

    /// The other half of the watermark contract: a row older than the
    /// watermark that lands AFTER it arrives tombstoned (Task 3), so
    /// skipping the range is safe.
    func testAnOldRowInsertedAfterTheWatermarkArrivesTombstoned() throws {
        let store = try makeStore()
        let sweepAt = Date(timeIntervalSince1970: 100).addingTimeInterval(25 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: sweepAt)

        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "ancient", "live_log": true, "snippet": "out"]),
        ], now: sweepAt.addingTimeInterval(60))
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"],
                     "a below-watermark row must arrive already tombstoned")
        XCTAssertEqual(try rawPayload(store, seq: 1)["expired"] as? Bool, true)
    }

    func testSweepCoversMoreRowsThanOneChunk() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 1)
        // 1200 rows = three chunks of 500 (the last partial), so a
        // single-chunk implementation leaves 700 rows un-tombstoned.
        let events = (1...1200).map { seq in
            event(Int64(seq), type: JournalEventType.toolOutput,
                  payload: ["command": "c\(seq)", "live_log": true, "snippet": "out"])
        }
        try store.insertHistory(events, now: insertAt)
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 1200).addingTimeInterval(25 * 3600))
        // Decode every payload rather than `LIKE '%snippet%'` over a BLOB
        // column: that relies on SQLite's implicit BLOB→TEXT coercion and
        // would also match a row whose COMMAND happened to contain the word.
        let stillCarryingABody = try store.events(convoID: "c1")
            .filter { $0.payload["snippet"] != nil }
            .map(\.seq)
        XCTAssertEqual(stillCarryingABody, [], "the sweep stopped after the first chunk")
    }

    func testApplyRetentionReturnsTheSeqsItTombstoned() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 3)
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "snippet": "out", "exit_code": 0]),
            event(2, type: JournalEventType.diff, payload: ["file_path": "/w/A.swift", "diff": "+ a"]),
            event(3, type: JournalEventType.text, payload: ["body": "kept forever"]),
        ], now: insertAt)

        let seqs = try store.applyRetention(
            now: Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600))
        XCTAssertEqual(seqs.sorted(), [1, 2], "text rows are never retention-tombstoned")
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"])
        XCTAssertNil(try rawPayload(store, seq: 2)["diff"])
        XCTAssertEqual(try rawPayload(store, seq: 2)["file_path"] as? String, "/w/A.swift")
        XCTAssertEqual(try rawPayload(store, seq: 3)["body"] as? String, "kept forever")

        XCTAssertEqual(try store.applyRetention(
            now: Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600 + 60)), [],
            "a second retention sweep over the same range must tombstone nothing")
    }

    /// `JournalMaintenance.stop()` (Task 6, R11) must be able to await an
    /// in-flight sweep rather than only ever waiting one out — that means
    /// the inter-chunk loop has to notice cancellation and stop without
    /// advancing the watermark, so the next pass resumes from scratch on
    /// the same, still-unswept range.
    func testApplyRetentionStopsAtTheNextChunkBoundaryWhenCancelled() async throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 1)
        // 1200 rows = three chunks of 500, so a cancellation that only took
        // effect after the whole sweep would still tombstone everything.
        let events = (1...1200).map { seq in
            event(Int64(seq), type: JournalEventType.toolOutput,
                  payload: ["command": "c\(seq)", "live_log": true, "snippet": "out"])
        }
        try store.insertHistory(events, now: insertAt)
        let sweepAt = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)

        let handle = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.applyRetention(now: sweepAt)
        }
        let seqs = try await handle.value
        XCTAssertEqual(seqs, [], "a sweep cancelled before its first chunk must tombstone nothing")
        XCTAssertEqual(try rawPayload(store, seq: 1)["snippet"] as? String, "out",
                       "a cancelled sweep must leave every row untouched")
        XCTAssertNil(try watermark(store, key: "retention_ts"),
                     "a cancelled sweep must not advance the watermark")

        // An uncancelled pass over the same, still-fully-unswept range must
        // still sweep everything — cancellation must not leave a gap.
        let resumed = try store.applyRetention(now: sweepAt)
        XCTAssertEqual(resumed.count, 1200)
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"])
        XCTAssertNotNil(try watermark(store, key: "retention_ts"))
    }

    /// Bugbot (PR #212, "Retention omits already-purged seqs"): a row the
    /// 24h TTL sweep already tombstoned — no `snippet`, no `live_log`,
    /// `expired: true`, a short command — is a no-op for the 30-day rule,
    /// so `EventTombstone.apply` returns `nil` for it and it never appears
    /// in a rewrite-only list. But the watermark guarantees this seq is
    /// visited exactly once, ever, by `applyRetention` — if its seq isn't
    /// reported here, nothing ever tells `JournalMaintenance` to drop the
    /// search row that was indexed while this row was still fresh.
    func testApplyRetentionReturnsEveryVisitedSeqNotJustRewrittenOnes() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 10)
        try store.insertHistory([
            // Already in tombstone shape — EventTombstone.apply is a no-op.
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "already gone", "expired": true, "exit_code": 1]),
            // Fresh-shape tool_output — retention rewrites it.
            event(2, type: JournalEventType.toolOutput,
                  payload: ["command": "still here", "snippet": "out", "live_log": true]),
            // Fresh-shape diff — retention rewrites it.
            event(3, type: JournalEventType.diff, payload: ["file_path": "/w/A.swift", "diff": "+ a"]),
        ], now: insertAt)

        let before: Data = try XCTUnwrap(try store.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM event WHERE seq = 1")
        })

        let seqs = try store.applyRetention(now: insertAt.addingTimeInterval(40 * 24 * 3600))
        XCTAssertEqual(seqs.sorted(), [1, 2, 3],
                       "the already-tombstoned row must still be reported: its search row is stale")

        let after: Data = try XCTUnwrap(try store.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM event WHERE seq = 1")
        })
        XCTAssertEqual(before, after, "a no-op row must be reported, not rewritten")

        XCTAssertNil(try rawPayload(store, seq: 2)["snippet"])
        XCTAssertNil(try rawPayload(store, seq: 3)["diff"])
    }

    /// A tool_output that was never a live log has no `expired_snippet` at
    /// insert time; once retention tombstones it, the list has nothing but
    /// the command to show, so the sweep refreshes the columns of the
    /// conversations it touched.
    func testRetentionRefreshesTheConversationColumns() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "legacy", "snippet": "durable"]),
                               now: Date(timeIntervalSince1970: 2))
        XCTAssertNil(try XCTUnwrap(try store.dbQueue.read {
            try ConversationRecord.fetchOne($0, key: "c1")
        }).expiredSnippet)

        _ = try store.applyRetention(now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600))
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.expiredSnippet, "$ legacy")
        XCTAssertEqual(try store.conversations(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)).first?.snippet,
            "$ legacy")
    }

    func testWipeResetsAllThreeWatermarksAndTheMaintenanceStamp() throws {
        let store = try makeStore()
        let sweepAt = Date(timeIntervalSince1970: 100).addingTimeInterval(31 * 24 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: sweepAt)
        _ = try store.applyRetention(now: sweepAt)
        try store.recordSearchRetirement(upTo: sweepAt)
        try store.recordMaintenanceRun(at: sweepAt)
        XCTAssertNotNil(try watermark(store, key: "snippet_ttl_ts"))
        XCTAssertNotNil(try watermark(store, key: "retention_ts"))
        XCTAssertNotNil(try watermark(store, key: "search_retention_ts"))
        XCTAssertNotNil(try store.maintenanceLastRun())

        try store.wipe()
        XCTAssertNil(try watermark(store, key: "snippet_ttl_ts"))
        XCTAssertNil(try watermark(store, key: "retention_ts"))
        XCTAssertNil(try watermark(store, key: "search_retention_ts"))
        XCTAssertNil(try store.maintenanceLastRun())
    }

    // MARK: pendingSearchRetirements / recordSearchRetirement (Bugbot round 2, PR #212)

    /// Same shape and cutoff as `applyRetention`, but over its OWN
    /// watermark — the basic scan.
    func testPendingSearchRetirementsFindsToolOutputAndDiffSeqsPastTheWindow() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 3)
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "snippet": "out", "exit_code": 0]),
            event(2, type: JournalEventType.diff, payload: ["file_path": "/w/A.swift", "diff": "+ a"]),
            event(3, type: JournalEventType.text, payload: ["body": "kept forever"]),
        ], now: insertAt)

        let now = Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600)
        let pending = try store.pendingSearchRetirements(now: now)
        XCTAssertEqual(pending.seqs.sorted(), [1, 2], "text rows are never retention-tombstoned")
        XCTAssertEqual(pending.cutoff, now.addingTimeInterval(-EventTombstone.retentionWindow),
                       "an uninterrupted scan's cutoff is the full retention cutoff")
    }

    /// The bug this round fixes: `applyRetention` tombstoning a row (which
    /// advances `retention_ts`) must NOT be mistaken for search coverage —
    /// the two watermarks are independent, so the pending scan still finds
    /// the row.
    func testPendingSearchRetirementsIsIndependentOfTheRetentionWatermark() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 3)
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "snippet": "out", "exit_code": 0]),
        ], now: insertAt)
        let now = Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600)

        _ = try store.applyRetention(now: now)
        XCTAssertNotNil(try watermark(store, key: "retention_ts"), "precondition: retention already ran")

        let pending = try store.pendingSearchRetirements(now: now)
        XCTAssertEqual(pending.seqs, [1],
                       "the retention watermark advancing must not hide this seq from search retirement")
    }

    func testRecordSearchRetirementAdvancesItsWatermarkSoASecondCallSeesNothingPending() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 3)
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "snippet": "out", "exit_code": 0]),
        ], now: insertAt)
        let now = Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600)

        let first = try store.pendingSearchRetirements(now: now)
        XCTAssertEqual(first.seqs, [1])
        try store.recordSearchRetirement(upTo: first.cutoff)

        let second = try store.pendingSearchRetirements(now: now.addingTimeInterval(60))
        XCTAssertEqual(second.seqs, [], "a second call after recording must see nothing pending")
    }

    /// Same cancellation contract as `applyRetention`: a scan cancelled
    /// before its first chunk boundary must report no seqs, and its
    /// `cutoff` must reflect only what was actually scanned — never the
    /// full retention cutoff, or a caller recording it would claim coverage
    /// it doesn't have.
    func testPendingSearchRetirementsStopsAtTheNextChunkBoundaryWhenCancelled() async throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 1)
        let events = (1...1200).map { seq in
            event(Int64(seq), type: JournalEventType.toolOutput,
                  payload: ["command": "c\(seq)", "live_log": true, "snippet": "out"])
        }
        try store.insertHistory(events, now: insertAt)
        let now = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)

        let handle = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.pendingSearchRetirements(now: now)
        }
        let pending = try await handle.value
        XCTAssertEqual(pending.seqs, [], "a scan cancelled before its first chunk must find nothing")
        XCTAssertLessThan(pending.cutoff, now.addingTimeInterval(-EventTombstone.retentionWindow),
                          "a cancelled scan's cutoff must not claim the full retention cutoff")

        // An uncancelled pass over the same, still-fully-unscanned range
        // must still find everything — cancellation must not leave a gap.
        let resumed = try store.pendingSearchRetirements(now: now)
        XCTAssertEqual(resumed.seqs.count, 1200)
    }

    func testMaintenanceLastRunRoundTripsToTheSecond() throws {
        let store = try makeStore()
        XCTAssertNil(try store.maintenanceLastRun())
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordMaintenanceRun(at: at)
        XCTAssertEqual(try store.maintenanceLastRun(), at)
    }
}
