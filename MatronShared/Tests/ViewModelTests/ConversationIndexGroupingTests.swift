import XCTest
@testable import MatronChat
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// The chat list a store serves from its `ConversationIndex` sorts and
/// groups exactly as the store's SQL read of the table, through the same
/// summary mapping and `ChatListViewModel.group` the app uses.
final class ConversationIndexGroupingTests: XCTestCase {
    private func event(_ seq: Int64, convo: String, ts: Date, type: String = "text",
                       payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: ts, sender: "agent:box-2", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// Today, yesterday, this week and earlier rows, ties, a row with no
    /// activity time, a hidden row and a child.
    private func seed(_ store: JournalStore, now: Date) throws {
        let hour: TimeInterval = 3600
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "never", title: "Never active", sessionState: "waiting", lastSeq: 3,
                            snippet: "", createdAt: 0),
            ConvoSummaryDTO(id: "earlier", title: "Earlier", sessionState: "done", lastSeq: 4,
                            snippet: "", createdAt: 0, lastTS: Int64(now.addingTimeInterval(-40 * 24 * hour).timeIntervalSince1970 * 1000)),
        ], headSeq: 10)
        try store.applyJournal(event(11, convo: "today-a", ts: now.addingTimeInterval(-hour)))
        try store.applyJournal(event(12, convo: "today-b", ts: now.addingTimeInterval(-hour)))
        try store.applyJournal(event(13, convo: "yesterday", ts: now.addingTimeInterval(-26 * hour)))
        try store.applyJournal(event(14, convo: "week", ts: now.addingTimeInterval(-4 * 24 * hour)))
        try store.applyJournal(event(15, convo: "hidden", ts: now))
        try store.setArchived(["hidden"], archived: true)
        try store.applyJournal(event(16, convo: "child", ts: now, type: "convo_meta",
                                     payload: ["parent_convo_id": "today-a", "title": "Child"]))
    }

    private func groups(_ records: [ConversationRecord], now: Date) -> [ChatListViewModel.GroupedSummaries] {
        let summaries = records.map { JournalChatService.summary(from: $0, boxNames: [:]) }
        return ChatListViewModel.group(summaries: summaries, now: now)
    }

    /// The chat list the index serves groups exactly as the store's own
    /// SQL read of the same rows does.
    func testIndexChatListGroupsExactlyAsTheTableRead() async throws {
        let now = Date()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: StoreMetrics())
        try seed(store, now: now)
        var iterator = store.conversationsStream().makeAsyncIterator()
        let recordsNext = await iterator.next()
        let fromIndex = groups(try XCTUnwrap(recordsNext), now: now)
        let fromTable = groups(try store.conversations(now: now), now: now)
        XCTAssertEqual(fromIndex, fromTable)
        XCTAssertGreaterThanOrEqual(fromIndex.count, 3, "the fixture spans several recency groups")
        XCTAssertFalse(fromIndex.flatMap(\.summaries).contains { $0.id == "hidden" || $0.id == "child" })
    }
}
