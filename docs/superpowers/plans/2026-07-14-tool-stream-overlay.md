# Tool-Stream Live Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render live command output (`tool_stream` ephemerals) as a terminal tile at the bottom of the timeline, retired by the durable `tool_output` row.

**Architecture:** New `ToolStreamUpdate` wire type decoded ahead of the text-streaming fallback (fixing the empty-bubble bug) → per-convo fan-out on `JournalSyncEngine` → byte-offset bookkeeping on `JournalTimelineService.OverlayState` (append/trim/gap/sync/end/retire) → new `TimelineItem.Kind.toolStreamLive` → new `ToolStreamCard` sharing a `TerminalPane` extracted from `LiveOutputCard`.

**Tech Stack:** Swift 6 SPM package (MatronShared), SwiftUI, swift-snapshot-testing, XCTest with `FakeWebSocket.serve(json)` end-to-end frame injection.

**Spec:** `docs/superpowers/specs/2026-07-14-tool-stream-overlay-design.md`

## Global Constraints

- Branch `feat/tool-stream-overlay` (stacked on `feat/tool-output-durable-ttl`).
- Byte offsets are UTF-8 **byte** positions (protocol.md); all buffer math in bytes, never `String.count`.
- Ephemerals for a retired `message_ref` must be ignored (200 ms late-flush rule), never re-open a tile.
- Client resync mechanism = re-send `viewing` (clients cannot send `stream_append`).
- Legacy `LiveOutputEvent`/`LiveOutputSession` viewer-WebSocket path stays behavior-identical.
- Never commit `Matron/App/Info.plist` / `MatronMac/App/Info.plist` (local NSAllowsLocalNetworking edits).
- SPM tests: `swift test --package-path MatronShared` filtered per task; snapshot flow = write test → run (auto-records, fails) → run again (green) → eyeball pngs.
- Run `xcodegen generate` before any xcodebuild.

---

### Task 1: WireModels — `ToolStreamUpdate` + decode branch

**Files:**
- Modify: `MatronShared/Sources/Journal/WireModels.swift` (after `ActivityUpdate`, ~line 108; decode ephemeral branch ~line 129)
- Test: `MatronShared/Tests/JournalTests/WireModelsTests.swift`

**Interfaces:**
- Produces: `ToolStreamUpdate {convoID: String, messageRef: String, event: Event}` with `Event = .append(offset: Int, chunk: String) | .sync(tool: String?, command: String?, offset: Int, content: String, headTruncated: Bool) | .end(reason: String?)`; `ServerFrame.toolStream(ToolStreamUpdate)`.

- [ ] **Step 1: Write the failing tests** — append to `WireModelsTests.swift`:

```swift
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

/// Regression: tool_stream frames used to fall through to the text-streaming
/// fallback (they carry message_ref, no text keys) and painted an EMPTY
/// streaming bubble whenever a command streamed. They must never decode as
/// `.ephemeral` again.
func testToolStreamFrameDoesNotDecodeAsEmptyTextEphemeral() throws {
    let frame = ServerFrame.decode(
        #"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"append","offset":0,"chunk":"x"}}"#)
    if case .ephemeral = frame { XCTFail("tool_stream frame decoded as text-streaming EphemeralUpdate") }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MatronShared --filter WireModelsTests 2>&1 | tail -5`
Expected: compile FAILURE — `ToolStreamUpdate` not defined.

- [ ] **Step 3: Implement** — in `WireModels.swift`, after `ActivityUpdate` (before `ServerFrame`):

```swift
/// One live tool-output stream frame (journal `tool_stream` ephemeral,
/// protocol.md stream_append section). `offset`s are UTF-8 BYTE positions in
/// the command's output. Never persisted; delivered only while `viewing`.
/// Normal completion sends no ephemeral — the durable `tool_output` row with
/// the same `message_ref` retires the stream.
public struct ToolStreamUpdate: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Consecutive appends coalesce by concatenation. No meta — the
        /// command string only arrives via `sync`.
        case append(offset: Int, chunk: String)
        /// Full scrollback so far, sent per active stream when the client
        /// (re-)sends `viewing`. `offset` is the byte position of
        /// `content`'s first byte; `headTruncated` means the server's ring
        /// buffer dropped the beginning.
        case sync(tool: String?, command: String?, offset: Int, content: String, headTruncated: Bool)
        /// Server idle sweep freed the buffer (bridge died) — drop the tile.
        case end(reason: String?)
    }

    public let convoID: String
    public let messageRef: String
    public let event: Event

    public init(convoID: String, messageRef: String, event: Event) {
        self.convoID = convoID
        self.messageRef = messageRef
        self.event = event
    }
}
```

Add `case toolStream(ToolStreamUpdate)` to `ServerFrame`. In `decode`'s ephemeral branch, after the `activity` check and BEFORE the `message_ref` text-streaming fallback:

```swift
// tool_stream frames also carry `message_ref`; matched before the
// text-streaming fallback below or they'd decode as an empty
// EphemeralUpdate and paint an empty streaming bubble.
if let toolStream = obj["tool_stream"] as? [String: Any] {
    guard let ref = obj["message_ref"] as? String,
          let eventName = toolStream["event"] as? String else { return nil }
    let event: ToolStreamUpdate.Event
    switch eventName {
    case "append":
        guard let offset = (toolStream["offset"] as? NSNumber)?.intValue,
              let chunk = toolStream["chunk"] as? String else { return nil }
        event = .append(offset: offset, chunk: chunk)
    case "sync":
        guard let offset = (toolStream["offset"] as? NSNumber)?.intValue,
              let content = toolStream["content"] as? String else { return nil }
        let meta = toolStream["meta"] as? [String: Any]
        event = .sync(tool: meta?["tool"] as? String,
                      command: meta?["command"] as? String,
                      offset: offset, content: content,
                      headTruncated: toolStream["head_truncated"] as? Bool ?? false)
    case "end":
        event = .end(reason: toolStream["reason"] as? String)
    default:
        return nil // unknown tool_stream event — skip so the protocol can grow
    }
    return .toolStream(ToolStreamUpdate(convoID: convoID, messageRef: ref, event: event))
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path MatronShared --filter WireModelsTests 2>&1 | tail -3`
Expected: all pass; assert "Executed N tests, with 0 failures" (N grows by 6).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/WireModels.swift MatronShared/Tests/JournalTests/WireModelsTests.swift
git commit -m "feat(journal): decode tool_stream ephemerals — append/sync/end

Matched before the text-streaming fallback, which also stops tool_stream
frames painting an empty streaming bubble."
```

---

### Task 2: JournalSyncEngine — `toolStreams(convoID:)` fan-out

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift` (registry ~line 54, accessor ~line 201, frame loop ~line 363)
- Test: `MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift`

**Interfaces:**
- Consumes: `ServerFrame.toolStream(ToolStreamUpdate)` (Task 1).
- Produces: `JournalSyncEngine.toolStreams(convoID: String) -> AsyncStream<ToolStreamUpdate>` — per-convo, mirrors `activities(convoID:)`.

- [ ] **Step 1: Write the failing test** — copy the pattern of the existing activity fan-out test in `JournalSyncEngineTests.swift` (find it with `grep -n "activities" MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift` and mirror its engine/socket setup exactly):

```swift
func testToolStreamFramesFanOutToMatchingConvoOnly() async throws {
    // Same harness as the activities fan-out test: engine + FakeWebSocket,
    // beginSync, wait for hello_ok.
    let socket = FakeWebSocket()
    let engine = makeEngine(store: try makeStore(), connector: FakeJournalConnector([socket]))
    await engine.beginSync()
    try await socket.awaitHello()

    var iterC1 = engine.toolStreams(convoID: "c1").makeAsyncIterator()
    var iterC2 = engine.toolStreams(convoID: "c2").makeAsyncIterator()
    // Registration is async (Task inside the AsyncStream builder) — give it
    // a beat the same way the existing ephemeral tests do.
    try await Task.sleep(for: .milliseconds(50))

    socket.serve(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"tu1","tool_stream":{"event":"append","offset":0,"chunk":"hi"}}"#)
    socket.serve(#"{"kind":"ephemeral","convo_id":"c2","message_ref":"tu9","tool_stream":{"event":"end","reason":"stale"}}"#)

    let first = await iterC1.next()
    XCTAssertEqual(first, ToolStreamUpdate(convoID: "c1", messageRef: "tu1",
                                           event: .append(offset: 0, chunk: "hi")))
    let second = await iterC2.next()
    XCTAssertEqual(second, ToolStreamUpdate(convoID: "c2", messageRef: "tu9",
                                            event: .end(reason: "stale")))
    await engine.endSync()
}
```

(Adjust helper names — `makeEngine`/`makeStore`/`awaitHello` — to whatever the existing engine tests in that file actually use; mirror the nearest ephemeral/activity test verbatim.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MatronShared --filter JournalSyncEngineTests/testToolStreamFramesFanOut 2>&1 | tail -5`
Expected: compile FAILURE — `toolStreams` not defined.

- [ ] **Step 3: Implement** — three additions mirroring the activity plumbing:

Registry (next to `activityContinuations`, line ~54):

```swift
private var toolStreamContinuations: [UUID: (convoID: String, continuation: AsyncStream<ToolStreamUpdate>.Continuation)] = [:]
```

Accessor + register/unregister (next to `activities(convoID:)`):

```swift
/// Per-conversation stream of live tool-output frames (`tool_stream`
/// ephemerals). Mirrors `activities(convoID:)`; all offset bookkeeping
/// lives in the subscriber (JournalTimelineService.OverlayState).
public nonisolated func toolStreams(convoID: String) -> AsyncStream<ToolStreamUpdate> {
    AsyncStream { continuation in
        let id = UUID()
        Task { await self.registerToolStream(id: id, convoID: convoID, continuation: continuation) }
        continuation.onTermination = { _ in
            Task { await self.unregisterToolStream(id: id) }
        }
    }
}

private func registerToolStream(id: UUID, convoID: String, continuation: AsyncStream<ToolStreamUpdate>.Continuation) {
    toolStreamContinuations[id] = (convoID, continuation)
}

private func unregisterToolStream(id: UUID) {
    toolStreamContinuations.removeValue(forKey: id)
}
```

Frame loop (next to `case .activity`):

```swift
case .toolStream(let update):
    for (_, entry) in toolStreamContinuations where entry.convoID == update.convoID {
        entry.continuation.yield(update)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path MatronShared --filter JournalSyncEngineTests 2>&1 | tail -3`
Expected: "Executed N tests, with 0 failures".

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalSyncEngine.swift MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift
git commit -m "feat(journal): per-convo toolStreams fan-out on the sync engine"
```

---

### Task 3: TimelineItem kind + mapper (`toolStreamText`, `toolStreamItem`)

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift` (Kind enum, after `.activityIndicator`)
- Modify: `MatronShared/Sources/Chat/TimelineItem+PrettyJSON.swift` (`kindAsJSON`, after `.activityIndicator` case)
- Modify: `MatronShared/Sources/Chat/JournalTimelineMapper.swift` (after `activityItem`)
- Test: `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`

**Interfaces:**
- Produces: `TimelineItem.Kind.toolStreamLive(messageRef: String, command: String?, text: String, headTruncated: Bool)`; `JournalTimelineMapper.toolStreamText(bytes: [UInt8], displayCapBytes: Int = 65536) -> String`; `JournalTimelineMapper.toolStreamItem(messageRef: String, command: String?, text: String, headTruncated: Bool, convoTS: Date) -> TimelineItem` (id `"toolstream:<ref>"`).

- [ ] **Step 1: Write the failing tests** — append to `JournalTimelineMapperTests.swift`:

```swift
// MARK: tool_stream overlay items

func testToolStreamItemShape() {
    let item = JournalTimelineMapper.toolStreamItem(
        messageRef: "tu1", command: "make test", text: "$ make test\nok\n",
        headTruncated: false, convoTS: Date(timeIntervalSince1970: 5000))
    XCTAssertEqual(item.id, "toolstream:tu1")
    XCTAssertEqual(item.sender, "agent")
    XCTAssertFalse(item.isOwn)
    XCTAssertEqual(item.kind, .toolStreamLive(
        messageRef: "tu1", command: "make test", text: "$ make test\nok\n", headTruncated: false))
}

func testToolStreamTextDropsIncompleteTrailingMultibyte() {
    // "é" is 0xC3 0xA9; feed only the lead byte after "ok" — a chunk
    // boundary mid-character must not render a replacement glyph.
    XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: [0x6F, 0x6B, 0xC3]), "ok")
    // Complete sequence renders fully.
    XCTAssertEqual(JournalTimelineMapper.toolStreamText(bytes: [0x6F, 0x6B, 0xC3, 0xA9]), "oké")
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MatronShared --filter JournalTimelineMapperTests/testToolStream 2>&1 | tail -5`
Expected: compile FAILURE — `toolStreamItem` not defined.

- [ ] **Step 3: Implement.** `TimelineItem.swift`, after `.activityIndicator`:

```swift
/// Live tool-output overlay (journal `tool_stream` ephemerals) — a
/// terminal tile streaming a running command's output at the bottom of
/// the timeline. Not persisted; retired when the durable `tool_output`
/// row with the same `messageRef` lands (which renders as `.toolCall`).
/// `command` is nil until a `sync` frame supplies meta.
case toolStreamLive(messageRef: String, command: String?, text: String, headTruncated: Bool)
```

`TimelineItem+PrettyJSON.swift`, after the `.activityIndicator` case in `kindAsJSON()`:

```swift
case .toolStreamLive(let messageRef, let command, let text, let headTruncated):
    return [
        "type": "toolStreamLive",
        "messageRef": messageRef,
        "command": command ?? NSNull(),
        "text": text,
        "headTruncated": headTruncated,
    ]
```

`JournalTimelineMapper.swift`, after `activityItem`:

```swift
/// Renders a tool-stream byte buffer for display. Keeps only the last
/// `displayCapBytes` (the server buffer is 1 MiB; SwiftUI Text does not
/// enjoy megabyte strings), then drops any orphaned continuation bytes at
/// the front of the cut and any incomplete multibyte sequence at the tail
/// (a chunk boundary can split a character — rendering the partial bytes
/// would flicker a U+FFFD until the next append completes it).
public static func toolStreamText(bytes: [UInt8], displayCapBytes: Int = 65536) -> String {
    var slice = bytes[...]
    if slice.count > displayCapBytes {
        slice = slice.suffix(displayCapBytes)
        while let first = slice.first, first & 0xC0 == 0x80 {
            slice = slice.dropFirst()
        }
    }
    // Walk back over trailing continuation bytes to the lead byte; if the
    // sequence it starts is longer than what we have, trim it off.
    var index = slice.endIndex
    var walked = 0
    while walked < 4, index > slice.startIndex {
        let previous = slice.index(before: index)
        let byte = slice[previous]
        if byte & 0x80 == 0 { break } // ASCII tail — complete
        walked += 1
        if byte & 0xC0 == 0xC0 { // lead byte of a multibyte sequence
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
            if walked < needed { slice = slice[..<previous] }
            break
        }
        index = previous
    }
    return String(decoding: slice, as: UTF8.self)
}

/// A live tool-output tile row. Stable id ("toolstream:<ref>") so appends
/// redraw one row in place; `convoTS` follows the same day-bucket rule as
/// `streamingItem`/`activityItem`.
public static func toolStreamItem(messageRef: String, command: String?, text: String,
                                  headTruncated: Bool, convoTS: Date) -> TimelineItem {
    TimelineItem(
        id: "toolstream:\(messageRef)", sender: "agent", timestamp: convoTS,
        kind: .toolStreamLive(messageRef: messageRef, command: command,
                              text: text, headTruncated: headTruncated),
        isOwn: false, sendState: .sent)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path MatronShared --filter JournalTimelineMapperTests 2>&1 | tail -3`
Expected: "Executed N tests, with 0 failures". (SPM target only — the app
targets' Kind switches gain their case in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Chat/TimelineItem.swift MatronShared/Sources/Chat/TimelineItem+PrettyJSON.swift MatronShared/Sources/Chat/JournalTimelineMapper.swift MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift
git commit -m "feat(chat): toolStreamLive timeline kind + UTF-8-safe stream text mapper"
```

---

### Task 4: OverlayState bookkeeping + timeline integration

**Files:**
- Modify: `MatronShared/Sources/Chat/JournalTimelineService.swift`
- Test: `MatronShared/Tests/ChatTests/JournalTimelineServiceTests.swift`

**Interfaces:**
- Consumes: `engine.toolStreams(convoID:)` (Task 2), `JournalTimelineMapper.toolStreamItem`/`toolStreamText` (Task 3).
- Produces: `OverlayState.applyToolStream(_:) -> Bool` ("caller should re-send viewing"); tool-stream rows in the `items()` snapshot between streaming-text rows and echoes.

- [ ] **Step 1: Write the failing tests** — append to `JournalTimelineServiceTests.swift`, mirroring the harness of `testEphemeralOverlayInsertsAndFinalizeRemoves` (same `makeEngine`/`FakeJournalConnector`/`socket.serve` pattern; use that test's exact setup lines including any store seeding and `items()` iteration helpers):

```swift
// MARK: tool_stream overlay

private func toolStreamFrame(_ ref: String, _ event: String) -> String {
    #"{"kind":"ephemeral","convo_id":"c1","message_ref":"\#(ref)","tool_stream":\#(event)}"#
}

func testToolStreamAppendsCoalesceAndOverlapTrims() async throws {
    // setup: store/engine/service exactly as testEphemeralOverlayInsertsAndFinalizeRemoves
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"one"}"#))
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":3,"chunk":"two"}"#))
    // idempotent retry: bytes 3..<6 resent with 3 extra
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":3,"chunk":"twoXYZ"}"#))
    // await items snapshot containing the tile
    // expect one item with id "toolstream:tu1", kind .toolStreamLive(text: "onetwoXYZ", command: nil)
}

func testToolStreamSyncReplacesContentAndSuppliesMeta() async throws {
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"junk"}"#))
    socket.serve(toolStreamFrame("tu1", #"{"event":"sync","meta":{"tool":"Bash","command":"make"},"offset":0,"content":"$ make\n","head_truncated":false}"#))
    // expect .toolStreamLive(messageRef: "tu1", command: "make", text: "$ make\n", headTruncated: false)
}

func testToolStreamGapDropsChunkAndResendsViewing() async throws {
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"ab"}"#))
    // gap: offset 999 with end == 2
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":999,"chunk":"lost"}"#))
    // expect: text still "ab"; socket's sent ops contain a SECOND viewing
    // op for c1 (the first from items() subscription). Use the same
    // sent-op inspection the sendText test uses.
    // Also: a third gapped append within the 2s debounce adds NO third viewing.
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":999,"chunk":"lost"}"#))
}

func testToolStreamMidJoinWithoutSyncRequestsViewing() async throws {
    // No offset-0 frame ever seen: append at 512 creates nothing but
    // triggers a viewing re-send; no tile appears yet.
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":512,"chunk":"tail"}"#))
    // expect: no "toolstream:" item; sent ops contain the extra viewing.
}

func testToolStreamEndRemovesTile() async throws {
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"x"}"#))
    // tile present…
    socket.serve(toolStreamFrame("tu1", #"{"event":"end","reason":"stale"}"#))
    // …then gone.
}

func testDurableToolOutputRetiresTileAndLateAppendIsIgnored() async throws {
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"$ make\n"}"#))
    // durable completion row, same shape the fixture finalize produces:
    socket.serve(#"{"kind":"journal","seq":1,"convo_id":"c1","ts":1700000000000,"sender":"agent:dev","type":"tool_output","payload":{"message_ref":"tu1","command":"make","exit_code":0,"denied":false,"truncated":false,"snippet":"$ make","blob_ref":"b1","live_log":true}}"#)
    // expect: no "toolstream:tu1" item; a .toolCall row exists instead.
    // 200ms late flush must NOT re-open the tile:
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":7,"chunk":"late"}"#))
    // expect: still no "toolstream:tu1" item, and no extra viewing op
    // (retired refs don't request resync).
}

func testToolStreamSurvivesTextStalenessSweepButNotToolStaleness() async throws {
    // Service constructed with overlayStaleness: .milliseconds(50),
    // toolStreamStaleness: .milliseconds(400), sweepInterval: .milliseconds(30)
    // (mirror testStalledOverlaySelfPrunesViaPeriodicSweep's timing style).
    socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"quiet build"}"#))
    // after ~150ms (> text staleness, < tool staleness): tile still present
    // after ~600ms (> tool staleness): tile gone
}
```

Flesh each skeleton into a real test using the file's existing snapshot-awaiting helpers (the ephemeral test shows how to await an `items()` emission matching a predicate — reuse that helper or its inline loop verbatim).

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MatronShared --filter JournalTimelineServiceTests/testToolStream 2>&1 | tail -5`
Expected: compile FAILURE (`toolStreamStaleness` init param) or assertion failures — no tool-stream items ever appear.

- [ ] **Step 3: Implement** in `JournalTimelineService.swift`:

Init gains `toolStreamStaleness: Duration = .seconds(600)` (after `overlayStaleness`), passed to `OverlayState(staleness:toolStaleness:)`. 600 s matches `LiveOutputCard.autoConnectWindow`; the server's own 30-min idle sweep emits `end` when a bridge dies mid-view, so this is only a backstop for missed frames.

`OverlayState` additions:

```swift
/// One live tool-output stream, keyed by message_ref. All positions are
/// UTF-8 BYTE offsets into the command's full output; `bytes[0]` sits at
/// absolute offset `startOffset` (nonzero after a head-truncated sync).
struct ToolStream {
    var tool: String?
    var command: String?      // nil until a sync supplies meta
    var bytes: [UInt8]
    var startOffset: Int
    var headTruncated: Bool
    var updated: Date
}
private(set) var toolStreams: [String: ToolStream] = [:]
/// Refs already retired by a durable row (FIFO, capped). Ephemerals can
/// flush up to 200ms after the completion frame (protocol.md) — anything
/// for a retired ref is ignored, never re-opened.
private var retiredToolRefs: [String] = []
/// Debounce ledger for viewing re-sends (the client's only resync
/// mechanism). Per-ref so one broken stream can't spam the socket.
private var resyncRequested: [String: Date] = [:]
private let toolStaleness: TimeInterval
```

(init signature becomes `init(staleness: TimeInterval, toolStaleness: TimeInterval)`.)

```swift
/// Applies one tool_stream frame. Returns true when the caller should
/// re-send `viewing` — the protocol's client-side resync path — because
/// we're missing bytes (gap / mid-join) or meta (offset-0 start carries
/// no command string; only a sync does).
func applyToolStream(_ update: ToolStreamUpdate) -> Bool {
    let ref = update.messageRef
    guard !retiredToolRefs.contains(ref) else { return false }
    switch update.event {
    case let .append(offset, chunk):
        let chunkBytes = Array(chunk.utf8)
        guard var stream = toolStreams[ref] else {
            guard offset == 0 else { return resyncDue(ref) } // mid-join: need full scrollback
            toolStreams[ref] = ToolStream(tool: nil, command: nil, bytes: chunkBytes,
                                          startOffset: 0, headTruncated: false, updated: Date())
            return resyncDue(ref) // appends carry no meta — fetch the command via sync
        }
        let end = stream.startOffset + stream.bytes.count
        if offset == end {
            stream.bytes.append(contentsOf: chunkBytes)
        } else if offset < end {
            let overlap = end - offset
            guard overlap < chunkBytes.count else { return false } // fully-duplicate retry
            stream.bytes.append(contentsOf: chunkBytes.dropFirst(overlap))
        } else {
            return resyncDue(ref) // gap: drop the chunk, ask for scrollback
        }
        stream.updated = Date()
        toolStreams[ref] = stream
        return false
    case let .sync(tool, command, offset, content, headTruncated):
        toolStreams[ref] = ToolStream(tool: tool, command: command,
                                      bytes: Array(content.utf8), startOffset: offset,
                                      headTruncated: headTruncated, updated: Date())
        return false
    case .end:
        toolStreams.removeValue(forKey: ref)
        return false
    }
}

private func resyncDue(_ ref: String) -> Bool {
    if let last = resyncRequested[ref], Date().timeIntervalSince(last) < 2 { return false }
    resyncRequested[ref] = Date()
    return true
}
```

`reconcile` — the existing message_ref branch grows retirement:

```swift
if let ref = event.payload["message_ref"] as? String {
    streaming.removeValue(forKey: ref)
    toolStreams.removeValue(forKey: ref)
    resyncRequested.removeValue(forKey: ref)
    if !retiredToolRefs.contains(ref) {
        retiredToolRefs.append(ref)
        if retiredToolRefs.count > 64 { retiredToolRefs.removeFirst() }
    }
}
```

and the staleness block gains (after the `activity` line — tool streams are
exempt from the 30 s text cutoff; a quiet build step legitimately produces
nothing for minutes):

```swift
let toolCutoff = Date().addingTimeInterval(-toolStaleness)
toolStreams = toolStreams.filter { $0.value.updated > toolCutoff }
resyncRequested = resyncRequested.filter { $0.value > toolCutoff }
```

`items()` — new consumer task next to `activityTask`:

```swift
let toolStreamTask = Task {
    for await update in engine.toolStreams(convoID: convoID) {
        if await overlay.applyToolStream(update) {
            // Client-side resync: re-sending `viewing` makes the server
            // re-emit a full-scrollback sync per active stream.
            await engine.setViewing(convoID: convoID)
        }
        signal()
    }
}
```

(cancel it in `onTermination` alongside the others), and `emit()` appends tool
tiles after the streaming-text loop, before echoes:

```swift
for (ref, stream) in await overlay.toolStreams.sorted(by: { $0.key < $1.key }) {
    items.append(JournalTimelineMapper.toolStreamItem(
        messageRef: ref, command: stream.command,
        text: JournalTimelineMapper.toolStreamText(bytes: stream.bytes),
        headTruncated: stream.headTruncated,
        convoTS: max(lastTS, stream.updated)))
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path MatronShared --filter JournalTimelineServiceTests 2>&1 | tail -3`
Expected: "Executed N tests, with 0 failures".

- [ ] **Step 5: Run the full Chat + Journal suites (regression)**

Run: `swift test --package-path MatronShared --filter "ChatTests|JournalTests" 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Chat/JournalTimelineService.swift MatronShared/Tests/ChatTests/JournalTimelineServiceTests.swift
git commit -m "feat(chat): tool_stream overlay bookkeeping — append/trim/gap/sync/retire

Byte-offset rules per protocol.md; gap or missing meta re-sends viewing
(debounced) to draw a fresh sync; durable rows retire the tile and late
flushes for retired refs are ignored."
```

---

### Task 5: `TerminalPane` extraction + `ToolStreamCard`

**Files:**
- Create: `MatronShared/Sources/DesignSystem/LiveOutput/TerminalPane.swift`
- Create: `MatronShared/Sources/DesignSystem/LiveOutput/ToolStreamCard.swift`
- Modify: `MatronShared/Sources/DesignSystem/LiveOutput/LiveOutputCard.swift` (replace `pane`)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ToolStreamCardSnapshotTests.swift`

**Interfaces:**
- Consumes: `AnsiSGRParser` (existing — `var p = AnsiSGRParser(); p.append(text) -> AttributedString`).
- Produces: `ToolStreamCard(command: String?, text: String, headTruncated: Bool)` public view; internal `TerminalPane(output: AttributedString, expanded: Bool)`.

- [ ] **Step 1: Write the failing snapshot tests**:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class ToolStreamCardSnapshotTests: XCTestCase {
    func test_streaming_collapsed_withCommand() {
        assertVariants(
            of: ToolStreamCard(command: "make test",
                               text: "$ make test\nCompiling Journal.swift\nCompiling Mapper.swift\nLinking…\n",
                               headTruncated: false).frame(width: 420),
            named: "streaming_collapsed")
    }

    func test_streaming_collapsed_withoutMeta_showsGenericHeader() {
        // Appends carry no meta; until a sync lands the header is generic.
        assertVariants(
            of: ToolStreamCard(command: nil, text: "warming up…\n", headTruncated: false)
                .frame(width: 420),
            named: "streaming_noMeta")
    }

    func test_streaming_expanded_headTruncated_showsNotice() {
        assertVariants(
            of: ToolStreamCard(command: "cargo build",
                               text: String(repeating: "compiling crate …\n", count: 12),
                               headTruncated: true, initiallyExpanded: true).frame(width: 420),
            named: "streaming_expanded_truncatedHead")
    }
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `swift test --package-path MatronShared --filter ToolStreamCardSnapshotTests 2>&1 | tail -5`
Expected: FAIL — `ToolStreamCard` not defined.

- [ ] **Step 3: Implement.** `TerminalPane.swift`:

```swift
import SwiftUI

/// Terminal-style output pane shared by `LiveOutputCard` (legacy viewer
/// WebSocket) and `ToolStreamCard` (journal tool_stream overlay): fixed dark
/// palette in both app themes so ANSI colors read the same everywhere;
/// `defaultScrollAnchor(.bottom)` gives sticky-tail behavior — pinned to the
/// newest output unless the user scrolls up, matching the web tile.
struct TerminalPane: View {
    let output: AttributedString
    let expanded: Bool

    var body: some View {
        ScrollView {
            Text(output)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.86, green: 0.86, blue: 0.86))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: expanded ? 600 : 76)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7))
    }
}
```

In `LiveOutputCard.swift`, replace the whole `private var pane: some View { … }` body with:

```swift
private var pane: some View {
    TerminalPane(output: session.output, expanded: expanded)
}
```

(keep the doc comment; byte-identical rendering is asserted by Step 5).

`ToolStreamCard.swift`:

```swift
import SwiftUI

/// Live tool-output tile for the journal `tool_stream` overlay — the
/// ephemeral sibling of `LiveOutputCard`, fed accumulated stream text by the
/// timeline instead of owning a socket. It has no terminal states: the tile
/// only exists while the command runs; completion replaces it with the
/// durable row's `ToolCallCard`.
public struct ToolStreamCard: View {
    private let command: String?
    private let text: String
    private let headTruncated: Bool
    @State private var expanded: Bool

    /// `initiallyExpanded` exists for previews/snapshots; product code uses
    /// the default collapsed start.
    public init(command: String?, text: String, headTruncated: Bool,
                initiallyExpanded: Bool = false) {
        self.command = command
        self.text = text
        self.headTruncated = headTruncated
        _expanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TerminalPane(output: rendered, expanded: expanded)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live command output: \(command ?? "running command"). running")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(command.map { "$ \($0.replacingOccurrences(of: "\n", with: " ⏎ "))" } ?? "live output")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("running…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse output" : "Expand output")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Full re-parse per text change: the timeline caps display text at
    /// 64 KiB (JournalTimelineMapper.toolStreamText), so a stateful
    /// incremental parse isn't worth carrying UI-side state for.
    private var rendered: AttributedString {
        var out = AttributedString()
        if headTruncated {
            var notice = AttributedString("… earlier output truncated\n")
            notice.foregroundColor = .secondary
            out += notice
        }
        var parser = AnsiSGRParser()
        out += parser.append(text)
        return out
    }
}
```

- [ ] **Step 4: Snapshot record + verify**

Run twice: `swift test --package-path MatronShared --filter ToolStreamCardSnapshotTests 2>&1 | tail -3`
Expected: first run FAILS with "No reference was found on disk. Automatically recorded"; second run passes. Then open and eyeball each png under `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ToolStreamCardSnapshotTests/` (dark pane, `$ make test` header, spinner, dimmed truncation notice in the expanded variant).

- [ ] **Step 5: Prove the LiveOutputCard extraction is invisible**

Run: `swift test --package-path MatronShared --filter "DesignSystemSnapshotTests" 2>&1 | tail -3` and `git status --short MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/`
Expected: 0 failures; NO modified pngs outside `ToolStreamCardSnapshotTests/` (LiveOutputCard has logic tests, not snapshots, but the full suite guards its helpers).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/LiveOutput/ MatronShared/Tests/DesignSystemSnapshotTests/ToolStreamCardSnapshotTests.swift "MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ToolStreamCardSnapshotTests/"
git commit -m "feat(design): ToolStreamCard live tile; TerminalPane shared with LiveOutputCard"
```

---

### Task 6: Render the new kind in both apps + full builds

**Files:**
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift` (after the `.liveOutput` case, ~line 170)
- Modify: `MatronMac/Features/Chat/MacTimelineItemView.swift` (after the `.liveOutput` case, ~line 145)

**Interfaces:**
- Consumes: `ToolStreamCard` (Task 5), `.toolStreamLive` (Task 3).

- [ ] **Step 1: Add the iOS case** — in `TimelineItemView.swift` after `case .liveOutput`:

```swift
case .toolStreamLive(_, let command, let text, let headTruncated):
    // Ephemeral live tile (journal tool_stream) — same width as the
    // legacy liveOutput tile; terminal output wants columns.
    HStack {
        ToolStreamCard(command: command, text: text, headTruncated: headTruncated)
            .frame(maxWidth: 480, alignment: .leading)
        Spacer(minLength: 0)
    }
    .padding(.horizontal)
```

- [ ] **Step 2: Add the Mac case** — in `MacTimelineItemView.swift` after `case .liveOutput`, identical but `.frame(maxWidth: 560, alignment: .leading)` (Mac tiles run wider).

- [ ] **Step 3: Generate + build both targets**

```bash
cd /Users/danbarker/Dev/matron-apple && xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Debug build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **` twice. A failure here is almost certainly a missed exhaustive switch over `TimelineItem.Kind` — the compiler names the file; add the `.toolStreamLive` case there in the spirit of its siblings.

- [ ] **Step 4: Commit**

```bash
git add Matron/Features/Chat/Rendering/TimelineItemView.swift MatronMac/Features/Chat/MacTimelineItemView.swift
git commit -m "feat(chat): render tool_stream live tiles on iOS and Mac"
```

---

### Task 7: Full suite, push, PR

- [ ] **Step 1: Full SPM suite**

Run: `swift test --package-path MatronShared 2>&1 | tail -3`
Expected: "Executed N tests, with 0 failures" (N ≥ 455; was 440 before this branch). Never trust a grep-quieted pass — read the count.

- [ ] **Step 2: Verify no Info.plist staged**

Run: `git status --short`
Expected: only `M …Info.plist` UNstaged entries remain.

- [ ] **Step 3: Push + open PR**

```bash
git push -u origin feat/tool-stream-overlay
gh pr create --base feat/tool-output-durable-ttl --title "feat: tool_stream live output overlay (journal handover piece 2)" --body "$(cat <<'EOF'
Live terminal tile for running commands, fed by journal tool_stream ephemerals.

- Decode append/sync/end tool_stream ephemerals (also fixes tool_stream frames painting an EMPTY streaming text bubble — they used to fall through to the text-streaming decode)
- Per-convo toolStreams fan-out on JournalSyncEngine
- Byte-offset bookkeeping on the timeline overlay: append at end, overlap-trim idempotent retries, gap/mid-join/missing-meta re-sends viewing (debounced 2s/ref) to draw a fresh sync, end(stale) drops the tile
- Durable tool_output row retires the tile; late ephemeral flushes (≤200ms per protocol) for retired refs are ignored
- ToolStreamCard reuses the LiveOutputCard terminal look via a shared TerminalPane (legacy path behavior-identical); UTF-8-safe display trim + 64KiB display cap
- Tool streams get a 10-min staleness backstop, exempt from the 30s text-overlay sweep

Spec: docs/superpowers/specs/2026-07-14-tool-stream-overlay-design.md
Server contract: matron-journal docs/protocol.md + conformance fixture 13_tool_stream.json

Stacked on #20.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Rebuild + reinstall the combined build** — recreate the local integration branch (never pushed):

```bash
git branch -D tmp/live-testing
git checkout -b tmp/live-testing feat/ask-user-instant-buttons
git merge --no-edit feat/tool-stream-overlay
xcodegen generate
```

Then build both schemes and install: iPhone via `xcrun devicectl device install app --device CA47988A-6782-5DDA-9A5B-A89549ECA908 <DerivedData Debug-iphoneos/Matron.app>`, Mac via `rm -rf /Applications/MatronMac.app && ditto <Debug/MatronMac.app> /Applications/MatronMac.app`. Use the `Matron-djxcczdoznrqzzazpztxtbtjtynv` DerivedData dir and verify the installed binary mtime is fresh (two DerivedData dirs exist; the glob picks the wrong one).
