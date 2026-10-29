import XCTest
import MatronModels
@testable import MatronChat

/// `ChatSummary` shares its fields across copies, and the service hands an
/// unchanged row on as last snapshot's instance, so the chat list's
/// main-actor compare is a pointer check for it.
final class ChatSummaryCarryOverTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil)

    private func summary(_ id: String, title: String = "Chat", unread: Int = 0) -> ChatSummary {
        ChatSummary(id: id, title: title, bot: bot, lastActivity: Date(timeIntervalSince1970: 10),
                    unreadCount: unread, snippet: "hi", roomBoxNames: ["a", "b"], roomBoxShorts: ["A", "B"])
    }

    func testSummariesCompareAndHashByValue() {
        let a = summary("c1"), b = summary("c1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertFalse(a.isSameInstance(as: b))
        XCTAssertNotEqual(a, summary("c1", unread: 1))
        XCTAssertNotEqual(a, summary("c1", title: "Other"))
        XCTAssertEqual(a.roomBoxShorts, ["A", "B"])
    }

    func testAnUnchangedRowIsCarriedOverAndAChangedOneIsNot() {
        let earlier = [summary("c1"), summary("c2")]
        let previous = Dictionary(uniqueKeysWithValues: earlier.map { ($0.id, $0) })
        let fresh = [summary("c1"), summary("c2", unread: 3), summary("c3")]

        let carried = JournalChatService.carryingOver(fresh, from: previous)

        XCTAssertEqual(carried, fresh)
        XCTAssertTrue(carried[0].isSameInstance(as: earlier[0]))
        XCTAssertFalse(carried[1].isSameInstance(as: earlier[1]))
        XCTAssertEqual(carried[1].unreadCount, 3)
        XCTAssertTrue(carried[2].isSameInstance(as: fresh[2]))
    }

    func testTheFirstSnapshotPassesThrough() {
        let fresh = [summary("c1")]
        XCTAssertTrue(JournalChatService.carryingOver(fresh, from: [:])[0].isSameInstance(as: fresh[0]))
    }
}
