#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// Tracker #2864 A — ⌘F (Edit ▸ Find in Chat) opens the in-chat search bar
/// on the chat that has focus in the key window: the Coordinator panel's
/// when focus is in the panel, otherwise the main chat. Never both, and
/// never another window's (it is a per-window action, not a bus post).
final class MacFindInChatTests: XCTestCase {

    func test_focusInPanel_opensThePanelChat() {
        XCTAssertEqual(MacFindInChatRouting.target(focusInPanel: true, panelHasChat: true,
                                                   mainHasChat: true, globalSearchAvailable: true),
                       .panel)
    }

    func test_focusElsewhere_opensTheMainChat() {
        XCTAssertEqual(MacFindInChatRouting.target(focusInPanel: false, panelHasChat: true,
                                                   mainHasChat: true, globalSearchAvailable: true),
                       .main)
    }

    /// The panel shows the chooser (no Coordinator set): focus there still
    /// finds in the main chat rather than doing nothing.
    func test_focusInAPanelWithoutAChat_fallsBackToMain() {
        XCTAssertEqual(MacFindInChatRouting.target(focusInPanel: true, panelHasChat: false,
                                                   mainHasChat: true, globalSearchAvailable: true),
                       .main)
    }

    /// Missions / Decisions with the panel open: the panel's chat is the
    /// only chat on screen.
    func test_noMainChat_usesTheOpenPanel() {
        XCTAssertEqual(MacFindInChatRouting.target(focusInPanel: false, panelHasChat: true,
                                                   mainHasChat: false, globalSearchAvailable: false),
                       .panel)
    }

    /// No chat anywhere: ⌘F keeps its old job of focusing the sidebar's
    /// search-all-chats field when it is on screen.
    func test_noChatAnywhere_focusesGlobalSearchOrNothing() {
        XCTAssertEqual(MacFindInChatRouting.target(focusInPanel: false, panelHasChat: false,
                                                   mainHasChat: false, globalSearchAvailable: true),
                       .globalSearch)
        XCTAssertNil(MacFindInChatRouting.target(focusInPanel: false, panelHasChat: false,
                                                 mainHasChat: false, globalSearchAvailable: false))
    }

    /// "Focus in the panel" is decided geometrically: the first responder's
    /// centre inside the panel's window rect.
    func test_regionContains_usesTheResponderCentre() {
        let panel = CGRect(x: 600, y: 0, width: 380, height: 800)
        XCTAssertTrue(MacFocusRegion.contains(responderRect: CGRect(x: 620, y: 20, width: 300, height: 40),
                                              regionRect: panel))
        XCTAssertFalse(MacFocusRegion.contains(responderRect: CGRect(x: 100, y: 20, width: 300, height: 40),
                                               regionRect: panel))
        XCTAssertFalse(MacFocusRegion.contains(responderRect: .zero, regionRect: .zero),
                       "an unmounted probe (zero rect) never claims focus")
    }

    /// Real views in a real window: a text view inside the probe's frame is
    /// "in the panel", one outside it is not, and no first responder or a
    /// probe outside any window claims nothing.
    @MainActor
    func test_region_readsTheWindowsFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = content
        let mainText = NSTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 40))
        let panelText = NSTextView(frame: NSRect(x: 700, y: 20, width: 200, height: 40))
        let probe = NSView(frame: NSRect(x: 620, y: 0, width: 380, height: 600))
        [mainText, panelText, probe].forEach(content.addSubview)
        let region = MacFocusRegion()
        XCTAssertFalse(region.containsFirstResponder(), "no probe view yet")
        region.view = probe

        window.makeFirstResponder(panelText)
        XCTAssertTrue(region.containsFirstResponder())
        window.makeFirstResponder(mainText)
        XCTAssertFalse(region.containsFirstResponder())
        window.makeFirstResponder(nil)
        XCTAssertFalse(region.containsFirstResponder(), "the window itself is not a view in the panel")
    }

    /// Find in Chat is a per-window action (`MacNavigationActions`), not a
    /// bus command: a post would reach every window's listener.
    func test_findInChat_isNotABusCommand() {
        XCTAssertFalse(MatronCommand.allCases.map(\.rawValue).contains { $0.lowercased().contains("find") })
    }
}
#endif
