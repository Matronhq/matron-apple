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

    /// Opens the index, recycling the store if it is structurally unopenable.
    ///
    /// The index is a *derived* cache — every row in it can be rebuilt from the
    /// journal mirror and the server backfill (`startBackfill`). So a store that
    /// can't be opened is never worth preserving: the old `try?` at the call
    /// sites turned any such failure into "search silently does not exist on
    /// this device, forever", which is exactly how a corrupt-on-disk index
    /// reads to the user (Dan's iPhone, 2026-08-08 — the search button was
    /// gated on this service being non-nil, so it just never appeared).
    ///
    /// Recycling is deliberately NOT applied to a failure caused by iOS data
    /// protection. `matron-search.sqlite` is `NSFileProtectionComplete`, so a
    /// launch while the device is locked (background push wake) genuinely
    /// cannot open it, and deleting a perfectly good index because the phone
    /// happened to be locked would throw away the whole index on every locked
    /// launch. That case is caught by trying to read a byte of the file
    /// directly: unreadable ⇒ protection ⇒ transient, rethrow and let the
    /// caller retry later.
    ///
    /// Readable-but-refused is NOT enough on its own, though. `SQLITE_BUSY` is
    /// the obvious counter-example: the App Group index is shared with the
    /// notification-service extension, and this open does a real write on iOS
    /// (`SearchSchema.makeDatabase` forces the WAL sidecars into existence), so
    /// an NSE holding the write lock past the 2s busy timeout produces a
    /// perfectly readable file that SQLite still refuses. Wiping there destroys
    /// a healthy index — the exact outcome recycling exists to avoid. So the
    /// error itself has to say the bytes are unusable: only `SQLITE_CORRUPT`
    /// (including its extended forms, which is what a broken FTS index raises)
    /// and `SQLITE_NOTADB` are recycled, and everything else is rethrown for a
    /// later retry.
    public static func open(databaseURL: URL) throws -> SearchServiceLive {
        do {
            return try SearchServiceLive(databaseURL: databaseURL)
        } catch {
            guard isStructurallyUnusable(error),
                  FileManager.default.fileExists(atPath: databaseURL.path),
                  isReadable(databaseURL) else { throw error }
            for url in [databaseURL,
                        URL(fileURLWithPath: databaseURL.path + "-wal"),
                        URL(fileURLWithPath: databaseURL.path + "-shm")] {
                try? FileManager.default.removeItem(at: url)
            }
            return try SearchServiceLive(databaseURL: databaseURL)
        }
    }

    /// Whether `error` means the bytes on disk are not a usable database, as
    /// opposed to a database that merely cannot be opened *right now*.
    ///
    /// Only the two verdicts SQLite gives about content are treated as fatal.
    /// Everything else — busy, locked, I/O errors, permissions, a non-SQLite
    /// error thrown on the way — is transient by assumption, because the cost
    /// of being wrong in that direction is one more failed open, while the cost
    /// of being wrong the other way is the user's whole search index.
    ///
    /// The primary code is what gets compared: SQLite reports corruption
    /// through extended codes too (`SQLITE_CORRUPT_VTAB` is what a corrupt FTS
    /// index raises), and every extended code carries its primary code in the
    /// low 8 bits.
    static func isStructurallyUnusable(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        let primary = dbError.resultCode.rawValue & 0xFF
        return primary == ResultCode.SQLITE_CORRUPT.rawValue
            || primary == ResultCode.SQLITE_NOTADB.rawValue
    }

    /// True when the file's bytes can actually be read right now. On iOS a
    /// `false` here means data protection is holding the file shut (the device
    /// is locked), not that the contents are bad.
    private static func isReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // A zero-length read still exercises the protection check, but an empty
        // file would then look "readable" — read a real byte where there is one.
        return (try? handle.read(upToCount: 1)) != nil
    }

    public func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        try await queue.write { db in
            try Self.upsert(db, roomID: roomID, eventID: eventID, sender: sender,
                            timestamp: timestamp, body: body)
        }
    }

    public func indexBatch(_ entries: [SearchIndexEntry]) async throws {
        guard !entries.isEmpty else { return }
        // One transaction (and one fsync) for the whole batch — a catch-up
        // replay indexes hundreds of rows, and per-row transactions made
        // that hundreds of journal commits.
        try await queue.write { db in
            for entry in entries {
                try Self.upsert(db, roomID: entry.roomID, eventID: entry.eventID,
                                sender: entry.sender, timestamp: entry.timestamp, body: entry.body)
            }
        }
    }

    // UPSERT, not INSERT OR REPLACE: REPLACE resolves the event_id conflict by
    // deleting the old row WITHOUT firing the AFTER DELETE trigger (delete
    // triggers only fire on REPLACE-deletions when recursive_triggers is ON),
    // which strands the old rowid's tokens in messages_fts — the 2026-08-06
    // index corruption. DO UPDATE keeps the rowid and fires the AFTER UPDATE
    // trigger, which maintains the FTS mirror correctly. The WHERE makes a
    // re-index of identical values (the backfill's common case) a no-op, so
    // it costs no FTS churn.
    private static func upsert(_ db: Database, roomID: String, eventID: String,
                               sender: String, timestamp: Date, body: String) throws {
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
