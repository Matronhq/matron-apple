import Foundation
import GRDB
import os

/// SQLite schema + database factory for the local full-text search index.
///
/// **Content-table FTS5 design.** FTS5's `DELETE … WHERE col = ?` is a silent
/// no-op against `UNINDEXED` columns — the rows stay in the index. So instead of
/// storing everything in the FTS table, a normal `messages` table holds the
/// indexable columns (with a `UNIQUE` `event_id`), `messages_fts` is an FTS5
/// mirror of just `body` (`content='messages'`), and three triggers keep the two
/// in sync. Re-index goes through an UPSERT (never `INSERT OR REPLACE` — REPLACE
/// skips the delete trigger and strands FTS entries, see the v2 migration) and
/// `DELETE FROM messages WHERE event_id = ?` (redaction) behaves correctly.
public enum SearchSchema {
    /// Whether `makeDatabase` opts into GRDB suspension by default — iOS
    /// only, matching `JournalStore.observesSuspensionByDefault`.
    #if os(iOS)
    public static let observesSuspensionByDefault = true
    #else
    public static let observesSuspensionByDefault = false
    #endif

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

        migrator.registerMigration("v2: rebuild messages_fts (REPLACE ghost entries)") { db in
            // Stores written while `index()` used INSERT OR REPLACE hold ghost FTS
            // entries: REPLACE deleted conflicting content rows without firing the
            // AFTER DELETE trigger, so the dead rowids' tokens stayed in the index
            // ('integrity-check' reported SQLITE_CORRUPT on a live store). `rebuild` regenerates the whole FTS index from the
            // content table — sub-second even at ~100k rows.
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
        }

        migrator.registerMigration("v3: meta") { db in
            // Index-level bookkeeping (which one-off prunes have run).
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        }
    }

    /// The Data Protection class every index file carries (the database and
    /// its `-wal`/`-shm` sidecars): readable from the first unlock after boot
    /// until the next reboot, locked or not.
    ///
    /// It used to be `.complete`, whose key iOS evicts about ten seconds after
    /// every lock. SQLite maps the WAL index (`-shm`) into memory, so any
    /// access that needed a page of it after the eviction died with SIGBUS
    /// ("FS pagein error: 1 Operation not permitted") — a signal, not an
    /// error anyone could catch. `LockAwareSearchService` stops index access
    /// when iOS warns that protected data is going away, but a process that
    /// was not running when that warning was posted (a push or refresh wake
    /// launched in the ten seconds after a lock, or one resumed from
    /// suspension then) never sees it, and the system flag still reads
    /// `true` until the eviction. No gate can close that window, so the
    /// class it guards against is gone instead.
    ///
    /// This loses nothing: every body in the index is also in the journal
    /// mirror, which has always been `.completeUntilFirstUserAuthentication`
    /// because background sync writes it while the phone is locked.
    public static let indexFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    /// The index file and its WAL sidecars that exist on disk at `path`.
    static func existingIndexFiles(at path: URL) -> [String] {
        [path.path, path.path + "-wal", path.path + "-shm"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Sets `indexFileProtection` on every index file present at `path`.
    ///
    /// Stores created before the class changed are `.complete` on disk; this
    /// is what moves them over. It runs before the database is opened, so no
    /// connection in this process ever maps a `.complete` `-shm`, and again
    /// after, for sidecars SQLite created during the open. Changing a
    /// `.complete` file's class needs its key, so while the phone is locked
    /// the first pass fails — and the open then fails too, exactly as it
    /// always has for a locked launch, and is retried after unlock.
    /// `setProtection` is injectable for tests.
    static func applyIndexFileProtection(
        at path: URL,
        setProtection: (FileProtectionType, String) throws -> Void = { protection, file in
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: file)
        }
    ) {
        for file in existingIndexFiles(at: path) {
            do {
                try setProtection(indexFileProtection, file)
            } catch {
                logger.error("could not set index file protection on \((file as NSString).lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let logger = os.Logger(subsystem: "chat.matron", category: "search-schema")

    /// Opens (or creates) a database at `path` with Data Protection set to
    /// `indexFileProtection`. The attribute is applied at file-creation time so
    /// the file is never briefly written without it.
    ///
    /// Platform note: file protection classes are iOS-only. On Mac, encryption
    /// at rest comes from FileVault (user-managed) and the file path is
    /// sandbox-private regardless, so the protection code is wrapped in
    /// `#if os(iOS)`.
    ///
    /// `observesSuspension` opts the queue into GRDB's suspension
    /// notifications: iOS kills an app suspended while holding a lock on a
    /// file in the App Group container (`0xdead10cc`), and this index lives
    /// there. Defaults to on for iOS only; the Mac is never suspended that
    /// way. See `DatabaseSuspensionController` in MatronJournal.
    public static func makeDatabase(at path: URL,
                                    observesSuspension: Bool = observesSuspensionByDefault) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // Pre-create the file with its protection class so the attribute is
        // set before GRDB writes any bytes. setAttributes-after-open leaves a
        // small window where the file exists without protection.
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(
                atPath: path.path,
                contents: nil,
                attributes: [.protectionKey: indexFileProtection]
            )
        }
        // Move a store written under the old `.complete` class over before
        // anything maps it (see `indexFileProtection`).
        applyIndexFileProtection(at: path)
        #endif
        var config = Configuration()
        config.observesSuspensionNotifications = observesSuspension
        // A second connection (an overlapping app instance during relaunch, or a
        // diagnostic sqlite3 shell) briefly holding the lock surfaced as a
        // hard "database is locked" backfill failure (2026-08-06). Wait it out
        // instead of erroring immediately.
        config.busyMode = .timeout(2)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // WAL instead of the default rollback journal: every index write
            // used to create+fsync+delete a `-journal` file. WAL appends and
            // fsyncs far less (synchronous=NORMAL is the documented-safe
            // pairing — a power cut can lose the last transactions but never
            // corrupts, and this index can always be rebuilt from the
            // journal mirror). Persistent in the file; re-issuing per
            // connection is a no-op.
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        #if os(iOS)
        // The WAL sidecars are created lazily by SQLite, not by us, so they
        // don't inherit the pre-created main file's protection class. Force
        // them into existence with an empty write, then match the main file.
        try queue.write { _ in }
        applyIndexFileProtection(at: path)
        #endif
        #if os(iOS) && !targetEnvironment(simulator)
        // Defensive check: confirm protection is set on the resulting file.
        // Device + signed builds only — the iOS Simulator doesn't enforce data
        // protection (the attribute reads back absent), so the assert would
        // spuriously fire under xcodebuild test on a Simulator. Mirrors
        // MatronApp's `#if !targetEnvironment(simulator)`-gated KeychainProbe.
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        assert((attrs[.protectionKey] as? FileProtectionType) == indexFileProtection,
               "matron-search.sqlite has the wrong file protection class")
        #endif
        var migrator = DatabaseMigrator()
        migrate(&migrator)
        try migrator.migrate(queue)
        return queue
    }
}
