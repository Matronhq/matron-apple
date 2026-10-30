#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// Window and split-view frames saved under earlier builds' type names go;
/// the ones this launch uses, and every other key, stay.
@MainActor
final class StaleAutosaveKeysTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "StaleAutosaveKeysTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let liveWindow = "NSWindow Frame SwiftUI.ModifiedContent<(unknown context at $2)>-1-AppWindow-1"
    private let liveSplit = "NSSplitView Subview Frames SwiftUI.ModifiedContent<(unknown context at $2)>-1-AppWindow-1, SidebarNavigationSplitView"

    func test_framesFromEarlierBuildsGo_andThisLaunchsStay() {
        let oldWindow = "NSWindow Frame SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1"
        let oldSplit = "NSSplitView Subview Frames SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1, SidebarNavigationSplitView"
        for key in [oldWindow, oldSplit, liveWindow, liveSplit] { defaults.set("0 0 800 600", forKey: key) }
        defaults.set(true, forKey: "items.readToEnd.it_1")
        defaults.set("x", forKey: "NSWindow Frame com_apple_SwiftUI_Settings_window")

        let removed = StaleAutosaveKeys.prune(defaults, domain: suiteName, keeping: [liveWindow, liveSplit])

        XCTAssertEqual(removed, 2)
        XCTAssertNil(defaults.object(forKey: oldWindow))
        XCTAssertNil(defaults.object(forKey: oldSplit))
        XCTAssertNotNil(defaults.object(forKey: liveWindow))
        XCTAssertNotNil(defaults.object(forKey: liveSplit))
        XCTAssertNotNil(defaults.object(forKey: "items.readToEnd.it_1"))
        XCTAssertNotNil(defaults.object(forKey: "NSWindow Frame com_apple_SwiftUI_Settings_window"))
    }

    /// Still on the sign-in screen: the split view isn't mounted, so its
    /// saved frames stay.
    func test_withoutALiveSplitView_splitViewFramesStay() {
        let oldWindow = "NSWindow Frame SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1"
        for key in [oldWindow, liveWindow, liveSplit] { defaults.set("0 0 800 600", forKey: key) }

        XCTAssertEqual(StaleAutosaveKeys.prune(defaults, domain: suiteName, keeping: [liveWindow]), 1)
        XCTAssertNil(defaults.object(forKey: oldWindow))
        XCTAssertNotNil(defaults.object(forKey: liveSplit))
    }

    /// A pane's split view that isn't open right now keeps its frames.
    func test_anUnmountedKindOfSplitView_keepsItsFrames() {
        let paneSplit = "NSSplitView Subview Frames SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1, PaneSplitView"
        for key in [liveWindow, liveSplit, paneSplit] { defaults.set("0 0 800 600", forKey: key) }

        XCTAssertEqual(StaleAutosaveKeys.prune(defaults, domain: suiteName, keeping: [liveWindow, liveSplit]), 0)
        XCTAssertNotNil(defaults.object(forKey: paneSplit))
    }

    func test_withoutALiveWindowFrame_nothingGoes() {
        let oldWindow = "NSWindow Frame SwiftUI.ModifiedContent<(unknown context at $1)>-1-AppWindow-1"
        defaults.set("0 0 800 600", forKey: oldWindow)

        XCTAssertEqual(StaleAutosaveKeys.prune(defaults, domain: suiteName, keeping: []), 0)
        XCTAssertEqual(StaleAutosaveKeys.prune(defaults, domain: suiteName, keeping: [liveSplit]), 0)
        XCTAssertNotNil(defaults.object(forKey: oldWindow))
    }

    func test_liveKeys_nameTheWindowFrameAndItsSplitViews() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowName = "SwiftUI.Test-\(UUID().uuidString)"
        window.setFrameAutosaveName(windowName)
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let splitName = "SwiftUI.TestSplit-\(UUID().uuidString)"
        split.autosaveName = splitName
        let container = NSView(frame: split.frame)
        container.addSubview(split)
        window.contentView = container
        defer {
            window.setFrameAutosaveName("")
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(windowName)")
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(splitName)")
            window.close()
        }

        let keys = StaleAutosaveKeys.liveKeys(in: [window])

        XCTAssertTrue(keys.contains("NSWindow Frame \(windowName)"), "\(keys)")
        XCTAssertTrue(keys.contains("NSSplitView Subview Frames \(splitName)"), "\(keys)")
    }
}
#endif
