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

final class KeyboardDismissTextDragTests: XCTestCase {
    private let field = CGRect(x: 40, y: 16, width: 240, height: 120)
    private let pullDown = CGSize(width: 2, height: 80)

    func testDraggingASelectionHandleDownNeverDismisses() {
        // A drag that starts on the text: a selection handle inside the
        // field, the caret being moved.
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: pullDown,
                                                     startLocation: CGPoint(x: 160, y: 100),
                                                     textFrames: [field]))
    }

    func testAHandleHangingJustBelowTheFieldNeverDismisses() {
        // The knob of the end handle sits under the last line, a little
        // outside the field's frame.
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: pullDown,
                                                     startLocation: CGPoint(x: 200, y: field.maxY + 10),
                                                     textFrames: [field]))
    }

    func testPullingDownElsewhereOnTheRowStillDismisses() {
        XCTAssertTrue(KeyboardDismiss.shouldDismiss(translation: pullDown,
                                                    startLocation: CGPoint(x: 10, y: 120),
                                                    textFrames: [field]))
        XCTAssertTrue(KeyboardDismiss.shouldDismiss(translation: pullDown,
                                                    startLocation: CGPoint(x: 160, y: field.maxY + 30),
                                                    textFrames: [field]))
    }

    func testARowWithNoMarkedFieldBehavesAsBefore() {
        XCTAssertTrue(KeyboardDismiss.shouldDismiss(translation: pullDown,
                                                    startLocation: CGPoint(x: 160, y: 100),
                                                    textFrames: []))
        XCTAssertFalse(KeyboardDismiss.shouldDismiss(translation: CGSize(width: 0, height: -60),
                                                     startLocation: CGPoint(x: 10, y: 120),
                                                     textFrames: [field]))
    }
}

