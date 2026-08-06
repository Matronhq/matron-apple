import Foundation
import GRDB

/// GRDB/SQLite-backed `SearchService`. All access funnels through a single
/// `DatabaseQueue`, which serialises reads + writes, so `@unchecked Sendable`
/// is sound (the queue is the synchronisation point).
public final class SearchServiceLive: SearchService, @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(databaseURL: URL) throws {
        self.queue = try SearchSchema.makeDatabase(at: databaseURL)
    }

    public func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        try await queue.write { db in
            // UPSERT, not INSERT OR REPLACE: REPLACE resolves the event_id conflict by
            // deleting the old row WITHOUT firing the AFTER DELETE trigger (delete
            // triggers only fire on REPLACE-deletions when recursive_triggers is ON),
            // which strands the old rowid's tokens in messages_fts — the 2026-08-06
            // index corruption. DO UPDATE keeps the rowid and fires the AFTER UPDATE
            // trigger, which maintains the FTS mirror correctly. The WHERE makes a
            // re-index of identical values (the backfill's common case) a no-op, so
            // it costs no FTS churn.
            try db.execute(
                sql: """
                    INSERT INTO messages(room_id, event_id, sender, timestamp, body)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(event_id) DO UPDATE SET
                        room_id = excluded.room_id,
                        sender = excluded.sender,
                        timestamp = excluded.timestamp,
                        body = excluded.body
                    WHERE messages.room_id IS NOT excluded.room_id
                       OR messages.sender IS NOT excluded.sender
                       OR messages.timestamp IS NOT excluded.timestamp
                       OR messages.body IS NOT excluded.body
                """,
                arguments: [roomID, eventID, sender, Int(timestamp.timeIntervalSince1970), body]
            )
        }
    }

    public func remove(eventID: String) async throws {
        try await queue.write { db in
            // DELETE on `messages` fires the AFTER DELETE trigger which removes the FTS row.
            try db.execute(sql: "DELETE FROM messages WHERE event_id = ?", arguments: [eventID])
        }
    }

    public func query(_ text: String, limit: Int) async throws -> [SearchHit] {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        let pattern = "\"\(escaped)\"*"
        return try await queue.read { db in
            // FTS5 now contains only `body` (column index 0). Sender/timestamp/room_id
            // come from the joined `messages` table.
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.room_id, m.event_id, m.sender, m.timestamp,
                       snippet(messages_fts, 0, '<mark>', '</mark>', '…', 32) AS snippet
                FROM messages_fts
                JOIN messages m ON m.rowid = messages_fts.rowid
                WHERE messages_fts MATCH ?
                ORDER BY m.timestamp DESC
                LIMIT ?
            """, arguments: [pattern, limit])

            return rows.map { row in
                SearchHit(
                    id: row["event_id"],
                    roomID: row["room_id"],
                    sender: row["sender"],
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row["timestamp"] as Int)),
                    snippet: row["snippet"]
                )
            }
        }
    }

    public func wipe() async throws {
        try await queue.write { db in
            // Deleting from `messages` fires the AFTER DELETE trigger for each row,
            // keeping messages_fts in sync.
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM indexed_rooms")
        }
    }

    public func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO indexed_rooms(room_id, backfill_complete, backfill_oldest_event_id, backfill_event_count)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(room_id) DO UPDATE SET
                    backfill_complete = excluded.backfill_complete,
                    backfill_oldest_event_id = excluded.backfill_oldest_event_id,
                    backfill_event_count = excluded.backfill_event_count
            """, arguments: [roomID, complete ? 1 : 0, oldestEventID, indexedCount])
        }
    }

    public func backfillOldestEventID(roomID: String) async throws -> String? {
        try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT backfill_oldest_event_id FROM indexed_rooms WHERE room_id = ?",
                arguments: [roomID]
            )
        }
    }

    public func resetBackfill() async throws {
        try await queue.write { db in
            // Bookkeeping only — `messages`/`messages_fts` stay intact, so
            // existing hits keep working while rooms re-walk.
            try db.execute(sql: "DELETE FROM indexed_rooms")
        }
    }

    public func backfillComplete(roomID: String) async throws -> Bool {
        try await queue.read { db in
            let value = try Int.fetchOne(db, sql: "SELECT backfill_complete FROM indexed_rooms WHERE room_id = ?", arguments: [roomID]) ?? 0
            return value == 1
        }
    }

    public func eventCount(roomID: String) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE room_id = ?", arguments: [roomID]) ?? 0
        }
    }

    public func contains(eventID: String) async throws -> Bool {
        try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE event_id = ?", arguments: [eventID])) != nil
        }
    }
}
