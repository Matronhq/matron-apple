import XCTest
@testable import MatronJournal

final class PushBadgeTests: XCTestCase {
    func testAlertPushCarriesTheCount() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "t", "body": "b"], "badge": 7], "seq": 12]
        XCTAssertEqual(PushBadge.count(from: userInfo), 7)
    }

    func testSilentWakeCarriesTheCount() {
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1, "badge": 3]]
        XCTAssertEqual(PushBadge.count(from: userInfo), 3)
    }

    func testNumberFromJSONSerialisation() throws {
        let data = Data(#"{"aps":{"content-available":1,"badge":42}}"#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
        XCTAssertEqual(PushBadge.count(from: object), 42)
    }

    func testZeroClearsTheBadge() {
        let userInfo: [AnyHashable: Any] = ["aps": ["content-available": 1, "badge": 0]]
        XCTAssertEqual(PushBadge.count(from: userInfo), 0)
        XCTAssertNil(PushBadge.label(for: 0))
        XCTAssertEqual(PushBadge.label(for: 5), "5")
    }

    func testNoBadgeKeyLeavesTheBadgeAlone() {
        XCTAssertNil(PushBadge.count(from: ["aps": ["content-available": 1]]))
        XCTAssertNil(PushBadge.count(from: [:]))
    }

    func testMalformedOrNegativeIsIgnored() {
        XCTAssertNil(PushBadge.count(from: ["aps": ["badge": -1]]))
        XCTAssertNil(PushBadge.count(from: ["aps": ["badge": "many"]]))
        XCTAssertNil(PushBadge.count(from: ["aps": "nope"]))
    }
}
