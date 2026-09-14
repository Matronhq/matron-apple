import XCTest
import MatronModels
@testable import MatronEvents

final class ItemMarkerEventTests: XCTestCase {
    func testParsesCommentedMarker() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "action": "commented",
            "by": "user", "awaiting": "agent", "resolution": NSNull(),
            "comment": ["id": "ic_1", "body": "use A", "attachments": [["blob_ref": "b", "mime": "audio/mp4", "name": "v.m4a", "size": 1, "transcript": NSNull()]]],
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.num, 12); XCTAssertEqual(m.action, .commented); XCTAssertEqual(m.by, .user)
        XCTAssertEqual(m.awaiting, .agent); XCTAssertNil(m.resolution)
        XCTAssertEqual(m.comment?.body, "use A"); XCTAssertTrue(m.comment!.attachments[0].isAudio)
    }

    func testRejectsUnknownActionOrMissingKeys() {
        XCTAssertNil(ItemMarkerEvent.parse(payload: ["item_id": "it_1", "num": 1, "kind": "task", "title": "t", "action": "exploded", "by": "agent"]))
        XCTAssertNil(ItemMarkerEvent.parse(payload: ["num": 1, "kind": "task", "title": "t", "action": "created", "by": "agent"]))
    }

    func testParsesUpdatedMarker() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 3, "kind": "task", "title": "Ship it", "action": "updated", "by": "agent",
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.action, .updated)
    }
}
