import XCTest
import MatronJournal
import MatronEvents
@testable import MatronChat

final class JournalTimelineMapperTests: XCTestCase {
    private let server = URL(string: "https://chat.example.com")!

    private func event(_ seq: Int64, type: String, sender: String = "agent:dev-2",
                       ts: Date = Date(timeIntervalSince1970: 1000),
                       payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: ts,
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

    func testToolOutputWithViewerURLBecomesLiveOutput() throws {
        // The bridge's live-output payload: {tool_use_id, command,
        // viewer_url} — renders the streaming tile, not the static card.
        let item = try XCTUnwrap(map(event(3, type: "tool_output", payload: [
            "tool_use_id": "toolu_01ABC",
            "command": "grep -rn \"needle\" src/ | head -40",
            "viewer_url": "https://viewer2.example.com/live?token=eyJhbGc",
            "expires_at": 1_760_000_000,
        ])))
        guard case .liveOutput(let eventID, let live) = item.kind else { return XCTFail() }
        XCTAssertEqual(eventID, "3")
        XCTAssertEqual(live.toolUseID, "toolu_01ABC")
        XCTAssertEqual(live.command, "grep -rn \"needle\" src/ | head -40")
        XCTAssertEqual(live.viewerURL.host, "viewer2.example.com")
        XCTAssertEqual(live.expiresAt, Date(timeIntervalSince1970: 1_760_000_000))
    }

    func testToolOutputCommandWithoutViewerURLStaysToolCall() throws {
        // Command shape but no viewer_url (live output disabled at the
        // bridge): keep the static command card, command as args.
        let item = try XCTUnwrap(map(event(3, type: "tool_output", payload: [
            "tool_use_id": "toolu_01ABC",
            "command": "grep -rn \"needle\" src/ | head -40",
        ])))
        guard case .toolCall(_, let tool) = item.kind else { return XCTFail() }
        XCTAssertEqual(tool.tool, "grep")
        XCTAssertEqual(tool.argsJSON, "grep -rn \"needle\" src/ | head -40")
    }

    // MARK: tool_output command-completion shapes (protocol.md Retention)

    func testToolOutputFreshShapeRendersSnippetAndExit() throws {
        // A live_log payload with the helper's 1970 timestamp would trip the
        // 24h render-time TTL against the real clock — fresh `ts` keeps this
        // test about shape parsing (TTL behavior is pinned separately below).
        let item = try XCTUnwrap(map(event(6, type: "tool_output", ts: Date(), payload: [
            "message_ref": "toolu_01A", "command": "make test",
            "exit_code": 0, "denied": false, "truncated": true,
            "snippet": "$ make test\nAll 12 tests passed",
            "blob_ref": "blob-1", "live_log": true,
        ])))
        guard case .toolCall(_, let tool) = item.kind else { return XCTFail() }
        XCTAssertEqual(tool.tool, "make")
        XCTAssertEqual(tool.argsJSON, "make test")
        XCTAssertEqual(tool.status, .ok)
        XCTAssertEqual(tool.resultText, "$ make test\nAll 12 tests passed")
        XCTAssertTrue(tool.resultTruncated)
        XCTAssertEqual(tool.exitCode, 0)
        XCTAssertFalse(tool.denied)
        XCTAssertFalse(tool.expired)
    }

    func testToolOutputNonzeroExitIsError() throws {
        let item = try XCTUnwrap(map(event(7, type: "tool_output", ts: Date(), payload: [
            "message_ref": "toolu_01B", "command": "make test",
            "exit_code": 2, "denied": false, "truncated": false,
            "snippet": "error: no rule", "blob_ref": NSNull(), "live_log": true,
        ])))
        guard case .toolCall(_, let tool) = item.kind else { return XCTFail() }
        XCTAssertEqual(tool.status, .error)
        XCTAssertEqual(tool.exitCode, 2)
        XCTAssertEqual(tool.resultText, "error: no rule")
    }

    func testToolOutputDeniedIsError() throws {
        let item = try XCTUnwrap(map(event(8, type: "tool_output", payload: [
            "message_ref": "toolu_01C", "command": "rm -rf /",
            "denied": true, "truncated": false, "live_log": true,
        ])))
        guard case .toolCall(_, let tool) = item.kind else { return XCTFail() }
        XCTAssertEqual(tool.status, .error)
        XCTAssertTrue(tool.denied)
    }

    func testToolOutputTombstoneRendersExpired() throws {
        // Server tombstone after the 24h purge: same fields minus snippet.
        let item = try XCTUnwrap(map(event(9, type: "tool_output", payload: [
            "message_ref": "toolu_01D", "command": "make", "exit_code": 0,
            "denied": false, "truncated": false, "live_log": true,
            "expired": true, "blob_ref": NSNull(),
        ])))
        guard case .toolCall(_, let tool) = item.kind else { return XCTFail() }
        XCTAssertTrue(tool.expired)
        XCTAssertNil(tool.resultText)
        XCTAssertEqual(tool.exitCode, 0)
        XCTAssertEqual(tool.status, .ok, "expiry hides output; it isn't a failure")
    }

    func testToolOutputLocalTTLExpiresStaleCachedSnippet() {
        // Binding client rule: drop a cached live_log snippet once ts + 24h
        // passes locally, even though the stored payload still carries it.
        let payload: [String: Any] = [
            "message_ref": "toolu_01E", "command": "ls",
            "exit_code": 0, "snippet": "file.txt", "live_log": true,
        ]
        let ts = Date(timeIntervalSince1970: 1000)
        let fresh = JournalTimelineMapper.toolCallEvent(
            fromToolOutput: payload, ts: ts,
            now: ts.addingTimeInterval(23 * 3600))
        XCTAssertFalse(fresh.expired)
        XCTAssertEqual(fresh.resultText, "file.txt")

        let stale = JournalTimelineMapper.toolCallEvent(
            fromToolOutput: payload, ts: ts,
            now: ts.addingTimeInterval(25 * 3600))
        XCTAssertTrue(stale.expired)
        XCTAssertNil(stale.resultText)
    }

    func testToolOutputTTLDoesNotTouchNonLiveLogPayloads() {
        // The retention OFFLOAD shape ({snippet, blob_ref}, 30-day job) keeps
        // its snippet server-side forever — the 24h TTL is live_log-only.
        let payload: [String: Any] = ["command": "ls", "snippet": "file.txt"]
        let ts = Date(timeIntervalSince1970: 1000)
        let old = JournalTimelineMapper.toolCallEvent(
            fromToolOutput: payload, ts: ts,
            now: ts.addingTimeInterval(48 * 3600))
        XCTAssertFalse(old.expired)
        XCTAssertEqual(old.resultText, "file.txt")
    }

    func testToolOutputMultilineCommandLabelIsFirstToken() throws {
        let item = try XCTUnwrap(map(event(4, type: "tool_output", payload: [
            "command": "cd /home/x\necho hi\ngrep foo bar",
        ])))
        guard case .toolCall(_, let tool) = item.kind else { return XCTFail() }
        XCTAssertEqual(tool.tool, "cd")
    }

    func testConvoMetaIsSkippedInTimeline() throws {
        XCTAssertNil(map(event(5, type: "convo_meta", payload: ["title": "New title"])),
                     "convo_meta updates the conversation row, not the timeline")
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

    func testActivityLabels() {
        XCTAssertEqual(JournalTimelineMapper.activityLabel(state: .thinking, detail: nil), "Thinking…")
        XCTAssertEqual(JournalTimelineMapper.activityLabel(state: .tool, detail: "Bash"), "Running Bash")
        // Empty / whitespace detail falls back to a generic label.
        XCTAssertEqual(JournalTimelineMapper.activityLabel(state: .tool, detail: "  "), "Working…")
        XCTAssertEqual(JournalTimelineMapper.activityLabel(state: .tool, detail: nil), "Working…")
        // idle has no label — the caller renders nothing.
        XCTAssertNil(JournalTimelineMapper.activityLabel(state: .idle, detail: nil))
    }

    func testActivityItem() {
        let item = JournalTimelineMapper.activityItem(label: "Thinking…",
                                                      convoTS: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(item.id, "activity")
        XCTAssertFalse(item.isOwn)
        guard case .activityIndicator(let label) = item.kind else { return XCTFail() }
        XCTAssertEqual(label, "Thinking…")
    }
}
