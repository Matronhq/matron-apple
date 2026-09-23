import XCTest
@testable import Matron

/// App shell (spec §3): the shell's navigation state is a plain observable
/// object so every cross-tab rule is a pure function of it.
@MainActor
final class AppShellNavigationTests: XCTestCase {
    func test_itemRoute_roundTripsThroughThePathValue() {
        let route = ItemRoute(id: "it_1")
        XCTAssertEqual(route.pathValue, "item/it_1")
        XCTAssertEqual(ItemRoute(pathValue: "item/it_1"), route)
        XCTAssertNil(ItemRoute(pathValue: "cv_1"), "a conversation id is not an item route")
        XCTAssertNil(ItemRoute(pathValue: "item/"), "an empty id is not a route")
    }

    func test_deepLink_switchesToConversations_andReplacesThePath() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.chatPath = ["!old:s", "!child:s"]
        nav.openChat("!new:s")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!new:s"], "a deep link collapses the stack to the target (Dan, 2026-08-06)")
    }

    func test_deepLink_isIdempotent_forTheOpenChat() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!r:s"]
        nav.openChat("!r:s")
        XCTAssertEqual(nav.chatPath, ["!r:s"])
    }

    func test_openConversationFromDecisions_switchesTab_thenAppends() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.decisionsPath = [ItemRoute(id: "it_1")]
        nav.openConversation(fromDecisions: "!r:s")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!r:s"])
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_1")], "the Decisions stack is left where it was")
        nav.openConversation(fromDecisions: "!r:s")
        XCTAssertEqual(nav.chatPath, ["!r:s"], "no duplicate push for the chat already on top")
    }

    // Dan, 2026-09-09: swipe between the conversation list and the
    // decisions list — a horizontal swipe at a tab's ROOT moves one tab
    // in bar order; deeper in a stack the chat's own pager / swipe-back own
    // horizontal drags, so a non-empty path ignores it.
    func test_rootSwipe_left_goesToTheNextTab_andRight_comesBack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 10)), "nothing to the right of the last tab")
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: 120, height: 10)),
                       "Missions is the first tab now the Coordinator tab is gone")
    }

    func test_rootSwipe_ignoresShortOrVerticalDrags_andNonRootStacks() {
        let nav = AppShellNavigation()
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -60, height: 0)), "below the threshold")
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 200)), "a list scroll")
        XCTAssertEqual(nav.tab, .conversations)
        nav.chatPath = ["!r:s"]
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 0)), "inside a chat the pager owns the drag")
        XCTAssertEqual(nav.tab, .conversations)
        nav.chatPath = []
        nav.tab = .decisions
        nav.decisionsPath = [ItemRoute(id: "it_1")]
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: 120, height: 0)), "inside an item detail too")
        XCTAssertEqual(nav.tab, .decisions)
    }

    /// Spec §3c: every route into the Coordinator's conversation presents
    /// the sheet; nothing selects a tab for it.
    func test_everyRouteToTheCoordinator_presentsTheSheet() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.coordinatorPath = ["!child:s"]
        nav.openChat("!coord:s")
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.coordinatorPath, [], "a deep link lands at the Coordinator's root")
        XCTAssertEqual(nav.tab, .conversations, "the tab underneath is left alone")

        nav.isCoordinatorPresented = false
        nav.tab = .decisions
        nav.openConversation(fromDecisions: "!coord:s")
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.tab, .decisions)

        nav.isCoordinatorPresented = false
        nav.openConversation(fromMissions: "!coord:s")
        XCTAssertTrue(nav.isCoordinatorPresented)
    }

    /// An origin link pushing the Coordinator onto Conversations stores
    /// only what is beneath it and presents the sheet instead — one mount.
    func test_chatPathSetter_redirectsTheCoordinatorToTheSheet() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.setChatPath(["!other:s", "!coord:s", "item/abc"])
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertTrue(nav.isCoordinatorPresented)
        nav.isCoordinatorPresented = false
        nav.setChatPath(["!other:s", "item/abc"])
        XCTAssertEqual(nav.chatPath, ["!other:s", "item/abc"])
        XCTAssertFalse(nav.isCoordinatorPresented)
    }

    /// A second copy pushed onto the sheet's own stack pops it to its root.
    func test_coordinatorPathSetter_popsASecondCopyToTheRoot() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.setCoordinatorPath(["item/abc", "!coord:s"])
        XCTAssertEqual(nav.coordinatorPath, [])
        nav.setCoordinatorPath(["!child:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!child:s"])
    }

    /// Presenting the sheet evicts the same conversation from Conversations
    /// first (it may be open there from before it became the Coordinator):
    /// two ChatViews would share one cached ChatViewModel.
    func test_presentingTheSheet_evictsTheSameChatFromConversations() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!other:s", "!coord:s", "item/abc"]
        nav.coordinatorConvoID = "!coord:s"
        XCTAssertEqual(nav.chatPath, ["!other:s", "!coord:s", "item/abc"], "assignment alone yanks nothing")
        nav.presentCoordinator()
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertTrue(nav.isCoordinatorPresented)
    }

    /// A new Coordinator starts at its root (Bugbot, PR #197).
    func test_changingTheCoordinator_resetsTheSheetStack() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!a:s"
        nav.coordinatorPath = ["!child:s"]
        nav.coordinatorConvoID = "!b:s"
        XCTAssertEqual(nav.coordinatorPath, [])
    }

    /// A tap on another conversation's notification leaves the sheet for it.
    func test_openingAnotherChat_dismissesTheSheet() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!r:s")
        XCTAssertFalse(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.chatPath, ["!r:s"])
    }

    /// Review focus: a session the Coordinator starts auto-opens underneath;
    /// the sheet stays where the user is.
    func test_autoOpen_keepsTheCoordinatorSheetUp() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!spawned:s", dismissingCoordinator: false)
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.chatPath, ["!spawned:s"])
        XCTAssertEqual(nav.tab, .conversations)
    }

    func test_pushDecision_appendsToTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.pushDecision("it_9")
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9")])
        XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
    }
}
