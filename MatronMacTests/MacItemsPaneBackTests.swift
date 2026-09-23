#if os(macOS)
import XCTest
@testable import MatronMac

/// The Tasks pane's own Back (#2608): one level down its stack, except from
/// the item the pane was opened straight onto, where it closes the pane.
@MainActor
final class MacItemsPaneBackTests: XCTestCase {
    func test_back_popsOneLevel_whenOpenedFromTheList() {
        let state = MacItemsPaneState()
        state.path = ["a", "b"]
        XCTAssertEqual(state.back(), .popped)
        XCTAssertEqual(state.path, ["a"])
        XCTAssertEqual(state.back(), .popped)
        XCTAssertEqual(state.path, [])
        XCTAssertEqual(state.back(), .nothing)
    }

    /// Dan: an item opened from a `#123` link "has a back button that goes
    /// back to the tasks list, which is unexpected".
    func test_back_fromTheItemTheLinkOpened_closesThePane() {
        let state = MacItemsPaneState()
        state.openedOnItem = true
        state.path = ["a"]
        XCTAssertEqual(state.back(), .closePane)
        XCTAssertEqual(state.path, [])
        XCTAssertFalse(state.openedOnItem)
    }

    /// A link inside that item pushed a second one: Back returns to the
    /// first, and only then closes.
    func test_back_afterAPushOnALinkOpenedItem_popsFirst() {
        let state = MacItemsPaneState()
        state.openedOnItem = true
        state.path = ["a", "b"]
        XCTAssertEqual(state.back(), .popped)
        XCTAssertEqual(state.path, ["a"])
        XCTAssertEqual(state.back(), .closePane)
    }
}
#endif
