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
