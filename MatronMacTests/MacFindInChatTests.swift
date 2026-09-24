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

    /// Overlay mode (detail narrower than the panel's minimum): the main
    /// chat spans the whole detail UNDER the panel, so its composer's
    /// centre can fall inside the panel's rect. It is still the main chat's
    /// (review I2).
    func test_overlay_mainResponderUnderThePanelIsNotInThePanel() {
        let panel = CGRect(x: 320, y: 0, width: 380, height: 600)
        XCTAssertFalse(MacFocusRegion.contains(responderRect: CGRect(x: 0, y: 20, width: 700, height: 60),
                                               regionRect: panel))
        XCTAssertTrue(MacFocusRegion.contains(responderRect: CGRect(x: 332, y: 20, width: 356, height: 60),
                                              regionRect: panel))
    }

    /// A 3000 pt reply's text view in the panel's transcript: its bounds
    /// centre is far off the window, its VISIBLE part is in the panel
    /// (review I1).
    @MainActor
    func test_region_tallResponderIsJudgedByItsVisiblePart() {
        let (window, content) = makeWindow()
        let probe = NSView(frame: NSRect(x: 620, y: 0, width: 380, height: 600))
        content.addSubview(probe)
        let scroll = NSScrollView(frame: NSRect(x: 630, y: 0, width: 360, height: 600))
        let tall = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 3000))
        // Fixed height: an empty text view would otherwise shrink to fit.
        tall.isVerticallyResizable = false
        scroll.documentView = tall
        tall.setFrameSize(NSSize(width: 360, height: 3000))
        content.addSubview(scroll)
        XCTAssertEqual(tall.frame.height, 3000, "the reply really is taller than the window")
        let region = MacFocusRegion()
        region.view = probe

        window.makeFirstResponder(tall)
        XCTAssertTrue(region.containsFirstResponder())
    }

    /// A responder scrolled out of view has no visible part, so it claims
    /// nothing — even when its geometric position projects onto the panel
    /// (here: the main chat's content scrolled sideways under the panel).
    @MainActor
    func test_region_scrolledOutResponderClaimsNothing() {
        let (window, content) = makeWindow()
        let probe = NSView(frame: NSRect(x: 620, y: 0, width: 380, height: 600))
        content.addSubview(probe)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 600))
        let hidden = NSTextView(frame: NSRect(x: 700, y: 100, width: 200, height: 40))
        document.addSubview(hidden)
        scroll.documentView = document
        content.addSubview(scroll)
        let region = MacFocusRegion()
        region.view = probe

        window.makeFirstResponder(hidden)
        XCTAssertFalse(region.containsFirstResponder())
    }

    @MainActor
    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = content
        return (window, content)
    }

    /// A chat whose column is not rendered (a sub-chat or the items pane
    /// taking over a narrow detail) is not a find target: opening its bar
    /// would leave an invisible search behind (review I3).
    func test_mainChatForFind_needsItsColumnOnScreen() {
        XCTAssertEqual(MacChatListView.mainChatForFind(onConversations: true, searchResultsShown: false,
                                                       selectedChatShown: "c1", columnShown: true), "c1")
        XCTAssertNil(MacChatListView.mainChatForFind(onConversations: true, searchResultsShown: false,
                                                     selectedChatShown: "c1", columnShown: false))
        XCTAssertNil(MacChatListView.mainChatForFind(onConversations: false, searchResultsShown: false,
                                                     selectedChatShown: "c1", columnShown: true))
        XCTAssertNil(MacChatListView.mainChatForFind(onConversations: true, searchResultsShown: true,
                                                     selectedChatShown: "c1", columnShown: true))
        XCTAssertNil(MacChatListView.mainChatForFind(onConversations: true, searchResultsShown: false,
                                                     selectedChatShown: nil, columnShown: true))
    }

    /// The column's presence counts appear/disappear pairs, so a branch move
    /// (the new instance appearing before the old one disappears) never
    /// reads as "gone".
    @MainActor
    func test_chatColumnPresence_survivesOverlappingBranchMoves() {
        let presence = MacChatColumnPresence()
        XCTAssertFalse(presence.isShown)
        presence.appeared()
        presence.appeared()
        presence.disappeared()
        XCTAssertTrue(presence.isShown)
        presence.disappeared()
        XCTAssertFalse(presence.isShown)
        presence.disappeared()
        XCTAssertFalse(presence.isShown, "never negative")
        presence.appeared()
        XCTAssertTrue(presence.isShown)
    }

    /// Menu item enabled only when something can answer it (review M2).
    func test_findInChatAvailability() {
        XCTAssertTrue(MacChatListView.canFindInChat(panelHasChat: true, onConversations: false))
        XCTAssertTrue(MacChatListView.canFindInChat(panelHasChat: false, onConversations: true))
        XCTAssertFalse(MacChatListView.canFindInChat(panelHasChat: false, onConversations: false))
    }

    /// Find in Chat is a per-window action (`MacNavigationActions`), not a
    /// bus command: a post would reach every window's listener.
    func test_findInChat_isNotABusCommand() {
        XCTAssertNil(MatronCommand(rawValue: "findInChat"))
        XCTAssertFalse(MatronCommand.allCases.map(\.rawValue).contains { $0.lowercased().contains("find") })
        var fired = false
        let actions = MacNavigationActions(canGoBack: false, canGoForward: false, goBack: {}, goForward: {},
                                           findInChat: { fired = true })
        actions.findInChat?()
        XCTAssertTrue(fired, "the key window's own action is what the menu calls")
    }
}
#endif
