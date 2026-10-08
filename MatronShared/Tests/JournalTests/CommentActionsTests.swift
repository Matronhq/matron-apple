import GRDB
import XCTest
import MatronModels
@testable import MatronJournal

/// Comment action buttons (contract 2026-10-04): `actions` /
/// `chosen_action` / `reply_to` on every comment. A journal that predates
/// them sends none, so each defaults rather than failing the decode.
final class CommentActionsTests: XCTestCase {
    private static let commentJSON: [String: Any] = [
        "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "agent", "device_id": 9, "kind": "comment",
        "body": "Ship it?", "attachments": [], "meta": NSNull(), "idem_key": NSNull(), "created_at": 1_700_000_002_000,
    ]

    // MARK: Decoding

    func testAskingCommentDecodesItsActionsAndTheChoice() throws {
        var json = Self.commentJSON
        json["actions"] = ["Go", "Wait"]
        json["chosen_action"] = "Wait"
        json["reply_to"] = NSNull()
        let comment = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(comment.actions, ["Go", "Wait"])
        XCTAssertEqual(comment.chosenAction, "Wait")
        XCTAssertNil(comment.replyTo)
        XCTAssertNil(comment.action)
    }

    func testTapDecodesReplyToFromTheTopLevelOrFromMeta() throws {
        var json = Self.commentJSON
        json["author"] = "user"; json["body"] = "Go"; json["action"] = "Go"; json["reply_to"] = "ic_ask"
        json["actions"] = [String](); json["chosen_action"] = NSNull()
        let lifted = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(lifted.action, "Go")
        XCTAssertEqual(lifted.replyTo, "ic_ask")
        XCTAssertEqual(lifted.actions, [])

        json.removeValue(forKey: "action"); json.removeValue(forKey: "reply_to")
        json["meta"] = ["action": "Go", "reply_to": "ic_ask"]
        let fromMeta = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(fromMeta.action, "Go")
        XCTAssertEqual(fromMeta.replyTo, "ic_ask")
    }

    func testCommentFromAnOlderJournalHasNoButtons() throws {
        let comment = try XCTUnwrap(TrackerComment(json: Self.commentJSON))
        XCTAssertEqual(comment.actions, [])
        XCTAssertNil(comment.chosenAction)
        XCTAssertNil(comment.replyTo)
    }

    // MARK: Visibility rule

    func testACommentOffersItsActionsOnlyWhileTheItemIsOpen() {
        let asking = TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "Ship it?", actions: ["Go"], chosenAction: "Go")
        XCTAssertEqual(asking.offeredActions(itemIsOpen: true), ["Go"])
        XCTAssertEqual(asking.offeredActions(itemIsOpen: false), [])
        let plain = TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "FYI")
        XCTAssertEqual(plain.offeredActions(itemIsOpen: true), [])
    }

    // MARK: Local store

    func testStoreRoundTripsACommentsButtonsChoiceAndReplyTo() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        try store.replaceComments(itemID: "it_1", [
            TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "Ship it?", createdAt: Date(timeIntervalSince1970: 1),
                           actions: ["Go", "Wait"], chosenAction: "Go"),
            TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: "Go", createdAt: Date(timeIntervalSince1970: 2),
                           action: "Go", replyTo: "ic_1"),
            TrackerComment(id: "ic_3", itemID: "it_1", author: .user, body: "hello", createdAt: Date(timeIntervalSince1970: 3)),
        ])
        let read = try store.comments(itemID: "it_1")
        XCTAssertEqual(read.map(\.actions), [["Go", "Wait"], [], []])
        XCTAssertEqual(read.map(\.chosenAction), ["Go", nil, nil])
        XCTAssertEqual(read.map(\.replyTo), [nil, "ic_1", nil])
        XCTAssertEqual(read.map(\.action), [nil, "Go", nil])
    }

    /// A comment row cached by a build that predates comment buttons has a
    /// `meta_json` without the new keys (or none at all) and still reads.
    func testACommentRowCachedByAnEarlierBuildStillReads() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO item_comment(id, item_id, author, device_id, kind, body, attachments_json, meta_json, created_at)
                VALUES('ic_1', 'it_1', 'user', 9, 'comment', 'Go', '[]', '{"action":"Go"}', 1),
                      ('ic_2', 'it_1', 'agent', 9, 'comment', 'hi', '[]', NULL, 2)
                """)
        }
        let read = try store.comments(itemID: "it_1")
        XCTAssertEqual(read.map(\.action), ["Go", nil])
        XCTAssertEqual(read.map(\.actions), [[], []])
        XCTAssertEqual(read.map(\.chosenAction), [nil, nil])
        XCTAssertEqual(read.map(\.replyTo), [nil, nil])
    }

    func testMarkingAChoiceTouchesOnlyACachedCommentOfThatItemThatOffersTheLabel() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let asking = TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "Ship it?", createdAt: Date(timeIntervalSince1970: 1),
                                    actions: ["Go", "Wait"])
        try store.replaceComments(itemID: "it_1", [asking])

        try store.markCommentActionChosen(itemID: "it_1", commentID: "ic_1", label: "Go")
        XCTAssertEqual(try store.comments(itemID: "it_1"), [asking.choosing("Go")])
        try store.markCommentActionChosen(itemID: "it_1", commentID: "ic_1", label: "Wait")
        XCTAssertEqual(try store.comments(itemID: "it_1").first?.chosenAction, "Wait", "the latest tap wins")

        try store.markCommentActionChosen(itemID: "it_1", commentID: "ic_1", label: "Maybe")
        try store.markCommentActionChosen(itemID: "it_other", commentID: "ic_1", label: "Go")
        try store.markCommentActionChosen(itemID: "it_1", commentID: "ic_missing", label: "Go")
        XCTAssertEqual(try store.comments(itemID: "it_1"), [asking.choosing("Wait")])
        XCTAssertEqual(try store.comments(itemID: "it_other"), [])
    }

    func testOutboxRowReportsTheCommentItsTapAnswers() {
        func row(_ payload: String, op: String = "comment") -> ItemOutboxRecord {
            ItemOutboxRecord(localID: "L1", itemID: "it_1", op: op, payloadJSON: payload, createdAt: 1, attempts: 0, lastError: nil)
        }
        let tap = row(#"{"body":"Go","attachments":[],"action":"Go","replyTo":"ic_ask"}"#)
        XCTAssertEqual(tap.commentAction, "Go")
        XCTAssertEqual(tap.commentReplyTo, "ic_ask")
        XCTAssertNil(row(#"{"body":"Go","attachments":[],"action":"Go"}"#).commentReplyTo, "a tap on the item's own buttons")
        XCTAssertNil(row(#"{"body":"hi","attachments":[]}"#).commentReplyTo)
        XCTAssertNil(row(#"{"replyTo":"ic_ask"}"#, op: "create").commentReplyTo)
    }

    // MARK: API

    func testCommentItemSendsReplyToOnlyWithAnAction() async throws {
        ItemsStubURLProtocol.status = 201
        var tapJSON = Self.commentJSON
        tapJSON["author"] = "user"; tapJSON["body"] = "Go"; tapJSON["action"] = "Go"; tapJSON["reply_to"] = "ic_ask"
        ItemsStubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["item": ItemsAPITests.itemJSON, "comment": tapJSON])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")

        let r = try await api.commentItem(id: "it_1", body: "Go", attachments: [], action: "Go", replyTo: "ic_ask", idempotencyKey: "k")
        XCTAssertEqual(r.comment.replyTo, "ic_ask")
        var sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as! [String: Any]
        XCTAssertEqual(sent["action"] as? String, "Go")
        XCTAssertEqual(sent["reply_to"] as? String, "ic_ask")

        _ = try await api.commentItem(id: "it_1", body: "Go", attachments: [], action: "Go", replyTo: nil, idempotencyKey: "k2")
        sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as! [String: Any]
        XCTAssertNil(sent["reply_to"], "a tap on the item's own buttons names no comment")

        _ = try await api.commentItem(id: "it_1", body: "hi", attachments: [], action: nil, replyTo: "ic_ask", idempotencyKey: "k3")
        sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as! [String: Any]
        XCTAssertNil(sent["reply_to"], "the journal refuses a reply_to without an action")
        XCTAssertNil(sent["action"])
    }
}
