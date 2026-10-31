#if os(macOS)
import XCTest
@testable import MatronMac

/// Window and split-view frames saved under SwiftUI type names go; the
/// main window's id-named frame, other windows' frames and every other key
/// stay.
final class StaleAutosaveKeysTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "StaleAutosaveKeysTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_framesNamedAfterSwiftUITypesGo_andEverythingElseStays() {
        let stale = [
            "NSWindow Frame SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1",
            "NSWindow Frame SwiftUI.ModifiedContent<(unknown context at $2)>-1-AppWindow-1",
            "NSSplitView Subview Frames SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1, SidebarNavigationSplitView",
        ]
        let kept = [
            "NSWindow Frame main-AppWindow-1",
            "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView",
            "NSWindow Frame com_apple_SwiftUI_Settings_window",
            "launch.last",
        ]
        for key in stale + kept { defaults.set("0 0 800 600", forKey: key) }

        XCTAssertEqual(StaleAutosaveKeys.prune(defaults, domain: suiteName), 3)

        for key in stale { XCTAssertNil(defaults.object(forKey: key), key) }
        for key in kept { XCTAssertNotNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(StaleAutosaveKeys.staleKeys(in: defaults, domain: suiteName), [])
    }

    func test_nothingStale_removesNothing() {
        defaults.set("0 0 800 600", forKey: "NSWindow Frame main-AppWindow-1")

        XCTAssertEqual(StaleAutosaveKeys.prune(defaults, domain: suiteName), 0)
        XCTAssertNotNil(defaults.object(forKey: "NSWindow Frame main-AppWindow-1"))
    }
}
#endif
