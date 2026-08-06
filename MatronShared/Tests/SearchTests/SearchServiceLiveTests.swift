import XCTest
import GRDB
@testable import MatronSearch

final class SearchServiceLiveTests: XCTestCase {
    var url: URL!
    var svc: SearchServiceLive!

    override func setUp() async throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("svc-\(UUID().uuidString).sqlite")
        svc = try SearchServiceLive(databaseURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    func test_indexAndQuery_roundTrip_preservesAllFields() async throws {
        let ts = Date(timeIntervalSince1970: 1_745_000_000)
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: ts, body: "the auth bug is in src/auth.rs")
        let hits = try await svc.query("auth bug", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, "$1")
        XCTAssertEqual(hits[0].roomID, "!r:s")
        XCTAssertEqual(hits[0].sender, "@a:s")
        XCTAssertEqual(hits[0].timestamp.timeIntervalSince1970, ts.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertTrue(hits[0].snippet.contains("<mark>auth"))
    }

    func test_indexIsIdempotent_replaceUpdatesBody() async throws {
        // Re-indexing the same eventID must replace the old row in BOTH messages and
        // messages_fts. This guards against the FTS5 UNINDEXED-DELETE silent no-op.
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "first")
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "second")
        let hits = try await svc.query("first", limit: 10)
        XCTAssertEqual(hits.count, 0, "old body must not remain in FTS after re-index")
        let hits2 = try await svc.query("second", limit: 10)
        XCTAssertEqual(hits2.count, 1)
    }

    /// FTS5's external-content integrity check (`rank = 1` verifies the index
    /// against the content table). Throws SQLITE_CORRUPT when the two diverge —
    /// e.g. ghost entries left by a REPLACE that deleted a content row without
    /// firing the delete trigger.
    private func assertFTSIntegrity(file: StaticString = #filePath, line: UInt = #line) throws {
        let queue = try DatabaseQueue(path: url.path)
        XCTAssertNoThrow(
            try queue.write { db in
                try db.execute(sql: "INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)")
            },
            "messages_fts diverged from its content table",
            file: file, line: line
        )
    }

    func test_reindex_keepsFTSIntegrity() async throws {
        // The backfill re-indexes events the live feeder already indexed, so the
        // duplicate-event path runs constantly. INSERT OR REPLACE broke it: REPLACE
        // deletes the conflicting row WITHOUT firing the AFTER DELETE trigger
        // (recursive_triggers is off), leaving ghost FTS entries for dead rowids —
        // 2026-08-06 live corruption on Dan's Mac store.
        let ts = Date(timeIntervalSince1970: 1_745_000_000)
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: ts, body: "same body")
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: ts, body: "same body")
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: ts, body: "changed body")
        try assertFTSIntegrity()
        let hits = try await svc.query("body", limit: 10)
        XCTAssertEqual(hits.count, 1, "one event must yield exactly one hit after re-indexing")
        XCTAssertTrue(hits[0].snippet.contains("changed"))
    }

    func test_migration_rebuildsGhostEntriesFromOlderStores() async throws {
        // Stores written before the UPSERT fix contain ghost FTS entries. The v2
        // migration's `rebuild` must repair them on open. Recreate the damage
        // against a v1-only store, then let a full open migrate + repair it.
        let corruptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        do {
            let queue = try DatabaseQueue(path: corruptURL.path)
            var migrator = DatabaseMigrator()
            SearchSchema.migrate(&migrator)
            try migrator.migrate(queue, upTo: "v1: messages + messages_fts + indexed_rooms")
            try queue.inDatabase { db in
                // The old index() SQL: REPLACE on a duplicate event_id orphans
                // the first row's FTS entry.
                for _ in 0..<2 {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO messages(room_id, event_id, sender, timestamp, body)
                        VALUES ('!r:s', '$1', '@a:s', 0, 'ghost maker')
                    """)
                }
                XCTAssertThrowsError(
                    try db.execute(sql: "INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)"),
                    "REPLACE should have corrupted the FTS index — if not, this test is stale"
                )
            }
        }

        let repaired = try SearchServiceLive(databaseURL: corruptURL)
        let queue = try DatabaseQueue(path: corruptURL.path)
        try queue.inDatabase { db in
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)")
        }
        let hits = try await repaired.query("ghost", limit: 10)
        XCTAssertEqual(hits.count, 1)
    }

    func test_indexBatch_singleTransaction_matchesPerRowIndexing() async throws {
        // The engine's catch-up path indexes whole replay batches through
        // this override (one write transaction). Same idempotence and FTS
        // integrity as per-row index() — including re-batching rows the
        // live feeder already indexed.
        let ts = Date(timeIntervalSince1970: 1_745_000_000)
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: ts, body: "already live-indexed")
        try await svc.indexBatch([
            SearchIndexEntry(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: ts, body: "already live-indexed"),
            SearchIndexEntry(roomID: "!r:s", eventID: "$2", sender: "@a:s", timestamp: ts, body: "batch row two"),
            SearchIndexEntry(roomID: "!r:s", eventID: "$3", sender: "@b:s", timestamp: ts, body: "batch row three"),
        ])
        try assertFTSIntegrity()
        let count = try await svc.eventCount(roomID: "!r:s")
        XCTAssertEqual(count, 3)
        let hits = try await svc.query("batch row", limit: 10)
        XCTAssertEqual(hits.count, 2)
        // Changed body via batch must replace, not duplicate (UPSERT path).
        try await svc.indexBatch([
            SearchIndexEntry(roomID: "!r:s", eventID: "$2", sender: "@a:s", timestamp: ts, body: "rewritten"),
        ])
        try assertFTSIntegrity()
        let oldBody = try await svc.query("two", limit: 10)
        XCTAssertEqual(oldBody.count, 0, "old body must leave FTS")
        let newBody = try await svc.query("rewritten", limit: 10)
        XCTAssertEqual(newBody.count, 1)
    }

    func test_indexBatch_empty_isNoOp() async throws {
        try await svc.indexBatch([])
        let count = try await svc.eventCount(roomID: "!r:s")
        XCTAssertEqual(count, 0)
    }

    func test_remove_clearsFTSRow() async throws {
        // Redaction path: `remove(eventID:)` must purge both messages and messages_fts.
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "secret payload")
        try await svc.remove(eventID: "$1")
        let hits = try await svc.query("secret", limit: 10)
        XCTAssertEqual(hits.count, 0, "redacted event must no longer match in FTS")
        let exists = try await svc.contains(eventID: "$1")
        XCTAssertFalse(exists)
    }

    func test_eventCount_perRoom() async throws {
        try await svc.index(roomID: "!a:s", eventID: "$1", sender: "@x:s", timestamp: Date(), body: "one")
        try await svc.index(roomID: "!a:s", eventID: "$2", sender: "@x:s", timestamp: Date(), body: "two")
        try await svc.index(roomID: "!b:s", eventID: "$3", sender: "@x:s", timestamp: Date(), body: "three")
        let a = try await svc.eventCount(roomID: "!a:s")
        let b = try await svc.eventCount(roomID: "!b:s")
        XCTAssertEqual(a, 2)
        XCTAssertEqual(b, 1)
    }

    func test_recordAndReadBackfill() async throws {
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 100, oldestEventID: "$old", complete: true)
        let done = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertTrue(done)
    }

    func test_backfillOldestEventID_roundTrips() async throws {
        let before = try await svc.backfillOldestEventID(roomID: "!r:s")
        XCTAssertNil(before, "no progress row yet")
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 3, oldestEventID: "42", complete: false)
        let after = try await svc.backfillOldestEventID(roomID: "!r:s")
        XCTAssertEqual(after, "42")
        // Upsert path: a later record replaces the resume point.
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 6, oldestEventID: "17", complete: false)
        let updated = try await svc.backfillOldestEventID(roomID: "!r:s")
        XCTAssertEqual(updated, "17")
    }

    func test_resetBackfill_clearsBookkeepingButKeepsMessages() async throws {
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: Date(), body: "still searchable after reset")
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 1, oldestEventID: "$1", complete: true)

        try await svc.resetBackfill()

        let done = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertFalse(done, "reset must clear the complete flag")
        let oldest = try await svc.backfillOldestEventID(roomID: "!r:s")
        XCTAssertNil(oldest)
        let hits = try await svc.query("searchable", limit: 10)
        XCTAssertEqual(hits.count, 1, "indexed messages must survive a bookkeeping reset")
    }
}
