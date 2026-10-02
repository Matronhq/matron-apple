import Foundation
import GRDB

/// GRDB/SQLite-backed `SearchService`. All access funnels through a single
/// `DatabaseQueue`, which serialises reads + writes, so `@unchecked Sendable`
/// is sound (the queue is the synchronisation point).
public final class SearchServiceLive: SearchService, @unchecked Sendable {
    private let queue: DatabaseQueue
    /// Checked ON the database queue, at the start of every access and before
    /// each row of a batch write. See `admit(_:)`.
    private let admission: @Sendable () -> Bool

    /// - Parameter admission: whether the index file may be touched right now
    ///   (iOS: protected data is available). Defaults to always.
    public init(databaseURL: URL, admission: @escaping @Sendable () -> Bool = { true }) throws {
        self.admission = admission
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
    public static func open(databaseURL: URL,
                            admission: @escaping @Sendable () -> Bool = { true }) throws -> SearchServiceLive {
        do {
            return try SearchServiceLive(databaseURL: databaseURL, admission: admission)
        } catch {
            guard isStructurallyUnusable(error),
                  FileManager.default.fileExists(atPath: databaseURL.path),
                  isReadable(databaseURL) else { throw error }
            for url in [databaseURL,
                        URL(fileURLWithPath: databaseURL.path + "-wal"),
                        URL(fileURLWithPath: databaseURL.path + "-shm")] {
                try? FileManager.default.removeItem(at: url)
            }
            return try SearchServiceLive(databaseURL: databaseURL, admission: admission)
        }
    }

    /// The admission barrier, evaluated on the database queue itself.
    ///
    /// `LockAwareSearchService` checks protected data on its actor, but the
    /// call then hops off to GRDB, and `DatabaseQueue.interrupt()` (what the
    /// lock warning triggers) only stops the statement running at that
    /// moment — it neither cancels nor blocks closures queued behind it. A
    /// write admitted just before the warning could therefore be enqueued
    /// after the interrupt and touch the `NSFileProtectionComplete` file
    /// once its key was gone: the SIGBUS page-in fault (CodeRabbit). The
    /// flag flips BEFORE the interrupt is issued, so every closure that
    /// starts after the flip is refused here, and one already running is
    /// interrupted. What remains is a statement that passed this check and
    /// had not started when the interrupt landed — microseconds, against the
    /// ~10 s between the warning and the key eviction.
    private func admit(_ db: Database) throws {
        guard admission() else { throw SearchIndexUnavailable.protectedDataUnavailable }
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

    /// Aborts whatever statement the index is running right now; it throws
    /// `SQLITE_INTERRUPT` to its caller and its transaction rolls back.
    /// Callable from any thread. `LockAwareSearchService` calls this when
    /// iOS announces protected data is about to become unavailable, so no
    /// write is still paging the `NSFileProtectionComplete` file in when the
    /// key goes away.
    public func interrupt() {
        queue.interrupt()
    }

    public func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        try await queue.write { db in
            try self.admit(db)
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
            try self.admit(db)
            for entry in entries {
                try self.admit(db)
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
            try self.admit(db)
            // DELETE on `messages` fires the AFTER DELETE trigger which removes the FTS row.
            try db.execute(sql: "DELETE FROM messages WHERE event_id = ?", arguments: [eventID])
        }
    }

    /// Ids per write transaction. 500 keeps the `IN (…)` list well inside
    /// `SQLITE_MAX_VARIABLE_NUMBER` and, more importantly, keeps each
    /// transaction short: the index has ONE connection, and a first
    /// retention pass retires on the order of 10^5 rows.
    static let removalChunkSize = 500

    /// Pure split, so the transaction count is unit-testable without
    /// instrumenting GRDB.
    static func removalChunks(of eventIDs: [String]) -> [[String]] {
        stride(from: 0, to: eventIDs.count, by: removalChunkSize).map {
            Array(eventIDs[$0..<min($0 + removalChunkSize, eventIDs.count)])
        }
    }

    public func removeAll(eventIDs: [String]) async throws {
        guard !eventIDs.isEmpty else { return }
        // ONE TRANSACTION PER CHUNK, not one for the whole batch (spec §3.4,
        // "one search write transaction per sweep chunk"). A single
        // transaction deleting every retired row would hold the index's only
        // connection for the whole delete and dirty the same kind of page
        // volume as the 2026-08-10 backfill incident this file already
        // carries a comment about. The caller passes the whole list; the
        // chunking is ours.
        for chunk in Self.removalChunks(of: eventIDs) {
            try await queue.write { db in
                try self.admit(db)
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                // DELETE on `messages` fires the AFTER DELETE trigger which
                // removes the matching FTS row — the same path the
                // single-row form takes, so no tokens are stranded.
                try db.execute(sql: "DELETE FROM messages WHERE event_id IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
        }
    }

    /// Rows per prune transaction, same bound and reason as `removalChunkSize`.
    static let pruneChunkSize = 500

    public func pruneRooms(containing infix: String) async throws {
        let key = "pruned_rooms_containing:\(infix)"
        let done = try await queue.read { db in
            try self.admit(db)
            return try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) != nil
        }
        if done { return }
        // A real index held 490,060 such rows (Dan's Mac, 2026-10-02): one
        // short transaction per chunk keeps the index's only connection
        // free for queries and live writes between them. The DELETE on
        // `messages` fires the AFTER DELETE trigger, so no FTS tokens are
        // stranded.
        let escaped = infix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        while true {
            try Task.checkCancellation()
            let deleted = try await queue.write { db -> Int in
                try self.admit(db)
                try db.execute(sql: """
                    DELETE FROM messages WHERE rowid IN (
                        SELECT rowid FROM messages WHERE room_id LIKE ? ESCAPE '\\' LIMIT ?)
                """, arguments: [pattern, Self.pruneChunkSize])
                return db.changesCount
            }
            if deleted < Self.pruneChunkSize { break }
        }
        try await queue.write { db in
            try self.admit(db)
            try db.execute(sql: "DELETE FROM indexed_rooms WHERE room_id LIKE ? ESCAPE '\\'", arguments: [pattern])
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, '1')", arguments: [key])
        }
    }

    public func query(_ text: String, limit: Int) async throws -> [SearchHit] {
        guard let parsed = SearchQuery(text) else { return [] }
        return try await queue.read { db in
            try self.admit(db)
            return try Self.hits(db, query: parsed, roomID: nil, limit: limit)
        }
    }

    public func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] {
        guard let parsed = SearchQuery(text) else { return [] }
        return try await queue.read { db in
            try self.admit(db)
            return try Self.hits(db, query: parsed, roomID: roomID, limit: limit)
        }
    }

    /// Flat message hits, newest first: every message containing all the
    /// typed words, optionally within one room. The room filter sits in the
    /// WHERE so `limit` applies post-filter.
    private static func hits(_ db: Database, query: SearchQuery, roomID: String?,
                             limit: Int) throws -> [SearchHit] {
        var arguments: [any DatabaseValueConvertible] = [query.allTermsMatch]
        arguments.append(contentsOf: query.literalPatterns)
        if let roomID { arguments.append(roomID) }
        arguments.append(limit)
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.room_id, m.event_id, m.sender, m.timestamp, m.body
            FROM messages_fts
            JOIN messages m ON m.rowid = messages_fts.rowid
            WHERE messages_fts MATCH ?\(literalFilter(query.literalPatterns))
              \(roomID == nil ? "" : "AND m.room_id = ?")
            ORDER BY m.timestamp DESC
            LIMIT ?
        """, arguments: StatementArguments(arguments))
        return rows.map { hit(from: $0, query: query) }
    }

    /// The `LIKE` half of the match rule: FTS finds the candidates (stems
    /// included), and these keep only bodies containing each word as typed
    /// — see `SearchQuery`. Scans only the rows FTS already matched.
    private static func literalFilter(_ patterns: [String]) -> String {
        patterns.map { _ in " AND m.body LIKE ? ESCAPE '\\'" }.joined()
    }

    private static func hit(from row: Row, query: SearchQuery) -> SearchHit {
        SearchHit(
            id: row["event_id"],
            roomID: row["room_id"],
            sender: row["sender"],
            timestamp: Date(timeIntervalSince1970: TimeInterval(row["timestamp"] as Int)),
            snippet: SearchSnippet.make(body: row["body"], query: query)
        )
    }

    /// One room's standing in a grouped query: how many messages match and
    /// which one is newest. The bare `m.rowid` rides SQLite's documented
    /// single-MAX rule: with exactly one MAX() aggregate, bare columns take
    /// their values from the row that supplied the maximum.
    private struct RoomGroup {
        let roomID: String
        let count: Int
        let newestTimestamp: Int
        let newestRowid: Int64
    }

    private static func groups(_ db: Database, match: String, patterns: [String],
                               roomIDs: [String]? = nil, limit: Int) throws -> [RoomGroup] {
        var arguments: [any DatabaseValueConvertible] = [match]
        arguments.append(contentsOf: patterns)
        var roomFilter = ""
        if let roomIDs {
            roomFilter = "AND m.room_id IN (\(roomIDs.map { _ in "?" }.joined(separator: ",")))"
            arguments.append(contentsOf: roomIDs)
        }
        arguments.append(limit)
        return try Row.fetchAll(db, sql: """
            SELECT m.room_id, COUNT(*) AS hit_count, MAX(m.timestamp) AS newest_ts,
                   m.rowid AS newest_rowid
            FROM messages_fts
            JOIN messages m ON m.rowid = messages_fts.rowid
            WHERE messages_fts MATCH ?\(literalFilter(patterns))
              \(roomFilter)
            GROUP BY m.room_id
            ORDER BY newest_ts DESC
            LIMIT ?
        """, arguments: StatementArguments(arguments)).map {
            RoomGroup(roomID: $0["room_id"], count: $0["hit_count"],
                      newestTimestamp: $0["newest_ts"], newestRowid: $0["newest_rowid"])
        }
    }

    public func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] {
        guard let parsed = SearchQuery(text) else { return [] }
        return try await queue.read { db in
            try self.admit(db)
            // Two tiers (Dan, 2026-10-02: sorting purely by newest put a
            // tool log from a minute ago above the exact phrase from
            // Tuesday). Rooms holding the query as an exact phrase come
            // first; rooms that only contain every word follow. Newest
            // first within each.
            var exact: [RoomGroup] = []
            if parsed.hasDistinctExactTier {
                exact = try Self.groups(db, match: parsed.exactMatch,
                                        patterns: parsed.exactLiteralPattern.map { [$0] } ?? [],
                                        limit: limit)
            }
            var all = try Self.groups(db, match: parsed.allTermsMatch,
                                      patterns: parsed.literalPatterns, limit: limit)
            // An exact room older than the newest `limit` all-terms rooms
            // still needs its total: every exact match is an all-terms
            // match, so the count comes from the same query, scoped.
            let listed = Set(all.map(\.roomID))
            let unlisted = exact.map(\.roomID).filter { !listed.contains($0) }
            if !unlisted.isEmpty {
                all += try Self.groups(db, match: parsed.allTermsMatch, patterns: parsed.literalPatterns,
                                       roomIDs: unlisted, limit: unlisted.count)
            }
            let counts = Dictionary(uniqueKeysWithValues: all.map { ($0.roomID, $0.count) })
            let exactRooms = Set(exact.map(\.roomID))
            let ranked = (exact.map { ($0, true) }
                + all.filter { !exactRooms.contains($0.roomID) }.map { ($0, false) }).prefix(limit)
            guard !ranked.isEmpty else { return [] }

            // Bodies for just the winning rows; the preview is cut from
            // them in Swift (`SearchSnippet`), so nothing is computed for
            // the thousands of matches that are not shown.
            let rowids = ranked.map { $0.0.newestRowid }
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.rowid, m.room_id, m.event_id, m.sender, m.timestamp, m.body
                FROM messages m
                WHERE m.rowid IN (\(rowids.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(rowids))
            let hitsByRowid = Dictionary(uniqueKeysWithValues: rows.map {
                ($0["rowid"] as Int64, Self.hit(from: $0, query: parsed))
            })
            return ranked.compactMap { group, isExact in
                guard let hit = hitsByRowid[group.newestRowid] else { return nil }
                return SearchChatHit(roomID: group.roomID, count: counts[group.roomID] ?? group.count,
                                     topHit: hit, isExact: isExact)
            }
        }
    }

    public func wipe() async throws {
        try await queue.write { db in
            try self.admit(db)
            // Deleting from `messages` fires the AFTER DELETE trigger for each row,
            // keeping messages_fts in sync.
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM indexed_rooms")
        }
    }

    public func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {
        try await queue.write { db in
            try self.admit(db)
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
            try self.admit(db)
            return try String.fetchOne(
                db,
                sql: "SELECT backfill_oldest_event_id FROM indexed_rooms WHERE room_id = ?",
                arguments: [roomID]
            )
        }
    }

    public func resetBackfill() async throws {
        try await queue.write { db in
            try self.admit(db)
            // Bookkeeping only — `messages`/`messages_fts` stay intact, so
            // existing hits keep working while rooms re-walk.
            try db.execute(sql: "DELETE FROM indexed_rooms")
        }
    }

    public func backfillComplete(roomID: String) async throws -> Bool {
        try await queue.read { db in
            try self.admit(db)
            let value = try Int.fetchOne(db, sql: "SELECT backfill_complete FROM indexed_rooms WHERE room_id = ?", arguments: [roomID]) ?? 0
            return value == 1
        }
    }

    public func eventCount(roomID: String) async throws -> Int {
        try await queue.read { db in
            try self.admit(db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE room_id = ?", arguments: [roomID]) ?? 0
        }
    }

    public func contains(eventID: String) async throws -> Bool {
        try await queue.read { db in
            try self.admit(db)
            return (try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE event_id = ?", arguments: [eventID])) != nil
        }
    }
}
