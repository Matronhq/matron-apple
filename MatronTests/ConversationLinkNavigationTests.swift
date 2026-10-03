import XCTest
import MatronDesignSystem
@testable import Matron

/// Conversation links (decision #2954) on iOS: a tapped link or pill pushes
/// the conversation onto the stack of the tab it was tapped in, so Back
/// returns to the chat the link sat in — like the Mac. The Coordinator's own
/// conversation selects its tab's root, and a tab with no chat destination
/// (Missions, Decisions) hands off to Conversations.
@MainActor
final class ConversationLinkNavigationTests: XCTestCase {
    func test_linkInTheCoordinatorTab_pushesOntoTheCoordinatorStack() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.tab = .coordinator
        nav.chatPath = ["c1"]
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, ["c2"], "Back pops to the Coordinator's chat")
        XCTAssertEqual(nav.chatPath, ["c1"], "the Conversations stack is left alone")
    }

    func test_linkInAChatPushedOnTheCoordinatorStack_stacksAboveIt() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.tab = .coordinator
        nav.coordinatorPath = ["c1"]
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.coordinatorPath, ["c1", "c2"])
    }

    func test_linkToAConversationOpenInConversations_evictsItThere() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.chatPath = ["c1", "c2", "c3"]
        nav.tab = .coordinator
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.coordinatorPath, ["c2"])
        XCTAssertEqual(nav.chatPath, ["c1"], "never mounted on two tabs at once")
    }

    func test_linkInConversations_pushesOntoTheConversationsStack() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.chatPath = ["c1", "c1:sub:a"]
        nav.coordinatorPath = ["c2", "c9"]
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1", "c1:sub:a", "c2"])
        XCTAssertEqual(nav.coordinatorPath, [], "never mounted on two tabs at once")
    }

    /// Bugbot, PR #241, carried over to the stack a chat is now pushed on
    /// (mission 7047): a link on the Projects or Decisions tab must not
    /// stack a second copy of a conversation already deeper in that stack.
    func test_linkInDecisionsOrMissionsToAChatDeeperInThatStack_popsBackToIt() {
        for tab in [AppTab.decisions, .missions] {
            let nav = AppShellNavigation()
            nav.tab = tab
            nav.setPath(["item/it_1", "c2", "item/it_2", "c3"], on: tab)
            nav.openConversationLink("c2")
            XCTAssertEqual(nav.tab, tab, "\(tab)")
            XCTAssertEqual(nav.path(of: tab), ["item/it_1", "c2"], "\(tab)")
        }
    }

    /// A copy of the conversation open in Conversations is cut from there,
    /// with what sat above it: one stack hosts a chat at a time.
    func test_openConversationFromDecisions_cutsACopyOpenInConversations() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.chatPath = ["c1", "c2", "c3"]
        nav.openConversation(fromDecisions: "c2")
        XCTAssertEqual(nav.decisionsPath, ["c2"])
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    func test_linkToTheChatAlreadyOnTop_isANoOp() {
        let nav = AppShellNavigation()
        nav.chatPath = ["c1", "c2"]
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.chatPath, ["c1", "c2"])
    }

    /// Two copies of one chat on one stack would share one cached view
    /// model; the link pops back to the copy already there instead.
    func test_linkToAChatDeeperInTheSameStack_popsBackToIt() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.tab = .coordinator
        nav.coordinatorPath = ["c1", ItemRoute(id: "i1").pathValue, "c2"]
        nav.openConversationLink("c1")
        XCTAssertEqual(nav.coordinatorPath, ["c1"])
    }

    func test_linkToTheCoordinator_selectsTheCoordinatorTabRoot() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.chatPath = ["c1"]
        nav.openConversationLink("k")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
        XCTAssertEqual(nav.chatPath, ["c1"], "the Conversations stack is left alone")
    }

    func test_linkToTheCoordinatorFromAChatOnItsStack_popsToTheRoot() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.tab = .coordinator
        nav.coordinatorPath = ["c1"]
        nav.openConversationLink("k")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
    }

    /// Mission 7047: a link in an item on the Projects or Decisions tab
    /// pushes the conversation onto that tab's stack, like their "Open
    /// conversation", so Back returns to the item the link sat in.
    func test_linkInDecisionsOrMissions_pushesOntoThatStack() {
        for tab in [AppTab.decisions, .missions] {
            let nav = AppShellNavigation()
            nav.tab = tab
            nav.chatPath = ["c1"]
            nav.setPath(["item/it_1"], on: tab)
            nav.openConversationLink("c2")
            XCTAssertEqual(nav.tab, tab, "\(tab)")
            XCTAssertEqual(nav.path(of: tab), ["item/it_1", "c2"], "\(tab)")
            XCTAssertEqual(nav.chatPath, ["c1"], "\(tab)")
        }
    }

    /// The shell's host only hands KNOWN conversations to the navigation.
    func test_unknownConversation_neverNavigates() async {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        let host = ConversationLinkHost()
        host.reset(titleLookup: { $0 == "c2" ? "" : nil })
        host.action("ghost")
        if let id = await host.resolve(host.pending!) { nav.openConversationLink(id) }
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertEqual(nav.decisionsPath, [])

        host.action("c2")
        if let id = await host.resolve(host.pending!) { nav.openConversationLink(id) }
        XCTAssertEqual(nav.tab, .decisions, "a known but untitled conversation still opens, on this tab")
        XCTAssertEqual(nav.decisionsPath, ["c2"])
    }
}
