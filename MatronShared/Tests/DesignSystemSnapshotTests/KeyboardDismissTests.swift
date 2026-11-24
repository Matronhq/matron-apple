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

final class KeyboardDismissTextEditingTests: XCTestCase {
    private typealias Other = KeyboardDismiss.OtherGesture

    func testAPlainSwipeOnTheTextIsNotEditing() {
        // A swipe down on the field: the text's tap and loupe gestures
        // have failed or are still waiting, so the pull-down may run.
        XCTAssertFalse(KeyboardDismiss.textIsEditing([
            Other(isOnText: true, isScrollPan: false, isActive: false),
            Other(isOnText: true, isScrollPan: false, isActive: false),
        ]))
    }

    func testMovingTheCaretOrASelectionIsEditing() {
        // The loupe (long press, then drag) or a handle drag has begun.
        XCTAssertTrue(KeyboardDismiss.textIsEditing([
            Other(isOnText: true, isScrollPan: false, isActive: false),
            Other(isOnText: true, isScrollPan: false, isActive: true),
        ]))
    }

    func testScrollingATallDraftIsNotEditing() {
        XCTAssertFalse(KeyboardDismiss.textIsEditing([
            Other(isOnText: true, isScrollPan: true, isActive: true),
        ]))
    }

    func testGesturesOffTheTextDoNotCount() {
        // The timeline's scroll, the navigation back-swipe.
        XCTAssertFalse(KeyboardDismiss.textIsEditing([
            Other(isOnText: false, isScrollPan: true, isActive: true),
            Other(isOnText: false, isScrollPan: false, isActive: true),
        ]))
        XCTAssertFalse(KeyboardDismiss.textIsEditing([]))
    }
}
