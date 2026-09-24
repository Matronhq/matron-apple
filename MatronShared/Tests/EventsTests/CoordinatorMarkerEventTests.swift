import XCTest
@testable import MatronEvents

final class CoordinatorMarkerEventTests: XCTestCase {
    func testParsesBothRoles() {
        XCTAssertEqual(CoordinatorMarkerEvent.parse(payload: ["role": "assigned"])?.role, .assigned)
        XCTAssertEqual(CoordinatorMarkerEvent.parse(payload: ["role": "released"])?.role, .released)
    }

    func testRejectsAnUnknownOrMissingRole() {
        XCTAssertNil(CoordinatorMarkerEvent.parse(payload: ["role": "promoted"]))
        XCTAssertNil(CoordinatorMarkerEvent.parse(payload: [:]))
    }

    /// Contract copy, verbatim.
    func testMarkerText() {
        XCTAssertEqual(CoordinatorMarkerEvent(role: .assigned).text, "This chat is now the Coordinator")
        XCTAssertEqual(CoordinatorMarkerEvent(role: .released).text, "This chat is no longer the Coordinator")
    }
}
