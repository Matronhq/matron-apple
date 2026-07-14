import XCTest
@testable import MatronJournal

final class WireModelsTests: XCTestCase {
    func testDecodeJournalFrame() throws {
        let text = #"{"kind":"journal","seq":43,"convo_id":"c-abc","ts":1752200000000,"sender":"user:dan","type":"text","payload":{"body":"hi"}}"#
        guard case let .journal(event)? = ServerFrame.decode(text) else {
            return XCTFail("expected journal frame")
        }
        XCTAssertEqual(event.seq, 43)
        XCTAssertEqual(event.convoID, "c-abc")
        XCTAssertEqual(event.sender, "user:dan")
        XCTAssertEqual(event.type, "text")
        XCTAssertEqual(event.ts, Date(timeIntervalSince1970: 1_752_200_000))
        XCTAssertEqual(event.payload["body"] as? String, "hi")
    }

    func testDecodeControlAndEphemeralFrames() throws {
        guard case let .helloOK(head)? = ServerFrame.decode(#"{"kind":"control","op":"hello_ok","seq":42}"#) else {
            return XCTFail("expected hello_ok")
        }
        XCTAssertEqual(head, 42)

        guard case let .error(code, ref)? = ServerFrame.decode(#"{"kind":"control","op":"error","code":"forbidden","ref":"send"}"#) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(code, "forbidden")
        XCTAssertEqual(ref, "send")

        guard case .snapshotRequired? = ServerFrame.decode(#"{"kind":"control","op":"snapshot_required"}"#) else {
            return XCTFail("snapshot_required must decode as its own first-class case")
        }

        guard case let .ephemeral(update)? = ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m7","replace_text":"progress 3"}"#) else {
            return XCTFail("expected ephemeral")
        }
        XCTAssertEqual(update.messageRef, "m7")
        XCTAssertEqual(update.replaceText, "progress 3")
        XCTAssertNil(update.textDelta)
    }

    func testDecodeActivityEphemeralFrames() throws {
        // `thinking` — a bare working indicator, no detail.
        guard case let .activity(thinking)? = ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","activity":{"state":"thinking"}}"#) else {
            return XCTFail("expected thinking activity")
        }
        XCTAssertEqual(thinking.convoID, "c1")
        XCTAssertEqual(thinking.state, .thinking)
        XCTAssertNil(thinking.detail)

        // `tool` carries the tool name in `detail`.
        guard case let .activity(tool)? = ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","activity":{"state":"tool","detail":"Bash"}}"#) else {
            return XCTFail("expected tool activity")
        }
        XCTAssertEqual(tool.state, .tool)
        XCTAssertEqual(tool.detail, "Bash")

        // `idle` clears — decodes as a valid activity update.
        guard case let .activity(idle)? = ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","activity":{"state":"idle"}}"#) else {
            return XCTFail("expected idle activity")
        }
        XCTAssertEqual(idle.state, .idle)

        // An unknown state is dropped (nil), not misdecoded.
        XCTAssertNil(ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","activity":{"state":"dancing"}}"#))
    }

    func testDecodeToolStreamAppendFrame() throws {
        let frame = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"append","offset":7,"chunk":"hello\n"}}"#)
        XCTAssertEqual(frame, .toolStream(ToolStreamUpdate(
            convoID: "c1", messageRef: "tu1", event: .append(offset: 7, chunk: "hello\n"))))
    }

    func testDecodeToolStreamSyncFrame() throws {
        let frame = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"sync","meta":{"tool":"Bash","command":"make"},"offset":0,"content":"$ make\n","head_truncated":false}}"#)
        XCTAssertEqual(frame, .toolStream(ToolStreamUpdate(
            convoID: "c1", messageRef: "tu1",
            event: .sync(tool: "Bash", command: "make", offset: 0, content: "$ make\n", headTruncated: false))))
    }

    func testDecodeToolStreamSyncWithoutMetaAndTruncatedHead() throws {
        let frame = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"sync","offset":512,"content":"tail","head_truncated":true}}"#)
        XCTAssertEqual(frame, .toolStream(ToolStreamUpdate(
            convoID: "c1", messageRef: "tu1",
            event: .sync(tool: nil, command: nil, offset: 512, content: "tail", headTruncated: true))))
    }

    func testDecodeToolStreamEndFrame() throws {
        let frame = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"end","reason":"stale"}}"#)
        XCTAssertEqual(frame, .toolStream(ToolStreamUpdate(
            convoID: "c1", messageRef: "tu1", event: .end(reason: "stale"))))
    }

    func testDecodeToolStreamUnknownEventSkipsFrame() {
        XCTAssertNil(ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"wat"}}"#))
    }

    /// Regression: tool_stream frames used to fall through to the
    /// text-streaming fallback (they carry message_ref, no text keys) and
    /// painted an EMPTY streaming bubble whenever a command streamed while
    /// the chat was open. They must never decode as `.ephemeral` again.
    func testToolStreamFrameDoesNotDecodeAsEmptyTextEphemeral() throws {
        let frame = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"append","offset":0,"chunk":"x"}}"#)
        if case .ephemeral = frame {
            XCTFail("tool_stream frame decoded as text-streaming EphemeralUpdate")
        }
    }

    func testStreamEphemeralStillRequiresMessageRef() {
        // Relaxing the ephemeral guard for activity frames must not let a
        // streaming frame through without its `message_ref`.
        XCTAssertNil(ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","text":"hi"}"#))
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(ServerFrame.decode("not json"))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"journal","seq":"nope"}"#))
    }

    func testEncodeClientOps() throws {
        func obj(_ op: ClientOp) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(op.encoded().utf8)) as? [String: Any])
        }
        let hello = try obj(.hello(token: "t", cursor: 5))
        XCTAssertEqual(hello["op"] as? String, "hello")
        XCTAssertEqual(hello["cursor"] as? Int64, 5)

        let send = try obj(.send(convoID: "c1", body: "hi", localID: "L1"))
        XCTAssertEqual(send["op"] as? String, "send")
        XCTAssertEqual(send["type"] as? String, "text")
        XCTAssertEqual((send["payload"] as? [String: Any])?["body"] as? String, "hi")
        XCTAssertEqual(send["local_id"] as? String, "L1")

        let reply = try obj(.promptReply(convoID: "c1", targetSeq: 40, choice: "yes", text: nil))
        XCTAssertEqual(reply["target_seq"] as? Int64, 40)
        XCTAssertEqual(reply["choice"] as? String, "yes")
        XCTAssertTrue(reply["text"] is NSNull)

        let viewingNil = try obj(.viewing(convoID: nil))
        XCTAssertTrue(viewingNil["convo_id"] is NSNull)

        let ack = try obj(.ack(cursor: 42))
        XCTAssertEqual(ack["cursor"] as? Int64, 42)

        let marker = try obj(.readMarker(convoID: "c1", upToSeq: 40))
        XCTAssertEqual(marker["op"] as? String, "read_marker")
        XCTAssertEqual(marker["up_to_seq"] as? Int64, 40)
    }
}
