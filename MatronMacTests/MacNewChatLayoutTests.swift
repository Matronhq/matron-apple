#if os(macOS)
import XCTest
@testable import MatronMac

/// Pins the New Chat sheet's rigid sizing rule: 70% of the window's width
/// (480…880) and 60% of its height (300…650) for the lists, with today's
/// exact dimensions when no window size is known (previews, tests).
final class MacNewChatLayoutTests: XCTestCase {
    func test_nilWindow_usesLegacyDimensions() {
        let layout = MacNewChatSheet.layout(for: nil)
        XCTAssertEqual(layout.width, 480)
        XCTAssertEqual(layout.listMaxHeight, 360)
    }

    func test_mediumWindow_scalesProportionally() {
        let layout = MacNewChatSheet.layout(for: CGSize(width: 900, height: 600))
        XCTAssertEqual(layout.width, 630)          // 0.7 × 900
        XCTAssertEqual(layout.listMaxHeight, 360)  // 0.6 × 600
    }

    func test_largeWindow_clampsToCeilings() {
        let layout = MacNewChatSheet.layout(for: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(layout.width, 880)
        XCTAssertEqual(layout.listMaxHeight, 650)
    }

    func test_tinyWindow_clampsToFloors() {
        let layout = MacNewChatSheet.layout(for: CGSize(width: 500, height: 400))
        XCTAssertEqual(layout.width, 480)
        XCTAssertEqual(layout.listMaxHeight, 300)
    }
}
#endif
