import XCTest
@testable import MatronJournal

final class CoordinatorConsentDecodeTests: XCTestCase {
    func test_decodesTheConsentKey() {
        XCTAssertEqual(JournalAPI.decodeCoordinatorConsent(["convo_id": "c1", "consent": false]), false)
        XCTAssertEqual(JournalAPI.decodeCoordinatorConsent(["convo_id": NSNull(), "consent": true]), true)
        // A journal predating the switch: no key, so the row stays hidden.
        XCTAssertNil(JournalAPI.decodeCoordinatorConsent(["convo_id": "c1"]))
    }
}
