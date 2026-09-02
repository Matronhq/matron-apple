import XCTest
import MatronModels
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

        guard case let .error(code, ref, _, _)? = ServerFrame.decode(#"{"kind":"control","op":"error","code":"forbidden","ref":"send"}"#) else {
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

        let media = try obj(.sendMedia(convoID: "c1", type: "image", blobRef: "b9",
                                       name: "cat.png", contentType: "image/png", size: 42,
                                       caption: nil, batch: nil, localID: "L2"))
        XCTAssertEqual(media["op"] as? String, "send")
        XCTAssertEqual(media["type"] as? String, "image")
        XCTAssertEqual(media["blob_ref"] as? String, "b9")
        XCTAssertEqual(media["local_id"] as? String, "L2")
        let mediaPayload = media["payload"] as? [String: Any]
        XCTAssertEqual(mediaPayload?["blob_ref"] as? String, "b9")
        XCTAssertEqual(mediaPayload?["name"] as? String, "cat.png")
        XCTAssertEqual(mediaPayload?["content_type"] as? String, "image/png")
        XCTAssertEqual(mediaPayload?["size"] as? Int, 42)
        XCTAssertNil(mediaPayload?["caption"], "a captionless send omits the key rather than sending null")

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

    /// JSON-decodes an op's wire form. Mirrors the local helper inside
    /// `testEncodeClientOps` — hoisted so the media-caption tests below can
    /// share it.
    private func encodedObject(_ op: ClientOp) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(op.encoded().utf8)) as? [String: Any])
    }

    /// The caption has to land inside `payload`, because that's the part of
    /// a media send the server stores verbatim and replays to the bridge.
    /// Putting it anywhere else would look fine here and silently never
    /// reach claude.
    func testEncodeSendMediaCarriesTheCaptionInsideThePayload() throws {
        let media = try encodedObject(.sendMedia(convoID: "c1", type: "image", blobRef: "b9",
                                                  name: "cat.png", contentType: "image/png", size: 42,
                                                  caption: "what breed is this?", batch: nil, localID: "L2"))

        let payload = try XCTUnwrap(media["payload"] as? [String: Any])
        XCTAssertEqual(payload["caption"] as? String, "what breed is this?")
    }

    /// The batch tag rides inside `payload` for the same reason the caption
    /// does — that's the only part of a media send the server stores
    /// verbatim and replays to the bridge, which gathers frames sharing a
    /// `batch_id` into one prompt.
    func testEncodeSendMediaCarriesTheBatchTagInsideThePayload() throws {
        let media = try encodedObject(.sendMedia(convoID: "c1", type: "image", blobRef: "b9",
                                                  name: "cat.png", contentType: "image/png", size: 42,
                                                  caption: nil,
                                                  batch: AttachmentBatchTag(id: "B7", index: 2, total: 3),
                                                  localID: "L2"))

        let payload = try XCTUnwrap(media["payload"] as? [String: Any])
        XCTAssertEqual(payload["batch_id"] as? String, "B7")
        XCTAssertEqual(payload["batch_index"] as? Int, 2)
        XCTAssertEqual(payload["batch_total"] as? Int, 3)
    }

    /// An untagged send omits the batch keys entirely — a lone attachment's
    /// frame stays byte-identical to what an older bridge understands.
    func testEncodeSendMediaOmitsBatchKeysWhenUntagged() throws {
        let media = try encodedObject(.sendMedia(convoID: "c1", type: "image", blobRef: "b9",
                                                  name: "cat.png", contentType: "image/png", size: 42,
                                                  caption: nil, batch: nil, localID: "L2"))

        let payload = try XCTUnwrap(media["payload"] as? [String: Any])
        XCTAssertNil(payload["batch_id"])
        XCTAssertNil(payload["batch_index"])
        XCTAssertNil(payload["batch_total"])
    }

    /// An empty caption is the same as no caption — an attachment sent from
    /// an empty composer must not carry an empty string down to claude.
    func testEncodeSendMediaTreatsAnEmptyCaptionAsAbsent() throws {
        let media = try encodedObject(.sendMedia(convoID: "c1", type: "image", blobRef: "b9",
                                                  name: "cat.png", contentType: "image/png", size: 42,
                                                  caption: "", batch: nil, localID: "L2"))

        let payload = try XCTUnwrap(media["payload"] as? [String: Any])
        XCTAssertNil(payload["caption"])
    }

    func testDecodeSessionStatusEphemeralFrame() throws {
        let text = #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"claude-fable-5","email":"dan@example.com","context":{"tokens":265000,"window":1000000,"pct":27},"limits":[{"label":"Week (Fable)","percent":80,"resets":"Jul 12, 6:59pm (UTC)","resets_at":"2026-07-12T18:59:00.000Z"}]}}"#
        guard case let .sessionStatus(update)? = ServerFrame.decode(text) else {
            return XCTFail("expected sessionStatus frame")
        }
        XCTAssertEqual(update.convoID, "c1")
        XCTAssertEqual(update.model, "claude-fable-5")
        XCTAssertEqual(update.email, "dan@example.com")
        XCTAssertEqual(update.context, SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(update.limits, [SessionStatus.Limit(
            label: "Week (Fable)", percent: 80,
            resets: "Jul 12, 6:59pm (UTC)",
            resetsAt: iso.date(from: "2026-07-12T18:59:00.000Z"))])
        XCTAssertNil(update.taskRef, "a normal conversation's status carries no task_ref")
    }

    /// The bridge publishes the session's absolute workdir and a host
    /// CPU/RAM sample (`vitals`, top-level — deliberately NOT a limits[]
    /// entry, so it can't render as a subscription meter) on every frame.
    func testDecodeSessionStatusCarriesWorkdirAndVitals() throws {
        let text = #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"claude-fable-5","workdir":"/Users/dan/Dev/matron-bridge","vitals":{"cpu_pct":12,"ram_pct":63,"sampled_at_ms":1754172000000}}}"#
        guard case let .sessionStatus(update)? = ServerFrame.decode(text) else {
            return XCTFail("expected sessionStatus frame")
        }
        XCTAssertEqual(update.workdir, "/Users/dan/Dev/matron-bridge")
        XCTAssertEqual(update.vitals, SessionStatus.Vitals(cpuPct: 12, ramPct: 63))
    }

    func testDecodeSessionStatusVitalsDegradeGracefully() throws {
        // cpu_pct is null until the bridge's sampler has two samples — the
        // RAM half must survive alone.
        guard case let .sessionStatus(ramOnly)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"vitals":{"cpu_pct":null,"ram_pct":63,"sampled_at_ms":1}}}"#) else {
            return XCTFail("expected sessionStatus frame with ram-only vitals")
        }
        XCTAssertEqual(ramOnly.vitals, SessionStatus.Vitals(cpuPct: nil, ramPct: 63))

        // A vitals object with neither number decodes as absent vitals, so
        // the merge keeps the last good sample instead of blanking it.
        guard case let .sessionStatus(empty)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"m","vitals":{"sampled_at_ms":1}}}"#) else {
            return XCTFail("expected sessionStatus frame with empty vitals")
        }
        XCTAssertNil(empty.vitals)
        XCTAssertNil(empty.workdir)
        XCTAssertEqual(empty.model, "m")
    }

    /// Phase 2 of the 2026-08-10 composer-suggestions spec: the bridge
    /// publishes the lists it owns (`model_options`, `effort_levels`) plus
    /// the current `effort`, and the palette serves them as `/model` and
    /// `/effort` argument suggestions. `label` is optional — a value with
    /// no label displays as itself.
    func testDecodeSessionStatusCarriesSuggestionListsAndEffort() throws {
        let text = #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"opus","effort":"high","model_options":[{"value":"opus","label":"Opus"},{"value":"sonnet","label":"Sonnet"}],"effort_levels":[{"value":"low","label":"Low"},{"value":"xhigh"}]}}"#
        guard case let .sessionStatus(update)? = ServerFrame.decode(text) else {
            return XCTFail("expected sessionStatus frame")
        }
        XCTAssertEqual(update.effort, .set("high"))
        XCTAssertEqual(update.modelOptions, [
            SessionStatus.Option(value: "opus", label: "Opus"),
            SessionStatus.Option(value: "sonnet", label: "Sonnet"),
        ])
        XCTAssertEqual(update.effortLevels, [
            SessionStatus.Option(value: "low", label: "Low"),
            SessionStatus.Option(value: "xhigh", label: nil),
        ])
    }

    /// Absent and empty are different statements and must stay different in
    /// the model: an older bridge omits the field entirely (nil — "doesn't
    /// say"), while an agent with nothing to offer sends `[]` ("offers
    /// nothing"). Both render as no suggestions, but only the second may
    /// overwrite a held list. Deliberately unlike `limits`, which collapses
    /// an empty array to nil.
    func testDecodeSessionStatusDistinguishesAbsentFromEmptyOptionLists() throws {
        guard case let .sessionStatus(absent)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"opus"}}"#) else {
            return XCTFail("expected sessionStatus frame from an older bridge")
        }
        XCTAssertNil(absent.modelOptions, "an omitted list is absent, not empty")
        XCTAssertNil(absent.effortLevels)
        XCTAssertNil(absent.effort, "an omitted effort says nothing — a Codex session, or an older bridge")

        guard case let (empty)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model_options":[],"effort_levels":[]}}"#),
              case let .sessionStatus(empty) = empty else {
            return XCTFail("expected sessionStatus frame with empty lists")
        }
        XCTAssertEqual(empty.modelOptions, [])
        XCTAssertEqual(empty.effortLevels, [])

        // An entry without a `value` carries nothing selectable and is
        // skipped; the good ones survive, as with limits[].
        guard case let .sessionStatus(mixed)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model_options":[{"label":"Nameless"},{"value":"opus"}]}}"#) else {
            return XCTFail("expected sessionStatus frame with a malformed option")
        }
        XCTAssertEqual(mixed.modelOptions?.map(\.value), ["opus"])
    }

    /// A non-empty array whose entries ALL fail to parse is a malformed
    /// frame, not the agent saying it offers nothing. Decoding it to `[]`
    /// would let a garbled frame overwrite a good list with "nothing" —
    /// so it degrades to nil (silence) and the held list stands. A wire
    /// `[]` is still a statement and still overwrites.
    func testDecodeSessionStatusAllMalformedOptionsSayNothing() throws {
        guard case let .sessionStatus(garbled)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model_options":[{"label":"Nameless"}],"effort_levels":["low"]}}"#) else {
            return XCTFail("expected sessionStatus frame with unparseable options")
        }
        XCTAssertNil(garbled.modelOptions, "all-malformed is silence, not an empty offer")
        XCTAssertNil(garbled.effortLevels, "entries of the wrong shape entirely are silence too")

        // The consequence that matters: a held list survives the garbled
        // frame, and a genuine empty one still clears it.
        var status = SessionStatus(
            modelOptions: [SessionStatus.Option(value: "opus", label: "Opus")])
        status.apply(garbled)
        XCTAssertEqual(status.modelOptions?.map(\.value), ["opus"],
                       "a garbled frame must not retract what the session offers")

        guard case let .sessionStatus(none)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model_options":[]}}"#) else {
            return XCTFail("expected sessionStatus frame with an empty list")
        }
        status.apply(none)
        XCTAssertEqual(status.modelOptions, [], "a wire [] is still a statement and still lands")
    }

    /// `effort` is the one tri-state field on the frame. A missing key and
    /// a JSON null mean different things and must decode differently:
    /// missing is silence (Codex, or a bridge that predates the field),
    /// null is the bridge saying it is no longer tracking a level.
    func testDecodeSessionStatusEffortIsTriState() throws {
        guard case let .sessionStatus(tracked)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"effort":"xhigh"}}"#) else {
            return XCTFail("expected sessionStatus frame with a tracked effort")
        }
        XCTAssertEqual(tracked.effort, .set("xhigh"))

        guard case let .sessionStatus(cleared)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"opus","effort":null}}"#) else {
            return XCTFail("expected sessionStatus frame with a null effort")
        }
        XCTAssertEqual(cleared.effort, .cleared, "an explicit null is a clear, not an absence")
        XCTAssertEqual(cleared.model, "opus", "the rest of the frame decodes as usual")

        guard case let .sessionStatus(omitted)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"gpt-5"}}"#) else {
            return XCTFail("expected sessionStatus frame with no effort key")
        }
        XCTAssertNil(omitted.effort, "a missing key is silence — it must not decode as a clear")

        // A number, a bool, an object: none of them are a level, and none
        // of them are the bridge saying it stopped tracking. Say nothing.
        guard case let .sessionStatus(junk)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"effort":7}}"#) else {
            return XCTFail("expected sessionStatus frame with a malformed effort")
        }
        XCTAssertNil(junk.effort)
    }

    func testDecodeSessionStatusCarriesTaskRefForChild() throws {
        // A subagent child's status frame rides `task_ref` (the parent's
        // spawning Task tool_use_id), replayed on `viewing` so the app can
        // link the Task card to the child.
        let text = #"{"kind":"ephemeral","convo_id":"p1:sub:a1","status":{"model":"claude-fable-5","task_ref":"toolu_abc123"}}"#
        guard case let .sessionStatus(update)? = ServerFrame.decode(text) else {
            return XCTFail("expected sessionStatus frame")
        }
        XCTAssertEqual(update.convoID, "p1:sub:a1")
        XCTAssertEqual(update.model, "claude-fable-5")
        XCTAssertEqual(update.taskRef, "toolu_abc123")
    }

    func testDecodeSessionStatusPartialAndMalformed() throws {
        // Context-only frame: model / limits stay nil.
        guard case let .sessionStatus(partial)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"context":{"tokens":5000,"window":200000,"pct":3}}}"#) else {
            return XCTFail("expected context-only sessionStatus frame")
        }
        XCTAssertNil(partial.model)
        XCTAssertNil(partial.limits)
        XCTAssertNil(partial.email)
        XCTAssertEqual(partial.context?.tokens, 5000)

        // Malformed resets_at degrades to nil; the raw string survives.
        guard case let .sessionStatus(badDate)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"limits":[{"label":"Session","percent":39,"resets":"soon","resets_at":"not-a-date"}]}}"#) else {
            return XCTFail("expected sessionStatus frame with unparseable resets_at")
        }
        XCTAssertEqual(badDate.limits?.first?.resets, "soon")
        XCTAssertNil(badDate.limits?.first?.resetsAt)

        // A context object missing a required key decodes as nil context.
        guard case let .sessionStatus(noPct)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"m","context":{"tokens":5000}}}"#) else {
            return XCTFail("expected sessionStatus frame with malformed context")
        }
        XCTAssertNil(noPct.context)
        XCTAssertEqual(noPct.model, "m")

        // A limits entry missing label/percent is skipped; the good one survives.
        guard case let .sessionStatus(mixed)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"limits":[{"percent":5},{"label":"Session","percent":39}]}}"#) else {
            return XCTFail("expected sessionStatus frame with mixed limits")
        }
        XCTAssertEqual(mixed.limits?.map(\.label), ["Session"])

        // Plain text-streaming ephemerals must still decode as before.
        guard case .ephemeral? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"m7","text":"hi"}"#) else {
            return XCTFail("text streaming ephemeral regressed")
        }
    }

    // MARK: Agent RPC (protocol.md §Agent RPC)

    func testDecodeRPCResponseFrames() throws {
        guard case let .rpcResponse(ok)? = ServerFrame.decode(
            #"{"kind":"rpc","response":{"request_id":"r1","agent_device_id":9,"ok":true,"result":{"convo_id":"c-new"}}}"#) else {
            return XCTFail("expected rpcResponse frame")
        }
        XCTAssertEqual(ok.requestID, "r1")
        XCTAssertEqual(ok.agentDeviceID, 9)
        XCTAssertTrue(ok.ok)
        let result = try XCTUnwrap(ok.resultData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        XCTAssertEqual(result["convo_id"] as? String, "c-new")
        XCTAssertNil(ok.errorCode)

        guard case let .rpcResponse(fail)? = ServerFrame.decode(
            #"{"kind":"rpc","response":{"request_id":"r2","agent_device_id":9,"ok":false,"error":{"code":"bad_workdir","detail":"/nope"}}}"#) else {
            return XCTFail("expected failing rpcResponse frame")
        }
        XCTAssertFalse(fail.ok)
        XCTAssertEqual(fail.errorCode, "bad_workdir")
        XCTAssertEqual(fail.errorDetail, "/nope")
        XCTAssertNil(fail.resultData)

        // ok:false without an error object still decodes (server enforces
        // error.code, but the client must not crash on a violation).
        guard case let .rpcResponse(bare)? = ServerFrame.decode(
            #"{"kind":"rpc","response":{"request_id":"r3","agent_device_id":9,"ok":false}}"#) else {
            return XCTFail("expected bare failing rpcResponse frame")
        }
        XCTAssertNil(bare.errorCode)

        // An rpc REQUEST frame (agent-side shape) is not for a client — skip.
        XCTAssertNil(ServerFrame.decode(
            #"{"kind":"rpc","request":{"request_id":"r1","from_device_id":7,"method":"start","params":null}}"#))
        // Malformed: missing request_id / ok.
        XCTAssertNil(ServerFrame.decode(#"{"kind":"rpc","response":{"agent_device_id":9,"ok":true}}"#))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"rpc","response":{"request_id":"r1","agent_device_id":9}}"#))
    }

    func testDecodeControlErrorCarriesRequestIDAndDetail() {
        guard case let .error(code, ref, requestID, detail)? = ServerFrame.decode(
            #"{"kind":"control","op":"error","code":"not_ready","ref":"agent_request","request_id":"r9","detail":"mid-replay"}"#) else {
            return XCTFail("expected error frame")
        }
        XCTAssertEqual(code, "not_ready")
        XCTAssertEqual(ref, "agent_request")
        XCTAssertEqual(requestID, "r9")
        XCTAssertEqual(detail, "mid-replay")

        guard case let .error(_, _, noRid, _)? = ServerFrame.decode(
            #"{"kind":"control","op":"error","code":"forbidden","ref":"send"}"#) else {
            return XCTFail("expected plain error frame")
        }
        XCTAssertNil(noRid)
    }

    func testEncodeAgentRequestOp() throws {
        let params = try JSONSerialization.data(withJSONObject: ["workdir": "~/dev", "browser": true])
        let op = ClientOp.agentRequest(requestID: "r1", agentDeviceID: 9,
                                       method: "start", paramsData: params)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(op.encoded().utf8)) as? [String: Any])
        XCTAssertEqual(obj["op"] as? String, "agent_request")
        XCTAssertEqual(obj["request_id"] as? String, "r1")
        XCTAssertEqual(obj["agent_device_id"] as? Int64, 9)
        XCTAssertEqual(obj["method"] as? String, "start")
        let sent = obj["params"] as? [String: Any]
        XCTAssertEqual(sent?["workdir"] as? String, "~/dev")
        XCTAssertEqual(sent?["browser"] as? Bool, true)

        // Unparseable params degrade to {} rather than dropping the frame.
        let broken = ClientOp.agentRequest(requestID: "r2", agentDeviceID: 9,
                                           method: "recent_folders", paramsData: Data("junk".utf8))
        let brokenObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(broken.encoded().utf8)) as? [String: Any])
        XCTAssertEqual((brokenObj["params"] as? [String: Any])?.isEmpty, true)
    }

    func testDecodesDeviceMetaRenameFrame() {
        // A server predating tags and an explicit JSON null both carry a nil
        // tag, but they are NOT the same frame: only the null is
        // authoritative. `tagCharKnown` is that distinction, and the store
        // needs it to avoid clearing a migration-seeded letter on a rename
        // from a pre-tag journal.
        let frame = ServerFrame.decode(#"{"kind":"device_meta","device_id":7,"name":"dev-y"}"#)
        XCTAssertEqual(frame, .deviceMeta(id: 7, name: "dev-y", tagChar: nil, tagCharKnown: false))
        let nullTag = ServerFrame.decode(#"{"kind":"device_meta","device_id":7,"name":"dev-y","tag_char":null}"#)
        XCTAssertEqual(nullTag, .deviceMeta(id: 7, name: "dev-y", tagChar: nil, tagCharKnown: true))
        let tagged = ServerFrame.decode(#"{"kind":"device_meta","device_id":7,"name":"dev-y","tag_char":"y"}"#)
        XCTAssertEqual(tagged, .deviceMeta(id: 7, name: "dev-y", tagChar: "y", tagCharKnown: true))
        // Malformed frames are skipped, not crashed on.
        XCTAssertNil(ServerFrame.decode(#"{"kind":"device_meta","name":"dev-y"}"#))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"device_meta","device_id":7}"#))
    }
}
