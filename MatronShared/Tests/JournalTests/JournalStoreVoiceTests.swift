import GRDB
import XCTest
@testable import MatronJournal
import MatronModels

/// Voice mode's store reads and the `summary` spoken fields (spec
/// 2026-10-03 §1, §3, §5).
final class JournalStoreVoiceTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:bev",
                       type: String = "text", ts: TimeInterval? = nil,
                       payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: ts ?? Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: summary spoken fields

    func testSummaryDecodesTheSpokenLines() throws {
        let entry = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: [
            "toc": "Deploy finished", "detail": "All green.", "model": "gpt",
            "spoken": "  The deploy finished. Shall I merge?  ",
            "spoken_more": "Every test passed and the cache was rebuilt.",
            "spoken_ref": "msg_9",
        ])))
        XCTAssertEqual(entry.spoken, "The deploy finished. Shall I merge?")
        XCTAssertEqual(entry.spokenMore, "Every test passed and the cache was rebuilt.")
        XCTAssertEqual(entry.spokenRef, "msg_9")
    }

    /// An old bridge sends none of the keys; a new one omits `spoken_more`
    /// when the model wrote NONE. Null, blank and non-strings read as nil.
    func testAbsentBlankAndNoneReadAsNil() throws {
        let old = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: ["toc": "T", "detail": "D"])))
        XCTAssertNil(old.spoken); XCTAssertNil(old.spokenMore); XCTAssertNil(old.spokenRef)
        let odd = try XCTUnwrap(SummaryEntryRecord(event: event(6, type: "summary", payload: [
            "toc": "T", "spoken": "   ", "spoken_more": "NONE", "spoken_ref": NSNull(),
        ])))
        XCTAssertNil(odd.spoken); XCTAssertNil(odd.spokenMore); XCTAssertNil(odd.spokenRef)
        let wrong = try XCTUnwrap(SummaryEntryRecord(event: event(7, type: "summary", payload: ["toc": "T", "spoken": 12])))
        XCTAssertNil(wrong.spoken)
    }

    func testSpokenLinesAreCutToTheContractCaps() throws {
        let entry = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: [
            "toc": "T", "spoken": String(repeating: "a", count: 500), "spoken_more": String(repeating: "b", count: 1_500),
        ])))
        XCTAssertEqual(entry.spoken?.count, 400)
        XCTAssertEqual(entry.spokenMore?.count, 1_200)
    }

    /// The migration is additive: a cache from before it keeps its rows,
    /// which read nil for the three new columns.
    func testSummarySpokenMigratesUpAndOldRowsReadNil() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "event_convo_type")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_entry(convo_id, seq, toc, detail, created_at) VALUES('c1', 4, 'Old', 'row', 1000)
                """)
        }
        try JournalStore.migrator().migrate(queue)
        try queue.read { db in
            let old = try XCTUnwrap(SummaryEntryRecord.fetchOne(db, sql: "SELECT * FROM summary_entry"))
            XCTAssertEqual(old.toc, "Old")
            XCTAssertNil(old.spoken); XCTAssertNil(old.spokenMore); XCTAssertNil(old.spokenRef)
            let columns = try db.columns(in: "summary_entry").map(\.name)
            XCTAssertTrue(columns.contains("spoken")); XCTAssertTrue(columns.contains("spoken_more"))
            XCTAssertTrue(columns.contains("spoken_ref"))
        }
    }

    func testSpokenLinesSurviveTheLiveApplyAndHistoryPaths() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(2, type: "summary", payload: ["toc": "Live", "spoken": "Live line.", "spoken_ref": "m2"]))
        try store.insertHistory([event(1, type: "summary", payload: ["toc": "Old", "spoken": "Old line."])])
        let entries = try store.summaryEntries(convoID: "c1")
        XCTAssertEqual(entries.map(\.spoken), ["Live line.", "Old line."])
        XCTAssertEqual(entries.first?.spokenRef, "m2")
    }

    // MARK: lastAgentReply / spokenSummary

    func testLastAgentReplyIsTheNewestReferencedTextAboveTheFloor() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "first", "message_ref": "m1"]),
            event(2, sender: "user:dan", payload: ["body": "my question"]),
            event(3, payload: ["body": "thinking out loud", "message_ref": "m3"]),
            event(4, type: "tool_output", payload: ["command": "ls"]),
            event(5, payload: ["body": "the answer", "message_ref": "m5"]),
            event(6, payload: ["body": "mirror of an item", "fallback_for": "item"]),
            event(7, type: "session_status", payload: ["state": "waiting"]),
        ])
        XCTAssertEqual(try store.lastAgentReply(convoID: "c1"),
                       AgentReplyRow(seq: 5, messageRef: "m5", body: "the answer"))
        XCTAssertEqual(try store.lastAgentReply(convoID: "c1", afterSeq: 2)?.seq, 5)
        XCTAssertNil(try store.lastAgentReply(convoID: "c1", afterSeq: 5), "nothing new since the reply already heard")
        XCTAssertNil(try store.lastAgentReply(convoID: "other"))
    }

    /// A long reply is several `text` rows; only the first carries the
    /// ref. The body is all of them. A bridge notice after the turn ended,
    /// or text after a tool call, is not part of it.
    func testALongReplyIsReadAcrossItsChunks() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "Part one.", "message_ref": "m1"]),
            event(2, payload: ["body": "Part two."]),
            event(3, sender: "user:dan", type: "read_marker", payload: ["up_to_seq": 2]),
            event(4, payload: ["body": "Part three."]),
            event(5, type: "session_status", payload: ["state": "waiting"]),
            event(6, payload: ["body": "✅ Always allowing Bash for this session."]),
        ])
        XCTAssertEqual(try store.lastAgentReply(convoID: "c1"),
                       AgentReplyRow(seq: 1, messageRef: "m1", body: "Part one.\n\nPart two.\n\nPart three."))
    }

    /// A bridge that sends no ref on an unstreamed reply: the newest
    /// assistant text stands alone, and has no spoken summary.
    func testAReplyWithoutARefIsTheNewestAssistantText() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "older"]),
            event(2, payload: ["body": "newer"]),
            event(3, type: "summary", payload: ["toc": "T", "spoken": "Line.", "spoken_ref": "m9"]),
        ])
        let reply = try XCTUnwrap(try store.lastAgentReply(convoID: "c1"))
        XCTAssertEqual(reply, AgentReplyRow(seq: 2, messageRef: nil, body: "newer"))
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: reply))
    }

    func testSpokenSummaryMatchesByRef() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "one", "message_ref": "m1"]),
            event(2, type: "summary", payload: ["toc": "A", "spoken": "About one.", "spoken_ref": "m1"]),
            event(3, payload: ["body": "two", "message_ref": "m3"]),
        ])
        let first = AgentReplyRow(seq: 1, messageRef: "m1", body: "one")
        let second = AgentReplyRow(seq: 3, messageRef: "m3", body: "two")
        XCTAssertEqual(try store.spokenSummary(convoID: "c1", for: first)?.spoken, "About one.")
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: second), "the summary for the new reply has not landed")
        _ = try store.applyJournal(event(4, type: "summary", payload: ["toc": "B", "spoken": "About two.", "spoken_ref": "m3"]))
        XCTAssertEqual(try store.spokenSummary(convoID: "c1", for: second)?.spoken, "About two.")
    }

    /// A summary can land after a newer reply was published: its line is
    /// for the older reply and must not be said for the newest one.
    func testALateSummaryForAnOlderReplyIsNotUsedForTheNewestOne() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "old reply", "message_ref": "m1"]),
            event(2, payload: ["body": "new reply", "message_ref": "m2"]),
            event(3, type: "summary", payload: ["toc": "Late", "spoken": "About the old reply.", "spoken_ref": "m1"]),
        ])
        let newest = try XCTUnwrap(try store.lastAgentReply(convoID: "c1"))
        XCTAssertEqual(newest.messageRef, "m2")
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: newest))
    }

    func testASummaryWithoutSpokenIsNotASpokenSummary() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "reply", "message_ref": "m1"]),
            event(2, type: "summary", payload: ["toc": "Old bridge"]),
        ])
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: AgentReplyRow(seq: 1, messageRef: "m1", body: "reply")))
    }

    // MARK: unansweredPrompts

    private func prompt(_ seq: Int64, convo: String = "c1", ts: TimeInterval = 1_000,
                        payload: [String: Any] = ["question": "Which one?", "options": ["A", "B"]]) -> JournalEvent {
        event(seq, convo: convo, type: "prompt", ts: ts, payload: payload)
    }

    func testAPromptNobodyAnsweredIsReturnedWithItsConversation() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, type: "convo_meta", payload: ["title": "[ab] Auth refactor"]),
            prompt(2),
        ])
        let rows = try store.unansweredPrompts(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rows.map(\.event.seq), [2])
        XCTAssertEqual(rows.first?.convoTitle, "[ab] Auth refactor")
        XCTAssertNil(rows.first?.agentName)
    }

    func testAnAnsweredPromptIsLeftOut() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            prompt(1), prompt(2), prompt(3, convo: "c2"), prompt(4, convo: "c3"),
            // A tap on prompt 2 only: prompt 1 is still open.
            event(5, sender: "user:dan", type: "prompt_reply", payload: ["target_seq": 2, "choice": "A"]),
            // Typed instead of tapped: answers everything before it in c2.
            event(6, convo: "c2", sender: "user:dan", payload: ["body": "the second"]),
            // The agent talking after its own prompt answers nothing.
            event(7, convo: "c3", payload: ["body": "still waiting"]),
        ])
        XCTAssertEqual(try store.unansweredPrompts(since: Date(timeIntervalSince1970: 0)).map(\.event.seq), [1, 4])
    }

    func testQueueCardsOldPromptsAndDeadConversationsAreLeftOut() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            prompt(1, payload: ["question": "Queued", "options": ["Send now"], "kind": "queued_release", "prompt_id": "pr_1"]),
            prompt(2, ts: 10),                         // older than `since`
            prompt(3, convo: "done"),
            event(4, convo: "done", type: "session_status", ts: 1_000, payload: ["state": "done"]),
            prompt(5, convo: "live"),
        ])
        XCTAssertEqual(try store.unansweredPrompts(since: Date(timeIntervalSince1970: 500)).map(\.event.seq), [5])
    }
}
