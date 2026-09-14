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
        nav.tab = .coordinator
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 10)), "nothing to the right of the last tab")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)), "Coordinator sits to the left of Missions")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: 120, height: 10)), "nothing to the left of the first tab")
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

    /// Bugbot, PR #197: the coordinator conversation must never be mounted
    /// in Conversations as well — every route to it lands on its tab.
    func test_coordinatorConversation_alwaysRoutesToItsOwnTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.coordinatorPath = ["!child:s"]
        nav.openChat("!coord:s")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, [], "a deep link lands at the coordinator root")
        XCTAssertEqual(nav.chatPath, [])
        nav.tab = .decisions
        nav.openConversation(fromDecisions: "!coord:s")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, [])
        // A chat-list row push of the coordinator hands off.
        nav.tab = .conversations
        nav.chatPath = ["!coord:s"]
        XCTAssertTrue(nav.redirectCoordinatorPush())
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, [])
        // An origin link from an open chat appends it on top: pop just that
        // entry and hand off, leaving the chat beneath where it was.
        nav.tab = .conversations
        nav.chatPath = ["!other:s", "!coord:s"]
        XCTAssertTrue(nav.redirectCoordinatorPush())
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        // Any other push is left alone.
        nav.tab = .conversations
        nav.chatPath = ["!other:s"]
        XCTAssertFalse(nav.redirectCoordinatorPush())
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        nav.coordinatorConvoID = nil
        nav.chatPath = ["!coord:s"]
        XCTAssertFalse(nav.redirectCoordinatorPush(), "no coordinator set: it is an ordinary chat")
    }

    /// Bugbot (PR #197, High): the coordinator must never be mounted twice.
    /// Assigning it to a chat already on the Conversations stack — even
    /// with an item detail above it — evicts that chat, and an origin link
    /// that pushes the coordinator onto its own stack pops to the root.
    func test_coordinatorIsNeverMountedTwice() {
        let nav = AppShellNavigation()
        // Assignment while the chat is open beneath an item detail.
        nav.tab = .conversations
        nav.chatPath = ["!other:s", "!coord:s", "item/abc"]
        nav.coordinatorConvoID = "!coord:s"
        XCTAssertEqual(nav.tab, .coordinator, "assigning an open chat hands off to its tab")
        XCTAssertEqual(nav.chatPath, ["!other:s"], "the chat and everything above it leave the Conversations stack")
        XCTAssertEqual(nav.coordinatorPath, [])
        // Re-assigning the same id is a no-op.
        nav.tab = .conversations
        nav.coordinatorConvoID = "!coord:s"
        XCTAssertEqual(nav.tab, .conversations)
        // A second copy pushed onto the Coordinator stack pops to the root.
        nav.tab = .coordinator
        nav.coordinatorPath = ["item/abc", "!coord:s"]
        XCTAssertTrue(nav.redirectCoordinatorPush())
        XCTAssertEqual(nav.coordinatorPath, [])
        XCTAssertEqual(nav.tab, .coordinator)
        // Other chats on the Coordinator stack are fine.
        nav.coordinatorPath = ["!other:s"]
        XCTAssertFalse(nav.redirectCoordinatorPush())
        XCTAssertEqual(nav.coordinatorPath, ["!other:s"])
    }

    /// Bugbot (PR #197): the stack bindings' setters redirect on the way
    /// in, so the coordinator id is never stored — a second copy cannot
    /// mount even for a frame.
    func test_stackSetters_redirectTheCoordinatorBeforeItIsStored() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.tab = .conversations
        nav.setChatPath(["!other:s", "!coord:s"])
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertEqual(nav.tab, .coordinator)
        nav.setCoordinatorPath(["item/abc", "!coord:s"])
        XCTAssertEqual(nav.coordinatorPath, [])
        nav.setCoordinatorPath(["!other:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!other:s"], "other pushes are stored as-is")
        nav.tab = .conversations
        nav.setChatPath(["!other:s", "item/abc"])
        XCTAssertEqual(nav.chatPath, ["!other:s", "item/abc"])
        XCTAssertEqual(nav.tab, .conversations)
    }

    func test_pushDecision_appendsToTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.pushDecision("it_9")
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9")])
        XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
    }

    func test_coordinatorTab_hasItsOwnStack() {
        let nav = AppShellNavigation()
        nav.tab = .coordinator
        nav.push("!child:s", on: .coordinator)
        XCTAssertEqual(nav.coordinatorPath, ["!child:s"], "a sub-chat opened from the coordinator pushes on coordinatorPath")
        XCTAssertEqual(nav.chatPath, [], "…not on the Conversations stack")
        XCTAssertEqual(nav.tab, .coordinator)
        nav.push(ItemRoute(id: "it_1").pathValue, on: .coordinator)
        XCTAssertEqual(nav.coordinatorPath, ["!child:s", "item/it_1"])
    }

    func test_deepLink_leavesTheCoordinatorStackAlone() {
        let nav = AppShellNavigation()
        nav.tab = .coordinator
        nav.coordinatorPath = ["!child:s"]
        nav.openChat("!r:s")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.coordinatorPath, ["!child:s"])
    }
}
