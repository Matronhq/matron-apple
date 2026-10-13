import XCTest
@testable import MatronChat
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// The chat list a store serves from its `ConversationIndex` (the
/// `store.changeFeed` flag) sorts and groups exactly as the one it serves
/// from the value observation, through the same summary mapping and
/// `ChatListViewModel.group` the app uses.
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
        try store.setHidden(true, convoID: "hidden")
        try store.applyJournal(event(16, convo: "child", ts: now, type: "convo_meta",
                                     payload: ["parent_convo_id": "today-a", "title": "Child"]))
    }

    private func groups(usesChangeFeed: Bool, now: Date) async throws -> [ChatListViewModel.GroupedSummaries] {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: StoreMetrics(),
                                     usesChangeFeed: usesChangeFeed)
        try seed(store, now: now)
        var iterator = store.conversationsStream().makeAsyncIterator()
        let recordsNext = await iterator.next()
        let records = try XCTUnwrap(recordsNext)
        let summaries = records.map { JournalChatService.summary(from: $0, boxNames: [:]) }
        return ChatListViewModel.group(summaries: summaries, now: now)
    }

    func testIndexChatListGroupsExactlyAsTheObservationDoes() async throws {
        let now = Date()
        let fromIndex = try await groups(usesChangeFeed: true, now: now)
        let fromObservation = try await groups(usesChangeFeed: false, now: now)
        XCTAssertEqual(fromIndex, fromObservation)
        XCTAssertGreaterThanOrEqual(fromIndex.count, 3, "the fixture spans several recency groups")
        XCTAssertFalse(fromIndex.flatMap(\.summaries).contains { $0.id == "hidden" || $0.id == "child" })
    }
}
