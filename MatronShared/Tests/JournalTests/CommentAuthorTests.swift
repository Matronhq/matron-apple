import GRDB
import XCTest
import MatronModels
@testable import MatronJournal

/// Comment author: `device_name` / `convo_id` / `convo_title` on an agent's
/// comment say which box, and which conversation on it, wrote the comment.
/// A journal that predates them sends none, and the caption falls back to
/// "Agent".
final class CommentAuthorTests: XCTestCase {
    private static let commentJSON: [String: Any] = [
        "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "agent", "device_id": 9, "kind": "comment",
        "body": "Done.", "attachments": [], "meta": NSNull(), "idem_key": NSNull(), "created_at": 1_700_000_002_000,
    ]

    func testAgentCommentDecodesItsBoxAndConversation() throws {
        var json = Self.commentJSON
        json["device_name"] = "box-a"; json["convo_id"] = "c1"; json["convo_title"] = "Audit\n the  runners"
        let comment = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(comment.deviceName, "box-a")
        XCTAssertEqual(comment.authorName, "box-a")
        XCTAssertEqual(comment.authorConversation?.id, "c1")
        // One line, whatever the title holds.
        XCTAssertEqual(comment.authorConversation?.title, "Audit the runners")
    }

    func testCommentFromAnOlderJournalIsHeadedAgent() throws {
        let comment = try XCTUnwrap(TrackerComment(json: Self.commentJSON))
        XCTAssertNil(comment.deviceName); XCTAssertNil(comment.convoID); XCTAssertNil(comment.convoTitle)
        XCTAssertEqual(comment.authorName, "Agent")
        XCTAssertNil(comment.authorConversation)
    }

    func testNullsAndBlanksNameNothing() throws {
        var json = Self.commentJSON
        json["device_name"] = "  "; json["convo_id"] = NSNull(); json["convo_title"] = NSNull()
        let blank = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(blank.authorName, "Agent")
        XCTAssertNil(blank.authorConversation)
        // A conversation the journal could not title is not offered as a link.
        json["device_name"] = "box-a"; json["convo_id"] = "c1"
        let untitled = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(untitled.authorName, "box-a")
        XCTAssertNil(untitled.authorConversation)
    }

    func testTheUsersOwnCommentIsAlwaysYou() {
        let mine = TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: "ok",
                                  deviceName: "box-a", convoID: "c1", convoTitle: "Audit")
        XCTAssertEqual(mine.authorName, "You")
        XCTAssertNil(mine.authorConversation)
    }

    func testChoosingAButtonKeepsTheAuthor() {
        let asking = TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "Ship it?", actions: ["Go"],
                                    deviceName: "box-a", convoID: "c1", convoTitle: "Audit")
        let chosen = asking.choosing("Go")
        XCTAssertEqual(chosen.authorName, "box-a")
        XCTAssertEqual(chosen.authorConversation?.title, "Audit")
    }

    func testStoreRoundTripsTheAuthor() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        try store.replaceComments(itemID: "it_1", [
            TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "one", createdAt: Date(timeIntervalSince1970: 1),
                           deviceName: "box-a", convoID: "c1", convoTitle: "Audit"),
            TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "two", createdAt: Date(timeIntervalSince1970: 2),
                           deviceName: "box-b"),
            TrackerComment(id: "ic_3", itemID: "it_1", author: .user, body: "three", createdAt: Date(timeIntervalSince1970: 3)),
        ])
        let read = try store.comments(itemID: "it_1")
        XCTAssertEqual(read.map(\.deviceName), ["box-a", "box-b", nil])
        XCTAssertEqual(read.map(\.convoID), ["c1", nil, nil])
        XCTAssertEqual(read.map(\.convoTitle), ["Audit", nil, nil])
    }
}
