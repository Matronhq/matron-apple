import XCTest
@testable import MatronChat

final class TimelineItemTests: XCTestCase {
    func test_textKind_equality() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        XCTAssertEqual(a, b)
    }

    func test_differentKinds_areInequal() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.file(url: nil, filename: "x", sizeBytes: nil)
        XCTAssertNotEqual(a, b)
    }

    func test_id_isStable() {
        let item = TimelineItem(
            id: "evt:1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: true
        )
        XCTAssertEqual(item.id, "evt:1")
    }

    func test_sendState_defaultsToSent() {
        let item = TimelineItem(
            id: "evt:1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: true
        )
        XCTAssertEqual(item.sendState, .sent)
    }

    func test_sendState_failed_carriesReason() {
        let a = TimelineItem.SendState.failed(reason: "network")
        let b = TimelineItem.SendState.failed(reason: "network")
        let c = TimelineItem.SendState.failed(reason: "auth")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
