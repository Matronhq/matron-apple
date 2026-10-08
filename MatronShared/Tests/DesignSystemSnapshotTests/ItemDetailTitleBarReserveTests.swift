#if os(macOS)
import XCTest
@testable import MatronDesignSystem

/// Pins the room the Decisions page's header row gives the title-bar ⋯
/// menu (`ItemDetailView.titleBarMenuReserve`): none while the centred
/// measure leaves a wide margin, enough once the pane narrows that the
/// status chip would otherwise sit under the menu.
final class ItemDetailTitleBarReserveTests: XCTestCase {
    func testWidePane_leavesTheChipWhereItIs() {
        XCTAssertEqual(ItemDetailView.titleBarMenuReserve(paneWidth: 1000), 0)
    }

    func testPaneNoWiderThanTheColumn_clearsTheWholeMenu() {
        let reserve = ItemDetailView.titleBarMenuReserve(paneWidth: 500)
        XCTAssertEqual(reserve + ItemDetailView.threadPadding, ItemDetailView.titleBarMenuWidth)
    }

    func testReserveShrinksAsTheMarginGrows() {
        let narrow = ItemDetailView.titleBarMenuReserve(paneWidth: 680)
        let wider = ItemDetailView.titleBarMenuReserve(paneWidth: 700)
        XCTAssertGreaterThan(narrow, wider)
        XCTAssertGreaterThanOrEqual(wider, 0)
    }
}
#endif
