#if os(macOS)
import XCTest
import MatronDesignSystem
@testable import MatronMac

/// Conversation links (decision #2954) on the Mac: a tapped link or pill
/// lands where a search hit or notification tap does — the Conversations
/// detail, or the Coordinator page for the Coordinator's own conversation —
/// and the window's history records the move so Back returns. Pure helpers,
/// `MacCoordinatorPageTests` style: `MacChatListView`'s state is private.
@MainActor
final class MacConversationLinkTests: XCTestCase {

    private func place(_ landing: MacChatListView.ConversationShowLanding, coordinator: String?) -> MacPlace {
        MacChatListView.place(nav: landing.nav, selectedSummaryID: landing.selection, selectedMissionID: nil,
                              selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: coordinator)
    }

    func test_linkToAnotherConversation_selectsItInTheDetail_andBackReturns() {
        let history = MacNavigationHistory()
        let start = MacPlace(detail: .conversation(id: "c1", pane: nil))
        history.visit(start)

        let landing = MacChatListView.landingForShowingConversation("c2", selected: "c1", coordinatorConvoID: "k")
        XCTAssertEqual(landing, .init(nav: .conversations, selection: "c2"))
        history.visit(place(landing, coordinator: "k"))

        XCTAssertEqual(history.current, MacPlace(detail: .conversation(id: "c2", pane: nil)))
        XCTAssertEqual(history.goBack(), start, "Back returns to the chat the link was tapped in")
    }

    /// A link in the Coordinator page or panel to a sub-chat or session.
    func test_linkFromTheCoordinatorPage_landsInConversations() {
        let landing = MacChatListView.landingForShowingConversation("c2", selected: nil, coordinatorConvoID: "k")
        XCTAssertEqual(landing, .init(nav: .conversations, selection: "c2"))
    }

    /// The Coordinator's own conversation opens on its page and leaves the
    /// Conversations selection where it was (decision #2911).
    func test_linkToTheCoordinator_opensTheCoordinatorPage() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .conversation(id: "c1", pane: nil)))

        let landing = MacChatListView.landingForShowingConversation("k", selected: "c1", coordinatorConvoID: "k")
        XCTAssertEqual(landing, .init(nav: .coordinator, selection: "c1"))
        history.visit(place(landing, coordinator: "k"))

        XCTAssertEqual(history.current, MacPlace(detail: .coordinator(id: "k", pane: nil)))
        XCTAssertTrue(history.canGoBack)
    }

    /// The window-level host routes a tap on a known conversation to the
    /// shell's `open`, and drops one this device has never seen.
    func test_hostOpensOnlyKnownConversations() async {
        let host = ConversationLinkHost()
        host.reset(titleLookup: { $0 == "c2" ? "Auth" : nil })
        host.action("c2")
        let known = await host.resolve(host.pending!)
        host.action("ghost")
        let unknown = await host.resolve(host.pending!)
        XCTAssertEqual(known, "c2")
        XCTAssertNil(unknown)
    }
}
#endif
