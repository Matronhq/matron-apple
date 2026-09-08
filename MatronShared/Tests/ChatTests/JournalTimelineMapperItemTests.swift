import XCTest
import MatronJournal
import MatronEvents
@testable import MatronChat

/// PR B / Task 13 — the tracker marker branch in `JournalTimelineMapper`
/// (spec 2026-09-08). `created`/`closed` map to `.itemMarker` so the row
/// renders a card; `reordered` and malformed payloads stay hidden (see
/// `JournalTimelineMapperTests.testItemMarkerUpdatedIsSkippedInTimeline`
/// for the `.updated` half of the controller ruling).
final class JournalTimelineMapperItemTests: XCTestCase {
    private func event(_ payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: 7, convoID: "c1", ts: Date(), sender: "agent:dev-2", type: "item", payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }
    private let base: [String: Any] = ["item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "by": "agent", "awaiting": "user", "resolution": NSNull()]

    func testCreatedMapsToItemMarker() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(from: event(base.merging(["action": "created"]) { $1 }), ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .itemMarker(let id, let marker) = item.kind else { return XCTFail("\(item.kind)") }
        XCTAssertEqual(id, "7"); XCTAssertEqual(marker.action, .created); XCTAssertEqual(marker.num, 12)
    }

    func testReorderedAndMalformedAreHidden() {
        XCTAssertNil(JournalTimelineMapper.timelineItem(from: event(base.merging(["action": "reordered"]) { $1 }), ownSender: "u", serverURL: URL(string: "https://j")!))
        XCTAssertNil(JournalTimelineMapper.timelineItem(from: event(["action": "created"]), ownSender: "u", serverURL: URL(string: "https://j")!))
    }
}
