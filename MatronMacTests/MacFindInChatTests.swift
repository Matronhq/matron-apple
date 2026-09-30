#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// Tracker #2864 A — ⌘F (Edit ▸ Find in Chat) opens the in-chat search bar
/// on the key window's chat — never another window's (it is a per-window
/// action, not a bus post).
final class MacFindInChatTests: XCTestCase {

    func test_aChatOnScreen_opensItsSearch() {
        XCTAssertEqual(MacFindInChatRouting.target(mainHasChat: true, globalSearchAvailable: true), .main)
    }

    /// No chat on screen: ⌘F keeps its old job of focusing the sidebar's
    /// search-all-chats field when it is on screen.
    func test_noChat_focusesGlobalSearchOrNothing() {
        XCTAssertEqual(MacFindInChatRouting.target(mainHasChat: false, globalSearchAvailable: true), .globalSearch)
        XCTAssertNil(MacFindInChatRouting.target(mainHasChat: false, globalSearchAvailable: false))
    }

    /// A chat whose column is not rendered (a sub-chat or the items pane
    /// taking over a narrow detail) is not a find target: opening its bar
    /// would leave an invisible search behind (review I3).
    func test_mainChatForFind_needsItsColumnOnScreen() {
        XCTAssertEqual(MacChatListView.mainChatForFind(nav: .conversations, searchResultsShown: false,
                                                       detailChatID: "c1", columnShown: true), "c1")
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .conversations, searchResultsShown: false,
                                                     detailChatID: "c1", columnShown: false))
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .missions, searchResultsShown: false,
                                                     detailChatID: "c1", columnShown: true))
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .conversations, searchResultsShown: true,
                                                     detailChatID: "c1", columnShown: true))
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .conversations, searchResultsShown: false,
                                                     detailChatID: nil, columnShown: true))
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

    /// Menu item enabled only when something can answer it (review M2): on
    /// Missions / Decisions / Memories, and on the Coordinator page with its
    /// column replaced, the item greys out rather than doing nothing.
    func test_findInChatAvailability() {
        XCTAssertTrue(MacChatListView.canFindInChat(onConversations: true, mainHasChat: false))
        XCTAssertTrue(MacChatListView.canFindInChat(onConversations: false, mainHasChat: true))
        XCTAssertFalse(MacChatListView.canFindInChat(onConversations: false, mainHasChat: false))
    }

    /// The menu's enabled state is computed in the window's body, so the
    /// chat column's presence must be observable for it to update.
    @MainActor
    func test_chatColumnPresence_isObservable() {
        let presence = MacChatColumnPresence()
        var changed = false
        withObservationTracking { _ = presence.isShown } onChange: { changed = true }
        presence.appeared()
        XCTAssertTrue(changed)
    }

    /// Search All Chats focuses the Conversations sidebar field, so it is
    /// only offered there (Bugbot, PR #236).
    func test_searchAllChatsAvailability() {
        XCTAssertTrue(MacChatListView.canSearchAllChats(onConversations: true))
        XCTAssertFalse(MacChatListView.canSearchAllChats(onConversations: false))
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
