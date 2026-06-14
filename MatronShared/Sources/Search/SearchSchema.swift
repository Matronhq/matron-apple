import Foundation
import GRDB

/// SQLite schema + database factory for the local full-text search index.
///
/// **Content-table FTS5 design.** FTS5's `DELETE … WHERE col = ?` is a silent
/// no-op against `UNINDEXED` columns — the rows stay in the index. So instead of
/// storing everything in the FTS table, a normal `messages` table holds the
/// indexable columns (with a `UNIQUE` `event_id`), `messages_fts` is an FTS5
/// mirror of just `body` (`content='messages'`), and three triggers keep the two
/// in sync. This makes `INSERT OR REPLACE INTO messages` (idempotent re-index)
/// and `DELETE FROM messages WHERE event_id = ?` (redaction) behave correctly.
public enum SearchSchema {
    public static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1: messages + messages_fts + indexed_rooms") { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    rowid INTEGER PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    event_id TEXT NOT NULL UNIQUE,
                    sender TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    body TEXT NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_messages_event_id ON messages(event_id);")
            try db.execute(sql: "CREATE INDEX idx_messages_room_id ON messages(room_id);")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    body,
                    content='messages',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                );
            """)

            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
                    INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
                END;
            """)

            try db.execute(sql: """
                CREATE TABLE indexed_rooms (
                    room_id TEXT PRIMARY KEY,
                    backfill_complete INTEGER NOT NULL DEFAULT 0,
                    backfill_oldest_event_id TEXT,
                    backfill_event_count INTEGER NOT NULL DEFAULT 0
                );
            """)
        }
    }

    /// Opens (or creates) a database at `path` with Data Protection set to complete.
    /// The protection attribute is applied at file-creation time so the file is never
    /// briefly written without it.
    ///
    /// Platform note: `NSFileProtectionComplete` is iOS-only — macOS doesn't have file
    /// protection classes. On Mac, encryption at rest comes from FileVault (user-managed)
    /// and the file path is sandbox-private regardless. The pre-create + assert block is
    /// therefore wrapped in `#if os(iOS)`.
    public static func makeDatabase(at path: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // Pre-create the file with NSFileProtectionComplete so the attribute is set
        // before GRDB writes any bytes. setAttributes-after-open leaves a small window
        // where the file exists without protection.
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(
                atPath: path.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        #endif
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        #if os(iOS) && !targetEnvironment(simulator)
        // Defensive check: confirm protection is set on the resulting file.
        // Device + signed builds only — the iOS Simulator doesn't enforce data
        // protection (NSFileProtectionComplete is a no-op there and the
        // attribute reads back absent), so the assert would spuriously fire
        // under xcodebuild test on a Simulator. Mirrors MatronApp's
        // `#if !targetEnvironment(simulator)`-gated KeychainProbe.
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        assert((attrs[.protectionKey] as? FileProtectionType) == .complete, "matron-search.sqlite missing NSFileProtectionComplete")
        #endif
        var migrator = DatabaseMigrator()
        migrate(&migrator)
        try migrator.migrate(queue)
        return queue
    }
}
