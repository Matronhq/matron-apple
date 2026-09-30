#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels

/// Decision #2911: the Coordinator is a nav-column page (⌘1), the only
/// way to it on Mac. Pure helpers, `MacMissionsNavTests` style:
/// `MacChatListView`'s state is private.
@MainActor
final class MacCoordinatorPageTests: XCTestCase {
    // MARK: Nav entry + shortcuts

    func test_coordinatorIsTheTopNavEntry() {
        XCTAssertEqual(MacNav.allCases.first, .coordinator)
        XCTAssertEqual(MacNav.coordinator.title, "Coordinator")
        XCTAssertEqual(MacNav.coordinator.symbol, "person.crop.circle.badge.checkmark")
    }

    /// View menu: ⌘1…⌘5 walk the nav column top to bottom, each posting
    /// its own bus command. Memories is last, so ⌘1…⌘4 kept their entries.
    func test_viewMenuShortcuts_areCmd1To5_topToBottom() {
        let shortcuts = ChatCommands.navShortcuts
        XCTAssertEqual(shortcuts.map(\.nav), [.coordinator, .missions, .decisions, .conversations, .memories])
        XCTAssertEqual(shortcuts.map(\.nav), MacNav.allCases)
        XCTAssertEqual(shortcuts.map(\.key), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(shortcuts.map(\.command),
                       [.showCoordinator, .showMissions, .showDecisions, .showConversations, .showMemories])
        XCTAssertEqual(shortcuts.map(\.title), shortcuts.map(\.nav.title), "menu titles are the nav entries' titles")
    }

    /// Final review I4: the Coordinator is hidden from Conversations, so its
    /// unread count badges its own nav entry.
    func test_navBadges_carryTheHiddenCoordinatorsUnread() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "B", avatarURL: nil)
        let unread = ChatSummary(id: "coord", title: "C", bot: bot, lastActivity: nil, unreadCount: 3)
        let read = ChatSummary(id: "coord", title: "C", bot: bot, lastActivity: nil, unreadCount: 0)
        let badges = MacChatListView.navBadges(decisions: 1, missions: 2, coordinator: unread)
        XCTAssertEqual(badges, [.decisions: 1, .missions: 2, .coordinator: 3])
        XCTAssertEqual(MacNavColumn.badgeCount(badges, for: .coordinator), 3)
        XCTAssertNil(MacNavColumn.badgeCount(MacChatListView.navBadges(decisions: 0, missions: 0, coordinator: read),
                                             for: .coordinator))
        XCTAssertNil(MacNavColumn.badgeCount(MacChatListView.navBadges(decisions: 0, missions: 0, coordinator: nil),
                                             for: .coordinator))
    }

    // MARK: Detail

    /// The page shows the Coordinator in the detail; the chooser (no chat)
    /// when none is set.
    func test_detailChatID_onTheCoordinatorPage() {
        XCTAssertEqual(MacChatListView.detailChatID(nav: .coordinator, selectedSummaryID: "c1",
                                                    coordinatorConvoID: "k", isStaleRestore: false), "k")
        XCTAssertNil(MacChatListView.detailChatID(nav: .coordinator, selectedSummaryID: "c1",
                                                  coordinatorConvoID: nil, isStaleRestore: false))
        XCTAssertNil(MacChatListView.detailChatID(nav: .coordinator, selectedSummaryID: "c1",
                                                  coordinatorConvoID: "", isStaleRestore: false))
        XCTAssertEqual(MacChatListView.detailChatID(nav: .conversations, selectedSummaryID: "c1",
                                                    coordinatorConvoID: "k", isStaleRestore: false), "c1")
        XCTAssertNil(MacChatListView.detailChatID(nav: .conversations, selectedSummaryID: "k",
                                                  coordinatorConvoID: "k", isStaleRestore: false),
                     "Conversations never shows the Coordinator")
        XCTAssertNil(MacChatListView.detailChatID(nav: .missions, selectedSummaryID: "c1",
                                                  coordinatorConvoID: "k", isStaleRestore: false))
    }

    // MARK: Routing

    /// A notification tap, search hit, milestone jump or "Open
    /// conversation" into the Coordinator's conversation goes to the
    /// Coordinator page (a recorded place, so Back returns); anything else
    /// goes to Conversations.
    func test_showingTheCoordinatorsConversation_landsOnTheCoordinatorPage() {
        XCTAssertEqual(MacChatListView.navForShowingConversation("k", coordinatorConvoID: "k"), .coordinator)
        XCTAssertEqual(MacChatListView.navForShowingConversation("c1", coordinatorConvoID: "k"), .conversations)
        XCTAssertEqual(MacChatListView.navForShowingConversation("k", coordinatorConvoID: nil), .conversations)
        XCTAssertEqual(MacChatListView.navForShowingConversation("k", coordinatorConvoID: ""), .conversations)
    }

    /// The selected conversation becoming the Coordinator clears the
    /// selection everywhere, but only moves the window to the page from
    /// Conversations, where that chat was on screen.
    func test_coordinatorChange_followsTheOpenChatToThePage_onlyFromConversations() {
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c1",
                                                                     nav: .conversations),
                       .init(selection: nil, showsPage: true))
        for nav in [MacNav.coordinator, .missions, .decisions, .memories] {
            XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c1",
                                                                         nav: nav),
                           .init(selection: nil, showsPage: false), "\(nav)")
        }
    }

    /// Bugbot B2 (PR #234): until the `.task` has read the cached setting,
    /// the Coordinator is read from the cache itself, so the page never
    /// flashes "Choose a conversation…".
    func test_theCachedCoordinatorIsReadBeforeTheFirstRead() {
        XCTAssertEqual(MacChatListView.resolvedCoordinatorID(state: nil, resolved: false, cached: { "coord" }), "coord")
        XCTAssertNil(MacChatListView.resolvedCoordinatorID(state: nil, resolved: true, cached: { "coord" }),
                     "once read, a cleared Coordinator is really cleared")
        XCTAssertEqual(MacChatListView.resolvedCoordinatorID(state: "new", resolved: true, cached: { "old" }), "new")
    }

    /// Bugbot (PR #238): on a cold start a notification tap or search hit
    /// for the Coordinator can run before the `.task` reads the cached
    /// setting. Routing must key off the resolved id, or the detail mounts
    /// a second MacChatView of the Coordinator on the other view-model cache.
    func test_coldStart_routingKeysOffTheResolvedID() {
        let id = MacChatListView.resolvedCoordinatorID(state: nil, resolved: false, cached: { "coord" })
        XCTAssertEqual(MacChatListView.conversationTarget("coord", coordinatorConvoID: id), .coordinator)
        XCTAssertFalse(MacChatListView.detailShowsChat("coord", coordinatorConvoID: id, isStaleRestore: false))
    }

    /// The wiring half of the test above: the raw `@State` mirror of the
    /// setting is read in exactly one place — the resolver every consumer
    /// (`showConversation`, `chatCache`, the detail, restores, the list
    /// filter) goes through. Declaration + write + that one read.
    func test_theRawCoordinatorSettingIsReadOnlyThroughTheResolver() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MatronMac/Features/ChatList/MacChatListView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let uses = text.components(separatedBy: .newlines).filter { $0.contains("coordinatorSettingID") }
        XCTAssertEqual(uses.count, 3, uses.joined(separator: "\n"))
    }

    // MARK: Find in Chat

    /// ⌘F on the Coordinator page opens the page's own chat, and only
    /// while its column is on screen.
    func test_find_onTheCoordinatorPage_picksTheMainChat() {
        let main = MacChatListView.mainChatForFind(nav: .coordinator, searchResultsShown: false,
                                                   detailChatID: "k", columnShown: true)
        XCTAssertEqual(main, "k")
        XCTAssertEqual(MacFindInChatRouting.target(mainHasChat: main != nil, globalSearchAvailable: false), .main)
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .coordinator, searchResultsShown: false,
                                                     detailChatID: "k", columnShown: false),
                     "Tasks or a sub-chat replaced the column")
        XCTAssertNil(MacChatListView.mainChatForFind(nav: .coordinator, searchResultsShown: false,
                                                     detailChatID: nil, columnShown: true),
                     "no Coordinator set: the chooser has nothing to search")
        // Leftover Conversations search results don't cover the page.
        XCTAssertEqual(MacChatListView.mainChatForFind(nav: .coordinator, searchResultsShown: true,
                                                       detailChatID: "k", columnShown: true), "k")
    }

    /// The menu item is enabled on the page exactly when it can act.
    func test_findMenuEnablement_onTheCoordinatorPage() {
        XCTAssertTrue(MacChatListView.canFindInChat(onConversations: false, mainHasChat: true))
        XCTAssertFalse(MacChatListView.canFindInChat(onConversations: false, mainHasChat: false))
    }

    // MARK: Sidebar

    /// The page collapses the sidebar to the nav column alone.
    func test_sidebarWidths_collapseToTheNavColumnOnTheCoordinatorPage() {
        let coordinator = MacChatListView.sidebarWidths(for: .coordinator)
        XCTAssertEqual(coordinator.min, MacNavColumn.width)
        XCTAssertEqual(coordinator.ideal, MacNavColumn.width)
        XCTAssertEqual(coordinator.max, MacNavColumn.width)
        for nav in [MacNav.decisions, .conversations] {
            let widths = MacChatListView.sidebarWidths(for: nav)
            XCTAssertEqual(widths.min, 260 + MacNavColumn.width)
            XCTAssertEqual(widths.ideal, 400 + MacNavColumn.width)
            XCTAssertEqual(widths.max, 600 + MacNavColumn.width)
        }
    }
}
#endif
