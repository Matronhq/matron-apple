import GRDB
import XCTest
import MatronModels
@testable import MatronJournal

/// Item action buttons (contract 2026-09-24): `actions` / `chosen_action`
/// on items, `action` on comments. Old journals send neither, so every
/// field defaults rather than failing the decode.
final class ItemActionsTests: XCTestCase {
    // MARK: Decoding

    func testItemDecodesActionsAndChosenAction() throws {
        var json = ItemsAPITests.itemJSON
        json["actions"] = ["Go", "Wait"]
        json["chosen_action"] = "Go"
        let item = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertEqual(item.actions, ["Go", "Wait"])
        XCTAssertEqual(item.chosenAction, "Go")
    }

    func testItemFromAnOldJournalHasNoActions() throws {
        let item = try XCTUnwrap(TrackerItem(json: ItemsAPITests.itemJSON))
        XCTAssertEqual(item.actions, [])
        XCTAssertNil(item.chosenAction)
    }

    func testNullChosenActionDecodesAsNil() throws {
        var json = ItemsAPITests.itemJSON
        json["actions"] = ["Go"]
        json["chosen_action"] = NSNull()
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json)).chosenAction)
    }

    private static let commentJSON: [String: Any] = [
        "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "user", "device_id": 9, "kind": "comment",
        "body": "Go", "attachments": [], "meta": NSNull(), "idem_key": NSNull(), "created_at": 1_700_000_002_000,
    ]

    func testCommentDecodesAction() throws {
        var json = Self.commentJSON
        json["action"] = "Go"
        XCTAssertEqual(try XCTUnwrap(TrackerComment(json: json)).action, "Go")
    }

    func testCommentFromAnOldJournalHasNoAction() throws {
        XCTAssertNil(try XCTUnwrap(TrackerComment(json: Self.commentJSON)).action)
        var json = Self.commentJSON
        json["action"] = NSNull()
        XCTAssertNil(try XCTUnwrap(TrackerComment(json: json)).action)
    }

    // MARK: Visibility rule

    func testOfferedActionsAreTheActionsWhileOpenAndNoneOnceClosed() {
        let open = TrackerItem(id: "it_1", num: 1, kind: .question, title: "Q", originConvoID: "c1", actions: ["Go"])
        XCTAssertEqual(open.offeredActions, ["Go"])
        let closed = TrackerItem(id: "it_1", num: 1, kind: .question, state: .closed, title: "Q", originConvoID: "c1",
                                 actions: ["Go"], chosenAction: "Go")
        XCTAssertEqual(closed.offeredActions, [])
    }

    // MARK: Local store

    func testStoreRoundTripsActionsChosenActionAndCommentAction() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "Q", originConvoID: "c1",
                               actions: ["Go", "Wait"], chosenAction: "Wait")
        try store.upsertItems([item])
        let read = try XCTUnwrap(try store.item(id: "it_1"))
        XCTAssertEqual(read.actions, ["Go", "Wait"])
        XCTAssertEqual(read.chosenAction, "Wait")

        try store.replaceComments(itemID: "it_1", [
            TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "Wait", action: "Wait"),
            TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: "hello"),
        ])
        XCTAssertEqual(try store.comments(itemID: "it_1").map(\.action), ["Wait", nil])
    }

    /// v12 adds the two columns to a store that already holds items, and
    /// clears the refresh watermarks so the next refresh refetches every
    /// item in full — otherwise a cached question with buttons would never
    /// show them until the item next changed on the server.
    func testV12AddsTheColumnsAndForcesAFullRefetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let dbQueue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(dbQueue, upTo: "v11")
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO item(id, num, kind, state, rank, title, body, labels_json, links_json, attachments_json,
                                     origin_convo_id, created_by, created_at, updated_at, comment_count, has_image)
                    VALUES('it_1', 1, 'question', 'open', 1024, 'Q', '', '[]', '[]', '[]', 'c1', 'agent', 0, 0, 0, 0)
                    """)
                try db.execute(sql: "INSERT INTO meta(key, value) VALUES('items_watermark_all', 5)")
            }
        }
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let item = try XCTUnwrap(try store.item(id: "it_1"))
        XCTAssertEqual(item.actions, [])
        XCTAssertNil(item.chosenAction)
        XCTAssertNil(try store.itemsWatermark(scope: .all))
    }

    // MARK: API

    func testCommentItemSendsActionOnlyWhenGiven() async throws {
        ItemsStubURLProtocol.status = 201
        var commentJSON = Self.commentJSON
        commentJSON["action"] = "Go"
        ItemsStubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["item": ItemsAPITests.itemJSON, "comment": commentJSON])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")

        let r = try await api.commentItem(id: "it_1", body: "Go", attachments: [], action: "Go", idempotencyKey: "k")
        XCTAssertEqual(r.comment.action, "Go")
        var sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as! [String: Any]
        XCTAssertEqual(sent["action"] as? String, "Go")
        XCTAssertEqual(sent["body"] as? String, "Go")

        _ = try await api.commentItem(id: "it_1", body: "hi", attachments: [], action: nil, idempotencyKey: "k2")
        sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as! [String: Any]
        XCTAssertNil(sent["action"], "an old journal must never see the key on an ordinary reply")
    }
}
