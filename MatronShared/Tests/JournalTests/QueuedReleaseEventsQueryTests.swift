import XCTest
@testable import MatronJournal

/// Pins the live query behind an item thread's queued replies (2026-10-01):
/// one conversation's `queued_release` cards (`prompt`) and releases
/// (`prompt_reply`), oldest first, and nothing else — not ordinary prompts
/// and answers, not text that merely mentions the word.
final class QueuedReleaseEventsQueryTests: XCTestCase {
    private func event(_ seq: Int64, convo: String = "c1", type: String, payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:dev-2", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testQueuedReleaseRowsOnlyThisConversationOldestFirstAndLive() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.insertHistory([
            event(1, type: "prompt", payload: ["kind": "queued_release", "prompt_id": "pr_a", "item": ["item_id": "it_1", "comment_id": "ic_1"]]),
            event(2, type: "prompt", payload: ["question": "A or B?"]),
            event(3, type: "text", payload: ["body": "the queued_release card"]),
            event(4, type: "prompt_reply", payload: ["target_seq": 2, "choice": "A"]),
            event(5, convo: "c2", type: "prompt", payload: ["kind": "queued_release", "prompt_id": "pr_b"]),
        ])
        var it = store.queuedReleaseEventsStream(convoID: "c1").makeAsyncIterator()
        let before = await it.next()
        XCTAssertEqual(before?.map(\.seq), [1])
        try store.insertHistory([event(6, type: "prompt_reply", payload: ["kind": "queued_release", "prompt_id": "pr_a", "action": "send"])])
        let after = await it.next()
        XCTAssertEqual(after?.map(\.seq), [1, 6], "the release, once it is in the store")
    }
}
