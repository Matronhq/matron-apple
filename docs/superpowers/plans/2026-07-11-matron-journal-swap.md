# Matron Journal Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the matrix-rust-sdk data layer in Matron (iOS + Mac) with a matron-journal protocol layer (WebSocket + cursor + GRDB mirror), then delete all Matrix code.

**Architecture:** New `MatronJournal` SPM target (wire DTOs, GRDB store, HTTP API, WebSocket client, sync engine). Journal-backed implementations of the EXISTING service protocols (`AuthService`, `ChatService`, `TimelineService`, `MediaService`, `PushService`, `SyncService`) replace the `*Live` Matrix implementations, so ViewModels/views stay nearly untouched. Every task compiles and commits green; Matrix code is deleted only after both apps are rewired.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB 6.x (already a dependency), URLSession WebSocket, XCTest. Server: `~/Dev/matron-journal` branch `feat/server-v1-core` (Node 20, chaos-tested).

**Spec:** `docs/superpowers/specs/2026-07-11-matron-journal-client-design.md`

## Global Constraints

- Branch: `feat/matron-journal` (already created off `main`). Commit after every task, conventional commits, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Swift 5.10 language mode; deployment iOS 17 / macOS 14. GRDB stays pinned `from: "6.29.0"`.
- After ANY `project.yml` change: run `xcodegen generate` before building.
- SPM tests: `swift test --package-path MatronShared --filter <Suite>`. NEVER pipe xcodebuild through `grep|tail` alone — always assert the `Executed N tests` line and exit code (a destination error can look like a pass).
- This machine has iPhone 17 simulators (no iPhone 16). iOS builds: `-destination 'platform=iOS Simulator,name=iPhone 17'`.
- Mac full-scheme test fails on the unsigned XCUITest runner — scope to `-only-testing:MatronMacTests`.
- Server wire format is authoritative in `~/Dev/matron-journal/src/*.js` (see "Wire reference" below). `snapshot_required` does NOT exist in server v1 — treat unknown control ops as no-ops.
- All new public types are `Sendable`. No new dependencies.

## Wire reference (from server `feat/server-v1-core`)

- `POST /login` body `{username, password, device_name}` → 200 `{token, device_id, user_id}` | 403 `{error:"bad_credentials"}` | 429 `{error:"rate_limited"}` or `{error:"locked_out", retry_after}` (+ `Retry-After` header).
- `GET /snapshot` (Bearer) → `{conversations:[{id,title,session_state,last_seq,unread_count,snippet,created_at}], seq}`.
- `GET /convo/:id/messages?before_seq&limit` (Bearer) → `{events:[{seq,convo_id,ts,sender,type,payload}]}` ascending; limit cap 200. 401 `{error:"unauthenticated"}`, 403 `{error:"forbidden"}`, 404 `{error:"not_found"}`.
- WS `/ws`: first frame `{op:"hello", token, cursor}` (cursor `0` = full replay, integer = replay `seq > cursor`); reply `{kind:"control",op:"hello_ok",seq}` then journal frames `{kind:"journal",seq,convo_id,ts,sender,type,payload}`; ephemeral `{kind:"ephemeral",convo_id,message_ref,text?,replace_text?}`; errors `{kind:"control",op:"error",code,ref?}` codes `auth|forbidden|bad_request|internal`.
- Client ops: `{op:"send",convo_id,type:"text",payload:{body},local_id?}` (whitelist: text only), `{op:"prompt_reply",convo_id,target_seq,choice?,text?}`, `{op:"read_marker",convo_id,up_to_seq}`, `{op:"ack",cursor}` (int ≥ 0), `{op:"viewing",convo_id|null}`.
- Agent ops (for test harness): `{op:"convo_upsert",convo_id,title?,session_state?}`, `{op:"publish",convo_id,type,payload,idem_key?}`, `{op:"stream",convo_id,message_ref,text?,replace_text?}`, `{op:"finalize",convo_id,message_ref,type?,payload}`.
- Sender strings: `user:<username>` / `agent:<name>`. `session_state`: `running|waiting|done|archived`. Message types (bump unread/snippet): `text,tool_output,diff,prompt,permission_request,file,image`.
- Server pings (protocol-level) every 20 s; URLSession auto-pongs. Client liveness = its own `sendPing` round-trips.
- Admin CLI: `MATRON_DB=<db> node bin/matron-admin.js user add <name> --password <pw>`; `... agent add <user> <agent-name>` (prints token once). Server: `MATRON_DB=<db> MATRON_PORT=<p> node src/server.js`.

## File Structure (new/major)

```
MatronShared/Sources/Journal/
  WireModels.swift        — JournalEvent, ServerFrame, EphemeralUpdate, ClientOp, JournalEventType
  JournalStore.swift      — GRDB mirror: conversation/event/meta, apply, observation streams
  JournalAPI.swift        — HTTP: login/snapshot/messages/media (dormant)
  WebSocketTransport.swift— WebSocketConnecting/Connection protocols + URLSession impl
  JournalConnection.swift — one socket: hello handshake, frame stream, op send, ping
  JournalSyncEngine.swift — reconnect loop, transactional apply, ack batching, ephemeral fan-out, state stream
MatronShared/Sources/Auth/JournalAuthService.swift
MatronShared/Sources/Chat/JournalTimelineMapper.swift
MatronShared/Sources/Chat/JournalChatService.swift
MatronShared/Sources/Chat/JournalTimelineService.swift
MatronShared/Sources/Chat/JournalMediaService.swift
MatronShared/Sources/Push/JournalPushService.swift
MatronShared/Sources/Sync/JournalSyncConformance.swift   (temporary shim; absorbed in Task 14)
MatronShared/Tests/JournalTests/…
MatronIntegrationTests/JournalServerTests.swift + JournalServerHarness.swift
```

---

### Task 1: MatronJournal target scaffold + wire DTOs

**Files:**
- Modify: `MatronShared/Package.swift`
- Create: `MatronShared/Sources/Journal/WireModels.swift`
- Test: `MatronShared/Tests/JournalTests/WireModelsTests.swift`

**Interfaces:**
- Produces: `JournalEvent` (seq: Int64, convoID: String, ts: Date, sender: String, type: String, payloadData: Data, `payload: [String: Any]` accessor, `init?(frameObject: [String: Any])`), `ServerFrame` enum (`.journal(JournalEvent)`, `.ephemeral(EphemeralUpdate)`, `.helloOK(headSeq: Int64)`, `.error(code: String, ref: String?)`, `.unknownControl(op: String)`; `static func decode(_ text: String) -> ServerFrame?`), `EphemeralUpdate` (convoID, messageRef, textDelta: String?, replaceText: String?), `ClientOp` enum with `encoded() -> String`, `JournalEventType` constants + `messageTypes: Set<String>`.

- [ ] **Step 1: Add the target to Package.swift**

In `MatronShared/Package.swift` add to `products`:
```swift
        .library(name: "MatronJournal", targets: ["MatronJournal"]),
```
Add to `targets` (before the test targets):
```swift
        // Journal protocol core (2026-07 Matrix replacement): wire DTOs,
        // GRDB mirror, HTTP API, WebSocket client, sync engine. No FFI.
        .target(
            name: "MatronJournal",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                "MatronSearch",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Journal"
        ),
```
And a test target:
```swift
        .testTarget(name: "JournalTests", dependencies: ["MatronJournal", "MatronModels"], path: "Tests/JournalTests"),
```

- [ ] **Step 2: Write the failing test**

`MatronShared/Tests/JournalTests/WireModelsTests.swift`:
```swift
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

        guard case let .unknownControl(op)? = ServerFrame.decode(#"{"kind":"control","op":"snapshot_required"}"#) else {
            return XCTFail("unknown control ops must decode as no-op frames")
        }
        XCTAssertEqual(op, "snapshot_required")

        guard case let .ephemeral(update)? = ServerFrame.decode(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m7","replace_text":"progress 3"}"#) else {
            return XCTFail("expected ephemeral")
        }
        XCTAssertEqual(update.messageRef, "m7")
        XCTAssertEqual(update.replaceText, "progress 3")
        XCTAssertNil(update.textDelta)
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path MatronShared --filter JournalTests 2>&1 | tail -5`
Expected: FAIL — no such module / cannot find `ServerFrame`.

- [ ] **Step 4: Write the implementation**

`MatronShared/Sources/Journal/WireModels.swift`:
```swift
import Foundation

/// String constants for journal event `type`s (spec §7). Use these, not
/// literals, so renames are compile-checked.
public enum JournalEventType {
    public static let text = "text"
    public static let prompt = "prompt"
    public static let promptReply = "prompt_reply"
    public static let toolOutput = "tool_output"
    public static let diff = "diff"
    public static let permissionRequest = "permission_request"
    public static let sessionStatus = "session_status"
    public static let file = "file"
    public static let image = "image"
    public static let readMarker = "read_marker"
    public static let edit = "edit"

    /// Types that bump unread counts and set the conversation snippet —
    /// mirrors the server's MESSAGE_TYPES (src/journal.js).
    public static let messageTypes: Set<String> = [
        text, toolOutput, diff, prompt, permissionRequest, file, image,
    ]
}

/// One durable journal row. `payloadData` keeps the raw JSON object bytes so
/// arbitrary payload shapes survive round-trips; `payload` decodes on access.
public struct JournalEvent: Equatable, Sendable {
    public let seq: Int64
    public let convoID: String
    public let ts: Date
    public let sender: String
    public let type: String
    public let payloadData: Data

    public var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
    }

    public init(seq: Int64, convoID: String, ts: Date, sender: String, type: String, payloadData: Data) {
        self.seq = seq
        self.convoID = convoID
        self.ts = ts
        self.sender = sender
        self.type = type
        self.payloadData = payloadData
    }

    /// Builds from a decoded `{seq, convo_id, ts, sender, type, payload}`
    /// object (shared shape of WS journal frames and HTTP pagination rows).
    public init?(frameObject obj: [String: Any]) {
        guard let seq = (obj["seq"] as? NSNumber)?.int64Value,
              let convoID = obj["convo_id"] as? String,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue,
              let sender = obj["sender"] as? String,
              let type = obj["type"] as? String
        else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        self.init(
            seq: seq, convoID: convoID, ts: Date(timeIntervalSince1970: ts / 1000),
            sender: sender, type: type, payloadData: payloadData
        )
    }
}

/// A streaming-output update. Never persisted; lost updates are harmless
/// (the finalize journal row supersedes them).
public struct EphemeralUpdate: Equatable, Sendable {
    public let convoID: String
    public let messageRef: String
    public let textDelta: String?
    public let replaceText: String?

    public init(convoID: String, messageRef: String, textDelta: String?, replaceText: String?) {
        self.convoID = convoID
        self.messageRef = messageRef
        self.textDelta = textDelta
        self.replaceText = replaceText
    }
}

/// Server → client frames. Unknown `kind`s decode to nil (skip); unknown
/// control ops decode to `.unknownControl` so the protocol can grow.
public enum ServerFrame: Equatable, Sendable {
    case journal(JournalEvent)
    case ephemeral(EphemeralUpdate)
    case helloOK(headSeq: Int64)
    case error(code: String, ref: String?)
    case unknownControl(op: String)

    public static func decode(_ text: String) -> ServerFrame? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let kind = obj["kind"] as? String
        else { return nil }
        switch kind {
        case "journal":
            return JournalEvent(frameObject: obj).map(ServerFrame.journal)
        case "ephemeral":
            guard let convoID = obj["convo_id"] as? String,
                  let ref = obj["message_ref"] as? String else { return nil }
            return .ephemeral(EphemeralUpdate(
                convoID: convoID, messageRef: ref,
                textDelta: obj["text"] as? String,
                replaceText: obj["replace_text"] as? String
            ))
        case "control":
            guard let op = obj["op"] as? String else { return nil }
            switch op {
            case "hello_ok":
                return .helloOK(headSeq: (obj["seq"] as? NSNumber)?.int64Value ?? 0)
            case "error":
                return .error(code: obj["code"] as? String ?? "unknown", ref: obj["ref"] as? String)
            default:
                return .unknownControl(op: op)
            }
        default:
            return nil
        }
    }
}

/// Client → server operations.
public enum ClientOp: Equatable, Sendable {
    case hello(token: String, cursor: Int64?)
    case send(convoID: String, body: String, localID: String)
    case promptReply(convoID: String, targetSeq: Int64, choice: String?, text: String?)
    case readMarker(convoID: String, upToSeq: Int64)
    case ack(cursor: Int64)
    case viewing(convoID: String?)

    public func encoded() -> String {
        let obj: [String: Any]
        switch self {
        case let .hello(token, cursor):
            obj = ["op": "hello", "token": token, "cursor": cursor.map(NSNumber.init(value:)) ?? NSNull()]
        case let .send(convoID, body, localID):
            obj = ["op": "send", "convo_id": convoID, "type": "text",
                   "payload": ["body": body], "local_id": localID]
        case let .promptReply(convoID, targetSeq, choice, text):
            obj = ["op": "prompt_reply", "convo_id": convoID,
                   "target_seq": NSNumber(value: targetSeq),
                   "choice": choice ?? NSNull(), "text": text ?? NSNull()]
        case let .readMarker(convoID, upToSeq):
            obj = ["op": "read_marker", "convo_id": convoID, "up_to_seq": NSNumber(value: upToSeq)]
        case let .ack(cursor):
            obj = ["op": "ack", "cursor": NSNumber(value: cursor)]
        case let .viewing(convoID):
            obj = ["op": "viewing", "convo_id": convoID ?? NSNull()]
        }
        // Dictionaries above are always valid JSON objects.
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalTests 2>&1 | tail -5`
Expected: PASS, `Executed 4 tests`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Journal/WireModels.swift MatronShared/Tests/JournalTests/WireModelsTests.swift
git commit -m "feat(journal): MatronJournal target with wire DTOs"
```

---

### Task 2: JournalStore — GRDB mirror

**Files:**
- Create: `MatronShared/Sources/Journal/JournalStore.swift`
- Test: `MatronShared/Tests/JournalTests/JournalStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `ConversationRecord`: `id, title, sessionState, lastSeq: Int64, snippet, createdAt: Int64, lastActivityTS: Int64?, muted: Bool, hidden: Bool, readUpToSeq: Int64, unreadCount: Int` (Codable/FetchableRecord/PersistableRecord).
  - `final class JournalStore: @unchecked Sendable` (wraps `DatabaseQueue`, which is thread-safe):
    - `init(databaseURL: URL?, ownSender: String) throws` — nil URL = in-memory. `ownSender` e.g. `"user:dan"`.
    - `var cursor: Int64 { get }` (throws-free; 0 on fresh store)
    - `func applyColdSnapshot(_ convos: [ConvoSummaryDTO], headSeq: Int64) throws`
    - `func refreshSummaries(_ convos: [ConvoSummaryDTO]) throws` — upserts title/sessionState/snippet/lastSeq (monotonic), never touches cursor/unread.
    - `@discardableResult func applyJournal(_ event: JournalEvent) throws -> Bool` — false when `seq <= cursor`.
    - `func insertHistory(_ events: [JournalEvent]) throws` — `INSERT OR IGNORE`, no cursor/unread change.
    - `func conversations() throws -> [ConversationRecord]`, `func events(convoID: String) throws -> [JournalEvent]`, `func minSeq(convoID: String) throws -> Int64?`, `func maxSeq(convoID: String) throws -> Int64?`
    - `func setMuted(_ muted: Bool, convoID: String) throws`, `func setHidden(_ hidden: Bool, convoID: String) throws`
    - `func conversationsStream() -> AsyncStream<[ConversationRecord]>`, `func eventsStream(convoID: String) -> AsyncStream<[JournalEvent]>` (GRDB ValueObservation; yields current value immediately).
    - `func wipe() throws`
  - `ConvoSummaryDTO`: `id, title, sessionState, lastSeq: Int64, snippet, createdAt: Int64` (defined here; JournalAPI reuses it).

- [ ] **Step 1: Write the failing test**

`MatronShared/Tests/JournalTests/JournalStoreTests.swift`:
```swift
import XCTest
@testable import MatronJournal

final class JournalStoreTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
                       type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testApplyAdvancesCursorAndIsIdempotent() throws {
        let store = try makeStore()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertTrue(try store.applyJournal(event(1)))
        XCTAssertTrue(try store.applyJournal(event(2)))
        XCTAssertFalse(try store.applyJournal(event(2)), "replayed frame must be a no-op")
        XCTAssertEqual(store.cursor, 2)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1, 2])
    }

    func testAutoCreatesConversationAndUpdatesSummary() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, payload: ["body": "hello world"]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.id, "c1")
        XCTAssertEqual(convo.lastSeq, 1)
        XCTAssertEqual(convo.snippet, "hello world")
        XCTAssertEqual(convo.unreadCount, 1)
    }

    func testOwnMessagesDoNotBumpUnread() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, sender: "user:dan"))
        XCTAssertEqual(try store.conversations().first?.unreadCount, 0)
    }

    func testReadMarkerRecomputesUnread() throws {
        let store = try makeStore()
        for i: Int64 in 1...5 { try store.applyJournal(event(i)) }
        XCTAssertEqual(try store.conversations().first?.unreadCount, 5)
        try store.applyJournal(event(6, sender: "user:dan", type: "read_marker",
                                     payload: ["convo_id": "c1", "up_to_seq": 4]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.readUpToSeq, 4)
        XCTAssertEqual(convo.unreadCount, 1)
    }

    func testSessionStatusUpdatesStateWithoutUnread() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: "session_status", payload: ["state": "waiting"]))
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.sessionState, "waiting")
        XCTAssertEqual(convo.unreadCount, 0)
    }

    func testColdSnapshotThenHistoryInsert() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "running",
                            lastSeq: 10, snippet: "s", createdAt: 0),
        ], headSeq: 10)
        XCTAssertEqual(store.cursor, 10)
        XCTAssertEqual(try store.conversations().first?.title, "T")
        // history pagination fills older events without touching cursor/unread
        try store.insertHistory([event(8), event(9)])
        XCTAssertEqual(store.cursor, 10)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [8, 9])
        XCTAssertEqual(try store.conversations().first?.unreadCount, 0)
        XCTAssertEqual(try store.minSeq(convoID: "c1"), 8)
    }

    func testRefreshSummariesNeverRegressesLastSeq() throws {
        let store = try makeStore()
        try store.applyJournal(event(5))
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "c1", title: "new title", sessionState: "done",
                            lastSeq: 3, snippet: "old", createdAt: 0),
        ])
        let convo = try XCTUnwrap(try store.conversations().first)
        XCTAssertEqual(convo.title, "new title")
        XCTAssertEqual(convo.sessionState, "done")
        XCTAssertEqual(convo.lastSeq, 5, "stale snapshot must not roll back lastSeq")
    }

    func testConversationsStreamYieldsOnChange() async throws {
        let store = try makeStore()
        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        try store.applyJournal(event(1))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.first?.id, "c1")
    }

    func testWipe() throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        try store.wipe()
        XCTAssertEqual(store.cursor, 0)
        XCTAssertEqual(try store.conversations().count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MatronShared --filter JournalStoreTests 2>&1 | tail -5`
Expected: FAIL — `JournalStore` not found.

- [ ] **Step 3: Write the implementation**

`MatronShared/Sources/Journal/JournalStore.swift`:
```swift
import Foundation
import GRDB

/// Server-side conversation summary (shape of /snapshot rows). Also the
/// input to store upserts, so it lives here rather than in JournalAPI.
public struct ConvoSummaryDTO: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sessionState: String
    public let lastSeq: Int64
    public let snippet: String
    public let createdAt: Int64

    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64) {
        self.id = id
        self.title = title
        self.sessionState = sessionState
        self.lastSeq = lastSeq
        self.snippet = snippet
        self.createdAt = createdAt
    }
}

public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "conversation"

    public var id: String
    public var title: String
    public var sessionState: String
    public var lastSeq: Int64
    public var snippet: String
    public var createdAt: Int64
    public var lastActivityTS: Int64?
    public var muted: Bool
    public var hidden: Bool
    public var readUpToSeq: Int64
    public var unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, snippet, muted, hidden
        case sessionState = "session_state"
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case lastActivityTS = "last_activity_ts"
        case readUpToSeq = "read_up_to_seq"
        case unreadCount = "unread_count"
    }
}

struct EventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "event"
    var seq: Int64
    var convoID: String
    var ts: Int64
    var sender: String
    var type: String
    var payload: Data

    enum CodingKeys: String, CodingKey {
        case seq, ts, sender, type, payload
        case convoID = "convo_id"
    }

    var journalEvent: JournalEvent {
        JournalEvent(seq: seq, convoID: convoID, ts: Date(timeIntervalSince1970: Double(ts) / 1000),
                     sender: sender, type: type, payloadData: payload)
    }

    init(_ e: JournalEvent) {
        seq = e.seq
        convoID = e.convoID
        ts = Int64(e.ts.timeIntervalSince1970 * 1000)
        sender = e.sender
        type = e.type
        payload = e.payloadData
    }
}

/// Local mirror of the user's journal. The UI reads ONLY this store; the
/// sync engine is the only writer. `cursor` advances inside the same
/// transaction as the event insert — the wedge-proof property.
public final class JournalStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let ownSender: String

    public init(databaseURL: URL?, ownSender: String) throws {
        self.ownSender = ownSender
        if let url = databaseURL {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: url.path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("session_state", .text).notNull().defaults(to: "running")
                t.column("last_seq", .integer).notNull().defaults(to: 0)
                t.column("snippet", .text).notNull().defaults(to: "")
                t.column("created_at", .integer).notNull().defaults(to: 0)
                t.column("last_activity_ts", .integer)
                t.column("muted", .boolean).notNull().defaults(to: false)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("read_up_to_seq", .integer).notNull().defaults(to: 0)
                t.column("unread_count", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "event") { t in
                t.column("seq", .integer).primaryKey()
                t.column("convo_id", .text).notNull().indexed()
                t.column("ts", .integer).notNull()
                t.column("sender", .text).notNull()
                t.column("type", .text).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: Cursor

    public var cursor: Int64 {
        (try? dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'")
        }) ?? 0
    }

    private static func setCursor(_ db: Database, _ value: Int64) throws {
        try db.execute(
            sql: "INSERT INTO meta(key, value) VALUES('cursor', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [value])
    }

    // MARK: Snapshot

    public func applyColdSnapshot(_ convos: [ConvoSummaryDTO], headSeq: Int64) throws {
        try dbQueue.write { db in
            for c in convos {
                try Self.upsertSummary(db, c, resetLocalState: true)
            }
            try Self.setCursor(db, headSeq)
        }
    }

    public func refreshSummaries(_ convos: [ConvoSummaryDTO]) throws {
        try dbQueue.write { db in
            for c in convos {
                try Self.upsertSummary(db, c, resetLocalState: false)
            }
        }
    }

    private static func upsertSummary(_ db: Database, _ c: ConvoSummaryDTO, resetLocalState: Bool) throws {
        if var existing = try ConversationRecord.fetchOne(db, key: c.id) {
            existing.title = c.title
            existing.sessionState = c.sessionState
            if c.lastSeq > existing.lastSeq {
                existing.lastSeq = c.lastSeq
                existing.snippet = c.snippet
            }
            try existing.update(db)
        } else {
            try ConversationRecord(
                id: c.id, title: c.title, sessionState: c.sessionState,
                lastSeq: c.lastSeq, snippet: c.snippet, createdAt: c.createdAt,
                lastActivityTS: nil, muted: false, hidden: false,
                readUpToSeq: resetLocalState ? c.lastSeq : 0,
                unreadCount: 0
            ).insert(db)
        }
    }

    // MARK: Journal apply

    @discardableResult
    public func applyJournal(_ event: JournalEvent) throws -> Bool {
        try dbQueue.write { db in
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            guard event.seq > current else { return false }
            try EventRecord(event).save(db)

            var convo = try ConversationRecord.fetchOne(db, key: event.convoID) ?? ConversationRecord(
                id: event.convoID, title: "", sessionState: "running", lastSeq: 0,
                snippet: "", createdAt: Int64(event.ts.timeIntervalSince1970 * 1000),
                lastActivityTS: nil, muted: false, hidden: false, readUpToSeq: 0, unreadCount: 0)

            convo.lastSeq = max(convo.lastSeq, event.seq)
            convo.lastActivityTS = Int64(event.ts.timeIntervalSince1970 * 1000)

            let payload = event.payload
            if event.type == JournalEventType.sessionStatus {
                if let state = payload["state"] as? String { convo.sessionState = state }
            } else if event.type == JournalEventType.readMarker {
                // All read_markers are the user's own (other devices included).
                let upTo = (payload["up_to_seq"] as? NSNumber)?.int64Value ?? 0
                convo.readUpToSeq = max(convo.readUpToSeq, upTo)
                convo.unreadCount = try Self.recountUnread(db, convoID: convo.id,
                                                           after: convo.readUpToSeq, ownSender: ownSender)
            } else if JournalEventType.messageTypes.contains(event.type) {
                convo.snippet = Self.snippet(type: event.type, payload: payload)
                if event.sender != ownSender, event.seq > convo.readUpToSeq {
                    convo.unreadCount += 1
                }
            }
            try convo.save(db)
            try Self.setCursor(db, event.seq)
            return true
        }
    }

    private static func recountUnread(_ db: Database, convoID: String, after seq: Int64, ownSender: String) throws -> Int {
        let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [convoID, seq]
        arguments.append(contentsOf: Array(JournalEventType.messageTypes))
        arguments.append(ownSender)
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM event
            WHERE convo_id = ? AND seq > ? AND type IN (\(placeholders)) AND sender != ?
            """, arguments: StatementArguments(arguments)) ?? 0
    }

    /// Mirrors the server's snippetOf (src/journal.js).
    static func snippet(type: String, payload: [String: Any]) -> String {
        switch type {
        case JournalEventType.text:
            return String((payload["body"] as? String ?? "").prefix(120))
        case JournalEventType.prompt:
            return "? " + String((payload["question"] as? String ?? "").prefix(110))
        case JournalEventType.permissionRequest:
            return "permission: " + String((payload["description"] as? String ?? "").prefix(100))
        default:
            if let s = payload["snippet"] as? String { return String(s.prefix(120)) }
            return "[\(type)]"
        }
    }

    // MARK: History

    public func insertHistory(_ events: [JournalEvent]) throws {
        try dbQueue.write { db in
            for e in events {
                try EventRecord(e).insert(db, onConflict: .ignore)
            }
        }
    }

    // MARK: Reads

    public func conversations() throws -> [ConversationRecord] {
        try dbQueue.read { db in
            try ConversationRecord
                .filter(Column("hidden") == false)
                .order(Column("last_seq").desc)
                .fetchAll(db)
        }
    }

    public func events(convoID: String) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq"))
                .fetchAll(db)
                .map(\.journalEvent)
        }
    }

    public func minSeq(convoID: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM event WHERE convo_id = ?", arguments: [convoID])
        }
    }

    public func maxSeq(convoID: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM event WHERE convo_id = ?", arguments: [convoID])
        }
    }

    public func setMuted(_ muted: Bool, convoID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET muted = ? WHERE id = ?", arguments: [muted, convoID])
        }
    }

    public func setHidden(_ hidden: Bool, convoID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET hidden = ? WHERE id = ?", arguments: [hidden, convoID])
        }
    }

    public func wipe() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event; DELETE FROM conversation; DELETE FROM meta;")
        }
    }

    // MARK: Observation

    public func conversationsStream() -> AsyncStream<[ConversationRecord]> {
        let observation = ValueObservation.tracking { db in
            try ConversationRecord
                .filter(Column("hidden") == false)
                .order(Column("last_seq").desc)
                .fetchAll(db)
        }
        return Self.stream(observation, in: dbQueue)
    }

    public func eventsStream(convoID: String) -> AsyncStream<[JournalEvent]> {
        let observation = ValueObservation.tracking { db in
            try EventRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq"))
                .fetchAll(db)
                .map(\.journalEvent)
        }
        return Self.stream(observation, in: dbQueue)
    }

    private static func stream<T: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<T>>,
        in dbQueue: DatabaseQueue
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            let cancellable = observation.start(in: dbQueue, scheduling: .immediate) { _ in
                continuation.finish()
            } onChange: { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalStoreTests 2>&1 | tail -5`
Expected: PASS, `Executed 9 tests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Tests/JournalTests/JournalStoreTests.swift
git commit -m "feat(journal): GRDB store with transactional apply and observation streams"
```

---

### Task 3: JournalAPI — HTTP client

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI.swift`
- Test: `MatronShared/Tests/JournalTests/JournalAPITests.swift`

**Interfaces:**
- Consumes: Task 1 `JournalEvent`, Task 2 `ConvoSummaryDTO`.
- Produces:
  - `LoginResponse` (`token: String, deviceID: Int64, userID: Int64`), `SnapshotResponse` (`conversations: [ConvoSummaryDTO], seq: Int64`).
  - `JournalAPIError: Error, Equatable` — `.badCredentials`, `.lockedOut(retryAfterSeconds: Int)`, `.rateLimited`, `.unauthenticated`, `.forbidden`, `.notFound`, `.http(status: Int, message: String)`, `.transport(String)`.
  - `actor JournalAPI`:
    - `init(serverURL: URL, urlSession: URLSession = .shared)`
    - `nonisolated let serverURL: URL`, `nonisolated var wsURL: URL` (`https`→`wss`, `http`→`ws`, path `/ws`)
    - `func setToken(_ token: String?)`
    - `func login(username: String, password: String, deviceName: String) async throws -> LoginResponse` (also stores the token on success)
    - `func snapshot() async throws -> SnapshotResponse`
    - `func messages(convoID: String, beforeSeq: Int64?, limit: Int) async throws -> [JournalEvent]`
    - `func mediaData(blobRef: String) async throws -> Data` (dormant: `GET /media/:id`)
    - `func registerAPNsToken(_ tokenHex: String) async throws` (dormant: `POST /devices/apns`; a 404 response is swallowed as no-op)

- [ ] **Step 1: Write the failing test**

`MatronShared/Tests/JournalTests/JournalAPITests.swift` — uses a `URLProtocol` stub:
```swift
import XCTest
@testable import MatronJournal

final class StubURLProtocol: URLProtocol {
    /// path → (status, body). Set per-test; read by the loader.
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let path = request.url!.path
        let (status, body) = Self.responses[path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class JournalAPITests: XCTestCase {
    private func makeAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config))
    }

    func testLoginSuccessStoresToken() async throws {
        StubURLProtocol.responses = ["/login": (200, #"{"token":"aabb","device_id":12,"user_id":3}"#)]
        let api = makeAPI()
        let login = try await api.login(username: "dan", password: "pw", deviceName: "mac")
        XCTAssertEqual(login.token, "aabb")
        XCTAssertEqual(login.deviceID, 12)

        StubURLProtocol.responses["/snapshot"] = (200, #"{"conversations":[],"seq":0}"#)
        _ = try await api.snapshot()
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer aabb")
    }

    func testLoginErrors() async throws {
        StubURLProtocol.responses = ["/login": (403, #"{"error":"bad_credentials"}"#)]
        let api = makeAPI()
        do {
            _ = try await api.login(username: "dan", password: "x", deviceName: "mac")
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .badCredentials)
        }

        StubURLProtocol.responses = ["/login": (429, #"{"error":"locked_out","retry_after":60}"#)]
        do {
            _ = try await api.login(username: "dan", password: "x", deviceName: "mac")
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .lockedOut(retryAfterSeconds: 60))
        }
    }

    func testSnapshotParsesConversations() async throws {
        StubURLProtocol.responses = ["/snapshot": (200, """
            {"conversations":[{"id":"c1","title":"T","session_state":"waiting","last_seq":9,"unread_count":2,"snippet":"s","created_at":5}],"seq":9}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let snap = try await api.snapshot()
        XCTAssertEqual(snap.seq, 9)
        XCTAssertEqual(snap.conversations, [
            ConvoSummaryDTO(id: "c1", title: "T", sessionState: "waiting", lastSeq: 9, snippet: "s", createdAt: 5),
        ])
    }

    func testMessagesBuildsQueryAndParsesEvents() async throws {
        StubURLProtocol.responses = ["/convo/c1/messages": (200, """
            {"events":[{"seq":8,"convo_id":"c1","ts":8000,"sender":"agent:a","type":"text","payload":{"body":"m8"}}]}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let events = try await api.messages(convoID: "c1", beforeSeq: 9, limit: 30)
        XCTAssertEqual(events.map(\.seq), [8])
        let query = StubURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("before_seq=9"))
        XCTAssertTrue(query.contains("limit=30"))
    }

    func testUnauthenticatedMapsToError() async throws {
        StubURLProtocol.responses = ["/snapshot": (401, #"{"error":"unauthenticated"}"#)]
        let api = makeAPI()
        do {
            _ = try await api.snapshot()
            XCTFail("expected throw")
        } catch let error as JournalAPIError {
            XCTAssertEqual(error, .unauthenticated)
        }
    }

    func testWsURL() {
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!)
        XCTAssertEqual(api.wsURL.absoluteString, "wss://chat.example.com/ws")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MatronShared --filter JournalAPITests 2>&1 | tail -5`
Expected: FAIL — `JournalAPI` not found.

- [ ] **Step 3: Write the implementation**

`MatronShared/Sources/Journal/JournalAPI.swift`:
```swift
import Foundation

public struct LoginResponse: Equatable, Sendable {
    public let token: String
    public let deviceID: Int64
    public let userID: Int64
}

public struct SnapshotResponse: Equatable, Sendable {
    public let conversations: [ConvoSummaryDTO]
    public let seq: Int64
}

public enum JournalAPIError: Error, Equatable, Sendable {
    case badCredentials
    case lockedOut(retryAfterSeconds: Int)
    case rateLimited
    case unauthenticated
    case forbidden
    case notFound
    case http(status: Int, message: String)
    case transport(String)
}

/// Thin HTTP surface of the journal server: login, snapshot, pagination,
/// plus the dormant media/APNs endpoints (spec'd; server lands them in
/// v1-completion — callers must tolerate `.notFound` until then).
public actor JournalAPI {
    public nonisolated let serverURL: URL
    private let urlSession: URLSession
    private var token: String?

    public init(serverURL: URL, urlSession: URLSession = .shared) {
        self.serverURL = serverURL
        self.urlSession = urlSession
    }

    public nonisolated var wsURL: URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/ws"
        return components.url!
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    public func login(username: String, password: String, deviceName: String) async throws -> LoginResponse {
        let body = ["username": username, "password": password, "device_name": deviceName]
        let obj = try await request(path: "/login", method: "POST", body: body, authenticated: false)
        guard let token = obj["token"] as? String,
              let deviceID = (obj["device_id"] as? NSNumber)?.int64Value,
              let userID = (obj["user_id"] as? NSNumber)?.int64Value
        else { throw JournalAPIError.transport("malformed login response") }
        self.token = token
        return LoginResponse(token: token, deviceID: deviceID, userID: userID)
    }

    public func snapshot() async throws -> SnapshotResponse {
        let obj = try await request(path: "/snapshot")
        let conversations = (obj["conversations"] as? [[String: Any]] ?? []).compactMap { c -> ConvoSummaryDTO? in
            guard let id = c["id"] as? String else { return nil }
            return ConvoSummaryDTO(
                id: id,
                title: c["title"] as? String ?? "",
                sessionState: c["session_state"] as? String ?? "running",
                lastSeq: (c["last_seq"] as? NSNumber)?.int64Value ?? 0,
                snippet: c["snippet"] as? String ?? "",
                createdAt: (c["created_at"] as? NSNumber)?.int64Value ?? 0
            )
        }
        return SnapshotResponse(conversations: conversations,
                                seq: (obj["seq"] as? NSNumber)?.int64Value ?? 0)
    }

    public func messages(convoID: String, beforeSeq: Int64?, limit: Int) async throws -> [JournalEvent] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let beforeSeq {
            query.append(URLQueryItem(name: "before_seq", value: String(beforeSeq)))
        }
        let escaped = convoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? convoID
        let obj = try await request(path: "/convo/\(escaped)/messages", query: query)
        return (obj["events"] as? [[String: Any]] ?? []).compactMap(JournalEvent.init(frameObject:))
    }

    /// Dormant until the server lands `GET /media/:id` (v1-completion).
    public func mediaData(blobRef: String) async throws -> Data {
        let escaped = blobRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? blobRef
        let (data, response) = try await rawRequest(path: "/media/\(escaped)", method: "GET", body: nil)
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: data) }
        return data
    }

    /// Dormant until the server lands APNs registration (v1-completion).
    /// A 404 (endpoint missing today) is swallowed as a no-op.
    public func registerAPNsToken(_ tokenHex: String) async throws {
        do {
            _ = try await request(path: "/devices/apns", method: "POST", body: ["apns_token": tokenHex])
        } catch JournalAPIError.notFound {
            // Server doesn't support push registration yet.
        }
    }

    // MARK: Internals

    private func request(
        path: String, method: String = "GET", body: [String: Any]? = nil,
        query: [URLQueryItem] = [], authenticated: Bool = true
    ) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: method, body: body,
                                                    query: query, authenticated: authenticated)
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: data) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JournalAPIError.transport("non-JSON response for \(path)")
        }
        return obj
    }

    private func rawRequest(
        path: String, method: String, body: [String: Any]?,
        query: [URLQueryItem] = [], authenticated: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JournalAPIError.transport("non-HTTP response")
            }
            return (data, http)
        } catch let error as JournalAPIError {
            throw error
        } catch {
            throw JournalAPIError.transport(error.localizedDescription)
        }
    }

    private static func error(status: Int, data: Data) -> JournalAPIError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["error"] as? String
        switch (status, code) {
        case (403, "bad_credentials"): return .badCredentials
        case (429, "locked_out"):
            return .lockedOut(retryAfterSeconds: (obj?["retry_after"] as? NSNumber)?.intValue ?? 60)
        case (429, _): return .rateLimited
        case (401, _): return .unauthenticated
        case (403, _): return .forbidden
        case (404, _): return .notFound
        default: return .http(status: status, message: obj?["message"] as? String ?? code ?? "")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalAPITests 2>&1 | tail -5`
Expected: PASS, `Executed 6 tests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI.swift MatronShared/Tests/JournalTests/JournalAPITests.swift
git commit -m "feat(journal): HTTP API client with typed error mapping"
```

---

### Task 4: WebSocket transport + JournalConnection

**Files:**
- Create: `MatronShared/Sources/Journal/WebSocketTransport.swift`, `MatronShared/Sources/Journal/JournalConnection.swift`
- Test: `MatronShared/Tests/JournalTests/JournalConnectionTests.swift` (+ shared fake in `MatronShared/Tests/JournalTests/FakeWebSocket.swift`)

**Interfaces:**
- Consumes: Task 1 `ServerFrame`, `ClientOp`.
- Produces:
  - `protocol WebSocketConnecting: Sendable { func connect(to url: URL) async throws -> any WebSocketConnection }`
  - `protocol WebSocketConnection: AnyObject, Sendable { func sendText(_ text: String) async throws; func receiveText() async throws -> String; func ping() async throws; func close() }`
  - `final class URLSessionWebSocketConnector: WebSocketConnecting` (production impl; `receiveText` maps `.data` messages through UTF-8).
  - `struct JournalConnection`:
    - `static func establish(connector: any WebSocketConnecting, wsURL: URL, token: String, cursor: Int64) async throws -> (connection: JournalConnection, headSeq: Int64)` — connects, sends hello, awaits `hello_ok`; throws `JournalConnectionError.authRejected` on an `error(code:"auth")` frame.
    - `func frames() -> AsyncThrowingStream<ServerFrame, Error>` — pump loop; undecodable text frames are skipped; the stream throws when the socket dies.
    - `func send(_ op: ClientOp) async throws`, `func ping() async throws`, `func close()`
  - `enum JournalConnectionError: Error, Equatable { case authRejected, badHandshake, socketClosed }`
  - Test fake: `final class FakeWebSocketConnection: WebSocketConnection` (scripted incoming lines via `AsyncStream<String>` + recorded `sent: [String]`, injectable failures) and `FakeConnector`.

- [ ] **Step 1: Write the failing test**

`MatronShared/Tests/JournalTests/FakeWebSocket.swift`:
```swift
import Foundation
@testable import MatronJournal

/// Scriptable fake socket. Push server frames with `serve(_:)`; closing
/// finishes the incoming stream so `receiveText` throws `socketClosed`.
final class FakeWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false
    private(set) var sent: [String] = []
    var pingError: Error?

    func serve(_ text: String) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
            lock.unlock()
        }
    }

    func closeFromServer() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(throwing: JournalConnectionError.socketClosed) }
    }

    func sendText(_ text: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw JournalConnectionError.socketClosed }
        sent.append(text)
    }

    func receiveText() async throws -> String {
        lock.lock()
        if !incoming.isEmpty {
            let next = incoming.removeFirst()
            lock.unlock()
            return next
        }
        if closed {
            lock.unlock()
            throw JournalConnectionError.socketClosed
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: JournalConnectionError.socketClosed)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func ping() async throws {
        if let pingError { throw pingError }
    }

    func close() { closeFromServer() }

    /// Convenience: last sent frame decoded as a JSON object.
    var lastSentObject: [String: Any]? {
        guard let last = sent.last else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
    }
}

/// Hands out pre-built fake connections in order; records connect calls.
final class FakeConnector: WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeWebSocketConnection]
    private(set) var connectCount = 0
    var connectError: Error?

    init(_ connections: [FakeWebSocketConnection]) { queue = connections }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        lock.lock()
        defer { lock.unlock() }
        connectCount += 1
        if let connectError { throw connectError }
        guard !queue.isEmpty else { throw JournalConnectionError.socketClosed }
        return queue.removeFirst()
    }
}
```

`MatronShared/Tests/JournalTests/JournalConnectionTests.swift`:
```swift
import XCTest
@testable import MatronJournal

final class JournalConnectionTests: XCTestCase {
    private let wsURL = URL(string: "wss://x/ws")!

    func testEstablishSendsHelloAndReturnsHead() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":7}"#)
        let (connection, head) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "tok", cursor: 3)
        XCTAssertEqual(head, 7)
        let hello = try XCTUnwrap(socket.lastSentObject)
        XCTAssertEqual(hello["op"] as? String, "hello")
        XCTAssertEqual(hello["token"] as? String, "tok")
        XCTAssertEqual(hello["cursor"] as? Int64, 3)
        connection.close()
    }

    func testEstablishThrowsOnAuthError() async {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"error","code":"auth"}"#)
        do {
            _ = try await JournalConnection.establish(
                connector: FakeConnector([socket]), wsURL: wsURL, token: "bad", cursor: 0)
            XCTFail("expected authRejected")
        } catch let error as JournalConnectionError {
            XCTAssertEqual(error, .authRejected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFramesStreamYieldsAndThrowsOnClose() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let (connection, _) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "t", cursor: 0)
        socket.serve(#"{"kind":"journal","seq":1,"convo_id":"c1","ts":1000,"sender":"agent:a","type":"text","payload":{"body":"x"}}"#)
        socket.serve("garbage that is skipped")
        socket.serve(#"{"kind":"journal","seq":2,"convo_id":"c1","ts":2000,"sender":"agent:a","type":"text","payload":{"body":"y"}}"#)

        var received: [Int64] = []
        do {
            for try await frame in connection.frames() {
                if case let .journal(event) = frame {
                    received.append(event.seq)
                    if event.seq == 2 { socket.closeFromServer() }
                }
            }
            XCTFail("stream must throw when the socket dies")
        } catch {
            // expected
        }
        XCTAssertEqual(received, [1, 2])
    }

    func testSendEncodesOp() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let (connection, _) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "t", cursor: 0)
        try await connection.send(.ack(cursor: 5))
        XCTAssertEqual(socket.lastSentObject?["op"] as? String, "ack")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MatronShared --filter JournalConnectionTests 2>&1 | tail -5`
Expected: FAIL — types not found.

- [ ] **Step 3: Write the implementation**

`MatronShared/Sources/Journal/WebSocketTransport.swift`:
```swift
import Foundation

public protocol WebSocketConnecting: Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection
}

public protocol WebSocketConnection: AnyObject, Sendable {
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    /// One liveness round-trip; throws if the peer is gone.
    func ping() async throws
    func close()
}

public enum JournalConnectionError: Error, Equatable, Sendable {
    case authRejected
    case badHandshake
    case socketClosed
}

public final class URLSessionWebSocketConnector: WebSocketConnecting {
    private let urlSession: URLSession

    public init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
    }

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func sendText(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw JournalConnectionError.socketClosed
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
```

`MatronShared/Sources/Journal/JournalConnection.swift`:
```swift
import Foundation

/// One established, authenticated socket. Create via `establish`, consume
/// `frames()` until it throws, then let the sync engine reconnect — a
/// resume is indistinguishable from a continuation server-side.
public struct JournalConnection: Sendable {
    private let socket: any WebSocketConnection

    public static func establish(
        connector: any WebSocketConnecting, wsURL: URL, token: String, cursor: Int64
    ) async throws -> (connection: JournalConnection, headSeq: Int64) {
        let socket = try await connector.connect(to: wsURL)
        try await socket.sendText(ClientOp.hello(token: token, cursor: cursor).encoded())
        // The first decodable frame after hello is hello_ok or an auth error.
        while true {
            let text = try await socket.receiveText()
            guard let frame = ServerFrame.decode(text) else { continue }
            switch frame {
            case .helloOK(let headSeq):
                return (JournalConnection(socket: socket), headSeq)
            case .error(let code, _):
                socket.close()
                throw code == "auth" ? JournalConnectionError.authRejected : JournalConnectionError.badHandshake
            default:
                socket.close()
                throw JournalConnectionError.badHandshake
            }
        }
    }

    public func frames() -> AsyncThrowingStream<ServerFrame, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let text = try await socket.receiveText()
                        if let frame = ServerFrame.decode(text) {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func send(_ op: ClientOp) async throws {
        try await socket.sendText(op.encoded())
    }

    public func ping() async throws {
        try await socket.ping()
    }

    public func close() {
        socket.close()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalConnectionTests 2>&1 | tail -5`
Expected: PASS, `Executed 4 tests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/WebSocketTransport.swift MatronShared/Sources/Journal/JournalConnection.swift MatronShared/Tests/JournalTests/FakeWebSocket.swift MatronShared/Tests/JournalTests/JournalConnectionTests.swift
git commit -m "feat(journal): websocket transport and connection handshake"
```

---

### Task 5: SyncConnectionState → MatronModels, then JournalSyncEngine

**Files:**
- Create: `MatronShared/Sources/Models/SyncConnectionState.swift`, `MatronShared/Sources/Journal/JournalSyncEngine.swift`
- Modify: `MatronShared/Sources/Sync/SyncService.swift` (delete the enum, add typealias), `MatronShared/Sources/DesignSystem/StateBridges.swift` (import swap), `MatronShared/Package.swift` (DesignSystem: replace `"MatronSync"` dep with nothing new — `MatronModels` is already there)
- Test: `MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; `SearchService` (from `MatronSearch`).
- Produces:
  - `SyncConnectionState` now lives in `MatronModels` (same three cases). `MatronSync` re-exports via `public typealias SyncConnectionState = MatronModels.SyncConnectionState` so all existing imports keep compiling.
  - `actor JournalSyncEngine`:
    - `init(api: JournalAPI, store: JournalStore, connector: any WebSocketConnecting, token: String, ownSender: String, search: (any SearchService)?, backoffBaseSeconds: Double = 1.0)`
    - `func start()` (idempotent; spawns the run loop), `func stop() async`
    - `var isRunning: Bool { get }`
    - `func waitUntilReady() async throws` — returns on first `.running`; throws `JournalSyncError.authRevoked` if auth fails first.
    - `nonisolated func stateStream() -> AsyncStream<SyncConnectionState>` — replays current state to new subscribers.
    - `func sendOp(_ op: ClientOp) async throws` — throws `JournalSyncError.offline` without a live connection.
    - `func setViewing(convoID: String?) async` — remembers and (re)sends on every (re)connect.
    - `nonisolated func ephemerals(convoID: String) -> AsyncStream<EphemeralUpdate>`
    - `func refreshSummaries() async` — best-effort `/snapshot` → `store.refreshSummaries`.
    - `func nudge()` — wake from backoff immediately (foreground/network-change hook).
  - `enum JournalSyncError: Error, Equatable { case offline, authRevoked }`
  - Behavior: cold start (cursor 0 + no conversations) does `/snapshot` → `applyColdSnapshot` before connecting; every reconnect re-sends `viewing` and kicks a background `refreshSummaries()`; journal frames → `store.applyJournal` + FTS index (`search.index(roomID: convoID, eventID: String(seq), sender:, timestamp:, body:)` for `text` bodies and `tool_output`/`diff` snippets); ack sent every 50 applied frames and on stream end; state `.connecting` until cursor ≥ headSeq, then `.running`; on socket death `.offline(reason:)` then exponential backoff (base × 2^attempt, cap 60 s, ±20 % jitter) — `nudge()` cancels the sleep; watchdog task pings every 20 s, two consecutive failures close the socket; an `error(code:"auth")` at handshake stops the loop permanently with `.offline(reason: "Signed out by server")`.

- [ ] **Step 1: Move the enum**

Create `MatronShared/Sources/Models/SyncConnectionState.swift`:
```swift
import Foundation

/// Connection state published by the sync layer and rendered by the
/// ConnectionStatusBanner (via SyncBannerState). Lives in MatronModels so
/// the design system doesn't depend on the sync implementation.
public enum SyncConnectionState: Equatable, Sendable {
    case connecting
    case running
    case offline(reason: String?)
}
```
In `MatronShared/Sources/Sync/SyncService.swift`: delete the `public enum SyncConnectionState { ... }` block (lines 20-24) and add in its place:
```swift
import MatronModels

/// Moved to MatronModels (journal swap); alias keeps existing imports compiling.
public typealias SyncConnectionState = MatronModels.SyncConnectionState
```
(Keep the existing `import MatrixRustSDK` etc. untouched for now.)

In `MatronShared/Sources/DesignSystem/StateBridges.swift`: change `import MatronSync` to `import MatronModels` (the `SyncBannerState.from(_:)` body is unchanged). In `MatronShared/Package.swift`, remove `"MatronSync"` from the `MatronDesignSystem` dependencies array, and remove `"MatronSync"` from the `DesignSystemSnapshotTests` test target dependencies. If any snapshot test file imports `MatronSync`, switch it to `MatronModels`.

Run: `swift build --package-path MatronShared 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 2: Write the failing engine test**

`MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift`:
```swift
import XCTest
import MatronModels
@testable import MatronJournal

final class JournalSyncEngineTests: XCTestCase {
    private func journalLine(_ seq: Int64, convo: String = "c1", sender: String = "agent:a",
                             type: String = "text", body: String = "m") -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"\#(sender)","type":"\#(type)","payload":{"body":"\#(body)\#(seq)"}}"#
    }

    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func makeEngine(store: JournalStore, connector: FakeConnector) -> JournalSyncEngine {
        let api = JournalAPI(serverURL: URL(string: "https://x")!) // HTTP unused in these tests: store pre-seeded
        return JournalSyncEngine(api: api, store: store, connector: connector,
                                 token: "t", ownSender: "user:dan", search: nil,
                                 backoffBaseSeconds: 0.01)
    }

    /// Pre-seed the store so the engine skips the cold /snapshot fetch.
    private func seededStore() throws -> JournalStore {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0)], headSeq: 0)
        return store
    }

    func testReplayAppliesToStoreAndReachesRunning() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(3))
        socket.serve(journalLine(1))
        socket.serve(journalLine(2))
        socket.serve(journalLine(3))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.start()
        try await engine.waitUntilReady()
        XCTAssertEqual(store.cursor, 3)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1, 2, 3])
        await engine.stop()
    }

    func testReconnectResumesFromCursorAfterSocketDeath() async throws {
        let first = FakeWebSocketConnection()
        first.serve(helloOK(2))
        first.serve(journalLine(1))
        first.serve(journalLine(2))
        let second = FakeWebSocketConnection()
        second.serve(helloOK(4))
        second.serve(journalLine(3))
        second.serve(journalLine(4))
        let store = try seededStore()
        let connector = FakeConnector([first, second])
        let engine = makeEngine(store: store, connector: connector)
        await engine.start()
        try await engine.waitUntilReady()
        first.closeFromServer()

        // wait for the second connection to drain
        for _ in 0..<200 where store.cursor < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cursor, 4)
        XCTAssertEqual(connector.connectCount, 2)
        // second hello must resume from cursor 2
        let hello = try XCTUnwrap(second.sent.first.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        })
        XCTAssertEqual(hello["cursor"] as? Int64, 2)
        await engine.stop()
    }

    func testDuplicateReplayFramesAreIdempotent() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(2))
        socket.serve(journalLine(1))
        socket.serve(journalLine(1)) // duplicate
        socket.serve(journalLine(2))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.start()
        try await engine.waitUntilReady()
        XCTAssertEqual(try store.events(convoID: "c1").count, 2)
        await engine.stop()
    }

    func testEphemeralFanOut() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.start()
        try await engine.waitUntilReady()
        var iterator = engine.ephemerals(convoID: "c1").makeAsyncIterator()
        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m1","replace_text":"working…"}"#)
        let update = await iterator.next()
        XCTAssertEqual(update?.replaceText, "working…")
        await engine.stop()
    }

    func testStateStreamTransitions() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        var iterator = engine.stateStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .connecting)
        await engine.start()
        var seen: [SyncConnectionState] = []
        for _ in 0..<3 {
            guard let state = await iterator.next() else { break }
            seen.append(state)
            if state == .running { break }
        }
        XCTAssertTrue(seen.contains(.running), "expected .running, saw \(seen)")
        await engine.stop()
    }

    /// Chaos-style: 60 events over connections that die every ~15 frames.
    /// The store must converge to an exact, gap-free prefix copy.
    func testChaosResumeConvergence() async throws {
        var sockets: [FakeWebSocketConnection] = []
        var next: Int64 = 1
        while next <= 60 {
            let socket = FakeWebSocketConnection()
            socket.serve(helloOK(60))
            let batchEnd = min(next + 14, 60)
            // overlap: re-serve up to 3 already-delivered events (server replays > cursor;
            // the fake approximates a race by double-sending — apply must dedupe)
            for seq in max(1, next - 3)...batchEnd { socket.serve(journalLine(seq)) }
            next = batchEnd + 1
            sockets.append(socket)
        }
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector(sockets))
        await engine.start()
        for (index, socket) in sockets.enumerated() where index < sockets.count - 1 {
            let target = Int64(min((index + 1) * 15, 60))
            for _ in 0..<300 where store.cursor < target {
                try await Task.sleep(for: .milliseconds(10))
            }
            socket.closeFromServer()
        }
        for _ in 0..<500 where store.cursor < 60 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cursor, 60)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), Array(1...60), "gap-free exactly-once")
        await engine.stop()
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path MatronShared --filter JournalSyncEngineTests 2>&1 | tail -5`
Expected: FAIL — `JournalSyncEngine` not found.

- [ ] **Step 4: Write the implementation**

`MatronShared/Sources/Journal/JournalSyncEngine.swift`:
```swift
import Foundation
import MatronModels
import MatronSearch

public enum JournalSyncError: Error, Equatable, Sendable {
    case offline
    case authRevoked
}

/// The single writer of the JournalStore and owner of the reconnect loop.
/// Any failure converges to "reconnect and resume from the store cursor" —
/// there is no other recovery path, so there is nothing to wedge.
public actor JournalSyncEngine {
    private let api: JournalAPI
    private let store: JournalStore
    private let connector: any WebSocketConnecting
    private let token: String
    private let ownSender: String
    private let search: (any SearchService)?
    private let backoffBaseSeconds: Double

    private var runTask: Task<Void, Never>?
    private var liveConnection: JournalConnection?
    private var viewingConvoID: String?
    private var backoffSleeper: Task<Void, Never>?
    private var attempt = 0

    private var state: SyncConnectionState = .connecting
    private var stateContinuations: [UUID: AsyncStream<SyncConnectionState>.Continuation] = [:]
    private var ephemeralContinuations: [UUID: (convoID: String, continuation: AsyncStream<EphemeralUpdate>.Continuation)] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    public init(
        api: JournalAPI, store: JournalStore, connector: any WebSocketConnecting,
        token: String, ownSender: String, search: (any SearchService)?,
        backoffBaseSeconds: Double = 1.0
    ) {
        self.api = api
        self.store = store
        self.connector = connector
        self.token = token
        self.ownSender = ownSender
        self.search = search
        self.backoffBaseSeconds = backoffBaseSeconds
    }

    // MARK: Lifecycle

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await runLoop() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        liveConnection?.close()
        liveConnection = nil
        backoffSleeper?.cancel()
        setState(.offline(reason: nil))
    }

    public var isRunning: Bool { runTask != nil }

    public func waitUntilReady() async throws {
        if case .running = state { return }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    public func nudge() {
        backoffSleeper?.cancel()
    }

    // MARK: Public surface

    public func sendOp(_ op: ClientOp) async throws {
        guard let connection = liveConnection else { throw JournalSyncError.offline }
        try await connection.send(op)
    }

    public func setViewing(convoID: String?) async {
        viewingConvoID = convoID
        try? await liveConnection?.send(.viewing(convoID: convoID))
    }

    public func refreshSummaries() async {
        guard let snapshot = try? await api.snapshot() else { return }
        try? store.refreshSummaries(snapshot.conversations)
    }

    public nonisolated func stateStream() -> AsyncStream<SyncConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerState(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterState(id: id) }
            }
        }
    }

    public nonisolated func ephemerals(convoID: String) -> AsyncStream<EphemeralUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerEphemeral(id: id, convoID: convoID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterEphemeral(id: id) }
            }
        }
    }

    // MARK: Registry plumbing

    private func registerState(id: UUID, continuation: AsyncStream<SyncConnectionState>.Continuation) {
        stateContinuations[id] = continuation
        continuation.yield(state)
    }

    private func unregisterState(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func registerEphemeral(id: UUID, convoID: String, continuation: AsyncStream<EphemeralUpdate>.Continuation) {
        ephemeralContinuations[id] = (convoID, continuation)
    }

    private func unregisterEphemeral(id: UUID) {
        ephemeralContinuations.removeValue(forKey: id)
    }

    private func setState(_ new: SyncConnectionState) {
        guard new != state else { return }
        state = new
        for continuation in stateContinuations.values { continuation.yield(new) }
        if case .running = new {
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        }
    }

    private func failReadyWaiters(_ error: Error) {
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters = []
    }

    // MARK: Run loop

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                setState(.connecting)
                try await coldStartIfNeeded()
                let cursor = store.cursor
                let (connection, headSeq) = try await JournalConnection.establish(
                    connector: connector, wsURL: api.wsURL, token: token, cursor: cursor)
                liveConnection = connection
                attempt = 0
                if let viewingConvoID {
                    try? await connection.send(.viewing(convoID: viewingConvoID))
                }
                Task { await self.refreshSummaries() } // title/state stopgap (spec §7 ask 4)
                if store.cursor >= headSeq { setState(.running) }

                let watchdog = Task {
                    var misses = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        if Task.isCancelled { return }
                        do {
                            try await connection.ping()
                            misses = 0
                        } catch {
                            misses += 1
                            if misses >= 2 { connection.close(); return }
                        }
                    }
                }
                defer { watchdog.cancel() }

                var appliedSinceAck: Int64 = 0
                for try await frame in connection.frames() {
                    switch frame {
                    case .journal(let event):
                        if (try? store.applyJournal(event)) == true {
                            indexForSearch(event)
                            appliedSinceAck += 1
                            if appliedSinceAck >= 50 {
                                try? await connection.send(.ack(cursor: store.cursor))
                                appliedSinceAck = 0
                            }
                        }
                        if store.cursor >= headSeq { setState(.running) }
                    case .ephemeral(let update):
                        for (_, entry) in ephemeralContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
                    case .error, .helloOK, .unknownControl:
                        break // post-hello control frames are advisory
                    }
                }
            } catch JournalConnectionError.authRejected {
                liveConnection = nil
                setState(.offline(reason: "Signed out by server"))
                failReadyWaiters(JournalSyncError.authRevoked)
                return
            } catch {
                // fall through to backoff
            }
            liveConnection?.close()
            liveConnection = nil
            if Task.isCancelled { return }
            setState(.offline(reason: nil))
            await backoff()
        }
    }

    private func coldStartIfNeeded() async throws {
        guard store.cursor == 0, (try? store.conversations().isEmpty) != false else { return }
        let snapshot = try await api.snapshot()
        try store.applyColdSnapshot(snapshot.conversations, headSeq: snapshot.seq)
    }

    private func backoff() async {
        attempt += 1
        let capped = min(backoffBaseSeconds * pow(2, Double(attempt - 1)), 60)
        let jittered = capped * Double.random(in: 0.8...1.2)
        let sleeper = Task { try? await Task.sleep(for: .seconds(jittered)) }
        backoffSleeper = sleeper
        await sleeper.value // nudge() cancels this → immediate retry
        backoffSleeper = nil
    }

    private func indexForSearch(_ event: JournalEvent) {
        guard let search else { return }
        let payload = event.payload
        let body: String?
        switch event.type {
        case JournalEventType.text:
            body = payload["body"] as? String
        case JournalEventType.toolOutput, JournalEventType.diff:
            body = payload["snippet"] as? String
        default:
            body = nil
        }
        guard let body, !body.isEmpty else { return }
        let convoID = event.convoID
        let seq = event.seq
        let sender = event.sender
        let ts = event.ts
        Task {
            try? await search.index(roomID: convoID, eventID: String(seq),
                                    sender: sender, timestamp: ts, body: body)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalSyncEngineTests 2>&1 | tail -5`
Expected: PASS, `Executed 6 tests`. Then the full package: `swift test --package-path MatronShared 2>&1 | tail -5` — all suites green.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Models/SyncConnectionState.swift MatronShared/Sources/Sync/SyncService.swift MatronShared/Sources/DesignSystem/StateBridges.swift MatronShared/Package.swift MatronShared/Sources/Journal/JournalSyncEngine.swift MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift
git commit -m "feat(journal): sync engine with resume-from-cursor loop; SyncConnectionState moved to MatronModels"
```

---

### Task 6: JournalTimelineMapper — events → TimelineItem

**Files:**
- Modify: `MatronShared/Package.swift` (add `"MatronJournal"` to `MatronChat` dependencies)
- Create: `MatronShared/Sources/Chat/JournalTimelineMapper.swift`
- Test: `MatronShared/Tests/JournalTests/…` cannot import MatronChat — instead create `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift` (ChatTests already depends on MatronChat; add `"MatronJournal"` to the ChatTests dependencies in Package.swift)

**Interfaces:**
- Consumes: `JournalEvent`/`JournalEventType` (MatronJournal), `TimelineItem` (MatronChat), `AskUserEvent`/`ToolCallEvent` (MatronEvents).
- Produces `public enum JournalTimelineMapper`:
  - `static func timelineItem(from event: JournalEvent, ownSender: String, serverURL: URL) -> TimelineItem?` — nil for `read_marker`/`edit`/`session_status` (not rendered as rows).
  - `static func askUserEvent(fromPrompt payload: [String: Any]) -> AskUserEvent`
  - `static func toolCallEvent(fromToolOutput payload: [String: Any], ts: Date) -> ToolCallEvent`
  - `static func streamingItem(messageRef: String, text: String, convoTS: Date) -> TimelineItem` — id `"eph:<ref>"`, sender `"agent"`, kind `.text`.
  - `static func displayName(fromSender sender: String) -> String` — strips `user:`/`agent:` prefix.
  - Mapping rules: `text`→`.text(body:formattedHTML:nil)`; `tool_output`→`.toolCall(eventID: String(seq), …)` — tries `ToolCallEvent.parse(content: payload)` first (bridge may keep rich keys), else builds from `tool_name`/`snippet`/`truncated`; `prompt`→`.askUser` (options from `options: [ {id,label,value} | String ]`, `allows_free_text`, `mode == "pick_many"` → multiChoice; options empty → `.text` kind; replyChannel `.buttonResponse` when options exist else `.textReply`); `permission_request`→`.askUser` (prompt = `description`, options default `["Allow","Deny"]`); `prompt_reply`→ choice non-nil: `.askUserAnswer(promptEventID: String(target_seq), selectedValues: [choice])`, else `.text(body: text)` with `inReplyToEventID = String(target_seq)`; `diff`→`.toolCall` with tool `"diff"`, resultText = `diff` string or snippet; `file`/`image`→`.file`/`.image` with `url = serverURL/media/<blob_ref>` when `blob_ref` present; unknown types→`.unknown(eventType: type)`; `isOwn = (sender == ownSender)`; `id = String(seq)`.

- [ ] **Step 1: Write the failing test** — `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`:
```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

First add `"MatronJournal"` to both the `MatronChat` target deps and the `ChatTests` test-target deps in `MatronShared/Package.swift`.
Run: `swift test --package-path MatronShared --filter JournalTimelineMapperTests 2>&1 | tail -5`
Expected: FAIL — `JournalTimelineMapper` not found.

- [ ] **Step 3: Write the implementation**

`MatronShared/Sources/Chat/JournalTimelineMapper.swift`:
```swift
import Foundation
import MatronEvents
import MatronJournal

/// Pure mapping from journal events to the render model. Unknown types get
/// a labeled fallback so the protocol can grow without lockstep upgrades.
public enum JournalTimelineMapper {
    public static func displayName(fromSender sender: String) -> String {
        if let colon = sender.firstIndex(of: ":"),
           ["user", "agent"].contains(String(sender[..<colon])) {
            return String(sender[sender.index(after: colon)...])
        }
        return sender
    }

    public static func timelineItem(from event: JournalEvent, ownSender: String, serverURL: URL) -> TimelineItem? {
        let payload = event.payload
        let kind: TimelineItem.Kind
        var inReplyTo: String?

        switch event.type {
        case JournalEventType.readMarker, JournalEventType.edit, JournalEventType.sessionStatus:
            return nil

        case JournalEventType.text:
            kind = .text(body: payload["body"] as? String ?? "", formattedHTML: nil)

        case JournalEventType.toolOutput:
            kind = .toolCall(eventID: String(event.seq),
                             toolCallEvent(fromToolOutput: payload, ts: event.ts))

        case JournalEventType.diff:
            let text = payload["diff"] as? String ?? payload["snippet"] as? String ?? ""
            kind = .toolCall(eventID: String(event.seq), ToolCallEvent(
                tool: "diff", argsJSON: "{}", status: .ok,
                resultText: text, resultTruncated: payload["truncated"] as? Bool ?? false,
                startedAt: event.ts, endedAt: event.ts))

        case JournalEventType.prompt:
            kind = .askUser(eventID: String(event.seq), askUserEvent(fromPrompt: payload))

        case JournalEventType.permissionRequest:
            let description = payload["description"] as? String ?? "Permission request"
            let optionValues = (payload["options"] as? [String]) ?? ["Allow", "Deny"]
            kind = .askUser(eventID: String(event.seq), AskUserEvent(
                prompt: description,
                kind: .choice(options: optionValues.map { AskUserEvent.Option(id: $0, label: $0) },
                              allowOther: false),
                expiresAt: nil, replyChannel: .buttonResponse))

        case JournalEventType.promptReply:
            let target = (payload["target_seq"] as? NSNumber)?.int64Value
            inReplyTo = target.map(String.init)
            if let choice = payload["choice"] as? String {
                kind = .askUserAnswer(promptEventID: inReplyTo ?? "", selectedValues: [choice])
            } else {
                kind = .text(body: payload["text"] as? String ?? "", formattedHTML: nil)
            }

        case JournalEventType.file, JournalEventType.image:
            let url = (payload["blob_ref"] as? String).map {
                serverURL.appendingPathComponent("media").appendingPathComponent($0)
            }
            let size = (payload["size"] as? NSNumber)?.int64Value
            if event.type == JournalEventType.image {
                kind = .image(url: url, caption: payload["caption"] as? String, sizeBytes: size)
            } else {
                kind = .file(url: url, filename: payload["filename"] as? String ?? "file", sizeBytes: size)
            }

        default:
            kind = .unknown(eventType: event.type)
        }

        return TimelineItem(
            id: String(event.seq),
            sender: displayName(fromSender: event.sender),
            timestamp: event.ts,
            kind: kind,
            isOwn: event.sender == ownSender,
            sendState: .sent,
            inReplyToEventID: inReplyTo
        )
    }

    public static func toolCallEvent(fromToolOutput payload: [String: Any], ts: Date) -> ToolCallEvent {
        // Rich payloads (bridge keeps chat.matron.tool_call keys) parse directly.
        if let parsed = ToolCallEvent.parse(content: payload) { return parsed }
        return ToolCallEvent(
            tool: payload["tool_name"] as? String ?? "tool",
            argsJSON: "{}",
            status: .ok,
            resultText: payload["snippet"] as? String,
            resultTruncated: payload["truncated"] as? Bool ?? false,
            startedAt: ts,
            endedAt: nil
        )
    }

    public static func askUserEvent(fromPrompt payload: [String: Any]) -> AskUserEvent {
        let question = payload["question"] as? String ?? ""
        let allowsFreeText = payload["allows_free_text"] as? Bool ?? false
        var options: [AskUserEvent.Option] = []
        for raw in payload["options"] as? [Any] ?? [] {
            if let label = raw as? String {
                options.append(AskUserEvent.Option(id: label, label: label))
            } else if let obj = raw as? [String: Any], let label = obj["label"] as? String {
                options.append(AskUserEvent.Option(
                    id: obj["id"] as? String ?? label, label: label,
                    value: obj["value"] as? String))
            }
        }
        let kind: AskUserEvent.InputKind
        if options.isEmpty {
            kind = .text
        } else if (payload["mode"] as? String) == "pick_many" {
            kind = .multiChoice(options: options, allowOther: allowsFreeText)
        } else {
            kind = .choice(options: options, allowOther: allowsFreeText)
        }
        return AskUserEvent(
            prompt: question, kind: kind, expiresAt: nil,
            replyChannel: options.isEmpty ? .textReply : .buttonResponse)
    }

    public static func streamingItem(messageRef: String, text: String, convoTS: Date) -> TimelineItem {
        TimelineItem(
            id: "eph:\(messageRef)", sender: "agent", timestamp: convoTS,
            kind: .text(body: text, formattedHTML: nil), isOwn: false, sendState: .sent)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalTimelineMapperTests 2>&1 | tail -5`
Expected: PASS, `Executed 10 tests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Chat/JournalTimelineMapper.swift MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift
git commit -m "feat(journal): timeline mapper from journal events to render model"
```

---

### Task 7: JournalAuthService

**Files:**
- Modify: `MatronShared/Package.swift` (add `"MatronJournal"` to `MatronAuth` deps; add `"MatronJournal"` to `AuthTests` deps)
- Create: `MatronShared/Sources/Auth/JournalAuthService.swift`
- Test: `MatronShared/Tests/AuthTests/JournalAuthServiceTests.swift`

**Interfaces:**
- Consumes: `AuthService`/`AuthError`/`ServerCapabilities` (existing, `AuthService.swift`), `ServerURLValidator.normalize`, `SessionStore`, `JournalAPI`, `UserSession`.
- Produces: `public final class JournalAuthService: AuthService, @unchecked Sendable`:
  - `init(sessionStore: any SessionStore, urlSession: URLSession = .shared)`
  - `probe(_ rawURL:)` → normalize URL, `GET /snapshot` unauthenticated; a `JournalAPIError.unauthenticated` response proves a journal server → `ServerCapabilities(supportsPasswordLogin: true, supportsSSO: false)`; any transport failure → `AuthError.serverUnreachable`.
  - `loginPassword(homeserverURL:username:password:initialDeviceDisplayName:)` → `JournalAPI.login`; maps to `UserSession(userID: username, deviceID: String(deviceID), homeserverURL: homeserverURL, accessToken: token)`. `.badCredentials` → `AuthError.invalidCredentials`; `.lockedOut/.rateLimited` → `AuthError.unexpected("Too many attempts — try again in …")`.
  - `restoreSession()/persist(_:)/clearSession()` — JSON `UserSession` under key `"matron.journal.session"` in the injected `SessionStore` (same pattern as `AuthServiceLive`'s `"matron.session"`; different key so a stale Matrix session is never restored).

- [ ] **Step 1: Write the failing test** — `MatronShared/Tests/AuthTests/JournalAuthServiceTests.swift`:
```swift
import XCTest
import MatronModels
import MatronStorage
@testable import MatronJournal
@testable import MatronAuth

final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) throws { values[key] = value }
    func get(key: String) throws -> String? { values[key] }
    func delete(key: String) throws { values[key] = nil }
}

final class JournalAuthServiceTests: XCTestCase {
    private func makeService() -> (JournalAuthService, InMemorySessionStore) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAuthURLProtocol.self]
        let store = InMemorySessionStore()
        return (JournalAuthService(sessionStore: store, urlSession: URLSession(configuration: config)), store)
    }

    func testProbeRecognisesJournalServer() async throws {
        StubAuthURLProtocol.responses = ["/snapshot": (401, #"{"error":"unauthenticated"}"#)]
        let (service, _) = makeService()
        let caps = try await service.probe("chat.example.com")
        XCTAssertTrue(caps.supportsPasswordLogin)
        XCTAssertFalse(caps.supportsSSO)
    }

    func testLoginMapsToUserSessionAndPersistRoundTrips() async throws {
        StubAuthURLProtocol.responses = ["/login": (200, #"{"token":"tok1","device_id":7,"user_id":3}"#)]
        let (service, _) = makeService()
        let session = try await service.loginPassword(
            homeserverURL: URL(string: "https://chat.example.com")!,
            username: "dan", password: "pw", initialDeviceDisplayName: "Matron Mac")
        XCTAssertEqual(session.userID, "dan")
        XCTAssertEqual(session.deviceID, "7")
        XCTAssertEqual(session.accessToken, "tok1")

        try service.persist(session)
        XCTAssertEqual(try service.restoreSession(), session)
        try service.clearSession()
        XCTAssertNil(try service.restoreSession())
    }

    func testBadCredentialsMapsToAuthError() async {
        StubAuthURLProtocol.responses = ["/login": (403, #"{"error":"bad_credentials"}"#)]
        let (service, _) = makeService()
        do {
            _ = try await service.loginPassword(
                homeserverURL: URL(string: "https://chat.example.com")!,
                username: "dan", password: "wrong", initialDeviceDisplayName: "x")
            XCTFail("expected throw")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class StubAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.responses[request.url!.path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run test to verify it fails**

Add `"MatronJournal"` to `MatronAuth` target deps and `AuthTests` deps in Package.swift first.
Run: `swift test --package-path MatronShared --filter JournalAuthServiceTests 2>&1 | tail -5`
Expected: FAIL — `JournalAuthService` not found.

- [ ] **Step 3: Write the implementation**

`MatronShared/Sources/Auth/JournalAuthService.swift`:
```swift
import Foundation
import MatronJournal
import MatronModels
import MatronStorage

/// AuthService against the matron-journal server: POST /login issues a
/// long-lived device token which maps onto UserSession.accessToken.
public final class JournalAuthService: AuthService, @unchecked Sendable {
    private let sessionStore: any SessionStore
    private let urlSession: URLSession
    private let sessionKey = "matron.journal.session"

    public init(sessionStore: any SessionStore, urlSession: URLSession = .shared) {
        self.sessionStore = sessionStore
        self.urlSession = urlSession
    }

    public func probe(_ rawURL: String) async throws -> ServerCapabilities {
        let url: URL
        do {
            url = try ServerURLValidator.normalize(rawURL)
        } catch let error as ServerURLValidator.ValidationError {
            throw AuthError.invalidServerURL(error)
        }
        let api = JournalAPI(serverURL: url, urlSession: urlSession)
        do {
            _ = try await api.snapshot() // unauthenticated on purpose
            throw AuthError.serverUnreachable // a journal server must 401 here
        } catch JournalAPIError.unauthenticated {
            return ServerCapabilities(supportsPasswordLogin: true, supportsSSO: false)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.serverUnreachable
        }
    }

    public func loginPassword(
        homeserverURL: URL, username: String, password: String, initialDeviceDisplayName: String
    ) async throws -> UserSession {
        let api = JournalAPI(serverURL: homeserverURL, urlSession: urlSession)
        do {
            let login = try await api.login(username: username, password: password,
                                            deviceName: initialDeviceDisplayName)
            return UserSession(
                userID: username,
                deviceID: String(login.deviceID),
                homeserverURL: homeserverURL,
                accessToken: login.token
            )
        } catch JournalAPIError.badCredentials {
            throw AuthError.invalidCredentials
        } catch let JournalAPIError.lockedOut(retryAfterSeconds) {
            throw AuthError.unexpected("Too many attempts — try again in \(retryAfterSeconds)s")
        } catch JournalAPIError.rateLimited {
            throw AuthError.unexpected("Too many attempts — try again in a minute")
        } catch let error as JournalAPIError {
            throw AuthError.unexpected(String(describing: error))
        }
    }

    public func restoreSession() throws -> UserSession? {
        guard let json = try sessionStore.get(key: sessionKey) else { return nil }
        return try? JSONDecoder().decode(UserSession.self, from: Data(json.utf8))
    }

    public func persist(_ session: UserSession) throws {
        let data = try JSONEncoder().encode(session)
        try sessionStore.set(String(decoding: data, as: UTF8.self), forKey: sessionKey)
    }

    public func clearSession() throws {
        try sessionStore.delete(key: sessionKey)
    }
}
```
Note: `AuthService.restoreSession()` is declared `async throws` — match the protocol exactly (`func restoreSession() async throws -> UserSession?`); the body above is synchronous, which satisfies an async requirement.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalAuthServiceTests 2>&1 | tail -5`
Expected: PASS, `Executed 3 tests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Auth/JournalAuthService.swift MatronShared/Tests/AuthTests/JournalAuthServiceTests.swift
git commit -m "feat(journal): AuthService implementation against POST /login"
```

---

### Task 8: JournalChatService (chat list)

**Files:**
- Create: `MatronShared/Sources/Chat/JournalChatService.swift`
- Test: `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift`

**Interfaces:**
- Consumes: `ChatService`/`ChatSummary`/`BotIdentity` (existing), `JournalStore`, `JournalSyncEngine`.
- Produces: `public final class JournalChatService: ChatService, @unchecked Sendable`:
  - `init(store: JournalStore, engine: JournalSyncEngine)`
  - `chatSummaries()` → maps `store.conversationsStream()`; `ChatSummary(id: record.id, title: record.title.isEmpty ? record.id : record.title, bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil), lastActivity: record.lastActivityTS.map { Date(timeIntervalSince1970: Double($0)/1000) } ?? (record.createdAt > 0 ? Date(timeIntervalSince1970: Double(record.createdAt)/1000) : nil), unreadCount: record.unreadCount)`.
  - `createChat(with:)` → `throw JournalChatError.creationNotSupported` (`LocalizedError`, message: "Creating conversations from the app needs server support (convo_create) — coming soon.").
  - `refresh()` → `try await engine.waitUntilReady()`.
  - `forceSnapshot()` → `await engine.refreshSummaries()`.
  - `mute(roomID:)` → `store.setMuted(true, convoID:)`. `leave(roomID:)` → `store.setHidden(true, convoID:)`.

- [ ] **Step 1: Write the failing test** — `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift`:
```swift
import XCTest
import MatronJournal
@testable import MatronChat

final class JournalChatServiceTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func makeService(_ store: JournalStore) -> JournalChatService {
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = JournalSyncEngine(api: api, store: store, connector: FakeChatConnector(),
                                       token: "t", ownSender: "user:dan", search: nil)
        return JournalChatService(store: store, engine: engine)
    }

    func testChatSummariesMapAndStream() async throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "Fix build", sessionState: "running",
                            lastSeq: 3, snippet: "s", createdAt: 1_752_000_000_000),
        ], headSeq: 3)
        let service = makeService(store)
        var iterator = service.chatSummaries().makeAsyncIterator()
        let summaries = try await iterator.next()
        XCTAssertEqual(summaries?.count, 1)
        XCTAssertEqual(summaries?.first?.id, "c1")
        XCTAssertEqual(summaries?.first?.title, "Fix build")
        XCTAssertEqual(summaries?.first?.unreadCount, 0)
        XCTAssertNotNil(summaries?.first?.lastActivity)
    }

    func testUntitledConvoFallsBackToID() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "sess-42", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"x"}"#.utf8)))
        let service = makeService(store)
        var iterator = service.chatSummaries().makeAsyncIterator()
        let summaries = try await iterator.next()
        XCTAssertEqual(summaries?.first?.title, "sess-42")
        XCTAssertEqual(summaries?.first?.unreadCount, 1)
    }

    func testCreateChatThrowsGracefully() async throws {
        let service = makeService(try makeStore())
        do {
            _ = try await service.createChat(with: "claude")
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is JournalChatError)
        }
    }

    func testLeaveHidesConversation() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"x"}"#.utf8)))
        let service = makeService(store)
        try await service.leave(roomID: "c1")
        XCTAssertEqual(try store.conversations().count, 0)
    }
}

/// Never connects — enough for list tests that only read the store.
final class FakeChatConnector: WebSocketConnecting, @unchecked Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection {
        throw JournalConnectionError.socketClosed
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MatronShared --filter JournalChatServiceTests 2>&1 | tail -5`
Expected: FAIL — `JournalChatService` not found.

- [ ] **Step 3: Write the implementation**

`MatronShared/Sources/Chat/JournalChatService.swift`:
```swift
import Foundation
import MatronJournal
import MatronModels

public enum JournalChatError: Error, LocalizedError, Equatable {
    case creationNotSupported

    public var errorDescription: String? {
        switch self {
        case .creationNotSupported:
            return "Creating conversations from the app needs server support (convo_create) — coming soon."
        }
    }
}

/// ChatService over the local journal mirror. The chat list is a pure
/// read of the store; freshness is the sync engine's job.
public final class JournalChatService: ChatService, @unchecked Sendable {
    private let store: JournalStore
    private let engine: JournalSyncEngine

    public init(store: JournalStore, engine: JournalSyncEngine) {
        self.store = store
        self.engine = engine
    }

    public func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        let store = store
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await records in store.conversationsStream() {
                    continuation.yield(records.map(Self.summary(from:)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func summary(from record: ConversationRecord) -> ChatSummary {
        let activityMS = record.lastActivityTS ?? (record.createdAt > 0 ? record.createdAt : nil)
        return ChatSummary(
            id: record.id,
            title: record.title.isEmpty ? record.id : record.title,
            bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
            lastActivity: activityMS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            unreadCount: record.unreadCount
        )
    }

    public func createChat(with botID: String) async throws -> String {
        throw JournalChatError.creationNotSupported
    }

    public func refresh() async throws {
        try await engine.waitUntilReady()
    }

    public func forceSnapshot() async throws {
        await engine.refreshSummaries()
    }

    public func mute(roomID: String) async throws {
        try store.setMuted(true, convoID: roomID)
    }

    public func leave(roomID: String) async throws {
        try store.setHidden(true, convoID: roomID)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter JournalChatServiceTests 2>&1 | tail -5`
Expected: PASS, `Executed 4 tests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Chat/JournalChatService.swift MatronShared/Tests/ChatTests/JournalChatServiceTests.swift
git commit -m "feat(journal): ChatService over the store mirror"
```

---

### Task 9: JournalTimelineService (per-conversation)

**Files:**
- Create: `MatronShared/Sources/Chat/JournalTimelineService.swift`
- Test: `MatronShared/Tests/ChatTests/JournalTimelineServiceTests.swift`

**Interfaces:**
- Consumes: `TimelineService` (existing protocol), `JournalStore`, `JournalSyncEngine`, `JournalAPI`, `JournalTimelineMapper`, `UserSession`.
- Produces: `public final class JournalTimelineService: TimelineService, @unchecked Sendable`:
  - `init(convoID: String, store: JournalStore, engine: JournalSyncEngine, api: JournalAPI, session: UserSession, search: (any SearchService)? = nil)` — `ownSender = "user:\(session.userID)"`. `search` receives paginated history (spec §2: FTS fed on ingest AND pagination).
  - `items()` — merges three inputs into one `[TimelineItem]` snapshot stream:
    1. `store.eventsStream(convoID:)` mapped through `JournalTimelineMapper` (nil-filtered),
    2. streaming overlay rows from `engine.ephemerals(convoID:)` (dict keyed `message_ref`; `replaceText` replaces, `textDelta` appends; an overlay is dropped when a journal event arrives whose `payload["message_ref"]` matches, or after 30 s without updates),
    3. local-echo rows for in-flight sends (`sendState: .sending`), dropped when an own `text` event with the same body arrives.
    Emits merged array (store items, then overlay+echo items ordered by timestamp). On stream start: `engine.setViewing(convoID:)`; on termination: `engine.setViewing(convoID: nil)`.
  - `sendText(_ body: String, inReplyTo: String?)` — `inReplyTo` parseable as Int64 → `engine.sendOp(.promptReply(convoID:targetSeq:choice:nil,text:body))`; else `.send(convoID:body:localID: UUID().uuidString)` with a local-echo row registered first.
  - `sendButtonResponse(selectedValues:inReplyTo:)` — `.promptReply(targetSeq: Int64(promptEventID) ?? 0, choice: selectedValues.joined(separator: ", "), text: nil)`.
  - `sendImage/sendFile` — `throw JournalChatError.creationNotSupported`? NO — add `case mediaNotSupported` to `JournalChatError` with message "Attachments need the server's /media endpoint — coming soon." and throw it.
  - `paginateBackward(requestSize:)` — `api.messages(convoID:beforeSeq: store.minSeq(convoID:), limit: Int(requestSize))` → `store.insertHistory` → returns `!events.isEmpty`.
  - `markAsRead()` — `store.maxSeq(convoID:)` → `engine.sendOp(.readMarker(...))`; swallow `JournalSyncError.offline` (retried implicitly next time).
- Test with the fakes from Task 4/8 (`FakeConnector`, `FakeWebSocketConnection`): drive an engine with a scripted socket, assert (a) store events surface as mapped items, (b) an ephemeral frame inserts an overlay row and a matching finalize (journal event with `payload.message_ref`) removes it, (c) `sendText` emits a `.sending` local echo immediately and the op reaches the socket, (d) `sendText(inReplyTo: "3")` sends a `prompt_reply` op, (e) `markAsRead` sends `read_marker` with the max seq. Write the test first (same structure as prior tasks — construct engine + service, feed frames via `FakeWebSocketConnection.serve`, iterate `service.items()`), run to see it fail, implement, re-run.

Implementation skeleton (the merge actor is the only subtle part):
```swift
import Foundation
import MatronJournal
import MatronModels

public final class JournalTimelineService: TimelineService, @unchecked Sendable {
    private let convoID: String
    private let store: JournalStore
    private let engine: JournalSyncEngine
    private let api: JournalAPI
    private let ownSender: String
    private let overlay = OverlayState()

    public init(convoID: String, store: JournalStore, engine: JournalSyncEngine,
                api: JournalAPI, session: UserSession) {
        self.convoID = convoID
        self.store = store
        self.engine = engine
        self.api = api
        self.ownSender = "user:\(session.userID)"
    }

    /// Streaming overlays + local echoes, isolated on one actor.
    actor OverlayState {
        struct Echo { let localID: String; let body: String; let created: Date }
        private(set) var streaming: [String: (text: String, updated: Date)] = [:]
        private(set) var echoes: [Echo] = []

        func applyEphemeral(_ update: EphemeralUpdate) {
            let current = streaming[update.messageRef]?.text ?? ""
            let text = update.replaceText ?? (current + (update.textDelta ?? ""))
            streaming[update.messageRef] = (text, Date())
        }

        func reconcile(with events: [JournalEvent], ownSender: String) {
            for event in events {
                if let ref = event.payload["message_ref"] as? String {
                    streaming.removeValue(forKey: ref)
                }
                if event.sender == ownSender, event.type == JournalEventType.text,
                   let body = event.payload["body"] as? String,
                   let index = echoes.firstIndex(where: { $0.body == body }) {
                    echoes.remove(at: index)
                }
            }
            let cutoff = Date().addingTimeInterval(-30)
            streaming = streaming.filter { $0.value.updated > cutoff }
            echoes = echoes.filter { $0.created > Date().addingTimeInterval(-30) }
        }

        func addEcho(localID: String, body: String) { echoes.append(Echo(localID: localID, body: body, created: Date())) }
    }

    public func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        let convoID = convoID
        let engine = engine
        let store = store
        let overlay = overlay
        let ownSender = ownSender
        let serverURL = api.serverURL
        return AsyncThrowingStream { continuation in
            let emit: @Sendable () async -> Void = {
                let events = (try? store.events(convoID: convoID)) ?? []
                await overlay.reconcile(with: events, ownSender: ownSender)
                var items = events.compactMap {
                    JournalTimelineMapper.timelineItem(from: $0, ownSender: ownSender, serverURL: serverURL)
                }
                let lastTS = items.last?.timestamp ?? Date()
                for (ref, entry) in await overlay.streaming.sorted(by: { $0.key < $1.key }) {
                    items.append(JournalTimelineMapper.streamingItem(messageRef: ref, text: entry.text, convoTS: max(lastTS, entry.updated)))
                }
                for echo in await overlay.echoes {
                    items.append(TimelineItem(id: "echo:\(echo.localID)", sender: ownSender,
                                              timestamp: echo.created,
                                              kind: .text(body: echo.body, formattedHTML: nil),
                                              isOwn: true, sendState: .sending))
                }
                continuation.yield(items)
            }
            let storeTask = Task {
                await engine.setViewing(convoID: convoID)
                for await _ in store.eventsStream(convoID: convoID) { await emit() }
                continuation.finish()
            }
            let ephemeralTask = Task {
                for await update in engine.ephemerals(convoID: convoID) {
                    await overlay.applyEphemeral(update)
                    await emit()
                }
            }
            self.onEchoChange = { Task { await emit() } }
            continuation.onTermination = { _ in
                storeTask.cancel()
                ephemeralTask.cancel()
                Task { await engine.setViewing(convoID: nil) }
            }
        }
    }

    private var onEchoChange: (@Sendable () -> Void)?

    public func sendText(_ body: String, inReplyTo: String?) async throws {
        if let inReplyTo, let target = Int64(inReplyTo) {
            try await engine.sendOp(.promptReply(convoID: convoID, targetSeq: target, choice: nil, text: body))
            return
        }
        let localID = UUID().uuidString
        await overlay.addEcho(localID: localID, body: body)
        onEchoChange?()
        try await engine.sendOp(.send(convoID: convoID, body: body, localID: localID))
    }

    public func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {
        try await engine.sendOp(.promptReply(convoID: convoID,
                                             targetSeq: Int64(promptEventID) ?? 0,
                                             choice: selectedValues.joined(separator: ", "), text: nil))
    }

    public func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        throw JournalChatError.mediaNotSupported
    }

    public func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        throw JournalChatError.mediaNotSupported
    }

    public func paginateBackward(requestSize: UInt16) async throws -> Bool {
        let before = try store.minSeq(convoID: convoID)
        let events = try await api.messages(convoID: convoID, beforeSeq: before, limit: Int(requestSize))
        let newOnes = events.filter { before == nil || $0.seq < before! }
        try store.insertHistory(newOnes)
        if let search {
            for event in newOnes {
                let body: String? = switch event.type {
                case JournalEventType.text: event.payload["body"] as? String
                case JournalEventType.toolOutput, JournalEventType.diff: event.payload["snippet"] as? String
                default: nil
                }
                if let body, !body.isEmpty {
                    try? await search.index(roomID: event.convoID, eventID: String(event.seq),
                                            sender: event.sender, timestamp: event.ts, body: body)
                }
            }
        }
        return !newOnes.isEmpty
    }

    public func markAsRead() async throws {
        guard let maxSeq = try store.maxSeq(convoID: convoID) else { return }
        do {
            try await engine.sendOp(.readMarker(convoID: convoID, upToSeq: maxSeq))
        } catch JournalSyncError.offline {
            // Best-effort; the next markAsRead after reconnect converges devices.
        }
    }
}
```
(Also add `case mediaNotSupported` to `JournalChatError` in `JournalChatService.swift` with `errorDescription` "Attachments need the server's /media endpoint — coming soon.")

Steps: write test → run (fail) → implement → `swift test --package-path MatronShared --filter JournalTimelineServiceTests` (PASS) → full package test → commit:
```bash
git add MatronShared/Sources/Chat/JournalTimelineService.swift MatronShared/Sources/Chat/JournalChatService.swift MatronShared/Tests/ChatTests/JournalTimelineServiceTests.swift
git commit -m "feat(journal): TimelineService with ephemeral overlay and local echo"
```

---

### Task 10: JournalMediaService, JournalPushService, SyncService conformance shim

**Files:**
- Create: `MatronShared/Sources/Chat/JournalMediaService.swift`, `MatronShared/Sources/Push/JournalPushService.swift`, `MatronShared/Sources/Sync/JournalSyncConformance.swift`
- Modify: `MatronShared/Package.swift` (add `"MatronJournal"` to `MatronPush` and `MatronSync` deps)
- Test: `MatronShared/Tests/ChatTests/JournalMediaServiceTests.swift`

**Interfaces:**
- `public final class JournalMediaService: MediaService, @unchecked Sendable` — `init(api: JournalAPI)`; `image(for url: URL) async -> Data?` = authed fetch: if the URL is under `serverURL/media/`, extract the blob ref and call `api.mediaData(blobRef:)`, returning nil on any error (server returns 404 until v1-completion — the UI already renders placeholders for nil).
- `public final class JournalPushService: PushService, @unchecked Sendable` — `init(api: JournalAPI)`; `requestPermission()` via `UNUserNotificationCenter.requestAuthorization([.alert, .badge, .sound])` (copy the exact pattern from `PushServiceLive`); `registerToken(_ deviceToken: Data, pusherBaseURL: URL)` → hex-encode token → `api.registerAPNsToken(hex)` (404-tolerant already); `unregister` → no-op.
- `MatronShared/Sources/Sync/JournalSyncConformance.swift` (temporary until Task 14 absorbs it):
```swift
import Foundation
import MatrixRustSDK
import MatronJournal

/// Bridges the journal engine into the legacy SyncService protocol while
/// the SDK-shaped `sdkService()` requirement still exists. Task 14 deletes
/// the requirement and this extension's sdkService with it.
extension JournalSyncEngine: SyncService {
    public func sdkService() async -> MatrixRustSDK.SyncService? { nil }
    public func start() async throws { start() as Void }
    // NOTE: if the compiler flags start()'s signature (protocol wants
    // `async throws`), rename the engine's method to `start()` non-throwing
    // and satisfy the protocol here by calling it.
}
```
Reconcile the exact signatures at implementation time: the protocol requires `start() async throws`, `stop() async`, `isRunning: Bool { get async }`, `waitUntilReady() async throws`, `stateStream() async -> AsyncStream<SyncConnectionState>`. Actor-isolated methods satisfy `async` requirements; where names collide (`start`), give the engine's internal method a distinct name (`beginSync()`) in Task 5's file and expose protocol-named wrappers here and in the engine. Prefer adjusting the engine (rename `start()`→`beginSync()`, `stop()`→`endSync()`, keep protocol-shaped wrappers in this shim) so MatronJournal itself never imports MatronSync.
- Media test: stub URLProtocol returns image bytes for `/media/b1` → `image(for:)` returns them; 404 → nil.

Steps: failing test → implement → `swift test --package-path MatronShared 2>&1 | tail -5` all green → commit `feat(journal): media/push dormant services + SyncService bridge`.

---

### Task 11: Rewire the iOS app

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (rewrite), `Matron/App/MatronApp.swift`, `Matron/Features/ChatList/ChatListView.swift`, `Matron/Features/Chat/ChatView.swift`, `Matron/Features/Settings/DeviceSettingsView.swift`, `Matron/Features/Chat/Composer/ComposerView.swift` (attachment gate), `MatronShared/Sources/ViewModels/SignInViewModel.swift` (default URL), `MatronShared/Sources/ViewModels/SearchViewModel.swift` (drop backfill-progress API)
- Delete: `Matron/Features/Verification/` (5 files), `Matron/Features/Onboarding/PostLoginVerificationView.swift`

**This task makes the iOS app run on the journal stack. Matrix code still exists but is no longer referenced by the iOS target.**

- [ ] **Step 1: Rewrite `Matron/App/AppDependencies.swift`**

Keep the class name, environment keys, and storage-layout helpers. New core:
```swift
import Foundation
import MatronAuth
import MatronChat
import MatronJournal
import MatronModels
import MatronPush
import MatronSearch
import MatronStorage
import MatronSync

@MainActor
final class AppDependencies {
    let auth: AuthService
    let search: SearchService?
    private let sessionsDirectory: URL
    private let journalDirectory: URL

    /// One journal stack per signed-in session.
    final class JournalCore {
        let api: JournalAPI
        let store: JournalStore
        let engine: JournalSyncEngine
        init(api: JournalAPI, store: JournalStore, engine: JournalSyncEngine) {
            self.api = api
            self.store = store
            self.engine = engine
        }
    }

    private var cores: [String: JournalCore] = [:]
    private var timelineCache = LRUCache<TimelineCacheKey, JournalTimelineService>(limit: 16)

    struct TimelineCacheKey: Hashable {
        let userID: String
        let roomID: String
    }

    init() {
        // Same container split as before: sessions/ survives sign-out wipes.
        let container = StoragePaths.groupContainer
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("matron-dev")
        sessionsDirectory = container.appendingPathComponent("sessions")
        journalDirectory = container.appendingPathComponent("journal-store")
        auth = JournalAuthService(sessionStore: FileSessionStore(directory: sessionsDirectory))
        search = StoragePaths.searchDBPath.flatMap { try? SearchServiceLive(databaseURL: $0) }
    }

    func core(for session: UserSession) -> JournalCore {
        if let existing = cores[session.userID] { return existing }
        let api = JournalAPI(serverURL: session.homeserverURL)
        Task { await api.setToken(session.accessToken) }
        let dbURL = journalDirectory.appendingPathComponent("\(session.userID).sqlite")
        // A store that fails to open is unrecoverable dev-time config; crash loudly.
        let store = try! JournalStore(databaseURL: dbURL, ownSender: "user:\(session.userID)")
        let engine = JournalSyncEngine(api: api, store: store,
                                       connector: URLSessionWebSocketConnector(),
                                       token: session.accessToken,
                                       ownSender: "user:\(session.userID)", search: search)
        let core = JournalCore(api: api, store: store, engine: engine)
        cores[session.userID] = core
        return core
    }

    func syncService(for session: UserSession) -> any SyncService { core(for: session).engine }
    func chatService(for session: UserSession) -> any ChatService {
        let core = core(for: session)
        return JournalChatService(store: core.store, engine: core.engine)
    }
    func mediaService(for session: UserSession) -> any MediaService {
        JournalMediaService(api: core(for: session).api)
    }
    func pushService(for session: UserSession) -> any PushService {
        JournalPushService(api: core(for: session).api)
    }
    func timelineService(for session: UserSession, roomID: String) -> any TimelineService {
        let key = TimelineCacheKey(userID: session.userID, roomID: roomID)
        if let cached = timelineCache[key] { return cached }
        let core = core(for: session)
        let service = JournalTimelineService(convoID: roomID, store: core.store,
                                             engine: core.engine, api: core.api,
                                             session: session, search: search)
        timelineCache[key] = service
        return service
    }

    func signOut() {
        for core in cores.values {
            Task { await core.engine.endSync() }
            try? core.store.wipe()
        }
        cores.removeAll()
        timelineCache = LRUCache(limit: 16)
        Task { try? await search?.wipe() }
        try? auth.clearSession()
    }
}
```
Adjust to the file's existing structure (environment keys, `timelineCacheLimit` test seams, the exact `LRUCache` API — check `MatronShared/Sources/Storage/LRUCache.swift` and mirror how the old file used it). Delete `clientProvider`, `verificationService/verificationCache`, `backfillCoordinator/backfillCache`, `awaitPendingIndexWipe` (keep a simple `pendingIndexWipe` Task if `SignInView` awaits it — check call sites and simplify to compile).

- [ ] **Step 2: Rewire `Matron/App/MatronApp.swift`**

- Delete: `verifyDone` state + branch, `verificationCenter` state + its `.task`, `PostLoginVerificationView` branch, `MatronSDKTracing.setup()`, the `KeychainProbe` race (journal keeps sessions in files; no keychain needed at bootstrap), the search-backfill `.task`.
- Keep: `bootstrapDone` + `restoreSession()` bootstrap, the sync-start `.task` (`dependencies.syncService(for: session)` then `try? await sync.start()`), the push `.task` (simplify: `_ = await dependencies.pushService(for: session).requestPermission()` then `UIApplication.shared.registerForRemoteNotifications()`; on token callback in `MatronAppDelegate`, call `pushService.registerToken(token, pusherBaseURL: session.homeserverURL)`), `NotificationDelegate` deep-link `.onReceive` (unchanged — journal pushes will carry `room_id`-compatible keys; see Task 13).
- Add scenePhase reconnect: on the signed-in branch attach
```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active, let session {
        Task { await (dependencies.syncService(for: session) as? JournalSyncEngine)?.nudge() }
    }
}
```
(with `@Environment(\.scenePhase) private var scenePhase` at the App level).
- Root branch becomes: `session != nil` → NavigationStack ChatListView (no `verificationCenter:` argument — see Step 4); else SignInView.

- [ ] **Step 3: SignInViewModel default + SearchViewModel trim**

`MatronShared/Sources/ViewModels/SignInViewModel.swift:15`: `public var serverURL: String = "https://chat.example.com"`.
`MatronShared/Sources/ViewModels/SearchViewModel.swift`: delete `applyBackfillProgress(_:)`, `observeBackfill(_:)` and the `AggregateBackfillProgress` references (backfill machinery dies in Task 14); fix any view call sites in the same commit (search views show results only — remove progress UI).

- [ ] **Step 4: Strip verification from iOS views**

- `git rm -r Matron/Features/Verification Matron/Features/Onboarding/PostLoginVerificationView.swift`
- `ChatListView.swift`: remove the `verificationCenter` property/parameter, `VerificationBanner`/`UnverifiedDeviceBanner` sections, SAS sheet state + `SasSheetWrapper` usages, and `import MatronVerification` if present. Keep `NewChatSheet`, `BotProfileView`, connection banner wiring (unchanged), unread badge, search entry.
- `ChatView.swift`: remove verification banner + per-bot verify sheet + `verificationService` references; keep BotProfile ⓘ (minus any verify button inside it).
- `DeviceSettingsView.swift`: remove verification/recovery sections; keep device name display + sign-out.
- `ComposerView.swift`: wrap the attachment button in `if ComposerViewModel.mediaAvailable` — add to `ComposerViewModel`: `public static let mediaAvailable = false // journal /media endpoint pending (spec §7)`.

- [ ] **Step 5: Build and run iOS tests**

```bash
xcodegen generate
xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`. Fix compile fallout within this task (any file still referencing deleted symbols in the iOS target). Note: `MatronTests`/`MatronUITests` may still reference verification — do NOT run them yet; Task 14 prunes them.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(ios): run on the journal stack; strip verification UI"
```

---

### Task 12: Rewire the Mac app

**Files:**
- Modify: `MatronMac/App/AppDependencies.swift` (same rewrite as Task 11 Step 1, but `StoragePaths.appSupport` instead of the group container — mirror the old file's platform differences), `MatronMac/App/MatronMacApp.swift`, `MatronMac/App/Commands.swift`, `MatronMac/Features/ChatList/MacChatListView.swift`, `MatronMac/Features/Chat/MacChatView.swift`, `MatronMac/Features/Chat/MacChatToolbar.swift`, `MatronMac/Features/Settings/MacDeviceSettingsView.swift`, `MatronMac/Features/Chat/MacComposerView.swift` (attachment gate)
- Delete: `MatronMac/Features/Verification/` (7 files), `MatronMac/Features/Onboarding/MacPostLoginVerificationView.swift`

Same surgery as Task 11, Mac names:
- `MatronMacApp.swift`: drop `verifyDone`, `verificationCenter`, `showVerifyDeviceSheet`/`showRecoveryKeySheet`/`verifyDeviceDismissToken` state + sheets + `HelpMenuVerifyDeviceSheet`; drop SDK tracing/keychain probe/backfill tasks; keep sync-start and (Mac) notification permission task; scenePhase equivalent: `.onChange(of: controlActiveState)` or `NSApplication.didBecomeActiveNotification` via `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))` → `engine.nudge()`.
- `Commands.swift`: remove `.verifyDevice` / `.showRecoveryKey` menu commands (keep the rest of ChatCommands).
- `MacChatListView.swift`: remove `verificationCenter`/banners/SAS sheets/verify listeners params and usages; keep `MacNewChatSheet`, `MacBotProfileSheet`, connection banner.
- `MacChatView.swift` + `MacChatToolbar.swift`: remove verification chrome; keep BotProfile.
- `MacDeviceSettingsView.swift`: sign-out + device info only.
- `MacComposerView.swift`: same `ComposerViewModel.mediaAvailable` gate.

Build check:
```bash
xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

Commit: `git add -A && git commit -m "feat(mac): run on the journal stack; strip verification UI"`

---

### Task 13: NSE passthrough rewrite

**Files:**
- Rewrite: `MatronNSE/NotificationService.swift`
- Modify: `project.yml` (MatronNSE target: remove the `MatronPush` and `MatronAuth` package dependencies — the passthrough needs nothing)

New `MatronNSE/NotificationService.swift` (complete file):
```swift
import UserNotifications

/// Journal-era NSE: the server (once APNs lands, v1-completion) sends
/// alert-carrying payloads in plaintext — no per-message crypto bootstrap.
/// This extension only normalises the payload: ensure a visible title and
/// keep convo_id in userInfo so the host app can deep-link on tap.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        if content.title.isEmpty { content.title = "Matron" }
        if let convoID = content.userInfo["convo_id"] as? String {
            content.threadIdentifier = convoID
            // Host deep-link path reads room_id (Matrix-era key, kept for reuse).
            var userInfo = content.userInfo
            userInfo["room_id"] = convoID
            content.userInfo = userInfo
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Passthrough has nothing async in flight; nothing to salvage.
    }
}
```
Then: `xcodegen generate` + iOS build (same command as Task 11 Step 5). Commit: `refactor(nse): plaintext passthrough for journal pushes`.

---

### Task 14: The Purge — delete Matrix

**Files (delete):**
- `MatronShared/Sources/Sync/SyncServiceLive.swift`, `MatronShared/Sources/Sync/ClientProvider.swift`
- `MatronShared/Sources/Verification/` (entire directory, 7 files)
- `MatronShared/Sources/Auth/AuthServiceLive.swift`, `MatronShared/Sources/Auth/SDKTracing.swift`
- `MatronShared/Sources/Chat/ChatServiceLive.swift`, `TimelineServiceLive.swift`, `TimelinePagerLive.swift`, `MediaServiceLive.swift`, `RoomListSubscription.swift`, `ChatSummaryBroadcaster.swift`
- `MatronShared/Sources/Push/PushServiceLive.swift`, `PushDecoder.swift`, `PushBootstrap.swift`, `PushConfig.swift`, `MatronNotificationSettings.swift` (keep any pure helper the journal push service reuses — check imports first)
- `MatronShared/Sources/Search/BackfillCoordinator.swift`, `BackfillRunner.swift`, `TimelinePager.swift`
- `MatronShared/Sources/ViewModels/VerificationCenter.swift`, `SasViewModel.swift`, `RecoveryKeyViewModel.swift`
- Test dirs: `MatronShared/Tests/VerificationTests/`, `MatronShared/Tests/SyncTests/`, `MatronShared/Tests/PushTests/`; within `AuthTests`/`ChatTests`/`ViewModelTests`/`SearchTests`, delete files that reference `MatrixRustSDK`, `*Live`, `Verification*`, `Sas*`, `RecoveryKey*`, `Backfill*`, `TimelinePager` (find them: `grep -rl 'MatrixRustSDK\|ServiceLive\|Verification\|SasViewModel\|RecoveryKey\|Backfill\|TimelinePager' MatronShared/Tests`)
- `MatronIntegrationTests/VerificationFlowIntegrationTests.swift`, `MatronIntegrationTests/ChatListLiveUpdatesTests.swift`
- Matrix-era UI-test files: `grep -rl 'verify\|recovery\|sas' MatronMacUITests MatronUITests MatronTests MatronMacTests --include='*.swift' -i` → delete matches (keep launch smokes if clean)
- Harness: `tests/integration/scenarios/*.sh` (all 11 — Task 15 adds the journal scenario), `tests/integration/docker/`, `tests/integration/partner/`, `tests/integration/run-all-ui.mjs`

**Files (modify):**
- `MatronShared/Sources/Sync/SyncService.swift`: delete `import MatrixRustSDK` and the `func sdkService() async -> MatrixRustSDK.SyncService?` requirement (keep the doc-comment-trimmed protocol + typealias).
- `MatronShared/Sources/Sync/JournalSyncConformance.swift`: delete `import MatrixRustSDK` + the `sdkService` method.
- `MatronShared/Package.swift`: remove the `matrix-rust-components-swift` package from `dependencies`; remove every `.product(name: "MatrixRustSDK", …)` from targets; delete the `MatronVerification` target + product + `VerificationTests`/`SyncTests`/`PushTests` test targets; remove `"MatronVerification"` from `MatronViewModels` deps and any test-target dep lists.
- `project.yml`: delete the `MatrixRustSDK` package block + every `- package: MatrixRustSDK` dependency; delete every `- package: MatronShared, product: MatronVerification` and `product: MatronSync`? NO — keep MatronSync (protocol + shim + typealias survive); delete only MatronVerification products. Remove verification-related comments where they cause confusion.
- `Matron/App/MatronAppDelegate.swift` / `NotificationDelegate.swift` / `MatronMac/App/MacNotificationHandler.swift`: fix any references to deleted push symbols (registerToken path now goes through `JournalPushService` — done in Tasks 11/12; here just delete dead imports).

- [ ] **Step 1:** Delete everything listed (`git rm` / edits). Run `grep -rn "MatrixRustSDK" --include='*.swift' Matron MatronMac MatronNSE MatronShared/Sources MatronShared/Tests MatronIntegrationTests MatronTests MatronMacTests MatronUITests MatronMacUITests` — expect ZERO hits. (`BotIdentity.matrixID` is a field name, not an import — leave it.)
- [ ] **Step 2:** `xcodegen generate`
- [ ] **Step 3:** Package tests: `swift test --package-path MatronShared 2>&1 | tail -5` — all green, assert the `Executed N tests` line is present.
- [ ] **Step 4:** iOS build: `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -3` → `BUILD SUCCEEDED`.
- [ ] **Step 5:** Mac build + unit tests: `xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests 2>&1 | tail -15` → assert `Executed N tests` with 0 failures (snapshot tests may need `MATRON_SKIP_SNAPSHOT_TESTS=1` per repo convention if the renderer drifts — follow the existing CI env var).
- [ ] **Step 6:** Verify the SDK is gone from resolved packages: `grep -c matrix Matron.xcodeproj/project.pbxproj` → 0.
- [ ] **Step 7:** Commit: `git add -A && git commit -m "refactor!: delete matrix-rust-sdk stack"`

---

### Task 15: Integration tests against the real server

**Files:**
- Create: `MatronIntegrationTests/JournalServerHarness.swift`, `MatronIntegrationTests/JournalServerTests.swift`, `tests/integration/scenarios/journal-live-sdk.sh`
- Modify: `project.yml` (MatronIntegrationTests deps: drop MatronSync/MatronVerification products already gone; add `- package: MatronShared, product: MatronJournal`)

**Interfaces:**
- `JournalServerHarness` (XCTest helper, `final class`):
  - `static func start() throws -> JournalServerHarness` — locates the server repo via `ProcessInfo.processInfo.environment["MATRON_JOURNAL_PATH"]` ?? `"../matron-journal"` (relative to the app repo root, resolved via `#filePath`); throws `XCTSkip` if the path or a `node` binary (`/usr/bin/env node --version`) is missing or `node_modules` isn't installed.
  - Boots `node src/server.js` via `Process` with env `MATRON_DB=<temp>.sqlite`, `MATRON_PORT=0`? — the server doesn't print its port on port 0; use a fixed free port instead: bind-probe with `Darwin.socket`/`bind` to find a free port, pass `MATRON_PORT=<port>`. Waits for readiness by polling `GET /snapshot` (expect 401) up to 5 s.
  - `func addUser(_ name: String, password: String) throws` / `func addAgent(user: String, name: String) throws -> String` — runs `node bin/matron-admin.js …` with the same `MATRON_DB`, parses the printed token (`agent <name> token: <hex64>`). IMPORTANT: admin CLI writes to the SAME SQLite file while the server has it open — WAL mode makes this safe; create users BEFORE starting the server to avoid any doubt (harness API: `configure(users:agents:)` then `start()`).
  - `var baseURL: URL`; `func stop()` (terminate process, delete temp db) — called from `defer`/`tearDown`.
  - `final class FakeAgent` — a raw `URLSessionWebSocketTask` to `/ws`, sends agent hello `{op:"hello",token,cursor:null}`, then `convoUpsert(id:title:state:)`, `publish(convoID:type:payload:idemKey:)`, `stream(convoID:ref:replaceText:)`, `finalize(convoID:ref:body:)` helpers (JSON via `JSONSerialization`).
- `JournalServerTests` (each test skips when the harness can't start):
  1. `testSignInSnapshotLiveRoundTrip` — harness with user `dan`/`pw` + agent `dev-2`. `JournalAuthService.loginPassword` → build `JournalStore` (in-memory) + `JournalSyncEngine` with `URLSessionWebSocketConnector`; agent upserts convo `sess-1` + publishes 3 texts; assert store converges (poll `store.events(convoID:).count == 3+` within 5 s); then `engine.sendOp(.send(...))` and assert the agent's socket receives the journal frame for it.
  2. `testResumeAfterEngineRestart` — publish 5, stop engine, publish 5 more, start a NEW engine on the SAME store, assert events 1–10 exactly once (cursor resume across process-lifecycle boundary).
  3. `testChaosResumeAgainstRealServer` — agent publishes 200 events with 1 ms spacing while a `ChaosConnector` (wraps `URLSessionWebSocketConnector`, closes the underlying socket after a random 10–40 frames) forces repeated reconnects; assert the store converges to exactly seqs of all 200 published events (gap-free, no dupes) within 30 s. This is the client-side headline test mirroring the server's chaos suite.
- `tests/integration/scenarios/journal-live-sdk.sh` — mirrors the old `chat-list-sdk.sh` pattern: `xcodegen generate` if needed, then
```bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
: "${MATRON_JOURNAL_PATH:=$HOME/Dev/matron-journal}"
export MATRON_JOURNAL_PATH
OUTPUT=$(xcodebuild test -project Matron.xcodeproj -scheme MatronMac \
  -destination 'platform=macOS' \
  -only-testing:MatronIntegrationTests/JournalServerTests 2>&1 | tail -40)
echo "$OUTPUT"
echo "$OUTPUT" | grep -q "Executed .* tests, with 0 failures" || { echo "FAIL: tests did not pass"; exit 1; }
```
Precondition documented in the file header: `cd ~/Dev/matron-journal && npm install` once.

Steps: harness + first test → run scenario script → see it fail/skip → fix until `Executed 3 tests, with 0 failures` → commit `test(integration): journal server harness with chaos resume`.

---

### Task 16: End-to-end verification + docs + PR

- [ ] **Step 1:** Full test sweep: `swift test --package-path MatronShared 2>&1 | tail -5`; iOS build; Mac `-only-testing:MatronMacTests`; `tests/integration/scenarios/journal-live-sdk.sh`. All must pass with explicit `Executed N tests` evidence.
- [ ] **Step 2:** Manual run (use the project's run/verify skill flow): start the local server (`MATRON_DB=/tmp/matron-dev.sqlite MATRON_PORT=9810 node src/server.js` with a `dan` user + `dev-2` agent), launch MatronMac from Xcode build, sign in as `dan` to `http://127.0.0.1:9810`, run a small node script that publishes convo_upsert + streamed output + finalize, and confirm: chat list populates, live messages appear WITHOUT restarting the app (the whole point), streaming text updates in place, prompt sheet answers round-trip, kill/restart the server and watch the banner go offline→connecting→running with no wedge. NOTE: sign-in normalizes to https — for a localhost dev server either run the tunnel hostname or temporarily allow http in `ServerURLValidator` for `127.0.0.1` (add an exception: scheme http permitted when host is 127.0.0.1/localhost; include a unit test).
- [ ] **Step 3:** Update `README.md` (protocol section: matron-journal, server repo pointer, local-dev recipe) and `docs/` index if present. Note the server/bridge asks (spec §7) as a checklist in the PR body for the server-side agent.
- [ ] **Step 4:** Commit, push, open PR to `main` titled "Replace Matrix with matron-journal protocol" with the spec+plan linked, test evidence pasted, and the §7 server-asks checklist. End PR body with the standard generation footer.

---

## Self-review notes (already applied)

- Spec §2 "liveness watchdog: server pings" corrected here: URLSession can't observe server pings — the engine uses its own `sendPing` round-trips (Task 5 watchdog).
- `snapshot_required` doesn't exist server-side yet; `ServerFrame.unknownControl` future-proofs it (Task 1 test pins this).
- Server `unread_count` is deliberately ignored (Task 2 computes locally) per spec §4.
- `CLIENT_SEND_TYPES` is text-only server-side — `sendImage`/`sendFile` throw `mediaNotSupported` (Task 9), UI gated (Tasks 11/12).
- Engine method names: protocol-shaped wrappers live in the Task 10 shim; if the concrete/protocol name collision bites, the engine's internal names are `beginSync`/`endSync` (Task 10 note governs Tasks 11/12's `signOut` which calls `endSync`).
