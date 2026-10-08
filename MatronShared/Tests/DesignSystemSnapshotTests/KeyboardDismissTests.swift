import XCTest
@testable import MatronDesignSystem

final class KeyboardDismissTests: XCTestCase {
    func testDownwardDragPastTheThresholdDismisses() {
        XCTAssertTrue(KeyboardDismiss.shouldDismiss(translation: CGSize(width: 3, height: 24)))
        XCTAssertTrue(KeyboardDismiss.shouldDismiss(translation: CGSize(width: -10, height: 80)))
    }

    func testShortDragDoesNotDismiss() {
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: CGSize(width: 0, height: 23)))
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: .zero))
    }

    func testUpwardDragNeverDismisses() {
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: CGSize(width: 0, height: -60)))
    }

    func testSidewaysDragNeverDismisses() {
        // A selection drag along a line of text moves mostly sideways even
        // when the finger drifts down a little.
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: CGSize(width: 90, height: 30)))
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: CGSize(width: -40, height: 30)))
    }
}
