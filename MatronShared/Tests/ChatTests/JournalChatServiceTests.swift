import XCTest
import MatronJournal
@testable import MatronChat

final class JournalChatServiceTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func makeService(_ store: JournalStore) -> JournalChatService {
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = JournalSyncEngine(api: api, store: store, connector: FakeChatConnector(),
                                       token: "t", ownSender: "user:dan", search: nil)
        return JournalChatService(store: store, engine: engine)
    }

    func testChatSummariesMapAndStream() async throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "Fix build", sessionState: "running",
                            lastSeq: 3, snippet: "s", createdAt: 1_752_000_000_000),
        ], headSeq: 3)
        let service = makeService(store)
        var iterator = service.chatSummaries().makeAsyncIterator()
        let summaries = try await iterator.next()
        XCTAssertEqual(summaries?.count, 1)
        XCTAssertEqual(summaries?.first?.id, "c1")
        XCTAssertEqual(summaries?.first?.title, "Fix build")
        XCTAssertEqual(summaries?.first?.unreadCount, 0)
        XCTAssertNotNil(summaries?.first?.lastActivity)
    }

    func testUntitledConvoFallsBackToID() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "sess-42", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"x"}"#.utf8)))
        let service = makeService(store)
        var iterator = service.chatSummaries().makeAsyncIterator()
        let summaries = try await iterator.next()
        XCTAssertEqual(summaries?.first?.title, "sess-42")
        XCTAssertEqual(summaries?.first?.unreadCount, 1)
    }

    func testCreateChatThrowsGracefully() async throws {
        let service = makeService(try makeStore())
        do {
            _ = try await service.createChat(with: "claude")
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is JournalChatError)
        }
    }

    func testLeaveHidesConversation() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"x"}"#.utf8)))
        let service = makeService(store)
        try await service.leave(roomID: "c1")
        XCTAssertEqual(try store.conversations().count, 0)
    }

    func testForceSnapshotIsBestEffortWhenOffline() async throws {
        // refreshSummaries is best-effort: unreachable API must not throw.
        let store = try makeStore()
        let service = makeService(store)
        try await service.forceSnapshot() // must not throw or hang
    }

}

/// Never connects — enough for list tests that only read the store.
final class FakeChatConnector: WebSocketConnecting, @unchecked Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection {
        throw JournalConnectionError.socketClosed
    }
}
