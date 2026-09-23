#if os(macOS)
import XCTest
@testable import MatronMac

/// The shell's side of the history (spec §1, §3, §4): the normalised
/// place it derives from its state, and the pane-route reset that keeps
/// today's "switching conversations shows the new chat's list" behaviour
/// without wiping a restored route. Pure helpers, `MacMissionsNavTests`
/// style — `MacChatListView`'s state is private.
final class MacNavigationShellTests: XCTestCase {
    private let route = MacChatPaneRoute.items(path: ["it_9"])

    func test_place_conversationsCarriesSelectionAndRoute() {
        let place = MacChatListView.place(nav: .conversations, selectedSummaryID: "c1", selectedMissionID: "m1",
                                          selectedDecisionID: "d1", paneRoute: route)
        XCTAssertEqual(place, MacPlace(detail: .conversation(id: "c1", pane: route)))
    }

    /// Review focus 2: an auto-open changes the Conversations selection
    /// while the user reads a mission; the mission place must not carry it,
    /// so the two places differ and Back returns to the mission.
    func test_place_missionsDropsConversationSelection() {
        let before = MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: "m1",
                                           selectedDecisionID: nil, paneRoute: route)
        let after = MacChatListView.place(nav: .missions, selectedSummaryID: "c2", selectedMissionID: "m1",
                                          selectedDecisionID: nil, paneRoute: route)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before, MacPlace(detail: .mission(id: "m1")))
    }

    func test_place_decisions() {
        XCTAssertEqual(MacChatListView.place(nav: .decisions, selectedSummaryID: "c1", selectedMissionID: nil,
                                             selectedDecisionID: "d1", paneRoute: route),
                       MacPlace(detail: .decision(id: "d1")))
    }

    /// "Select a chat" has no pane on screen, so the per-window route is
    /// not part of that place.
    func test_place_emptyConversationSelectionDropsTheRoute() {
        XCTAssertEqual(MacChatListView.place(nav: .conversations, selectedSummaryID: nil, selectedMissionID: nil,
                                             selectedDecisionID: nil, paneRoute: route),
                       MacPlace(detail: .conversation(id: nil, pane: nil)))
    }

    // MARK: Route reset on a conversation switch (spec §3)

    /// A chat that doesn't own the route sees the switch reset from its
    /// first read: an open pane shows its list.
    func test_ownedRoute_otherChatSeesAPushedPaneAsTheList() {
        let owned = MacOwnedPaneRoute(owner: "c1", route: route)
        XCTAssertEqual(owned.route(for: "c1"), route)
        XCTAssertEqual(owned.route(for: "c2"), .items(path: []))
    }

    /// Review focus 3: a sub-chat belongs to its parent and never follows
    /// a switch.
    func test_ownedRoute_otherChatNeverInheritsASubChat() {
        let owned = MacOwnedPaneRoute(owner: "c1", route: .subChat(id: "s1"))
        XCTAssertEqual(owned.route(for: "c1"), .subChat(id: "s1"))
        XCTAssertNil(owned.route(for: "c2"))
    }

    func test_ownedRoute_keepsAnOpenListAndAClosedPane() {
        XCTAssertEqual(MacOwnedPaneRoute(owner: "c1", route: .items(path: [])).route(for: "c2"), .items(path: []))
        XCTAssertNil(MacOwnedPaneRoute(owner: "c1", route: nil).route(for: "c2"))
        XCTAssertNil(MacOwnedPaneRoute(owner: "c1", route: route).route(for: nil), "no chat, no pane")
    }

    /// Leaving every chat drops the owner, so coming back to the same chat
    /// by a click resets like a click; the pane stays open on its list.
    func test_paneRouteLandingOn_nonChatPlaceDropsTheOwner() {
        let owned = MacOwnedPaneRoute(owner: "c1", route: route)
        let left = MacChatListView.paneRoute(owned, landingOn: MacPlace(detail: .mission(id: "m1")))
        XCTAssertEqual(left, MacOwnedPaneRoute(owner: nil, route: route))
        XCTAssertEqual(left.route(for: "c1"), .items(path: []))
        XCTAssertEqual(MacChatListView.paneRoute(owned, landingOn: MacPlace(detail: .conversation(id: nil, pane: nil))).owner, nil)
    }

    /// Landing on a chat that doesn't own the route claims the switch
    /// reset for it; the chat that owns it (a restore sets the owner
    /// first) keeps its route as restored.
    func test_paneRouteLandingOn_otherChatClaimsTheReset_ownerKeepsItsRoute() {
        let owned = MacOwnedPaneRoute(owner: "c1", route: route)
        XCTAssertEqual(MacChatListView.paneRoute(owned, landingOn: MacPlace(detail: .conversation(id: "c2", pane: .items(path: [])))),
                       MacOwnedPaneRoute(owner: "c2", route: .items(path: [])))
        XCTAssertEqual(MacChatListView.paneRoute(owned, landingOn: MacPlace(detail: .conversation(id: "c1", pane: route))), owned)
    }

    /// CodeRabbit, PR #233: c1 has a sub-chat open, the user clicks c2
    /// (which shows no pane, so never writes the route), then clicks c1
    /// again. A click resets: c1 must NOT reopen the sub-chat.
    func test_paneRouteLandingOn_switchAwayAndBack_doesNotResurfaceASubChat() {
        var owned = MacOwnedPaneRoute(owner: "c1", route: .subChat(id: "s1"))
        owned = MacChatListView.paneRoute(owned, landingOn: MacPlace(detail: .conversation(id: "c2", pane: nil)))
        owned = MacChatListView.paneRoute(owned, landingOn: MacPlace(detail: .conversation(id: "c1", pane: nil)))
        XCTAssertNil(owned.route(for: "c1"))
    }

    /// Review M3: the empty launch state is never the first entry, so a
    /// cold-start auto-open doesn't leave a Back onto "Select a chat".
    func test_isRecordable_skipsTheEmptyLaunchStateOnly() {
        let empty = MacPlace(detail: .conversation(id: nil, pane: nil))
        XCTAssertFalse(MacChatListView.isRecordable(empty, historyIsEmpty: true))
        XCTAssertTrue(MacChatListView.isRecordable(empty, historyIsEmpty: false))
        XCTAssertTrue(MacChatListView.isRecordable(MacPlace(detail: .conversation(id: "c1", pane: nil)), historyIsEmpty: true))
        XCTAssertTrue(MacChatListView.isRecordable(MacPlace(detail: .mission(id: nil)), historyIsEmpty: true))
    }
}
#endif
