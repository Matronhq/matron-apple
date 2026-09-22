#if os(macOS)
import XCTest
@testable import MatronMac

/// `MacItemsPaneChrome` leads its header row with ONE control, so the pane
/// unwinds one level per click.
final class MacItemsPaneChromeTests: XCTestCase {
    func test_leadingControl_isBack_wheneverSomethingIsPushed() {
        XCTAssertEqual(MacItemsPaneLeadingControl.resolve(canGoBack: true, showsBackChevron: false), .back)
        XCTAssertEqual(MacItemsPaneLeadingControl.resolve(canGoBack: true, showsBackChevron: true), .back,
                       "in the narrow takeover a pushed item goes back to the list first, then the list goes back to the chat")
    }

    func test_leadingControl_atTheList_isTheChatChevron_onlyInTheTakeover() {
        XCTAssertEqual(MacItemsPaneLeadingControl.resolve(canGoBack: false, showsBackChevron: true), .toChat)
        XCTAssertEqual(MacItemsPaneLeadingControl.resolve(canGoBack: false, showsBackChevron: false), .absent,
                       "side by side, the trailing ✕ is the only way out")
    }
}
#endif
