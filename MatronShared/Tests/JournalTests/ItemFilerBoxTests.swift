import XCTest
import MatronModels
@testable import MatronJournal

/// An agent's item names the box whose session filed it (`device_name`),
/// so the item's own post is headed with that box, as an agent's comment
/// is headed with the box that wrote it.
final class ItemFilerBoxTests: XCTestCase {
    private let itemJSON: [String: Any] = [
        "id": "it_1", "num": 12, "kind": "notice", "state": "open", "title": "File: fee note",
        "origin_convo_id": "c1", "created_by": "agent",
        "created_at": 1_700_000_000_000, "updated_at": 1_700_000_001_000,
    ]

    func testAnAgentsItemIsHeadedWithTheBoxThatFiledIt() throws {
        var json = itemJSON
        json["device_name"] = "box-2"
        let item = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertEqual(item.deviceName, "box-2")
        XCTAssertEqual(item.filerName, "box-2")
    }

    func testWithoutABoxItFallsBackToAgent() throws {
        XCTAssertEqual(try XCTUnwrap(TrackerItem(json: itemJSON)).filerName, "Agent")
        var json = itemJSON
        json["device_name"] = NSNull()
        XCTAssertEqual(try XCTUnwrap(TrackerItem(json: json)).filerName, "Agent")
        json["device_name"] = "  "
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json)).deviceName)
    }

    func testTheUsersOwnItemAndAContributorsKeepTheirNames() throws {
        var mine = itemJSON
        mine["created_by"] = "user"
        mine["device_name"] = "box-2"
        XCTAssertEqual(try XCTUnwrap(TrackerItem(json: mine)).filerName, "You")
        var theirs = itemJSON
        theirs["device_name"] = "box-2"
        theirs["contributor"] = ["name": "bob", "via": "agent"]
        XCTAssertEqual(try XCTUnwrap(TrackerItem(json: theirs)).filerName, "bob's agent")
    }

    func testTheCacheKeepsTheBox() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        var json = itemJSON
        json["device_name"] = "box-2"
        try store.upsertItems([try XCTUnwrap(TrackerItem(json: json))])
        XCTAssertEqual(try store.item(id: "it_1")?.filerName, "box-2")
    }
}
