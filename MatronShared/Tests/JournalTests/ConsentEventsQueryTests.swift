import XCTest
@testable import MatronJournal

/// Pins the live query behind the consent card in item detail: the
/// `permission_request` and `spawn_outcome` rows of ONE conversation, in
/// seq order, nothing else — a card and its resolution are the only two
/// events a consent item needs, and scanning a long conversation's every
/// row for them would be the wrong shape. Live, because the card can sync
/// after the item was opened.
final class ConsentEventsQueryTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
                       type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private func first(_ stream: AsyncStream<[JournalEvent]>) async throws -> [JournalEvent] {
        for await rows in stream { return rows }
        throw XCTSkip("stream ended without a value")
    }

    func testConsentEventsFiltersTypesAndOrdersBySeq() async throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "permission_request", payload: ["kind": "agent_spawn", "request_id": "spawn-1", "task": "Run the spec"]),
            event(2, type: "text", payload: ["body": "chatter"]),
            event(3, type: "spawn_outcome", payload: ["request_id": "spawn-1", "outcome": "started", "room_id": "room-7"]),
            event(4, type: "permission_request", payload: ["kind": "agent_chat", "justification": "x"]),
            event(5, type: "prompt", payload: ["body": "not a card"]),
        ])
        let result = try await first(store.consentEventsStream(convoID: "c1"))
        XCTAssertEqual(result.map(\.seq), [1, 3, 4], "consent cards and spawn outcomes only, oldest first")
        XCTAssertEqual(result.map(\.type), ["permission_request", "spawn_outcome", "permission_request"])
    }

    func testConsentEventsIsolatesConversations() async throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "spawn_outcome", payload: ["request_id": "spawn-1", "outcome": "started"]),
            event(2, convo: "c1:sub:x", type: "spawn_outcome", payload: ["request_id": "spawn-2", "outcome": "started"]),
            event(3, convo: "c2", type: "permission_request", payload: ["kind": "agent_spawn", "request_id": "spawn-3", "task": "t"]),
        ])
        let c1 = try await first(store.consentEventsStream(convoID: "c1"))
        XCTAssertEqual(c1.map(\.seq), [1], "a parent chat must not pool its sub-chats' cards")
        let c3 = try await first(store.consentEventsStream(convoID: "c3"))
        XCTAssertEqual(c3.map(\.seq), [], "an unknown conversation reads empty, not as an error")
    }

    /// The push-open case: the item is on screen before its card has
    /// synced. The stream must carry the card in when it lands.
    func testConsentEventsStreamEmitsACardThatLandsLater() async throws {
        let store = try makeStore()
        var iterator = store.consentEventsStream(convoID: "c1").makeAsyncIterator()
        let before = await iterator.next()
        XCTAssertEqual(before?.map(\.seq), [], "nothing yet")
        try store.insertHistory([
            event(1, type: "text", payload: ["body": "chatter"]),
            event(2, type: "permission_request", payload: ["kind": "agent_spawn", "request_id": "spawn-1", "task": "t"]),
        ])
        let after = await iterator.next()
        XCTAssertEqual(after?.map(\.seq), [2], "the card, once it is in the store")
    }
}
