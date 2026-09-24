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
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertEqual(nav.tab, .coordinator)
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

    /// Decision #2913: the Coordinator is the FIRST tab again.
    func test_tabOrder_putsTheCoordinatorFirst() {
        XCTAssertEqual(AppTab.allCases, [.coordinator, .missions, .decisions, .conversations])
        XCTAssertEqual(AppShellNavigation.tabs(missionsSupported: false), [.coordinator, .decisions, .conversations])
        XCTAssertEqual(AppShellNavigation().tab, .conversations, "the app still opens on Conversations")
    }

    /// Dan: "it's only a swipe or two away" — a root swipe right from
    /// Missions lands on the Coordinator; from Decisions with no Missions
    /// tab, likewise.
    func test_rootSwipe_reachesTheCoordinatorTab() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 0)))
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: 120, height: 0)), "nothing left of the first tab")

        let old = AppShellNavigation()
        old.missionsSupported = false
        old.tab = .decisions
        XCTAssertTrue(old.swipeRoot(translation: CGSize(width: 120, height: 0)))
        XCTAssertEqual(old.tab, .coordinator)

        nav.coordinatorPath = ["!child:s"]
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 0)), "a pushed chat owns the drag")
    }

    /// Every route into the Coordinator's conversation selects its tab at
    /// the root — it never mounts in Conversations as a second copy.
    func test_everyRouteToTheCoordinator_selectsItsTab() {
        let entries: [@MainActor (AppShellNavigation) -> Void] = [
            { $0.openChat("!coord:s") },
            { $0.openConversation(fromDecisions: "!coord:s") },
            { $0.openConversation(fromMissions: "!coord:s") },
            { $0.setChatPath(["!other:s", "!coord:s", "item/abc"]) },
        ]
        for open in entries {
            let nav = AppShellNavigation()
            nav.coordinatorConvoID = "!coord:s"
            nav.tab = .decisions
            nav.chatPath = ["!other:s"]
            nav.coordinatorPath = ["!child:s"]
            open(nav)
            XCTAssertEqual(nav.tab, .coordinator)
            XCTAssertEqual(nav.coordinatorPath, [], "lands at the Coordinator's root")
            XCTAssertEqual(nav.chatPath, ["!other:s"], "Conversations keeps what was beneath, never the Coordinator")
        }
    }

    /// A second copy pushed onto the Coordinator tab's own stack pops it
    /// to its root.
    func test_coordinatorPathSetter_popsASecondCopyToTheRoot() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.setCoordinatorPath(["item/abc", "!coord:s"])
        XCTAssertEqual(nav.coordinatorPath, [])
        nav.setCoordinatorPath(["!child:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!child:s"])
    }

    /// Selecting the Coordinator evicts the same conversation from
    /// Conversations (a path written directly, not via the setter): two
    /// ChatViews would share one cached ChatViewModel.
    func test_selectingTheCoordinator_evictsTheSameChatFromConversations() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.chatPath = ["!other:s", "!coord:s", "item/abc"]
        nav.selectCoordinator()
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertEqual(nav.tab, .coordinator)
    }

    /// Final review C2: assigning a chat open in Conversations cuts it (and
    /// everything above it) from that stack. When Conversations is the tab
    /// on screen it moves to the Coordinator tab; on another tab it only
    /// cuts. A new Coordinator starts at its root; re-assigning is a no-op.
    func test_assigningTheOpenChat_movesItToTheCoordinatorTab() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!a:s", "!x:s", "item/abc"]
        nav.coordinatorPath = ["!child:s"]
        nav.coordinatorConvoID = "!x:s"
        XCTAssertEqual(nav.chatPath, ["!a:s"])
        XCTAssertEqual(nav.coordinatorPath, [])
        XCTAssertEqual(nav.tab, .coordinator)

        nav.chatPath = ["!a:s", "!b:s"]
        nav.tab = .conversations
        nav.coordinatorConvoID = "!x:s"
        XCTAssertEqual(nav.chatPath, ["!a:s", "!b:s"])
        XCTAssertEqual(nav.tab, .conversations)

        let away = AppShellNavigation()
        away.tab = .decisions
        away.chatPath = ["!y:s"]
        away.coordinatorConvoID = "!y:s"
        XCTAssertEqual(away.chatPath, [], "cut from the stack the TabView keeps mounted")
        XCTAssertEqual(away.tab, .decisions, "a remote assignment never yanks the user off another tab")

        let untouched = AppShellNavigation()
        untouched.chatPath = ["!a:s"]
        untouched.coordinatorConvoID = "!z:s"
        XCTAssertEqual(untouched.chatPath, ["!a:s"])
        XCTAssertEqual(untouched.tab, .conversations)
    }

    /// The TabView keeps both stacks mounted, so a chat pushed on one is cut
    /// from the other (with everything above it): one cached ChatViewModel
    /// never backs two ChatViews, whose tab-switch disappear would stop the
    /// stream the other copy shows (Bugbot, PR #197). Item routes are pages
    /// and never count.
    func test_aChatNeverMountsOnBothStacks() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.chatPath = ["!a:s", "!b:s", "item/x"]
        nav.setCoordinatorPath(["!s", "item/y", "!b:s"])
        XCTAssertEqual(nav.chatPath, ["!a:s"], "cut at the first shared chat, with everything above it")
        nav.setCoordinatorPath(["!s", "item/y", "!b:s", "item/x"])
        XCTAssertEqual(nav.chatPath, ["!a:s"], "an item route is not a chat and evicts nothing")

        nav.setChatPath(["!a:s", "!s"])
        XCTAssertEqual(nav.coordinatorPath, [], "the Coordinator tab's copy is cut")

        nav.coordinatorPath = ["!c:s", "!t:s"]
        nav.openChat("!t:s")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!t:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!c:s"], "a deep link cuts the other tab's copy too")

        nav.coordinatorPath = ["!u:s"]
        nav.tab = .missions
        nav.openConversation(fromMissions: "!u:s")
        XCTAssertEqual(nav.chatPath, ["!t:s", "!u:s"])
        XCTAssertEqual(nav.coordinatorPath, [], "and so does Open conversation")
    }

    /// A session the Coordinator starts auto-opens in Conversations without
    /// pulling the user off the Coordinator tab; elsewhere it switches as
    /// any deep link does. Already open on the Coordinator's stack, it is
    /// left where the user is looking at it.
    func test_autoOpen_staysOnTheCoordinatorTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.tab = .coordinator
        nav.chatPath = ["!old:s"]
        nav.autoOpenChat("!spawned:s")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, ["!spawned:s"])

        nav.setCoordinatorPath(["!s", "item/y"])
        nav.autoOpenChat("!s")
        XCTAssertEqual(nav.chatPath, ["!spawned:s"], "never mounted a second time")
        XCTAssertEqual(nav.coordinatorPath, ["!s", "item/y"])

        nav.tab = .decisions
        nav.autoOpenChat("!n:s")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!n:s"])
    }

    func test_pushDecision_appendsToTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.pushDecision("it_9")
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9")])
        XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
    }
}
