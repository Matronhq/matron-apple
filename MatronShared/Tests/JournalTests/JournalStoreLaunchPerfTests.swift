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
}
