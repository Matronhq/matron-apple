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

    func testDiffEventMapsToRichDiffKind() throws {
        let item = try XCTUnwrap(map(event(42, type: "diff", payload: [
            "file_path": "/w/Sources/A.swift",
            "display_path": "Sources/A.swift",
            "viewer_url": "https://v.example/view?token=t",
            "tool": "Edit",
            "diff": "@@ -1,1 +1,1 @@\n-a\n+b",
            "added": 1, "removed": 1,
            "truncated": false, "new_file": false,
        ])))
        guard case .diff(let eventID, let evt) = item.kind else {
            return XCTFail("expected .diff, got \(item.kind)")
        }
        XCTAssertEqual(eventID, "42")
        XCTAssertEqual(evt.filename, "A.swift")
        XCTAssertEqual(evt.added, 1)
        XCTAssertFalse(item.isOwn)
    }

    func testBareDiffPayloadStillRenders() throws {
        let item = try XCTUnwrap(map(event(43, type: "diff", payload: ["diff": "+only"])))
        guard case .diff(_, let evt) = item.kind else {
            return XCTFail("expected .diff, got \(item.kind)")
        }
        XCTAssertEqual(evt.diff, "+only")
        XCTAssertNil(evt.filename)
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

    // MARK: - queued_release (bridge busy-queue cards)

    func testQueuedReleasePromptCarriesItsPromptID() throws {
        let item = try XCTUnwrap(map(event(20, type: "prompt", payload: [
            "kind": "queued_release",
            "prompt_id": "pr_abc",
            "question": "Send all 2 queued messages now, or cancel this one?",
            "options": [
                ["id": "send", "label": "⚡ Send all now", "value": "send"],
                ["id": "cancel", "label": "✕ Cancel this", "value": "cancel"],
            ],
            "mode": "pick_one",
        ])))
        guard case .askUser(_, let ask) = item.kind else { return XCTFail() }
        XCTAssertEqual(ask.queuedReleasePromptID, "pr_abc",
                       "the card must remember its bridge prompt id so releases can find it")
    }

    func testOrdinaryPromptHasNoQueuedReleasePromptID() throws {
        let item = try XCTUnwrap(map(event(3, type: "prompt", payload: [
            "question": "Deploy?",
            "options": [["id": "y", "label": "Yes"]],
        ])))
        guard case .askUser(_, let ask) = item.kind else { return XCTFail() }
        XCTAssertNil(ask.queuedReleasePromptID)
    }

    /// The bridge's durable release frame carries prompt_id + action but no
    /// target_seq and no choice — it must hide as a namespaced answer row
    /// (retiring the card's buttons on every device), not render as an
    /// empty text bubble.
    func testQueuedReleaseReplyHidesAsNamespacedAnswer() throws {
        let item = try XCTUnwrap(map(event(21, type: "prompt_reply", sender: "agent:bridge",
                                           payload: [
                                               "kind": "queued_release",
                                               "prompt_id": "pr_abc",
                                               "action": "send",
                                               "released": ["pr_abc::0"],
                                           ])))
        guard case .askUserAnswer(let promptID, let values) = item.kind else {
            return XCTFail("expected hidden answer row, got \(item.kind)")
        }
        XCTAssertEqual(promptID, "qr:pr_abc")
        XCTAssertEqual(values, ["send"])
    }

    func testImageBuildsMediaURL() throws {
        let item = try XCTUnwrap(map(event(8, type: "image",
                                           payload: ["blob_ref": "b123", "content_type": "image/png"])))
        guard case .image(let url, _, _, _) = item.kind else { return XCTFail() }
        XCTAssertEqual(url?.absoluteString, "https://chat.example.com/media/b123")
    }

    func testSkippedAndUnknownTypes() throws {
        XCTAssertNil(map(event(9, type: "read_marker", payload: ["up_to_seq": 5])))
        XCTAssertNil(map(event(10, type: "session_status", payload: ["state": "done"])))
        let item = try XCTUnwrap(map(event(11, type: "shiny_new_thing", payload: ["x": 1])))
        guard case .unknown(let type) = item.kind else { return XCTFail() }
        XCTAssertEqual(type, "shiny_new_thing")
    }

    func testSummaryEventsAreExcludedFromTranscript() {
        XCTAssertNil(map(event(11, type: "summary", payload: ["toc": "Fixed auth", "detail": "…", "model": "m"])))
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

    // MARK: tool_stream overlay items

    func testToolStreamItemShape() {
        let item = JournalTimelineMapper.toolStreamItem(
            messageRef: "tu1", command: "make test", text: "$ make test\nok\n",
            headTruncated: false, convoTS: Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(item.id, "toolstream:tu1")
        XCTAssertEqual(item.sender, "agent")
        XCTAssertFalse(item.isOwn)
        XCTAssertEqual(item.timestamp, Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(item.kind, .toolStreamLive(
            messageRef: "tu1", command: "make test", text: "$ make test\nok\n", headTruncated: false))
    }

    func testToolStreamTextDropsIncompleteTrailingMultibyte() {
        // "é" is 0xC3 0xA9; feed only the lead byte after "ok" — a chunk
        // boundary mid-character must not render a replacement glyph.
        XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: [0x6F, 0x6B, 0xC3]), "ok")
        // Complete sequence renders fully.
        XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: [0x6F, 0x6B, 0xC3, 0xA9]), "oké")
        // Four-byte emoji missing its last byte is trimmed too.
        XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: [0x6F] + Array("😀".utf8).dropLast()), "o")
        // Pure ASCII untouched.
        XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: Array("done\n".utf8)), "done\n")
    }

    func testToolStreamTextCapsDisplayToTail() {
        let bytes = Array(String(repeating: "a", count: 100).utf8)
        XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: bytes, displayCapBytes: 10),
                       String(repeating: "a", count: 10))
        // Cap cut landing mid-multibyte drops the orphaned continuation bytes.
        let multi = Array("xx😀".utf8) // 2 + 4 bytes
        XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: multi, displayCapBytes: 3), "")
    }

    // MARK: - Media events

    /// Regression: the mapper read `payload["filename"]`, but the key the
    /// media-send contract defines — and the key both producers actually
    /// emit — is `name`. So the `?? "file"` fallback fired every time and
    /// every file in the timeline rendered as a generic "file", whatever it
    /// was really called.
    func testFileEventUsesTheNameKeyTheProducersActuallySend() throws {
        let item = map(event(1, type: "file", payload: [
            "blob_ref": "b1", "name": "quarterly-report.pdf",
            "content_type": "application/pdf", "size": 1234,
        ]))

        guard case let .file(_, filename, _, sizeBytes, _)? = item?.kind else {
            return XCTFail("expected a file item, got \(String(describing: item?.kind))")
        }
        XCTAssertEqual(filename, "quarterly-report.pdf")
        XCTAssertEqual(sizeBytes, 1234)
    }

    /// A file with no name at all still renders, rather than dropping the
    /// event — the fallback is meant for this case, and only this case.
    func testFileEventWithoutANameFallsBackToAPlaceholder() throws {
        let item = map(event(1, type: "file", payload: ["blob_ref": "b1"]))

        guard case let .file(_, filename, _, _, _)? = item?.kind else {
            return XCTFail("expected a file item")
        }
        XCTAssertEqual(filename, "file")
    }

    func testImageEventCarriesItsCaption() throws {
        let item = map(event(1, type: "image", payload: [
            "blob_ref": "b2", "name": "cat.png",
            "content_type": "image/png", "caption": "what breed is this?",
        ]))

        guard case let .image(url, caption, _, _)? = item?.kind else {
            return XCTFail("expected an image item")
        }
        XCTAssertEqual(caption, "what breed is this?")
        XCTAssertEqual(url?.absoluteString, "https://chat.example.com/media/b2")
    }

    /// Captions aren't image-only: a PDF sent with "review this before
    /// Friday" has to show the sentence too.
    func testFileEventCarriesItsCaption() throws {
        let item = map(event(1, type: "file", payload: [
            "blob_ref": "b3", "name": "contract.pdf", "caption": "review this before Friday",
        ]))

        guard case let .file(_, _, caption, _, _)? = item?.kind else {
            return XCTFail("expected a file item")
        }
        XCTAssertEqual(caption, "review this before Friday")
    }

    /// A reaped attachment (journal media reaper, matron-journal#63)
    /// arrives tombstoned: blob_ref null + expired:true, with name/size/
    /// caption intact — the kind must carry the flag so the chip can say
    /// "Expired" instead of offering a dead download.
    func testExpiredFileTombstoneMapsWithExpiredFlag() throws {
        let item = map(event(1, type: "file", payload: [
            "blob_ref": NSNull(), "name": "old.pdf", "size": 1234, "expired": true,
        ]))
        guard case let .file(url, filename, _, sizeBytes, expired)? = item?.kind else {
            return XCTFail("expected a file item")
        }
        XCTAssertNil(url)
        XCTAssertEqual(filename, "old.pdf")
        XCTAssertEqual(sizeBytes, 1234)
        XCTAssertTrue(expired)
    }

    func testExpiredImageTombstoneMapsWithExpiredFlag() throws {
        let item = map(event(1, type: "image", payload: [
            "blob_ref": NSNull(), "caption": "old shot", "expired": true,
        ]))
        guard case let .image(url, caption, _, expired)? = item?.kind else {
            return XCTFail("expected an image item")
        }
        XCTAssertNil(url)
        XCTAssertEqual(caption, "old shot")
        XCTAssertTrue(expired)
    }

    /// Live attachments must not read as expired — the flag defaults false
    /// when the payload carries none.
    func testLiveAttachmentIsNotExpired() throws {
        let item = map(event(1, type: "file", payload: ["blob_ref": "b1", "name": "a.pdf"]))
        guard case let .file(_, _, _, _, expired)? = item?.kind else {
            return XCTFail("expected a file item")
        }
        XCTAssertFalse(expired)
    }

    // MARK: Agent-chat consent card

    func testAgentChatPermissionRequestMapsToItsOwnKind() throws {
        let item = try XCTUnwrap(map(event(11, type: "permission_request", payload: [
            "kind": "agent_chat", "request": "invite", "room_id": "room-1",
            "from_device_id": 4, "from_name": "dev-2", "target_device_id": 7,
            "topic": "ci triage", "justification": "need the build log",
        ])))
        guard case .agentChatRequest(let eventID, let request) = item.kind else {
            return XCTFail("expected .agentChatRequest, got \(item.kind)")
        }
        XCTAssertEqual(eventID, "11")
        XCTAssertEqual(request.roomID, "room-1")
        XCTAssertEqual(request.targetDeviceID, 7)
    }

    /// The regression this whole case exists for: the agent-chat card has no
    /// `description`/`options`, so the generic branch rendered it as the
    /// literal words "Permission request" with Allow/Deny buttons that
    /// answered over `prompt_reply` — a channel that never reaches the
    /// parked row, so the tap did nothing at all.
    func testAgentChatCardNoLongerFallsBackToAGenericPrompt() throws {
        let item = try XCTUnwrap(map(event(12, type: "permission_request", payload: [
            "kind": "agent_chat", "request": "join", "room_id": "r",
            "from_device_id": 4, "target_device_id": 4,
        ])))
        if case .askUser(_, let evt) = item.kind {
            XCTFail("mapped to a generic ask with prompt \(evt.prompt)")
        }
    }

    func testNonAgentChatPermissionRequestKeepsTheGenericRendering() throws {
        let item = try XCTUnwrap(map(event(13, type: "permission_request", payload: [
            "description": "Allow writing to /etc?", "options": ["Allow", "Deny"],
        ])))
        guard case .askUser(_, let evt) = item.kind else {
            return XCTFail("expected .askUser, got \(item.kind)")
        }
        XCTAssertEqual(evt.prompt, "Allow writing to /etc?")
    }

    /// A card whose payload is missing something the answer call needs is
    /// unanswerable — and its answer channel is HTTP, not `prompt_reply`, so
    /// the generic card's Allow/Deny would be dead buttons. It renders as an
    /// inert notice instead.
    func testUnanswerableAgentChatPayloadRendersAsAnInertNotice() throws {
        let item = try XCTUnwrap(map(event(14, type: "permission_request", payload: [
            "kind": "agent_chat", "request": "invite", "from_device_id": 4,
        ])))
        guard case .stateChange = item.kind else {
            return XCTFail("expected the inert notice, got \(item.kind)")
        }
    }

    // MARK: Agent-spawn consent card

    func testAgentSpawnPermissionRequestMapsToItsOwnKind() throws {
        let item = try XCTUnwrap(map(event(21, type: "permission_request", payload: [
            "kind": "agent_spawn", "request_id": "spawn-1",
            "from_device_id": 4, "from_name": "dev-2",
            "from_convo_id": "68385da9", "from_convo_title": "Syncing bridge services",
            "target_device_id": 7, "target_name": "dev-6",
            "workdir": "/srv/app", "task": "Rebase and push", "topic": "spawn wiring",
        ])))
        guard case .agentSpawnRequest(let eventID, let request) = item.kind else {
            return XCTFail("expected .agentSpawnRequest, got \(item.kind)")
        }
        XCTAssertEqual(eventID, "21", "the journal seq, as a string")
        XCTAssertEqual(request.requestID, "spawn-1")
        XCTAssertEqual(request.task, "Rebase and push")
    }

    /// The two consent cards share an event type and are told apart by
    /// `kind` alone — neither parser may claim the other's payload.
    func testAgentChatAndAgentSpawnCardsDoNotClaimEachOther() throws {
        let chat = try XCTUnwrap(map(event(22, type: "permission_request", payload: [
            "kind": "agent_chat", "request": "invite", "room_id": "r",
            "from_device_id": 4, "target_device_id": 7,
        ])))
        guard case .agentChatRequest = chat.kind else {
            return XCTFail("expected .agentChatRequest, got \(chat.kind)")
        }
        let spawn = try XCTUnwrap(map(event(23, type: "permission_request", payload: [
            "kind": "agent_spawn", "request_id": "spawn-2", "task": "do a thing",
        ])))
        guard case .agentSpawnRequest = spawn.kind else {
            return XCTFail("expected .agentSpawnRequest, got \(spawn.kind)")
        }
    }

    /// Unanswerable (no `request_id`) — the spawn flow answers over
    /// `POST /agent-spawn/answer`, never `prompt_reply`, so the generic
    /// card's Allow/Deny would be dead buttons until the ask expired. An
    /// inert notice carrying the headline is right; buttons that go nowhere
    /// are not.
    func testUnanswerableAgentSpawnPayloadRendersAsAnInertNotice() throws {
        let item = try XCTUnwrap(map(event(24, type: "permission_request", payload: [
            "kind": "agent_spawn", "task": "Rebase and push",
        ])))
        guard case .stateChange(let text) = item.kind else {
            return XCTFail("expected the inert notice, got \(item.kind)")
        }
        XCTAssertTrue(text.contains("Rebase and push"))
    }

    // MARK: Spawn outcome

    func testSpawnOutcomeMapsToItsOwnRow() throws {
        let item = try XCTUnwrap(map(event(25, type: "spawn_outcome", sender: "journal", payload: [
            "request_id": "spawn-1", "outcome": "started",
            "room_id": "room-9", "child_convo_id": "convo-9",
        ])))
        guard case .spawnOutcomeRow(let eventID, let outcome) = item.kind else {
            return XCTFail("expected .spawnOutcomeRow, got \(item.kind)")
        }
        XCTAssertEqual(eventID, "25")
        XCTAssertEqual(item.id, "25", "eventID and the row id are the same seq string")
        XCTAssertEqual(outcome.requestID, "spawn-1")
        XCTAssertEqual(outcome.openableRoomID, "room-9")
    }

    /// A malformed outcome must not vanish silently — it falls into the same
    /// unknown-event handling every other unparseable row uses.
    func testMalformedSpawnOutcomeFallsBackToUnknown() throws {
        let item = try XCTUnwrap(map(event(26, type: "spawn_outcome", sender: "journal",
                                           payload: ["outcome": "started"])))
        guard case .unknown(let eventType) = item.kind else {
            return XCTFail("expected .unknown, got \(item.kind)")
        }
        XCTAssertEqual(eventType, "spawn_outcome")
    }
}
