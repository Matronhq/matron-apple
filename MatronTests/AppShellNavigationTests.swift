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
        nav.coordinatorConvoID = "!coord:s"
        // A path written directly (not via the redirecting setter).
        nav.chatPath = ["!other:s", "!coord:s", "item/abc"]
        nav.presentCoordinator()
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertTrue(nav.isCoordinatorPresented)
    }

    /// Final review C2: one cached ChatViewModel must never mount twice.
    /// Assigning a chat that is open in Conversations — "New coordinator
    /// chat…" (auto-opened underneath, then the PUT assigns it) or Choose
    /// on a chat open underneath the sheet — cuts it (and everything above
    /// it) from that stack, like the Mac's landingAfterCoordinatorChange.
    func test_coordinatorIsNeverMountedTwice() {
        // Path 1: New coordinator chat… from the sheet.
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!old:s"
        nav.presentCoordinator()
        nav.openChat("!new:s", dismissingCoordinator: false)
        XCTAssertEqual(nav.chatPath, ["!new:s"])
        nav.coordinatorConvoID = "!new:s"
        XCTAssertEqual(nav.chatPath, [], "the new Coordinator leaves the Conversations stack")
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.coordinatorPath, [])

        // Path 2: ⓘ → Coordinator → setup → Choose the chat underneath.
        let other = AppShellNavigation()
        other.chatPath = ["!a:s", "!x:s", "item/abc"]
        other.presentCoordinator()
        other.coordinatorConvoID = "!x:s"
        XCTAssertEqual(other.chatPath, ["!a:s"], "cut at the new id, with everything above it")
        XCTAssertTrue(other.isCoordinatorPresented)

        // Re-assigning the same id is a no-op.
        other.chatPath = ["!a:s", "!b:s"]
        other.coordinatorConvoID = "!x:s"
        XCTAssertEqual(other.chatPath, ["!a:s", "!b:s"])
    }

    /// With the sheet down, the chat being looked at becoming the
    /// Coordinator (e.g. assigned from another device) moves it into the
    /// sheet — the iOS twin of the Mac opening its panel.
    func test_assigningTheOpenChat_withTheSheetDown_presentsIt() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!x:s"]
        nav.coordinatorConvoID = "!x:s"
        XCTAssertEqual(nav.chatPath, [])
        XCTAssertTrue(nav.isCoordinatorPresented)

        let untouched = AppShellNavigation()
        untouched.chatPath = ["!a:s"]
        untouched.coordinatorConvoID = "!x:s"
        XCTAssertFalse(untouched.isCoordinatorPresented, "a Coordinator not on screen presents nothing")
    }

    /// Final review I2: a search hit on the Coordinator dismisses the search
    /// sheet and opens the Coordinator in one update. Presenting while that
    /// sheet is still up/dismissing is dropped by SwiftUI, so it waits for
    /// the shell to be uncovered — and asks covering sheets to close (a
    /// notification tap while the ⓘ sheet or Settings is up).
    func test_presentingWhileCovered_waitsForTheCoveringSheetToLeave() {
        let nav = AppShellNavigation()
        var covered = true
        nav.isShellCovered = { covered }
        nav.coordinatorConvoID = "!coord:s"
        let requestBefore = nav.uncoverRequest
        nav.openChat("!coord:s")
        XCTAssertFalse(nav.isCoordinatorPresented, "never presented over another sheet")
        XCTAssertTrue(nav.isCoordinatorPresentationPending)
        XCTAssertEqual(nav.uncoverRequest, requestBefore + 1, "covering sheets are asked to close")

        covered = false
        nav.shellDidUncover()
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertFalse(nav.isCoordinatorPresentationPending)

        // Nothing pending: uncovering presents nothing.
        nav.isCoordinatorPresented = false
        nav.shellDidUncover()
        XCTAssertFalse(nav.isCoordinatorPresented)
    }

    /// A New Chat start that was in flight when the presentation parked
    /// lands its chat underneath and keeps the parked Coordinator.
    func test_aCreatedChatLandingUnderneath_keepsAParkedPresentation() {
        let nav = AppShellNavigation()
        var covered = true
        nav.isShellCovered = { covered }
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!new:s", dismissingCoordinator: false)
        XCTAssertEqual(nav.chatPath, ["!new:s"])
        XCTAssertTrue(nav.isCoordinatorPresentationPending)
        covered = false
        nav.shellDidUncover()
        XCTAssertTrue(nav.isCoordinatorPresented)
    }

    /// Opening another chat in the meantime drops the pending presentation.
    func test_openingAnotherChat_cancelsAPendingPresentation() {
        let nav = AppShellNavigation()
        nav.isShellCovered = { true }
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!r:s")
        XCTAssertFalse(nav.isCoordinatorPresentationPending)
        nav.shellDidUncover()
        XCTAssertFalse(nav.isCoordinatorPresented)
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

    /// Fix round 1 (PR #197 hazard): an auto-opened session sits in
    /// Conversations under the sheet; pushing the same chat inside the sheet
    /// (Open, the sub-chat strip) cuts it from Conversations, so dismissing
    /// the sheet cannot stop the stream a second copy is still showing.
    func test_pushingInTheSheet_evictsTheSameChatFromConversations() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!s", dismissingCoordinator: false)
        nav.setCoordinatorPath(["!s"])
        XCTAssertEqual(nav.chatPath, [])
        XCTAssertEqual(nav.coordinatorPath, ["!s"])

        nav.chatPath = ["!a:s", "!b:s", "item/x"]
        nav.setCoordinatorPath(["!s", "item/y", "!b:s"])
        XCTAssertEqual(nav.chatPath, ["!a:s"], "cut at the first shared chat, with everything above it")
        nav.setCoordinatorPath(["!s", "item/y", "!b:s", "item/x"])
        XCTAssertEqual(nav.chatPath, ["!a:s"], "an item route is not a chat and evicts nothing")
    }

    /// The reverse: a chat already open inside the sheet never lands in
    /// Conversations under it too. An auto-open of it leaves both stacks
    /// alone (the user is already looking at it); any other write that
    /// puts it on the Conversations stack while the sheet is up cuts the
    /// sheet's copy.
    func test_aChatOpenInTheSheet_isNeverMountedUnderneathToo() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.setCoordinatorPath(["!s", "item/y"])
        nav.chatPath = ["!old:s"]
        nav.openChat("!s", dismissingCoordinator: false)
        XCTAssertEqual(nav.chatPath, ["!old:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!s", "item/y"])
        XCTAssertTrue(nav.isCoordinatorPresented)

        nav.setChatPath(["!old:s", "!s"])
        XCTAssertEqual(nav.chatPath, ["!old:s", "!s"])
        XCTAssertEqual(nav.coordinatorPath, [], "the sheet's copy is cut")

        nav.isCoordinatorPresented = false
        nav.coordinatorPath = ["!t"]
        nav.setChatPath(["!t"])
        XCTAssertEqual(nav.coordinatorPath, ["!t"], "a dismissed sheet mounts nothing; its stack is reset on present")
    }

    func test_pushDecision_appendsToTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.pushDecision("it_9")
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9")])
        XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
    }
}
