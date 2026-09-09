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
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 10)), "nothing to the right of the last tab")
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertEqual(nav.tab, .conversations)
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

    func test_pushDecision_appendsToTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.pushDecision("it_9")
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9")])
        XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
    }
}
