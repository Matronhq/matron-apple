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

    func test_place_decisionsAndCoordinator() {
        XCTAssertEqual(MacChatListView.place(nav: .decisions, selectedSummaryID: "c1", selectedMissionID: nil,
                                             selectedDecisionID: "d1", paneRoute: route),
                       MacPlace(detail: .decision(id: "d1")))
        XCTAssertEqual(MacChatListView.place(nav: .coordinator, selectedSummaryID: "c1", selectedMissionID: nil,
                                             selectedDecisionID: nil, paneRoute: route),
                       MacPlace(detail: .coordinator(pane: route)))
    }

    /// "Select a chat" has no pane on screen, so the per-window route is
    /// not part of that place.
    func test_place_emptyConversationSelectionDropsTheRoute() {
        XCTAssertEqual(MacChatListView.place(nav: .conversations, selectedSummaryID: nil, selectedMissionID: nil,
                                             selectedDecisionID: nil, paneRoute: route),
                       MacPlace(detail: .conversation(id: nil, pane: nil)))
    }

    // MARK: Route reset on a conversation switch (spec §3)

    func test_paneRouteAfter_switchResetsAPushedPaneToTheList() {
        let from = MacPlace(detail: .conversation(id: "c1", pane: route))
        let to = MacPlace(detail: .conversation(id: "c2", pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: to, previous: from, current: route, coordinatorConvoID: nil),
                       .items(path: []))
    }

    /// Review focus 3.
    func test_paneRouteAfter_switchClearsASubChat() {
        let child = MacChatPaneRoute.subChat(id: "s1")
        let from = MacPlace(detail: .conversation(id: "c1", pane: child))
        let to = MacPlace(detail: .conversation(id: "c2", pane: child))
        XCTAssertNil(MacChatListView.paneRoute(after: to, previous: from, current: child, coordinatorConvoID: nil))
    }

    func test_paneRouteAfter_switchKeepsAnOpenListAndAClosedPane() {
        let from = MacPlace(detail: .conversation(id: "c1", pane: .items(path: [])))
        let to = MacPlace(detail: .conversation(id: "c2", pane: .items(path: [])))
        XCTAssertEqual(MacChatListView.paneRoute(after: to, previous: from, current: .items(path: []), coordinatorConvoID: nil),
                       .items(path: []))
        let closedFrom = MacPlace(detail: .conversation(id: "c1", pane: nil))
        let closedTo = MacPlace(detail: .conversation(id: "c2", pane: nil))
        XCTAssertNil(MacChatListView.paneRoute(after: closedTo, previous: closedFrom, current: nil, coordinatorConvoID: nil))
    }

    /// A restore: the history's current place already IS the place being
    /// landed on, so the route it carries is kept.
    func test_paneRouteAfter_restoreKeepsTheRestoredRoute() {
        let restored = MacPlace(detail: .conversation(id: "c2", pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: restored, previous: restored, current: route, coordinatorConvoID: nil),
                       route)
    }

    /// Leaving the chat for Missions and coming back is a conversation
    /// change (nil → c1) and resets like a click; a nav-only move away
    /// leaves the per-window route untouched.
    func test_paneRouteAfter_nonChatPlacesLeaveTheRouteAlone() {
        let chat = MacPlace(detail: .conversation(id: "c1", pane: route))
        let mission = MacPlace(detail: .mission(id: "m1"))
        XCTAssertEqual(MacChatListView.paneRoute(after: mission, previous: chat, current: route, coordinatorConvoID: nil), route)
        XCTAssertEqual(MacChatListView.paneRoute(after: chat, previous: mission, current: route, coordinatorConvoID: nil),
                       .items(path: []))
    }

    /// The coordinator's own conversation is a displayed conversation too:
    /// moving between it and another chat resets exactly like a click.
    func test_paneRouteAfter_coordinatorCountsAsAConversation() {
        let coord = MacPlace(detail: .coordinator(pane: route))
        let chat = MacPlace(detail: .conversation(id: "c1", pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: chat, previous: coord, current: route, coordinatorConvoID: "k"),
                       .items(path: []))
        let coordAgain = MacPlace(detail: .coordinator(pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: coordAgain, previous: coord, current: route, coordinatorConvoID: "k"),
                       route, "same place, no change")
    }
}
#endif
