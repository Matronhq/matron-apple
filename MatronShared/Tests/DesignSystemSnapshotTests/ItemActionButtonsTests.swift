import XCTest
@testable import MatronDesignSystem

/// Pins `ItemDetailView.showsActions` — when the item action-button row
/// draws under the body card (contract 2026-09-24).
final class ItemActionButtonsTests: XCTestCase {
    func testShowsForAnOpenItemWithActions() {
        XCTAssertTrue(ItemDetailView.showsActions(["Go"], isOpen: true))
    }

    func testHiddenWithoutActions() {
        XCTAssertFalse(ItemDetailView.showsActions([], isOpen: true))
    }

    func testHiddenOnceClosed() {
        XCTAssertFalse(ItemDetailView.showsActions(["Go", "Wait"], isOpen: false))
    }
}
