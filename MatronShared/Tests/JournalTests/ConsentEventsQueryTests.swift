import XCTest
@testable import MatronJournal

/// Pins the read-only query behind the consent card in item detail: the
/// `permission_request` and `spawn_outcome` rows of ONE conversation, in
/// seq order, nothing else — a card and its resolution are the only two
/// events a consent item needs, and scanning a long conversation's every
/// row for them would be the wrong shape.
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

    func testConsentEventsFiltersTypesAndOrdersBySeq() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "permission_request", payload: ["kind": "agent_spawn", "request_id": "spawn-1", "task": "Run the spec"]),
            event(2, type: "text", payload: ["body": "chatter"]),
            event(3, type: "spawn_outcome", payload: ["request_id": "spawn-1", "outcome": "started", "room_id": "room-7"]),
            event(4, type: "permission_request", payload: ["kind": "agent_chat", "justification": "x"]),
            event(5, type: "prompt", payload: ["body": "not a card"]),
        ])
        let result = try store.consentEvents(convoID: "c1")
        XCTAssertEqual(result.map(\.seq), [1, 3, 4], "consent cards and spawn outcomes only, oldest first")
        XCTAssertEqual(result.map(\.type), ["permission_request", "spawn_outcome", "permission_request"])
    }

    func testConsentEventsIsolatesConversations() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "spawn_outcome", payload: ["request_id": "spawn-1", "outcome": "started"]),
            event(2, convo: "c1:sub:x", type: "spawn_outcome", payload: ["request_id": "spawn-2", "outcome": "started"]),
            event(3, convo: "c2", type: "permission_request", payload: ["kind": "agent_spawn", "request_id": "spawn-3", "task": "t"]),
        ])
        XCTAssertEqual(try store.consentEvents(convoID: "c1").map(\.seq), [1],
                       "a parent chat must not pool its sub-chats' cards")
        XCTAssertEqual(try store.consentEvents(convoID: "c3").map(\.seq), [], "an unknown conversation reads empty, not as an error")
    }
}
