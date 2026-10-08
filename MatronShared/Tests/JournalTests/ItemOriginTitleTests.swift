import GRDB
import XCTest
import MatronModels
@testable import MatronJournal

/// `origin_convo_title` on items: the item detail names the
/// conversation that filed an item even when this device has no row for
/// it. Old journals send no field, and an untitled conversation sends null.
final class ItemOriginTitleTests: XCTestCase {
    func testItemDecodesTheOriginConversationTitle() throws {
        var json = ItemsAPITests.itemJSON
        json["origin_convo_title"] = "[ab] Launch plan"
        XCTAssertEqual(try XCTUnwrap(TrackerItem(json: json)).originConvoTitle, "[ab] Launch plan")
    }

    func testAMissingNullOrEmptyTitleDecodesAsNil() throws {
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: ItemsAPITests.itemJSON)).originConvoTitle)
        for value: Any in [NSNull(), ""] {
            var json = ItemsAPITests.itemJSON
            json["origin_convo_title"] = value
            XCTAssertNil(try XCTUnwrap(TrackerItem(json: json)).originConvoTitle)
        }
    }

    func testStoreRoundTripsTheOriginConversationTitle() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        try store.upsertItems([TrackerItem(id: "it_1", num: 1, kind: .task, title: "T", originConvoID: "c1",
                                           originConvoTitle: "[ab] Launch plan")])
        XCTAssertEqual(try XCTUnwrap(try store.item(id: "it_1")).originConvoTitle, "[ab] Launch plan")
    }

    /// The migration adds the column to a store that already holds items;
    /// those read `nil` until their next fetch.
    func testTheMigrationAddsTheColumnToAnExistingStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let dbQueue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(dbQueue, upTo: "mission_names")
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO item(id, num, kind, state, rank, title, body, labels_json, links_json, attachments_json,
                                     origin_convo_id, created_by, created_at, updated_at, comment_count, has_image)
                    VALUES('it_1', 1, 'task', 'open', 1024, 'T', '', '[]', '[]', '[]', 'c1', 'agent', 0, 0, 0, 0)
                    """)
            }
        }
        let store = try JournalStore(databaseURL: url, ownSender: "user:alice")
        XCTAssertNil(try XCTUnwrap(try store.item(id: "it_1")).originConvoTitle)
        try store.upsertItems([TrackerItem(id: "it_1", num: 1, kind: .task, title: "T", originConvoID: "c1",
                                           originConvoTitle: "Launch")])
        XCTAssertEqual(try XCTUnwrap(try store.item(id: "it_1")).originConvoTitle, "Launch")
    }

    /// The owner row follows its conversation: unknown until the row
    /// syncs, then present with its label.
    func testTheConversationOriginStreamFollowsTheRow() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-mac")])
        var iterator = store.conversationOriginStream(id: "c1").makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .unknown)
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "Missions plan", sessionState: "running", lastSeq: 1, snippet: "",
                            createdAt: 1, agentDeviceID: 7),
        ], headSeq: 1)
        let second = await iterator.next()
        XCTAssertEqual(second, .init(exists: true, label: "dev-mac \u{00B7} Missions plan"))
    }
}
