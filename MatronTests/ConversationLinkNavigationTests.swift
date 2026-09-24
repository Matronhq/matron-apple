import XCTest
import MatronDesignSystem
@testable import Matron

/// Conversation links (decision #2954) on iOS: a tapped link or pill lands
/// like a notification tap — Conversations, stack replaced by the target —
/// and the Coordinator's own conversation selects its tab.
@MainActor
final class ConversationLinkNavigationTests: XCTestCase {
    func test_linkFromTheCoordinatorTab_opensTheConversationInConversations() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.tab = .coordinator
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c2"])
    }

    func test_linkInsideAChat_replacesTheConversationsStack() {
        let nav = AppShellNavigation()
        nav.chatPath = ["c1", "c1:sub:a"]
        nav.openConversationLink("c2")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c2"])
    }

    func test_linkToTheCoordinator_selectsTheCoordinatorTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "k"
        nav.chatPath = ["c1"]
        nav.openConversationLink("k")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
        XCTAssertEqual(nav.chatPath, ["c1"], "the Conversations stack is left alone")
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
