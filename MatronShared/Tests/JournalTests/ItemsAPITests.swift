import XCTest
import MatronModels
@testable import MatronJournal

final class ItemsAPITests: XCTestCase {
    static let itemJSON: [String: Any] = [
        "id": "it_1", "user_id": 1, "num": 12, "kind": "question", "state": "open", "resolution": NSNull(),
        "awaiting": "user", "rank": 1024.0, "title": "Which auth?", "body": "A or B", "labels": ["auth"],
        "links": [["url": "https://x", "title": "issue"]],
        "attachments": [["blob_ref": "b1", "mime": "image/png", "name": "s.png", "size": 10]],
        "supersedes": NSNull(), "origin_convo_id": "c1", "origin_device_id": 3, "created_by": "agent",
        "idem_key": NSNull(), "created_at": 1_700_000_000_000, "updated_at": 1_700_000_001_000, "closed_at": NSNull(),
        "comment_count": 2, "last_comment_at": 1_700_000_001_000, "has_image": 1,
    ]

    func testTrackerItemDecodes() throws {
        let item = try XCTUnwrap(TrackerItem(json: Self.itemJSON))
        XCTAssertEqual(item.id, "it_1"); XCTAssertEqual(item.num, 12); XCTAssertEqual(item.kind, .question)
        XCTAssertEqual(item.state, .open); XCTAssertNil(item.resolution); XCTAssertEqual(item.awaiting, .user)
        XCTAssertEqual(item.rank, 1024); XCTAssertEqual(item.labels, ["auth"]); XCTAssertEqual(item.links.first?.url, "https://x")
        XCTAssertEqual(item.attachments.first?.blobRef, "b1"); XCTAssertTrue(item.attachments.first!.isImage)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_700_000_000)); XCTAssertNil(item.closedAt)
        XCTAssertEqual(item.commentCount, 2); XCTAssertTrue(item.hasImage); XCTAssertTrue(item.needsUser)
        XCTAssertEqual(item.createdBy, .agent); XCTAssertEqual(item.originConvoID, "c1")
    }

    func testTrackerItemRejectsMissingKeys() {
        var bad = Self.itemJSON; bad["kind"] = "bug"
        XCTAssertNil(TrackerItem(json: bad))
        bad = Self.itemJSON; bad.removeValue(forKey: "num")
        XCTAssertNil(TrackerItem(json: bad))
    }

    func testTrackerCommentDecodesStatusMeta() throws {
        let json: [String: Any] = [
            "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "user", "device_id": 9, "kind": "status",
            "body": "no", "attachments": [], "meta": ["from": ["state": "open", "resolution": NSNull(), "awaiting": "user"],
                                                    "to": ["state": "closed", "resolution": "reversed", "awaiting": NSNull()]],
            "idem_key": NSNull(), "created_at": 1_700_000_002_000,
        ]
        let c = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(c.kind, .status); XCTAssertEqual(c.author, .user); XCTAssertEqual(c.statusTo?.resolution, .reversed)
        XCTAssertEqual(c.statusFrom?.awaiting, .user); XCTAssertNil(c.statusTo?.awaiting)
    }
}
