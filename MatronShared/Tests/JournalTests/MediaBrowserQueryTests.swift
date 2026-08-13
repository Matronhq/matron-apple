import XCTest
@testable import MatronJournal

/// Pins the two read-only queries behind the media & links browser: type
/// filtering, newest-first ordering, per-conversation isolation (sub-chats
/// excluded), and the LIKE '%http%' link prefilter.
final class MediaBrowserQueryTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
                       type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testAttachmentEventsFiltersTypesAndOrdersNewestFirst() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "image", payload: ["blob_ref": "b1"]),
            event(2, type: "text", payload: ["body": "not an attachment"]),
            event(3, type: "file", payload: ["blob_ref": "b3", "name": "a.pdf"]),
            event(4, type: "tool_output", payload: ["blob_ref": "b4"]),
            event(5, type: "image", payload: ["expired": true]),
        ])
        let result = try store.attachmentEvents(convoID: "c1")
        XCTAssertEqual(result.map(\.seq), [5, 3, 1], "images+files only, newest first")
        XCTAssertEqual(result.map(\.type), ["image", "file", "image"])
    }

    func testAttachmentEventsIsolatesConversations() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "image", payload: ["blob_ref": "b1"]),
            event(2, convo: "c1:sub:x", type: "image", payload: ["blob_ref": "b2"]),
            event(3, convo: "c2", type: "file", payload: ["blob_ref": "b3", "name": "z"]),
        ])
        XCTAssertEqual(try store.attachmentEvents(convoID: "c1").map(\.seq), [1],
                       "a parent chat must not pool its sub-chats' media")
    }

    func testLinkCandidateEventsPrefilterAndOrdering() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, payload: ["body": "see https://example.com/a"]),
            event(2, payload: ["body": "no links here"]),
            event(3, payload: ["body": "also http://plain.example"]),
            event(4, type: "image", payload: ["blob_ref": "b", "caption": "https://in-caption.example"]),
            event(5, convo: "c2", payload: ["body": "https://other-convo.example"]),
        ])
        let result = try store.linkCandidateEvents(convoID: "c1")
        XCTAssertEqual(result.map(\.seq), [3, 1],
                       "text events with an http substring, this convo only, newest first")
    }
}
