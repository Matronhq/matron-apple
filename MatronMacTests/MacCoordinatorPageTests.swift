#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

/// Decision #2911: the Coordinator is BOTH a nav-column page (⌘1) and a
/// panel over Missions / Decisions / Conversations (⌘0) — never both at
/// once. Pure helpers, `MacMissionsNavTests` style: `MacChatListView`'s
/// state is private.
@MainActor
final class MacCoordinatorPageTests: XCTestCase {
    // MARK: Nav entry + shortcuts

    func test_coordinatorIsTheTopNavEntry() {
        XCTAssertEqual(MacNav.allCases.first, .coordinator)
        XCTAssertEqual(MacNav.coordinator.title, "Coordinator")
        XCTAssertEqual(MacNav.coordinator.symbol, "person.crop.circle.badge.checkmark")
    }

    /// View menu: ⌘1…⌘4 walk the nav column top to bottom, each posting
    /// its own bus command.
    func test_viewMenuShortcuts_areCmd1To4_topToBottom() {
        let shortcuts = ChatCommands.navShortcuts
        XCTAssertEqual(shortcuts.map(\.nav), [.coordinator, .missions, .decisions, .conversations])
        XCTAssertEqual(shortcuts.map(\.key), ["1", "2", "3", "4"])
        XCTAssertEqual(shortcuts.map(\.command), [.showCoordinator, .showMissions, .showDecisions, .showConversations])
        XCTAssertEqual(shortcuts.map(\.title), shortcuts.map(\.nav.title), "menu titles are the nav entries' titles")
    }

    /// The Go menu's ⌘0 item names the PANEL, so it can't be confused
    /// with View ▸ Coordinator (⌘1).
    func test_goMenuPanelItem_namesThePanel() {
        XCTAssertEqual(ChatCommands.coordinatorPanelMenuTitle(isOpen: false), "Show Coordinator Panel")
        XCTAssertEqual(ChatCommands.coordinatorPanelMenuTitle(isOpen: true), "Hide Coordinator Panel")
    }

    // MARK: Panel suppression

    /// While the Coordinator page is showing, the panel is not rendered,
    /// but its stored open state is untouched — it comes back on leaving.
    func test_panelIsSuppressedOnTheCoordinatorPage_andReturnsAfter() {
        XCTAssertFalse(MacChatListView.panelShown(open: true, nav: .coordinator))
        for nav in [MacNav.missions, .decisions, .conversations] {
            XCTAssertTrue(MacChatListView.panelShown(open: true, nav: nav), "\(nav)")
            XCTAssertFalse(MacChatListView.panelShown(open: false, nav: nav), "\(nav)")
        }
    }

    /// ⌘0, Go ▸ Coordinator panel and the toolbar toggle all do nothing on
    /// the Coordinator page.
    func test_panelToggleIsDisabledOnTheCoordinatorPage() {
        XCTAssertFalse(MacChatListView.canToggleCoordinatorPanel(nav: .coordinator))
        XCTAssertTrue(MacChatListView.canToggleCoordinatorPanel(nav: .missions))
        XCTAssertTrue(MacChatListView.canToggleCoordinatorPanel(nav: .decisions))
        XCTAssertTrue(MacChatListView.canToggleCoordinatorPanel(nav: .conversations))
    }

    func test_toggleHelp_saysTheCoordinatorIsOpenWhileDisabled() {
        XCTAssertEqual(MacCoordinatorToolbarToggle.help(isOpen: false, enabled: false), "Coordinator is open")
        XCTAssertEqual(MacCoordinatorToolbarToggle.help(isOpen: true, enabled: false), "Coordinator is open")
        XCTAssertEqual(MacCoordinatorToolbarToggle.help(isOpen: false, enabled: true), "Show Coordinator (⌘0)")
        XCTAssertEqual(MacCoordinatorToolbarToggle.help(isOpen: true, enabled: true), "Hide Coordinator (⌘0)")
    }

    // MARK: No dual mount

    /// The Coordinator's conversation is never mounted by the panel and
    /// the detail at once — whatever the nav entry, the stored panel
    /// state, and the Conversations selection (which may still name the
    /// Coordinator after a restore or a Coordinator change).
    func test_panelAndDetailNeverBothMountTheCoordinator() {
        let coordinatorIDs: [String?] = ["k", nil, ""]
        let selections: [String?] = ["k", "c1", nil]
        for nav in MacNav.allCases {
            for open in [true, false] {
                for coordinator in coordinatorIDs {
                    for selected in selections {
                        for stale in [true, false] {
                            let detail = MacChatListView.detailChatID(nav: nav, selectedSummaryID: selected,
                                                                      coordinatorConvoID: coordinator,
                                                                      isStaleRestore: stale)
                            let panel = MacChatListView.panelShown(open: open, nav: nav)
                            let panelMountsCoordinator = panel && coordinator?.isEmpty == false
                            XCTAssertFalse(panelMountsCoordinator && detail != nil && detail == coordinator,
                                           "dual mount: nav=\(nav) open=\(open) coord=\(coordinator ?? "nil") sel=\(selected ?? "nil")")
                        }
                    }
                }
            }
        }
    }

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

    /// Making the open conversation the Coordinator while on the page must
    /// not flip the (suppressed) panel's stored state open behind it.
    func test_coordinatorChangeOnThePage_leavesThePanelStateAlone() {
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c1",
                                                                     onCoordinatorPage: true),
                       .init(selection: nil, opensPanel: false))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c1",
                                                                     onCoordinatorPage: false),
                       .init(selection: nil, opensPanel: true))
    }

    // MARK: Find in Chat

    /// ⌘F on the Coordinator page opens the page's own chat (the panel is
    /// suppressed there), and only while its column is on screen.
    func test_find_onTheCoordinatorPage_picksTheMainChat() {
        let main = MacChatListView.mainChatForFind(nav: .coordinator, searchResultsShown: false,
                                                   detailChatID: "k", columnShown: true)
        XCTAssertEqual(main, "k")
        XCTAssertEqual(MacFindInChatRouting.target(focusInPanel: false, panelHasChat: false,
                                                   mainHasChat: main != nil, globalSearchAvailable: false), .main)
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
        XCTAssertTrue(MacChatListView.canFindInChat(panelHasChat: false, panelColumnShown: false,
                                                    onConversations: false, mainHasChat: true))
        XCTAssertFalse(MacChatListView.canFindInChat(panelHasChat: false, panelColumnShown: false,
                                                     onConversations: false, mainHasChat: false))
    }

    // MARK: Sidebar

    /// The page collapses the sidebar to the nav column alone.
    func test_sidebarWidths_collapseToTheNavColumnOnTheCoordinatorPage() {
        let coordinator = MacChatListView.sidebarWidths(for: .coordinator)
        XCTAssertEqual(coordinator.min, MacNavColumn.width)
        XCTAssertEqual(coordinator.ideal, MacNavColumn.width)
        XCTAssertEqual(coordinator.max, MacNavColumn.width)
        for nav in [MacNav.missions, .decisions, .conversations] {
            let widths = MacChatListView.sidebarWidths(for: nav)
            XCTAssertEqual(widths.min, 260 + MacNavColumn.width)
            XCTAssertEqual(widths.ideal, 400 + MacNavColumn.width)
            XCTAssertEqual(widths.max, 600 + MacNavColumn.width)
        }
    }
}
#endif
