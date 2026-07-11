import XCTest
import MatronJournal
import MatronEvents
@testable import MatronChat

final class JournalTimelineMapperTests: XCTestCase {
    private let server = URL(string: "https://chat.example.com")!

    private func event(_ seq: Int64, type: String, sender: String = "agent:dev-2",
                       payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: 1000),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private func map(_ e: JournalEvent) -> TimelineItem? {
        JournalTimelineMapper.timelineItem(from: e, ownSender: "user:dan", serverURL: server)
    }

    func testTextEvent() throws {
        let item = try XCTUnwrap(map(event(5, type: "text", payload: ["body": "hello"])))
        XCTAssertEqual(item.id, "5")
        XCTAssertEqual(item.sender, "dev-2")
        XCTAssertFalse(item.isOwn)
        guard case .text(let body, _) = item.kind else { return XCTFail() }
        XCTAssertEqual(body, "hello")
    }

    func testOwnDetection() throws {
        let item = try XCTUnwrap(map(event(1, type: "text", sender: "user:dan", payload: ["body": "x"])))
        XCTAssertTrue(item.isOwn)
        XCTAssertEqual(item.sender, "dan")
    }

    func testToolOutputFallbackConstruction() throws {
        let item = try XCTUnwrap(map(event(2, type: "tool_output",
                                           payload: ["tool_name": "Bash", "snippet": "ls -la", "truncated": true])))
        guard case .toolCall(let eventID, let tool) = item.kind else { return XCTFail() }
        XCTAssertEqual(eventID, "2")
        XCTAssertEqual(tool.tool, "Bash")
        XCTAssertEqual(tool.resultText, "ls -la")
        XCTAssertTrue(tool.resultTruncated)
        XCTAssertEqual(tool.status, .ok)
    }

    func testPromptWithOptions() throws {
        let item = try XCTUnwrap(map(event(3, type: "prompt", payload: [
            "question": "Deploy?",
            "options": [["id": "y", "label": "Yes"], ["id": "n", "label": "No"]],
            "allows_free_text": true,
        ])))
        guard case .askUser(let eventID, let ask) = item.kind else { return XCTFail() }
        XCTAssertEqual(eventID, "3")
        XCTAssertEqual(ask.prompt, "Deploy?")
        XCTAssertEqual(ask.replyChannel, .buttonResponse)
        guard case .choice(let options, let allowOther) = ask.kind else { return XCTFail() }
        XCTAssertEqual(options.map(\.label), ["Yes", "No"])
        XCTAssertTrue(allowOther)
    }

    func testPromptWithoutOptionsIsFreeText() throws {
        let item = try XCTUnwrap(map(event(4, type: "prompt", payload: ["question": "Name?"])))
        guard case .askUser(_, let ask) = item.kind else { return XCTFail() }
        XCTAssertEqual(ask.replyChannel, .textReply)
        guard case .text = ask.kind else { return XCTFail("expected free-text kind") }
    }

    func testPromptReplyWithChoiceHidesAsAnswer() throws {
        let item = try XCTUnwrap(map(event(6, type: "prompt_reply", sender: "user:dan",
                                           payload: ["target_seq": 3, "choice": "Yes"])))
        guard case .askUserAnswer(let promptID, let values) = item.kind else { return XCTFail() }
        XCTAssertEqual(promptID, "3")
        XCTAssertEqual(values, ["Yes"])
        XCTAssertEqual(item.inReplyToEventID, "3")
    }

    func testPromptReplyWithTextRendersAsReply() throws {
        let item = try XCTUnwrap(map(event(7, type: "prompt_reply", sender: "user:dan",
                                           payload: ["target_seq": 4, "text": "call it matron"])))
        guard case .text(let body, _) = item.kind else { return XCTFail() }
        XCTAssertEqual(body, "call it matron")
        XCTAssertEqual(item.inReplyToEventID, "4")
    }

    func testPromptReplyWithoutTargetFallsBackToUnknown() throws {
        let item = try XCTUnwrap(map(event(12, type: "prompt_reply", sender: "user:dan",
                                           payload: ["choice": "Yes"])))
        guard case .unknown(let type) = item.kind else { return XCTFail("expected labeled fallback") }
        XCTAssertEqual(type, "prompt_reply")
        XCTAssertNil(item.inReplyToEventID)
    }

    func testImageBuildsMediaURL() throws {
        let item = try XCTUnwrap(map(event(8, type: "image",
                                           payload: ["blob_ref": "b123", "content_type": "image/png"])))
        guard case .image(let url, _, _) = item.kind else { return XCTFail() }
        XCTAssertEqual(url?.absoluteString, "https://chat.example.com/media/b123")
    }

    func testSkippedAndUnknownTypes() throws {
        XCTAssertNil(map(event(9, type: "read_marker", payload: ["up_to_seq": 5])))
        XCTAssertNil(map(event(10, type: "session_status", payload: ["state": "done"])))
        let item = try XCTUnwrap(map(event(11, type: "shiny_new_thing", payload: ["x": 1])))
        guard case .unknown(let type) = item.kind else { return XCTFail() }
        XCTAssertEqual(type, "shiny_new_thing")
    }

    func testStreamingItem() {
        let item = JournalTimelineMapper.streamingItem(messageRef: "m1", text: "working…",
                                                       convoTS: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(item.id, "eph:m1")
        guard case .text(let body, _) = item.kind else { return XCTFail() }
        XCTAssertEqual(body, "working…")
    }
}
