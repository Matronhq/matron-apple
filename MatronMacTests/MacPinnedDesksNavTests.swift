#if os(macOS)
import XCTest
import MatronChat
import MatronJournal
import MatronModels
@testable import MatronMac

/// Pinned desk chats on the Mac (journal "Pinned desk chats"): nav-column
/// entries under the Coordinator, each a full-width page on its own view
/// models, hidden from the Conversations detail.
final class MacPinnedDesksNavTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)

    func testDesksSitUnderTheCoordinatorInTheUsersOrder() {
        let pins = [ConvoPin(convoID: "b", label: "B"), ConvoPin(convoID: "a", label: "A")]
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: true, pins: pins),
                       [.coordinator, .desk("b"), .desk("a"), .missions, .decisions, .conversations, .memories])
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: false, pins: pins),
                       [.coordinator, .desk("b"), .desk("a"), .decisions, .conversations, .memories])
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: true), MacNav.allCases, "no pins, no change")
    }

    func testADeskIsAFullWidthChatPage() {
        XCTAssertTrue(MacNav.desk("a").isChatPage)
        XCTAssertTrue(MacNav.coordinator.isChatPage)
        XCTAssertFalse(MacNav.conversations.isChatPage)
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.desk("a")))
        XCTAssertEqual(MacChatListView.sidebarWidths(for: .desk("a")).ideal, MacNavColumn.width)
    }

    func testBadgesCarryUnreadAndNeedsYouForTheCoordinatorAndDesks() {
        let coordinator = ChatSummary(id: "co", title: "Co", bot: bot, lastActivity: nil, unreadCount: 2, needsUserCount: 1)
        let desk = ChatSummary(id: "d", title: "D", bot: bot, lastActivity: nil, unreadCount: 5, needsUserCount: 3)
        let badges = MacChatListView.navBadges(decisions: 4, missions: 0, coordinator: coordinator, desks: ["d": desk])
        XCTAssertEqual(badges[.coordinator], 2)
        XCTAssertEqual(badges[.desk("d")], 5)
        XCTAssertEqual(badges[.decisions], 4)
        let needs = MacChatListView.navNeedsYou(coordinator: coordinator, desks: ["d": desk])
        XCTAssertEqual(needs[.coordinator], 1)
        XCTAssertEqual(needs[.desk("d")], 3)
        XCTAssertNil(MacNavColumn.badgeCount([.desk("d"): 0], for: .desk("d")), "zero hides")
    }

    func testAPinnedConversationOpensOnItsPageNeverInTheDetail() {
        let pinned: Set<String> = ["d"]
        XCTAssertEqual(MacChatListView.conversationTarget("d", coordinatorConvoID: "co", pinnedIDs: pinned), .desk)
        XCTAssertEqual(MacChatListView.conversationTarget("co", coordinatorConvoID: "co", pinnedIDs: ["co"]), .coordinator,
                       "the Coordinator stays the Coordinator")
        XCTAssertEqual(MacChatListView.navForShowingConversation("d", coordinatorConvoID: "co", pinnedIDs: pinned), .desk("d"))
        XCTAssertEqual(MacChatListView.landingForShowingConversation("d", selected: "x", coordinatorConvoID: nil, pinnedIDs: pinned),
                       .init(nav: .desk("d"), selection: "x"), "the Conversations selection is left alone")
        XCTAssertFalse(MacChatListView.detailShowsChat("d", coordinatorConvoID: nil, isStaleRestore: false, pinnedIDs: pinned))
        XCTAssertEqual(MacChatListView.detailChatID(nav: .desk("d"), selectedSummaryID: "x", coordinatorConvoID: nil,
                                                    isStaleRestore: false, pinnedIDs: pinned), "d")
        XCTAssertNil(MacChatListView.detailChatID(nav: .desk("gone"), selectedSummaryID: nil, coordinatorConvoID: nil,
                                                  isStaleRestore: false, pinnedIDs: pinned),
                     "a page whose pin went (or is missing) mounts no chat")
        XCTAssertEqual(MacChatListView.mainChatForFind(nav: .desk("d"), searchResultsShown: false,
                                                       detailChatID: "d", columnShown: true), "d")
    }

    func testADeskPageIsAPlaceWithItsOwnPaneRoute() {
        let place = MacChatListView.place(nav: .desk("d"), selectedSummaryID: "x", selectedMissionID: nil,
                                          selectedDecisionID: nil, paneRoute: .items(path: []), coordinatorConvoID: nil)
        XCTAssertEqual(place, MacPlace(detail: .desk(id: "d", pane: .items(path: []))))
        XCTAssertEqual(place.nav, .desk("d"))
        XCTAssertEqual(place.displayedConversationID, "d")
        XCTAssertEqual(MacChatListView.routeConvoID(nav: .desk("d"), coordinatorConvoID: "co", selectedSummaryID: "x"), "d")
        XCTAssertEqual(MacChatListView.routeConvoID(nav: .coordinator, coordinatorConvoID: "co", selectedSummaryID: "x"), "co")
        XCTAssertEqual(MacChatListView.routeConvoID(nav: .conversations, coordinatorConvoID: "co", selectedSummaryID: "x"), "x")
    }

    private func pins(_ ids: String...) -> [ConvoPin] { ids.map { ConvoPin(convoID: $0, label: "L-\($0)") } }

    func testPinningTheSelectedChatFollowsItToItsPage() {
        let pinned = MacChatListView.landingAfterPinsChange(selected: "d", nav: .conversations, from: [], to: pins("d"),
                                                            coordinatorConvoID: nil)
        XCTAssertEqual(pinned, .init(nav: .desk("d"), selection: nil))
        let offScreen = MacChatListView.landingAfterPinsChange(selected: "d", nav: .decisions, from: [], to: pins("d"),
                                                               coordinatorConvoID: nil)
        XCTAssertEqual(offScreen, .init(nav: .decisions, selection: nil), "off screen, the window stays")
        XCTAssertNil(MacChatListView.landingAfterPinsChange(selected: "x", nav: .conversations, from: [], to: pins("d"),
                                                            coordinatorConvoID: nil))
    }

    func testALaterPinsFrameLeavesAPrePinConversationsPlaceAlone() {
        // Back onto a Conversations place recorded before "d" was pinned:
        // a reorder, rename or successor hint must not pull it to the desk.
        let renamed = [ConvoPin(convoID: "d", label: "Renamed"), ConvoPin(convoID: "e", label: "L-e")]
        XCTAssertNil(MacChatListView.landingAfterPinsChange(selected: "d", nav: .conversations, from: pins("e", "d"),
                                                            to: renamed, coordinatorConvoID: nil))
        let foundAgain = [ConvoPin(convoID: "d", label: "L-d", missing: true)]
        XCTAssertEqual(MacChatListView.landingAfterPinsChange(selected: "d", nav: .conversations, from: foundAgain,
                                                              to: pins("d"), coordinatorConvoID: nil),
                       .init(nav: .desk("d"), selection: nil), "a missing pin that came back gets its page again")
    }

    func testCoordinatorEntryAnnouncesNeedsYouThenUnread() {
        XCTAssertEqual(MacNavColumn.accessibilityLabel("Coordinator", needsYou: 2, count: 5),
                       "Coordinator, 2 need you, 5 unread")
    }

    func testUnpinningTheOpenDeskHandsItBackToConversations() {
        let unpinned = MacChatListView.landingAfterPinsChange(selected: nil, nav: .desk("d"), from: pins("d"), to: [],
                                                              coordinatorConvoID: nil)
        XCTAssertEqual(unpinned, .init(nav: .conversations, selection: "d"))
        let missing = [ConvoPin(convoID: "d", label: "L-d", missing: true)]
        XCTAssertNil(MacChatListView.landingAfterPinsChange(selected: nil, nav: .desk("d"), from: pins("d"), to: missing,
                                                            coordinatorConvoID: nil),
                     "a pin that went missing keeps its page, greyed, with Move pin… and Unpin")
    }

    func testTheOpenDeskFollowsItsPinWhenItMoves() {
        let moved = [ConvoPin(convoID: "s", label: "L-d"), ConvoPin(convoID: "e", label: "L-e")]
        let landing = MacChatListView.landingAfterPinsChange(selected: "x", nav: .desk("d"), from: pins("d", "e"), to: moved,
                                                             coordinatorConvoID: nil)
        XCTAssertEqual(landing, .init(nav: .desk("s"), selection: "x"))
        XCTAssertNil(MacChatListView.movedPin("d", from: pins("d"), to: [ConvoPin(convoID: "s", label: "Other")]),
                     "an unpin plus a new pin is not a move")
    }

    func testDeskShortcutsAreControlCommandDigitsInOrder() {
        let shortcuts = ChatCommands.deskShortcuts([(id: "a", label: "Support"), (id: "b", label: "Mail")])
        XCTAssertEqual(shortcuts.map(\.id), ["a", "b"])
        XCTAssertEqual(shortcuts.map(\.key), ["1", "2"])
    }

    func testAHeaderRequestNamesItsConversation() {
        let pin = ConvoPin(convoID: "d", label: "D")
        let actions: [MacPinAction] = [.edit(pin), .move(convoID: "d"), .unpin(convoID: "d"),
                                       .moveToSuccessor(convoID: "d", successorID: "s"), .dismissSuccessor(convoID: "d")]
        for action in actions {
            let note = Notification(name: MacPinRequest.name, userInfo: [MacPinRequest.actionKey: action])
            XCTAssertEqual(MacPinRequest.convoID(of: note), "d")
        }
        XCTAssertEqual(MacPinRequest.convoID(of: Notification(name: MacPinRequest.name,
                                                              userInfo: [MacPinRequest.pinConvoKey: "n"])), "n")
    }

    func testNavLabelsReadTheCountsAndTheHint() {
        XCTAssertEqual(MacNavColumn.accessibilityLabel("Inbox triage", needsYou: 2, count: 3, hint: nil),
                       "Inbox triage, 2 need you, 3 unread")
        XCTAssertEqual(MacNavColumn.accessibilityLabel("Mail", needsYou: nil, count: nil, hint: "conversation gone"),
                       "Mail, conversation gone")
    }
}
#endif
