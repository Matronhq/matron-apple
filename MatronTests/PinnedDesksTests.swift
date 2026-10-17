import XCTest
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels
@testable import Matron

/// Pinned desk chats on the iPhone (journal "Pinned desk chats"): the
/// Pinned section's rows and the Coordinator tab's badge.
final class PinnedDesksTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)

    func testARowShowsTheConversationsTitleUnderTheLabel() {
        let pin = ConvoPin(convoID: "c1", label: "Inbox triage", emoji: "📮")
        let summary = ChatSummary(id: "c1", title: "Yes, I accept", bot: bot, lastActivity: nil, unreadCount: 0)
        XCTAssertEqual(PinnedDeskRow.secondaryLine(pin: pin, summary: summary), "Yes, I accept")
        XCTAssertEqual(PinnedDeskRow.secondaryLine(pin: pin, summary: nil), "", "not loaded yet")
    }

    func testAMissingPinSaysWhatIsLeftToDo() {
        let pin = ConvoPin(convoID: "c1", label: "Inbox triage", missing: true)
        XCTAssertEqual(PinnedDeskRow.secondaryLine(pin: pin, summary: nil), "Conversation gone — move or unpin")
    }

    func testEditTargetsAreDistinctSheets() {
        let pin = ConvoPin(convoID: "c1", label: "Inbox triage")
        XCTAssertNotEqual(PinEditTarget.new(convoID: "c1", suggestedLabel: "x").id, PinEditTarget.edit(pin).id)
    }

    func testCoordinatorTabBadgeIsNeedsYouElseAnUnreadDot() {
        func counts(unread: Int, needs: Int) -> ChatCounts { ChatCounts(unread: unread, needsYou: needs) }
        XCTAssertNil(AppShellView.coordinatorBadge(counts(unread: 0, needs: 0)))
        XCTAssertEqual(AppShellView.coordinatorBadge(counts(unread: 3, needs: 0)), "•")
        XCTAssertEqual(AppShellView.coordinatorBadge(counts(unread: 3, needs: 2)), "2")
        XCTAssertEqual(AppShellView.coordinatorBadge(counts(unread: 0, needs: 120)), "99+")
    }
}
