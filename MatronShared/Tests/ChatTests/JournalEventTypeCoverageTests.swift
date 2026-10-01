import XCTest
import MatronEvents
import MatronJournal
@testable import MatronChat

/// Every event type the journal can store — matron-journal's
/// `AGENT_PUBLISH_TYPES` and `CLIENT_SEND_TYPES` (src/ws.js) plus the types
/// only the journal itself appends — must be either drawn or deliberately
/// hidden, never the grey "[unsupported event: …]" fallback. `routine` and
/// `consent_decision` both reached Dan's Mac as that fallback after shipping
/// server-side. When the journal grows a type, add it here.
final class JournalEventTypeCoverageTests: XCTestCase {
    static let journalEventTypes = [
        // agent publish
        "text", "prompt", "prompt_reply", "tool_output", "diff", "permission_request", "file", "image", "edit", "summary",
        // journal-appended
        "convo_meta", "read_marker", "session_status", "spawn_outcome", "consent_decision",
        "coordinator", "item", "memory", "milestone", "mission", "routine",
    ]

    /// A representative well-formed payload per type: enough for the
    /// mapper's parsers to accept it, so the test proves the type's own
    /// branch is reached rather than a malformed-payload skip.
    static let payloads: [String: [String: Any]] = [
        "text": ["body": "hi"],
        "prompt": ["question": "Go?", "options": ["Yes", "No"]],
        "prompt_reply": ["reply_to": "1", "value": "Yes"],
        "tool_output": ["tool": "Bash", "output": "ok"],
        "diff": ["diff": "--- a\n+++ b\n"],
        "permission_request": ["description": "Run ls?"],
        "file": ["url": "https://j/blob/1", "name": "a.pdf"],
        "image": ["url": "https://j/blob/2"],
        "edit": ["target_seq": 1, "body": "edited"],
        "summary": ["toc": "Fixed auth", "detail": "…"],
        "convo_meta": ["title": "Chat"],
        "read_marker": ["seq": 1],
        "session_status": ["state": "running"],
        "spawn_outcome": ["request_id": "sp_1", "outcome": "started"],
        "consent_decision": ["kind": "spawn", "request_id": "sp_1", "decision": "approve",
                             "by": "coordinator", "convo_id": "coord", "reason": "Fits the box rules"],
        "coordinator": ["role": "assigned"],
        "item": ["item_id": "it_1", "num": 3, "kind": "task", "title": "Do it", "action": "created", "by": "agent"],
        "memory": ["memory_id": "me_1", "name": "x", "action": "saved", "created": true, "by": "agent"],
        "milestone": ["milestone_id": "ml_1", "num": 4, "kind": "progress", "title": "Done",
                      "mission_id": "ms_1", "mission_num": 2, "by": "agent"],
        "mission": ["mission_id": "ms_1", "num": 2, "action": "created", "by": "agent"],
        "routine": ["routine_id": "rt_1", "name": "daily-sweep", "action": "fired", "outcome": "applied now"],
    ]

    func testNoJournalEventTypeFallsBackToUnsupported() throws {
        for type in Self.journalEventTypes {
            let payload = try XCTUnwrap(Self.payloads[type], "no sample payload for \(type)")
            let event = JournalEvent(seq: 5, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:bev",
                                     type: type, payloadData: try JSONSerialization.data(withJSONObject: payload))
            let item = JournalTimelineMapper.timelineItem(from: event, ownSender: "user:dan",
                                                         serverURL: URL(string: "https://j")!)
            if case .unknown = item?.kind {
                XCTFail("journal event type \(type) renders as [unsupported event]")
            }
        }
    }
}
