import XCTest
import GRDB
@testable import MatronSearch

final class SearchSchemaTests: XCTestCase {
    var dbURL: URL!

    override func setUp() {
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matron-search-test-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
    }

    // The index's protection class must outlive a lock. Under `.complete`
    // iOS evicts the key ~10 s after the phone locks, and SQLite's mapped
    // `-shm` then faults with SIGBUS on the next page-in — the crash a
    // background wake launched just after a lock kept hitting, because it
    // could never see the lock warning that a gate depended on.
    func test_indexFileProtection_survivesLock() {
        XCTAssertEqual(SearchSchema.indexFileProtection, .completeUntilFirstUserAuthentication)
    }

    // A store written under the old class must be moved over in full: the
    // `-shm` is the file that faults, so missing a sidecar keeps the crash.
    func test_applyIndexFileProtection_coversDatabaseAndSidecars() throws {
        let queue = try SearchSchema.makeDatabase(at: dbURL, observesSuspension: false)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO messages(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["!r:s", "$1", "@a:s", 1745000000, "hello"])
        }
        var applied: [String: FileProtectionType] = [:]
        SearchSchema.applyIndexFileProtection(at: dbURL) { protection, file in
            applied[file] = protection
        }
        XCTAssertEqual(applied, [
            dbURL.path: .completeUntilFirstUserAuthentication,
            dbURL.path + "-wal": .completeUntilFirstUserAuthentication,
            dbURL.path + "-shm": .completeUntilFirstUserAuthentication,
        ])
        try queue.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
    }

    // A file that can't be re-protected (the phone is locked and the old
    // class holds it shut) must not stop the others from being tried.
    func test_applyIndexFileProtection_continuesPastAFailure() throws {
        for file in [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"] {
            FileManager.default.createFile(atPath: file, contents: Data())
        }
        defer { for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) } }
        struct Refused: Error {}
        var attempted: [String] = []
        SearchSchema.applyIndexFileProtection(at: dbURL) { _, file in
            attempted.append(file)
            if file == self.dbURL.path { throw Refused() }
        }
        XCTAssertEqual(attempted, [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"])
    }

    func test_migrationCreatesTables() throws {
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.read { db in
            let messages = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'messages'")
            XCTAssertEqual(messages, true)
            let fts = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'messages_fts'")
            XCTAssertEqual(fts, true)
            let rooms = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'indexed_rooms'")
            XCTAssertEqual(rooms, true)
        }
    }

    func test_canInsertAndQueryFTS() throws {
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.write { db in
            // Insert into messages — the AFTER INSERT trigger mirrors body into messages_fts.
            try db.execute(sql: "INSERT INTO messages(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["!r:s", "$1", "@a:s", 1745000000, "the quick brown fox jumps over the lazy dog"])
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'fox'")
            XCTAssertEqual(count, 1)
        }
    }

    func test_deleteRemovesFromFTS() throws {
        // Verifies the AFTER DELETE trigger keeps messages_fts in sync — this is the
        // bug that motivated switching to the content-table design.
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO messages(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["!r:s", "$1", "@a:s", 1745000000, "secret payload"])
            try db.execute(sql: "DELETE FROM messages WHERE event_id = ?", arguments: ["$1"])
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'secret'")
            XCTAssertEqual(count, 0)
        }
    }
}
