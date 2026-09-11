import GRDB
import XCTest
@testable import MatronJournal

/// Tracker #216: GRDB's `DatabaseMigrator` records applied migrations by
/// NAME, not by inspecting the schema. A device that reached today's schema
/// via a different migration history (a renamed/renumbered migration
/// upstream, or a hand-patched DB) can have a column on disk with no
/// matching entry in `grdb_migrations`. Before this fix, the next plain
/// `t.add(column:)` migration to touch that column would re-run and throw
/// "duplicate column", and both `AppDependencies` callers open the store
/// with `try!` — turning that mismatch into a launch crash loop.
///
/// These tests reproduce the mismatch directly: freeze a temp-file database
/// at an intermediate migration, hand-add a column a *later* migration also
/// adds, then prove `JournalStore.init` still opens cleanly and the column
/// isn't duplicated.
final class JournalStoreMigrationIdempotenceTests: XCTestCase {
    func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("journal.sqlite")
    }

    /// Freezes at v7 (before v8 adds `agent.tag_char`), then hand-adds the
    /// column exactly as v8 would — simulating a device whose `tag_char`
    /// arrived under a different, un-recorded migration name. The `dbQueue`
    /// this opens must go out of scope before `JournalStore` opens the same
    /// path, exactly as `JournalStoreLaunchPerfTests.seedPreV11Database`
    /// does, so only one connection ever holds the file.
    private func seedPreV8DatabaseWithTagCharAlreadyPresent(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try JournalStore.migrator().migrate(dbQueue, upTo: "v7")
        try dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE agent ADD COLUMN tag_char TEXT")
        }
    }

    func testV8SkipsTheAlterWhenTagCharAlreadyExists() throws {
        let url = try tempStoreURL()
        try seedPreV8DatabaseWithTagCharAlreadyPresent(at: url)

        // Before the fix this `init` throws "duplicate column: tag_char"
        // partway through v8, and both AppDependencies callers wrap this
        // exact call in `try!`.
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")

        let tagCharColumns = try store.dbQueue.read { db in
            try db.columns(in: "agent").filter { $0.name == "tag_char" }
        }
        XCTAssertEqual(tagCharColumns.count, 1,
                       "agent.tag_char must exist exactly once, not be duplicated or missing")
    }

    /// Freezes at v10 (before v11 adds `conversation.last_message_type` /
    /// `expired_snippet`) with one conversation and a `tool_output` event
    /// that the v11 backfill would turn into a command stub, then hand-adds
    /// only `last_message_type` — leaving `expired_snippet` for v11 to add
    /// normally. Proves two things at once: the pre-existing column doesn't
    /// crash the migration, and the per-conversation backfill loop still
    /// runs and fills both columns (the loop itself has no "already ran"
    /// guard — it's expected to re-run harmlessly, per the brief).
    private func seedPreV11DatabaseWithLastMessageTypeAlreadyPresent(at url: URL) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try JournalStore.migrator().migrate(dbQueue, upTo: "v10")
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversation(id, title, session_state, last_seq, snippet, created_at) VALUES(?, ?, 'running', 0, '', 0)",
                arguments: ["c1", "T-c1"])
            let payload = try! JSONSerialization.data(withJSONObject: ["command": "make test", "live_log": true])
            try db.execute(
                sql: "INSERT INTO event(seq, convo_id, ts, sender, type, payload) VALUES(?, ?, ?, ?, ?, ?)",
                arguments: [1, "c1", 1_000, "agent:dev-2", JournalEventType.toolOutput, payload])
            try db.execute(sql: "ALTER TABLE conversation ADD COLUMN last_message_type TEXT")
        }
    }

    func testV11SkipsTheAlterForLastMessageTypeButStillRunsTheBackfill() throws {
        let url = try tempStoreURL()
        try seedPreV11DatabaseWithLastMessageTypeAlreadyPresent(at: url)

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")

        let conversationColumns = try store.dbQueue.read { db in
            try db.columns(in: "conversation").map(\.name)
        }
        XCTAssertEqual(conversationColumns.filter { $0 == "last_message_type" }.count, 1,
                       "conversation.last_message_type must exist exactly once, not be duplicated")
        XCTAssertTrue(conversationColumns.contains("expired_snippet"),
                      "expired_snippet still needed adding — its ALTER must not have been skipped")

        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput,
                       "the backfill loop must still have run even though the column pre-existed")
        XCTAssertEqual(row.expiredSnippet, "$ make test")
    }
}
