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

    /// Missions and Decisions stacks hold pages, not chats: a link in an
    /// item there opens in Conversations, like their "Open conversation".
    func test_linkInDecisionsOrMissions_opensInConversations() {
        for tab in [AppTab.decisions, .missions] {
            let nav = AppShellNavigation()
            nav.tab = tab
            nav.chatPath = ["c1"]
            nav.openConversationLink("c2")
            XCTAssertEqual(nav.tab, .conversations, "\(tab)")
            XCTAssertEqual(nav.chatPath, ["c1", "c2"], "\(tab)")
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
        XCTAssertEqual(nav.chatPath, [])

        host.action("c2")
        if let id = await host.resolve(host.pending!) { nav.openConversationLink(id) }
        XCTAssertEqual(nav.tab, .conversations, "a known but untitled conversation still opens")
        XCTAssertEqual(nav.chatPath, ["c2"])
    }
}
