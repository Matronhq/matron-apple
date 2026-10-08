import XCTest
import MatronModels
import MatronViewModels
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
        XCTAssertEqual(nav.chatPath, ["!new:s"], "a deep link collapses the stack to the target (Alice, 2026-08-06)")
    }

    func test_deepLink_isIdempotent_forTheOpenChat() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!r:s"]
        nav.openChat("!r:s")
        XCTAssertEqual(nav.chatPath, ["!r:s"])
    }

    /// "Open conversation" on a Decisions item pushes onto
    /// the Decisions stack, so Back returns to the item — not a switch to
    /// Conversations, where Back went to the list.
    func test_openConversationFromDecisions_pushesOnTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.chatPath = ["!other:s"]
        nav.decisionsPath = [ItemRoute(id: "it_1").pathValue]
        nav.openConversation(fromDecisions: "!r:s")
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertEqual(nav.decisionsPath, ["item/it_1", "!r:s"], "Back pops to the item")
        XCTAssertEqual(nav.chatPath, ["!other:s"], "the Conversations stack is left where it was")
        nav.openConversation(fromDecisions: "!r:s")
        XCTAssertEqual(nav.decisionsPath, ["item/it_1", "!r:s"], "no duplicate push for the chat already on top")
    }

    /// From a Decisions row, at the root: Back returns to the list.
    func test_openConversationFromADecisionsRow_pushesAtTheRoot() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.openConversation(fromDecisions: "!r:s")
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertEqual(nav.decisionsPath, ["!r:s"])
    }

    /// The 2026-08-06 rule survives where it was needed: a notification
    /// tap, search hit or new chat still REPLACES the Conversations stack,
    /// so Back from it goes to the list and never through a chat the user
    /// did not choose to visit. A copy of that chat hosted on another
    /// tab's stack is cut, with what sat above it.
    func test_deepLink_stillReplacesConversations_andCutsACopyHostedElsewhere() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.chatPath = ["!old:s"]
        nav.missionsPath = ["project/p1", "mission/m1", "!r:s", "item/it_2"]
        nav.decisionsPath = ["item/it_1", "!q:s"]
        nav.openChat("!r:s")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!r:s"])
        XCTAssertEqual(nav.missionsPath, ["project/p1", "mission/m1"], "back on the page it was opened from")
        XCTAssertEqual(nav.decisionsPath, ["item/it_1", "!q:s"], "another chat is untouched")
    }

    /// A chat is mounted on one stack at a time, whichever of the four it
    /// is opened on.
    func test_aChatHostedOnOneStack_isCutFromEveryOther() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.chatPath = ["!a:s", "!r:s"]
        nav.coordinatorPath = ["!s", "!r:s"]
        nav.decisionsPath = ["item/it_1", "!r:s", "item/it_2"]
        nav.tab = .missions
        nav.missionsPath = ["mission/m1"]
        nav.openConversation(fromMissions: "!r:s")
        XCTAssertEqual(nav.missionsPath, ["mission/m1", "!r:s"])
        XCTAssertEqual(nav.chatPath, ["!a:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!s"])
        XCTAssertEqual(nav.decisionsPath, ["item/it_1"])
        XCTAssertTrue(nav.isOpen("!r:s"))
        XCTAssertFalse(nav.isOpen("!gone:s"))
    }

    /// Back and swipe-back write the popped path through the stack
    /// binding's setter: the page underneath is what is left.
    func test_backFromAHostedChat_leavesThePageItWasOpenedFrom() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["project/p1", "mission/m1"]
        nav.openConversation(fromMissions: "!r:s")
        nav.setPath(Array(nav.missionsPath.dropLast()), on: .missions)
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["project/p1", "mission/m1"])
    }

    /// The Coordinator's conversation pushed onto the Projects or
    /// Decisions stack through its binding (a sub-chat strip, an origin
    /// link) never mounts there: the stack keeps what was beneath and the
    /// Coordinator tab is selected.
    func test_theCoordinatorNeverMountsOnAPagedStack() {
        for tab in [AppTab.missions, .decisions] {
            let nav = AppShellNavigation()
            nav.coordinatorConvoID = "!coord:s"
            nav.tab = tab
            nav.setPath(["item/it_1", "!coord:s"], on: tab)
            XCTAssertEqual(nav.path(of: tab), ["item/it_1"], "\(tab)")
            XCTAssertEqual(nav.tab, .coordinator, "\(tab)")
        }
    }

    /// Choosing a chat hosted on the Projects stack as the Coordinator
    /// moves it to the Coordinator tab, as it does from Conversations; a
    /// copy behind another tab is cut without moving the user.
    func test_assigningAHostedChatAsCoordinator_cutsItFromItsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["mission/m1", "!r:s", "item/it_1"]
        nav.coordinatorConvoID = "!r:s"
        XCTAssertEqual(nav.missionsPath, ["mission/m1"])
        XCTAssertEqual(nav.tab, .coordinator)

        let behind = AppShellNavigation()
        behind.tab = .conversations
        behind.decisionsPath = ["item/it_1", "!r:s"]
        behind.coordinatorConvoID = "!r:s"
        XCTAssertEqual(behind.decisionsPath, ["item/it_1"])
        XCTAssertEqual(behind.tab, .conversations, "a remote assignment must not move the user")
    }

    // Swipe between the conversation list and the
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
        nav.decisionsPath = [ItemRoute(id: "it_1").pathValue]
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: 120, height: 0)), "inside an item detail too")
        XCTAssertEqual(nav.tab, .decisions)
    }

    /// The Coordinator is the FIRST tab again.
    func test_tabOrder_putsTheCoordinatorFirst() {
        XCTAssertEqual(AppTab.allCases, [.coordinator, .missions, .decisions, .conversations])
        XCTAssertEqual(AppShellNavigation.tabs(missionsSupported: false), [.coordinator, .decisions, .conversations])
        XCTAssertEqual(AppShellNavigation().tab, .conversations, "the app still opens on Conversations")
    }

    /// The user: "it's only a swipe or two away" — a root swipe right from
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
        XCTAssertEqual(nav.missionsPath, ["!u:s"])
        XCTAssertEqual(nav.chatPath, ["!t:s"])
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

    /// A session an agent or a routine started used to
    /// open over whatever he was doing. It must change nothing — not the
    /// tab, not any stack — and only be marked new in the list.
    func test_sessionNotStartedHere_changesNothing_andIsMarkedNew() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        for tab in AppTab.allCases {
            nav.tab = tab
            nav.chatPath = ["!reading:s"]
            nav.coordinatorPath = ["!sub:s"]
            nav.decisionsPath = [ItemRoute(id: "it_1").pathValue]
            nav.missionsPath = ["mission/7"]

            let markNew = nav.conversationBorn(NewConversation(id: "!spawned:s", startedHere: false))

            XCTAssertTrue(markNew, "the list shows it arrived")
            XCTAssertEqual(nav.tab, tab, "the tab on screen stays on screen")
            XCTAssertEqual(nav.chatPath, ["!reading:s"], "the open chat stays open")
            XCTAssertEqual(nav.coordinatorPath, ["!sub:s"])
            XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_1").pathValue])
            XCTAssertEqual(nav.missionsPath, ["mission/7"])
        }
    }

    /// A quiet arrival already open on the Projects or Decisions stack is
    /// on screen too.
    func test_quietArrivalHostedOnAPagedStack_isNotMarkedNew() {
        let nav = AppShellNavigation()
        nav.missionsPath = ["mission/m1", "!open:s"]
        nav.decisionsPath = ["item/it_1", "!other:s"]
        XCTAssertFalse(nav.conversationBorn(NewConversation(id: "!open:s", startedHere: false)))
        XCTAssertFalse(nav.conversationBorn(NewConversation(id: "!other:s", startedHere: false)))
    }

    /// A session the user started from this device still opens, by the
    /// same rules as before, and needs no marker.
    func test_sessionStartedHere_stillOpens() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.chatPath = ["!old:s"]
        let markNew = nav.conversationBorn(NewConversation(id: "!mine:s", startedHere: true))
        XCTAssertFalse(markNew)
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!mine:s"])
    }

    /// One already on screen is not new: the user is looking at it.
    func test_quietArrivalAlreadyOnScreen_isNotMarkedNew() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!open:s"]
        nav.setCoordinatorPath(["!sub:s"])
        XCTAssertFalse(nav.conversationBorn(NewConversation(id: "!open:s", startedHere: false)))
        XCTAssertFalse(nav.conversationBorn(NewConversation(id: "!sub:s", startedHere: false)))
        XCTAssertEqual(nav.chatPath, ["!open:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!sub:s"])
    }

    func test_pushDecision_appendsToTheDecisionsStack() {
        let nav = AppShellNavigation()
        nav.pushDecision("it_9")
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_9").pathValue])
        XCTAssertEqual(nav.tab, .conversations, "pushing a decision never changes the tab")
    }

    // MARK: Voice-note pill

    func test_voiceNotePill_returnsToItsConversation() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.missionsPath = ["mission/m1"]
        nav.openVoiceNoteTarget(.conversation("!r:s"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["!r:s"])
        XCTAssertEqual(nav.missionsPath, ["mission/m1"], "the page Alice was browsing stays put on its own tab")
    }

    func test_voiceNotePill_returnsToItsItem_onDecisions_withoutStackingIt() {
        let nav = AppShellNavigation()
        nav.openVoiceNoteTarget(.item("it_7"))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_7").pathValue])
        nav.tab = .conversations
        nav.openVoiceNoteTarget(.item("it_7"))
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_7").pathValue], "already on top: not pushed twice")
        XCTAssertEqual(nav.tab, .decisions)
    }
}
