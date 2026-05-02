# Matron iOS — Phase 5 (Custom Events) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 4 (Push & NSE) merged and CI green. Bridge-side changes (separate spec, see below) are needed to actually emit these events; until then the app falls back to plain text rendering.

**Goal:** Add the three Matron-specific event types from spec §4 — `chat.matron.tool_call` (collapsible card), `chat.matron.ask_user` (interactive half-sheet), `chat.matron.session_meta` (chat header) — and wire them through parsing, rendering, and reply-correlation. Update the push notification body to include "🔧 Tool call" / "❓ Question" hints when relevant. Document the bridge-side contract changes in a separate spec stub so the bridge engineer has a concrete target.

**Architecture:** New `MatronEvents` module in MatronShared with parsers + DTOs for each custom type. `TimelineItem.Kind` gains three cases. `TimelineServiceLive` maps SDK events → custom DTOs when type matches. UI: `ToolCallCard`, `AskUserSheet`, `SessionMetaHeader` components. Replies to `ask_user` use `m.in_reply_to` + a known body suffix so the bot can correlate.

**Tech Stack:** Same as prior phases. No new third-party deps.

**Reference:** Spec §4.1–4.6 (custom events + bridge change list).

---

## Companion bridge spec

A bridge-side spec for these contract changes lives at:
`<claude-matrix-bridge repo>/docs/superpowers/specs/<date>-matron-events-protocol.md` (to be written alongside this plan).

This iOS plan ships a *graceful-degradation* implementation: if the bridge doesn't emit the new event types, everything falls back to text rendering and the chat still works.

---

## File structure (Phase 5 deliverables)

```
matron-iOS-app/
├── MatronShared/Sources/Events/
│   ├── ToolCallEvent.swift                NEW
│   ├── AskUserEvent.swift                 NEW
│   ├── SessionMetaEvent.swift             NEW
│   └── EventTypes.swift                   NEW — namespace constants
├── MatronShared/Sources/Chat/
│   ├── TimelineItem.swift                 MODIFIED — adds toolCall/askUser/sessionMeta cases
│   └── TimelineServiceLive.swift          MODIFIED — map custom events
├── MatronShared/Sources/Push/
│   └── PushDecoder.swift                  MODIFIED — body for tool_call/ask_user
├── MatronShared/Sources/DesignSystem/
│   ├── ToolCallCard.swift                 NEW
│   ├── AskUserSheetBody.swift             NEW — DesignSystem-snapshottable inner view
│   └── SessionMetaHeader.swift            NEW
├── Matron/Features/Chat/Rendering/
│   ├── AskUserSheet.swift                 NEW — app-target wrapper around AskUserSheetBody
│   └── AskUserSheetViewModel.swift        NEW
├── Matron/Features/Chat/
│   ├── TimelineItemView.swift             MODIFIED — switch over new cases
│   ├── ChatView.swift                     MODIFIED — present sheet, render header
│   └── ChatViewModel.swift                MODIFIED — answeredPromptIDs + pendingAsk()
├── MatronShared/Sources/Chat/
│   └── TimelineService.swift              MODIFIED — sendText(_:inReplyTo:)
├── MatronShared/Tests/EventsTests/
│   ├── ToolCallEventTests.swift           NEW
│   ├── AskUserEventTests.swift            NEW
│   └── SessionMetaEventTests.swift        NEW
└── MatronShared/Tests/DesignSystemSnapshotTests/
    ├── ToolCallCardSnapshotTests.swift    NEW
    ├── AskUserSheetSnapshotTests.swift    NEW
    └── SessionMetaHeaderSnapshotTests.swift NEW
```

---

## Tasks

### Task 1: EventTypes namespace + Events module

**Files:**
- Create: `MatronShared/Sources/Events/EventTypes.swift`
- Modify: `MatronShared/Package.swift`

- [ ] **Step 1: Add MatronEvents library**

```swift
.library(name: "MatronEvents", targets: ["MatronEvents"]),
.target(name: "MatronEvents", dependencies: ["MatronModels"], path: "Sources/Events"),
.testTarget(name: "EventsTests", dependencies: ["MatronEvents"], path: "Tests/EventsTests"),
```

- [ ] **Step 2: Define type constants**

```swift
import Foundation

public enum MatronEventType {
    public static let toolCall = "chat.matron.tool_call"
    public static let askUser = "chat.matron.ask_user"
    public static let sessionMeta = "chat.matron.session_meta"
}
```

- [ ] **Step 3: Commit**

```bash
git add MatronShared/Sources/Events/EventTypes.swift MatronShared/Package.swift
git commit -m "feat: MatronEvents library + event type constants"
git push
```

---

### Task 2: ToolCallEvent parsing

**Files:**
- Create: `MatronShared/Sources/Events/ToolCallEvent.swift`
- Create: `MatronShared/Tests/EventsTests/ToolCallEventTests.swift`

- [ ] **Step 1: Define DTO + parser**

```swift
import Foundation

public struct ToolCallEvent: Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, ok, error }

    public let tool: String
    public let argsJSON: String                  // raw args object as JSON string for display
    public let status: Status
    public let resultText: String?               // string form (we don't render structured results yet)
    public let resultTruncated: Bool
    public let startedAt: Date
    public let endedAt: Date?

    public init(tool: String, argsJSON: String, status: Status, resultText: String?, resultTruncated: Bool, startedAt: Date, endedAt: Date?) {
        self.tool = tool
        self.argsJSON = argsJSON
        self.status = status
        self.resultText = resultText
        self.resultTruncated = resultTruncated
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Parse a JSON `content` blob from a `chat.matron.tool_call` event.
    public static func parse(content: [String: Any]) -> ToolCallEvent? {
        guard let tool = content["tool"] as? String,
              let statusRaw = content["status"] as? String,
              let status = Status(rawValue: statusRaw),
              let startedMs = content["started_at"] as? Double else {
            return nil
        }
        let argsAny = content["args"] ?? [:]
        let argsJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: argsAny, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }()
        let resultText: String? = {
            if let s = content["result"] as? String { return s }
            if let obj = content["result"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) { return s }
            return nil
        }()
        let resultTruncated = content["result_truncated"] as? Bool ?? false
        let endedAt: Date? = (content["ended_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ToolCallEvent(
            tool: tool,
            argsJSON: argsJSON,
            status: status,
            resultText: resultText,
            resultTruncated: resultTruncated,
            startedAt: Date(timeIntervalSince1970: startedMs / 1000),
            endedAt: endedAt
        )
    }
}
```

- [ ] **Step 2: Tests**

```swift
import XCTest
@testable import MatronEvents

final class ToolCallEventTests: XCTestCase {
    func test_parses_runningEvent() throws {
        let content: [String: Any] = [
            "tool": "Read",
            "args": ["file_path": "/etc/hosts"],
            "status": "running",
            "started_at": 1745000000000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.tool, "Read")
        XCTAssertEqual(evt.status, .running)
        XCTAssertNil(evt.resultText)
        XCTAssertNil(evt.endedAt)
    }

    func test_parses_okWithStringResult() throws {
        let content: [String: Any] = [
            "tool": "Read",
            "args": ["file_path": "/etc/hosts"],
            "status": "ok",
            "result": "127.0.0.1 localhost",
            "started_at": 1745000000000.0,
            "ended_at": 1745000001000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.status, .ok)
        XCTAssertEqual(evt.resultText, "127.0.0.1 localhost")
        XCTAssertNotNil(evt.endedAt)
    }

    func test_returnsNil_whenMissingRequiredFields() {
        XCTAssertNil(ToolCallEvent.parse(content: ["tool": "Read"]))
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd MatronShared && swift test --filter ToolCallEventTests
git add MatronShared/Sources/Events/ToolCallEvent.swift MatronShared/Tests/EventsTests/ToolCallEventTests.swift
git commit -m "feat: ToolCallEvent DTO + parser"
git push
```

---

### Task 3: AskUserEvent parsing

**Files:**
- Create: `MatronShared/Sources/Events/AskUserEvent.swift`
- Create: `MatronShared/Tests/EventsTests/AskUserEventTests.swift`

- [ ] **Step 1: Define DTO + parser**

```swift
import Foundation

public struct AskUserEvent: Equatable, Sendable {
    public enum InputKind: Equatable, Sendable {
        case text
        case choice(options: [Option], allowOther: Bool)
        case multiChoice(options: [Option], allowOther: Bool)
        case boolean
    }

    public struct Option: Equatable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    public let prompt: String
    public let kind: InputKind
    public let expiresAt: Date?

    public init(prompt: String, kind: InputKind, expiresAt: Date?) {
        self.prompt = prompt
        self.kind = kind
        self.expiresAt = expiresAt
    }

    public static func parse(content: [String: Any]) -> AskUserEvent? {
        guard let prompt = content["prompt"] as? String,
              let inputDict = content["input"] as? [String: Any],
              let kindRaw = inputDict["kind"] as? String else {
            return nil
        }
        let allowOther = inputDict["allow_other"] as? Bool ?? false
        let optionsArr = (inputDict["options"] as? [[String: Any]]) ?? []
        let options = optionsArr.compactMap { dict -> Option? in
            guard let id = dict["id"] as? String, let label = dict["label"] as? String else { return nil }
            return Option(id: id, label: label)
        }
        let kind: InputKind
        switch kindRaw {
        case "text":         kind = .text
        case "choice":       kind = .choice(options: options, allowOther: allowOther)
        case "multi_choice": kind = .multiChoice(options: options, allowOther: allowOther)
        case "boolean":      kind = .boolean
        default: return nil
        }
        let expiresAt = (content["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return AskUserEvent(prompt: prompt, kind: kind, expiresAt: expiresAt)
    }
}
```

- [ ] **Step 2: Tests**

```swift
import XCTest
@testable import MatronEvents

final class AskUserEventTests: XCTestCase {
    func test_parses_text() throws {
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "What's your name?",
            "input": ["kind": "text"]
        ]))
        XCTAssertEqual(evt.prompt, "What's your name?")
        XCTAssertEqual(evt.kind, .text)
    }

    func test_parses_choice() throws {
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "Which file?",
            "input": [
                "kind": "choice",
                "allow_other": true,
                "options": [
                    ["id": "a", "label": "main.rs"],
                    ["id": "b", "label": "lib.rs"]
                ]
            ]
        ]))
        if case .choice(let options, let allowOther) = evt.kind {
            XCTAssertEqual(options.count, 2)
            XCTAssertTrue(allowOther)
        } else {
            XCTFail("Expected .choice")
        }
    }

    func test_returnsNil_whenInputKindUnknown() {
        XCTAssertNil(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": ["kind": "alien"]
        ]))
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd MatronShared && swift test --filter AskUserEventTests
git add MatronShared/Sources/Events/AskUserEvent.swift MatronShared/Tests/EventsTests/AskUserEventTests.swift
git commit -m "feat: AskUserEvent DTO + parser (text/choice/multi/boolean)"
git push
```

---

### Task 4: SessionMetaEvent parsing

**Files:**
- Create: `MatronShared/Sources/Events/SessionMetaEvent.swift`
- Create: `MatronShared/Tests/EventsTests/SessionMetaEventTests.swift`

- [ ] **Step 1: DTO + parser**

```swift
import Foundation

public struct SessionMetaEvent: Equatable, Sendable {
    public let sessionID: String
    public let model: String?
    public let workdir: String?
    public let startedAt: Date

    public init(sessionID: String, model: String?, workdir: String?, startedAt: Date) {
        self.sessionID = sessionID; self.model = model; self.workdir = workdir; self.startedAt = startedAt
    }

    public static func parse(content: [String: Any]) -> SessionMetaEvent? {
        guard let sessionID = content["session_id"] as? String,
              let startedMs = content["started_at"] as? Double else {
            return nil
        }
        return SessionMetaEvent(
            sessionID: sessionID,
            model: content["model"] as? String,
            workdir: content["workdir"] as? String,
            startedAt: Date(timeIntervalSince1970: startedMs / 1000)
        )
    }
}
```

- [ ] **Step 2: Tests**

```swift
import XCTest
@testable import MatronEvents

final class SessionMetaEventTests: XCTestCase {
    func test_parses_full() throws {
        let evt = try XCTUnwrap(SessionMetaEvent.parse(content: [
            "session_id": "abc",
            "model": "claude-sonnet-4-7",
            "workdir": "~/yearbook-app",
            "started_at": 1745000000000.0,
        ]))
        XCTAssertEqual(evt.sessionID, "abc")
        XCTAssertEqual(evt.model, "claude-sonnet-4-7")
    }

    func test_parses_partial() throws {
        let evt = try XCTUnwrap(SessionMetaEvent.parse(content: [
            "session_id": "abc",
            "started_at": 1745000000000.0,
        ]))
        XCTAssertNil(evt.model)
        XCTAssertNil(evt.workdir)
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd MatronShared && swift test --filter SessionMetaEventTests
git add MatronShared/Sources/Events/SessionMetaEvent.swift MatronShared/Tests/EventsTests/SessionMetaEventTests.swift
git commit -m "feat: SessionMetaEvent DTO + parser"
git push
```

---

### Task 5: Extend TimelineItem with new cases

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift`
- Modify: `MatronShared/Tests/ChatTests/TimelineItemTests.swift`

- [ ] **Step 1: Extend the enum**

In `TimelineItem.Kind`:

```swift
public enum Kind: Equatable, Sendable {
    case text(body: String, formattedHTML: String?)
    case image(url: URL?, caption: String?, sizeBytes: Int64?)
    case file(url: URL?, filename: String, sizeBytes: Int64?)
    case stateChange(text: String)
    case toolCall(eventID: String, ToolCallEvent)
    case askUser(eventID: String, AskUserEvent)
    case unknown(eventType: String)
}
```

(`eventID` is the underlying Matrix event ID — needed to correlate replies and to send `m.replace` updates. `SessionMetaEvent` is a *state* event, not a timeline event — handled separately in Task 7.)

- [ ] **Step 2: Add tests**

```swift
func test_toolCallKind_equality() {
    let a = TimelineItem.Kind.toolCall(eventID: "$1", ToolCallEvent(
        tool: "Read", argsJSON: "{}", status: .running,
        resultText: nil, resultTruncated: false,
        startedAt: Date(timeIntervalSince1970: 0), endedAt: nil
    ))
    let b = TimelineItem.Kind.toolCall(eventID: "$1", ToolCallEvent(
        tool: "Read", argsJSON: "{}", status: .running,
        resultText: nil, resultTruncated: false,
        startedAt: Date(timeIntervalSince1970: 0), endedAt: nil
    ))
    XCTAssertEqual(a, b)
}
```

- [ ] **Step 3: Commit**

```bash
git add MatronShared/Sources/Chat/TimelineItem.swift MatronShared/Tests/ChatTests/TimelineItemTests.swift
git commit -m "feat: TimelineItem.Kind gains toolCall / askUser cases"
git push
```

---

### Task 6: Map custom events in TimelineServiceLive

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineServiceLive.swift`

- [ ] **Step 1: Inside `TimelineListener`, when an event's `eventType()` returns one of the matron event types, parse it and emit the appropriate `TimelineItem.Kind`**

Pseudocode (real code depends on SDK):

```swift
let raw = sdkEvent.eventType()  // String
let eventID = sdkEvent.eventId()
let contentJSON = sdkEvent.contentJSON()  // [String: Any]

switch raw {
case MatronEventType.toolCall:
    if let evt = ToolCallEvent.parse(content: contentJSON) {
        kind = .toolCall(eventID: eventID, evt)
    } else {
        kind = .unknown(eventType: raw)
    }
case MatronEventType.askUser:
    if let evt = AskUserEvent.parse(content: contentJSON) {
        kind = .askUser(eventID: eventID, evt)
    } else {
        kind = .unknown(eventType: raw)
    }
default:
    // existing m.text / m.image / etc. mapping
}
```

`m.replace` updates: the SDK delivers a *replacement* timeline item with the same `eventID`. The listener should overwrite the corresponding entry in its mutable buffer, preserving order, and emit a fresh snapshot.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: TimelineServiceLive maps chat.matron.tool_call and ask_user"
git push
```

---

### Task 7: SessionMeta — fetch state event in ChatService

**Files:**
- Modify: `MatronShared/Sources/Chat/ChatService.swift`
- Modify: `MatronShared/Sources/Chat/ChatServiceLive.swift`

- [ ] **Step 1: Add a method to read the state event**

```swift
public protocol ChatService: Sendable {
    // ... existing
    func sessionMeta(for roomID: String) async throws -> SessionMetaEvent?
}
```

- [ ] **Step 2: Implement on Live**

```swift
public func sessionMeta(for roomID: String) async throws -> SessionMetaEvent? {
    let client = try await provider.client(for: session)
    let room = try await client.getRoom(roomId: roomID)
    let raw = try await room.getStateEvent(eventType: MatronEventType.sessionMeta, stateKey: "")
    guard let dict = raw.contentJSON as? [String: Any] else { return nil }
    return SessionMetaEvent.parse(content: dict)
}
```

> **Implementer note:** API name `getStateEvent` may differ — check `Package.resolved`.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat: ChatService.sessionMeta reads chat.matron.session_meta state event"
git push
```

---

### Task 8: ToolCallCard component

**Files:**
- Create: `MatronShared/Sources/DesignSystem/ToolCallCard.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/ToolCallCardSnapshotTests.swift`

(Lives in DesignSystem so it's snapshottable in isolation.)

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MatronEvents

public struct ToolCallCard: View {
    let event: ToolCallEvent
    @State private var expanded: Bool

    /// `expanded` defaults to `false` for production tap-toggle behaviour.
    /// Callers (notably snapshot tests) may pass `true` to render the
    /// expanded state directly.
    public init(event: ToolCallEvent, expanded: Bool = false) {
        self.event = event
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    statusIcon
                    Text(event.tool).font(.system(.callout, design: .monospaced)).bold()
                    Text(argSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !event.argsJSON.isEmpty && event.argsJSON != "{}" {
                    Section(header: header("Arguments")) {
                        codeView(event.argsJSON)
                    }
                }
                if let result = event.resultText {
                    Section(header: header("Result\(event.resultTruncated ? " (truncated)" : "")")) {
                        codeView(result)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch event.status {
        case .running: ProgressView().scaleEffect(0.7).frame(width: 12, height: 12)
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .error:   Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
        }
    }

    private var argSummary: String {
        let trimmed = event.argsJSON.replacingOccurrences(of: "\n", with: " ")
        return trimmed.count > 80 ? String(trimmed.prefix(77)) + "…" : trimmed
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func codeView(_ s: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(s).font(.system(.caption, design: .monospaced))
                .padding(8)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Step 2: Snapshot tests for collapsed + expanded + each status**

```swift
#if canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

final class ToolCallCardSnapshotTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1745000000)

    func test_running_collapsed() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "ls -la" }"#,
            status: .running, resultText: nil, resultTruncated: false,
            startedAt: baseDate, endedAt: nil
        )
        assertSnapshot(of: ToolCallCard(event: evt).frame(width: 320), as: .image(layout: .sizeThatFits))
    }

    func test_ok_collapsed() {
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: #"{ "file_path": "/etc/hosts" }"#,
            status: .ok, resultText: "127.0.0.1 localhost\n::1 ip6-localhost",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.5)
        )
        assertSnapshot(of: ToolCallCard(event: evt).frame(width: 320), as: .image(layout: .sizeThatFits))
    }

    func test_error_collapsed() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "false" }"#,
            status: .error, resultText: "exit 1", resultTruncated: false,
            startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.1)
        )
        assertSnapshot(of: ToolCallCard(event: evt).frame(width: 320), as: .image(layout: .sizeThatFits))
    }

    func test_ok_expanded_showsArgsAndResult() {
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: #"{ "file_path": "/etc/hosts" }"#,
            status: .ok, resultText: "127.0.0.1 localhost\n::1 ip6-localhost",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.5)
        )
        assertSnapshot(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       as: .image(layout: .sizeThatFits))
    }

    func test_error_expanded_showsErrorBody() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "false" }"#,
            status: .error, resultText: "exit 1: command not found",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.1)
        )
        assertSnapshot(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       as: .image(layout: .sizeThatFits))
    }

    func test_ok_expanded_truncatedResult() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "ls -la /" }"#,
            status: .ok, resultText: String(repeating: "drwxr-xr-x  1 root root  4096 Jan  1 00:00 .\n", count: 30),
            resultTruncated: true, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.2)
        )
        assertSnapshot(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       as: .image(layout: .sizeThatFits))
    }
}
#endif
```

- [ ] **Step 3: Add MatronEvents to MatronDesignSystem dependencies**

In `MatronShared/Package.swift`:

```swift
.target(
    name: "MatronDesignSystem",
    dependencies: [
        "MatronEvents",
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
    ],
    path: "Sources/DesignSystem"
),
```

- [ ] **Step 4: Run + commit**

```bash
cd MatronShared && swift test --filter ToolCallCardSnapshotTests
git add MatronShared/Sources/DesignSystem/ToolCallCard.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/ToolCallCardSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ \
        MatronShared/Package.swift
git commit -m "feat: ToolCallCard component + snapshots"
git push
```

---

### Task 9: AskUserSheet component + ViewModel

**Files:**
- Create: `Matron/Features/Chat/Rendering/AskUserSheetViewModel.swift`
- Create: `Matron/Features/Chat/Rendering/AskUserSheet.swift`

(Sheet lives in app target, not DesignSystem, because it has app-level reply behavior.)

- [ ] **Step 1: Extend `TimelineService` with reply support (TDD)**

Per spec §4.2: "the user's response goes back as a normal `m.room.message` with `m.in_reply_to` referencing the prompt event so the bot can correlate." Add an optional reply event ID to `sendText` (or a dedicated `sendReply`).

Update the protocol in `MatronShared/Sources/Chat/TimelineService.swift`:

```swift
public protocol TimelineService: Sendable {
    // ... existing
    /// Send a text message. If `inReplyTo` is non-nil, the wire content includes
    /// `m.relates_to.m.in_reply_to.event_id` so the bot can correlate.
    func sendText(_ body: String, inReplyTo: String?) async throws
}

public extension TimelineService {
    func sendText(_ body: String) async throws { try await sendText(body, inReplyTo: nil) }
}
```

In `TimelineServiceLive`, when `inReplyTo` is set, build the content map with the relation block before handing to the SDK. Real shape (SDK API may differ — flag with implementer note):

```swift
public func sendText(_ body: String, inReplyTo: String?) async throws {
    var content: [String: Any] = ["msgtype": "m.text", "body": body]
    if let replyID = inReplyTo {
        content["m.relates_to"] = ["m.in_reply_to": ["event_id": replyID]]
    }
    // SDK API likely either:
    //   try await timeline.sendReply(eventId: replyID, content: ...)
    // or build a TimelineEventBuilder:
    //   let builder = TimelineEventBuilder(eventType: "m.room.message", content: content)
    //   try await timeline.send(builder)
    try await sdkTimeline.send(content: content)
}
```

> **Implementer note:** Matrix Rust SDK exposes `Timeline.sendReply(...)` taking an `EventOrTransactionId`. Confirm the exact symbol in `Package.resolved` (`matrix-rust-sdk`) and prefer it over hand-rolled `m.relates_to`, since the SDK adds the rich-reply fallback formatting automatically.

Write the test first (in `MatronShared/Tests/ChatTests/TimelineServiceLiveTests.swift` or a new `FakeTimelineServiceTests.swift`):

```swift
func test_sendText_withReply_recordsInReplyTo() async throws {
    let fake = FakeTimelineService()
    try await fake.sendText("yes", inReplyTo: "$prompt-evt-1")
    XCTAssertEqual(fake.lastSentBody, "yes")
    XCTAssertEqual(fake.lastSentInReplyTo, "$prompt-evt-1")
}
```

Update `FakeTimelineService` (test fake) to record the reply target:

```swift
final class FakeTimelineService: TimelineService {
    private(set) var lastSentBody: String?
    private(set) var lastSentInReplyTo: String?
    func sendText(_ body: String, inReplyTo: String?) async throws {
        lastSentBody = body
        lastSentInReplyTo = inReplyTo
    }
    // ... other protocol stubs
}
```

- [ ] **Step 2: ViewModel**

```swift
import Foundation
import MatronEvents
import MatronChat

@Observable
@MainActor
final class AskUserSheetViewModel {
    let event: AskUserEvent
    let promptEventID: String
    var textInput: String = ""
    var selectedChoiceIDs: Set<String> = []
    var booleanAnswer: Bool? = nil
    private(set) var isSending = false
    private(set) var error: String?

    private let timeline: TimelineService
    private let onClose: () -> Void

    init(event: AskUserEvent, promptEventID: String, timeline: TimelineService, onClose: @escaping () -> Void) {
        self.event = event
        self.promptEventID = promptEventID
        self.timeline = timeline
        self.onClose = onClose
    }

    /// True once `expiresAt` has passed. UI uses this to disable Send and auto-dismiss.
    var isExpired: Bool {
        guard let expiresAt = event.expiresAt else { return false }
        return Date.now >= expiresAt
    }

    func send() async {
        let body = constructReplyBody()
        guard !body.isEmpty, !isExpired else { return }
        isSending = true
        defer { isSending = false }
        do {
            // Per spec §4.2: include `m.in_reply_to` so the bot correlates the answer
            // back to the originating ask_user prompt event.
            try await timeline.sendText(body, inReplyTo: promptEventID)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func constructReplyBody() -> String {
        switch event.kind {
        case .text:
            return textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .choice(let options, _):
            guard let id = selectedChoiceIDs.first,
                  let opt = options.first(where: { $0.id == id }) else {
                return textInput.isEmpty ? "" : textInput
            }
            return opt.label
        case .multiChoice(let options, _):
            let chosen = options.filter { selectedChoiceIDs.contains($0.id) }.map(\.label)
            return chosen.joined(separator: ", ")
        case .boolean:
            return booleanAnswer == true ? "Yes" : (booleanAnswer == false ? "No" : "")
        }
    }
}
```

TDD: add a ViewModel test (`AskUserSheetViewModelTests`) that uses `FakeTimelineService` and asserts `send()` sends the reply with the right `inReplyTo`:

```swift
@MainActor
func test_send_passesPromptEventID_asInReplyTo() async {
    let fake = FakeTimelineService()
    let vm = AskUserSheetViewModel(
        event: AskUserEvent(prompt: "Which?", kind: .text, expiresAt: nil),
        promptEventID: "$prompt-1",
        timeline: fake,
        onClose: {}
    )
    vm.textInput = "src/main.rs"
    await vm.send()
    XCTAssertEqual(fake.lastSentBody, "src/main.rs")
    XCTAssertEqual(fake.lastSentInReplyTo, "$prompt-1")
}
```

- [ ] **Step 3: Sheet view**

```swift
import SwiftUI
import MatronEvents

struct AskUserSheet: View {
    @State var viewModel: AskUserSheetViewModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.event.prompt).font(.body)

                switch viewModel.event.kind {
                case .text:
                    TextField("Your answer…", text: $viewModel.textInput, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isExpired)

                case .choice(let options, let allowOther):
                    ForEach(options, id: \.id) { opt in
                        Button {
                            viewModel.selectedChoiceIDs = [opt.id]
                        } label: {
                            HStack {
                                Image(systemName: viewModel.selectedChoiceIDs.contains(opt.id) ? "circle.inset.filled" : "circle")
                                Text(opt.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isExpired)
                    }
                    if allowOther {
                        TextField("Other…", text: $viewModel.textInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isExpired)
                    }

                case .multiChoice(let options, let allowOther):
                    ForEach(options, id: \.id) { opt in
                        Button {
                            if viewModel.selectedChoiceIDs.contains(opt.id) {
                                viewModel.selectedChoiceIDs.remove(opt.id)
                            } else {
                                viewModel.selectedChoiceIDs.insert(opt.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: viewModel.selectedChoiceIDs.contains(opt.id) ? "checkmark.square.fill" : "square")
                                Text(opt.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isExpired)
                    }
                    if allowOther {
                        TextField("Other…", text: $viewModel.textInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isExpired)
                    }

                case .boolean:
                    HStack {
                        Button("Yes") { viewModel.booleanAnswer = true }
                            .buttonStyle(viewModel.booleanAnswer == true ? .borderedProminent : .bordered)
                            .disabled(viewModel.isExpired)
                        Button("No") { viewModel.booleanAnswer = false }
                            .buttonStyle(viewModel.booleanAnswer == false ? .borderedProminent : .bordered)
                            .disabled(viewModel.isExpired)
                        Spacer()
                    }
                }

                if viewModel.isExpired {
                    Label("This question has expired.", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if let error = viewModel.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Button {
                    Task { await viewModel.send() }
                } label: {
                    if viewModel.isSending { ProgressView() } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSending || viewModel.isExpired)
            }
            .padding()
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            // Auto-dismiss when `expires_at` is reached. The `.task(id:)` is keyed
            // on the prompt event ID so a new prompt restarts the timer.
            .task(id: viewModel.promptEventID) {
                await viewModel.awaitExpiry(onExpire: onClose)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
```

> **Note:** `promptEventID` is exposed on the ViewModel so SwiftUI can key the auto-dismiss task on it. Mark the property `let` (immutable, public to module).

- [ ] **Step 4: TDD — auto-dismiss on expiry**

The auto-dismiss timer lives in the `.task(id:)` modifier on `AskUserSheet`. We extract the sleep-and-fire body into a small helper on the ViewModel so it's deterministically testable:

```swift
extension AskUserSheetViewModel {
    /// Sleeps until `event.expiresAt`, then calls `onClose` (unless cancelled).
    /// Driven by the View's `.task(id: promptEventID)` modifier.
    func awaitExpiry(onExpire: @escaping () -> Void) async {
        guard let expiresAt = event.expiresAt else { return }
        let interval = max(0, expiresAt.timeIntervalSinceNow)
        try? await Task.sleep(for: .seconds(interval))
        if !Task.isCancelled { onExpire() }
    }
}
```

Update the `.task(id:)` block in the View to call `await viewModel.awaitExpiry(onExpire: onClose)`.

Test fixture with `expires_at` 100ms in the future:

```swift
@MainActor
func test_awaitExpiry_callsOnExpire_afterExpiresAt() async {
    var didExpire = false
    let expires = Date.now.addingTimeInterval(0.1)
    let vm = AskUserSheetViewModel(
        event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: expires),
        promptEventID: "$p-1",
        timeline: FakeTimelineService(),
        onClose: {}
    )
    await vm.awaitExpiry(onExpire: { didExpire = true })
    XCTAssertTrue(didExpire)
    XCTAssertTrue(vm.isExpired)
}

@MainActor
func test_awaitExpiry_isNoop_whenNoExpiresAt() async {
    var didExpire = false
    let vm = AskUserSheetViewModel(
        event: AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil),
        promptEventID: "$p-1",
        timeline: FakeTimelineService(),
        onClose: {}
    )
    await vm.awaitExpiry(onExpire: { didExpire = true })
    XCTAssertFalse(didExpire)
}
```

Also add a unit test for `isExpired`:

```swift
@MainActor
func test_isExpired_isTrue_afterExpiresAt() {
    let vm = AskUserSheetViewModel(
        event: AskUserEvent(prompt: "Q", kind: .text, expiresAt: Date.now.addingTimeInterval(-1)),
        promptEventID: "$p-1",
        timeline: FakeTimelineService(),
        onClose: {}
    )
    XCTAssertTrue(vm.isExpired)
}

@MainActor
func test_send_isNoop_whenExpired() async {
    let fake = FakeTimelineService()
    let vm = AskUserSheetViewModel(
        event: AskUserEvent(prompt: "Q", kind: .text, expiresAt: Date.now.addingTimeInterval(-1)),
        promptEventID: "$p-1",
        timeline: fake,
        onClose: {}
    )
    vm.textInput = "answer"
    await vm.send()
    XCTAssertNil(fake.lastSentBody)  // expired → not sent
}
```

- [ ] **Step 5: Commit**

```bash
git add Matron/Features/Chat/Rendering/AskUserSheet.swift \
        Matron/Features/Chat/Rendering/AskUserSheetViewModel.swift \
        Matron/Tests/ChatTests/AskUserSheetViewModelTests.swift \
        MatronShared/Sources/Chat/TimelineService.swift \
        MatronShared/Tests/ChatTests/FakeTimelineService.swift
git commit -m "feat: AskUserSheet half-sheet with reply correlation + expiry"
git push
```

---

### Task 9b: AskUserSheet snapshot tests

**Files:**
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/AskUserSheetSnapshotTests.swift`

The sheet view itself lives in the app target, but for snapshotting we extract the *content* of the sheet (the inner `VStack`) into a `View` that DesignSystem-tests can instantiate without app-only dependencies. Either:

1. Move the sheet body into a `public struct AskUserSheetBody: View` in `MatronShared/Sources/DesignSystem/AskUserSheetBody.swift`, parameterised on the same state values the ViewModel exposes (so it doesn't need `TimelineService`), or
2. Use a snapshot-only stub `TimelineService` and render the full sheet.

Prefer (1) — keeps DesignSystem decoupled from app types.

- [ ] **Step 1: Extract `AskUserSheetBody` into DesignSystem**

```swift
import SwiftUI
import MatronEvents

public struct AskUserSheetBody: View {
    public let event: AskUserEvent
    @Binding public var textInput: String
    @Binding public var selectedChoiceIDs: Set<String>
    @Binding public var booleanAnswer: Bool?
    public let isSending: Bool
    public let isExpired: Bool
    public let onSend: () -> Void

    public init(event: AskUserEvent, textInput: Binding<String>, selectedChoiceIDs: Binding<Set<String>>, booleanAnswer: Binding<Bool?>, isSending: Bool, isExpired: Bool, onSend: @escaping () -> Void) {
        self.event = event
        self._textInput = textInput
        self._selectedChoiceIDs = selectedChoiceIDs
        self._booleanAnswer = booleanAnswer
        self.isSending = isSending
        self.isExpired = isExpired
        self.onSend = onSend
    }
    // body: same VStack contents as in Task 9 Step 3
}
```

Update `AskUserSheet` (app target) to wrap `AskUserSheetBody` and connect it to the ViewModel.

- [ ] **Step 2: Snapshot tests for all four input kinds + expired variant**

```swift
#if canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

final class AskUserSheetSnapshotTests: XCTestCase {
    private func body(event: AskUserEvent, isExpired: Bool = false) -> some View {
        StatefulPreviewWrapper(initial: ("", Set<String>(), Bool?.none)) { state in
            AskUserSheetBody(
                event: event,
                textInput: Binding(get: { state.wrappedValue.0 }, set: { state.wrappedValue.0 = $0 }),
                selectedChoiceIDs: Binding(get: { state.wrappedValue.1 }, set: { state.wrappedValue.1 = $0 }),
                booleanAnswer: Binding(get: { state.wrappedValue.2 }, set: { state.wrappedValue.2 = $0 }),
                isSending: false,
                isExpired: isExpired,
                onSend: {}
            )
            .frame(width: 375, height: 480)
        }
    }

    private func snapshot(_ view: some View, named: String, file: StaticString = #file, line: UInt = #line) {
        for (suffix, traits) in [
            ("light",      UITraitCollection(userInterfaceStyle: .light)),
            ("dark",       UITraitCollection(userInterfaceStyle: .dark)),
            ("xxxl-light", UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: .light),
                UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
            ]))
        ] {
            assertSnapshot(of: view, as: .image(layout: .sizeThatFits, traits: traits),
                           named: "\(named).\(suffix)", file: file, line: line)
        }
    }

    func test_text() {
        snapshot(body(event: AskUserEvent(prompt: "What's the workdir?", kind: .text, expiresAt: nil)),
                 named: "text")
    }

    func test_choice() {
        let opts = [AskUserEvent.Option(id: "a", label: "src/main.rs"),
                    AskUserEvent.Option(id: "b", label: "src/lib.rs")]
        snapshot(body(event: AskUserEvent(prompt: "Which file?",
                                          kind: .choice(options: opts, allowOther: true),
                                          expiresAt: nil)),
                 named: "choice")
    }

    func test_multiChoice() {
        let opts = [AskUserEvent.Option(id: "a", label: "Build"),
                    AskUserEvent.Option(id: "b", label: "Test"),
                    AskUserEvent.Option(id: "c", label: "Lint")]
        snapshot(body(event: AskUserEvent(prompt: "Which steps to run?",
                                          kind: .multiChoice(options: opts, allowOther: false),
                                          expiresAt: nil)),
                 named: "multiChoice")
    }

    func test_boolean() {
        snapshot(body(event: AskUserEvent(prompt: "Proceed?", kind: .boolean, expiresAt: nil)),
                 named: "boolean")
    }

    func test_expired_disablesControls() {
        snapshot(body(event: AskUserEvent(prompt: "What's the workdir?", kind: .text,
                                          expiresAt: Date.now.addingTimeInterval(-1)),
                      isExpired: true),
                 named: "expired")
    }
}
#endif
```

> **Implementer note:** `StatefulPreviewWrapper` is a tiny SwiftUI helper that gives a snapshot test a mutable backing store for a `@Binding`. If one isn't already in the test helpers, add it to `MatronShared/Tests/DesignSystemSnapshotTests/Support/StatefulPreviewWrapper.swift`.

- [ ] **Step 3: Run + commit**

```bash
cd MatronShared && swift test --filter AskUserSheetSnapshotTests
git add MatronShared/Sources/DesignSystem/AskUserSheetBody.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/AskUserSheetSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/Support/StatefulPreviewWrapper.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/
git commit -m "test: AskUserSheetBody snapshots (text/choice/multi/boolean + expired)"
git push
```

---

### Task 10: SessionMetaHeader

**Files:**
- Create: `MatronShared/Sources/DesignSystem/SessionMetaHeader.swift`
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/SessionMetaHeaderSnapshotTests.swift`

(Lives in DesignSystem so it's snapshottable in isolation. Wrapped from the app target by a thin `Matron/Features/Chat/Rendering/SessionMetaHeader.swift` if app-level state is needed later.)

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MatronEvents

public struct SessionMetaHeader: View {
    let event: SessionMetaEvent
    let chatTitle: String
    @State private var collapsed: Bool

    public init(event: SessionMetaEvent, chatTitle: String, collapsed: Bool = false) {
        self.event = event
        self.chatTitle = chatTitle
        self._collapsed = State(initialValue: collapsed)
    }

    public var body: some View {
        Button { collapsed.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2)
                    Text(chatTitle).font(.caption).bold()
                    Spacer()
                    Text(event.startedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                if !collapsed {
                    HStack(spacing: 6) {
                        if let model = event.model {
                            Text(model).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let workdir = event.workdir {
                            Text("· \(workdir)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

The collapsed state shows only the chat title + chevron + time. The expanded state additionally shows model + workdir details.

- [ ] **Step 2: Snapshot tests for both states**

```swift
#if canImport(UIKit)
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

final class SessionMetaHeaderSnapshotTests: XCTestCase {
    private let evt = SessionMetaEvent(
        sessionID: "abc",
        model: "claude-sonnet-4-7",
        workdir: "~/yearbook-app",
        startedAt: Date(timeIntervalSince1970: 1745000000)
    )

    func test_expanded_showsModelAndWorkdir() {
        assertSnapshot(
            of: SessionMetaHeader(event: evt, chatTitle: "Refactor login flow", collapsed: false)
                .frame(width: 375),
            as: .image(layout: .sizeThatFits)
        )
    }

    func test_collapsed_showsOnlyTitle() {
        assertSnapshot(
            of: SessionMetaHeader(event: evt, chatTitle: "Refactor login flow", collapsed: true)
                .frame(width: 375),
            as: .image(layout: .sizeThatFits)
        )
    }
}
#endif
```

- [ ] **Step 3: Commit**

```bash
cd MatronShared && swift test --filter SessionMetaHeaderSnapshotTests
git add MatronShared/Sources/DesignSystem/SessionMetaHeader.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/SessionMetaHeaderSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/
git commit -m "feat: SessionMetaHeader collapsible chat header + snapshots"
git push
```

---

### Task 11: Wire all three into ChatView + TimelineItemView

**Files:**
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift`
- Modify: `Matron/Features/Chat/ChatView.swift`
- Modify: `Matron/Features/Chat/ChatViewModel.swift`

- [ ] **Step 1: Update `TimelineItemView` to render new cases**

```swift
case .toolCall(_, let event):
    HStack {
        ToolCallCard(event: event).frame(maxWidth: 320)
        Spacer(minLength: 0)
    }
    .padding(.horizontal)

case .askUser(_, _):
    EmptyView()  // sheet is presented from ChatView; the prompt itself shows as a brief inline marker.
```

The `askUser` event also appears in the timeline as a small pill ("❓ Pending question") so the user knows there's an unanswered prompt:

```swift
case .askUser(_, let event):
    HStack {
        Spacer()
        Label(event.prompt, systemImage: "questionmark.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
        Spacer()
    }
```

- [ ] **Step 2: ChatViewModel tracks already-answered prompts (idempotency)**

Push decryption can re-deliver an `ask_user` event after the user has already answered (e.g. NSE ran for a backgrounded notification, then the foregrounded app re-decrypts the same event). We must NOT re-pop the sheet.

In `ChatViewModel`:

```swift
@MainActor
final class ChatViewModel: ObservableObject {
    let roomID: String
    @Published private(set) var items: [TimelineItem] = []

    /// Event IDs of `ask_user` prompts the user has already answered in this room.
    /// Persisted across app launches under `matron.answeredPrompts.<roomID>`.
    private var answeredPromptIDs: Set<String>

    private var defaultsKey: String { "matron.answeredPrompts.\(roomID)" }

    init(roomID: String, /* ... */) {
        self.roomID = roomID
        let stored = UserDefaults.standard.stringArray(forKey: "matron.answeredPrompts.\(roomID)") ?? []
        self.answeredPromptIDs = Set(stored)
    }

    /// Filter timeline items to only `ask_user` prompts the user hasn't answered yet.
    /// Returns the most recent unanswered prompt, if any.
    func pendingAsk() -> (eventID: String, AskUserEvent)? {
        for item in items.reversed() {
            if case .askUser(let id, let evt) = item.kind, !answeredPromptIDs.contains(id) {
                return (id, evt)
            }
        }
        return nil
    }

    /// Called from `AskUserSheetViewModel.onClose` after a successful send.
    func markPromptAnswered(_ eventID: String) {
        answeredPromptIDs.insert(eventID)
        UserDefaults.standard.set(Array(answeredPromptIDs), forKey: defaultsKey)
    }
}
```

- [ ] **Step 3: TDD — re-delivered prompt does not re-present**

```swift
@MainActor
func test_pendingAsk_excludesAnsweredPrompts_evenAfterRedelivery() {
    let vm = ChatViewModel(roomID: "!room:server", /* ... */)
    let prompt = AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil)
    vm.items = [TimelineItem(id: "$1", kind: .askUser(eventID: "$1", prompt))]
    XCTAssertNotNil(vm.pendingAsk())

    vm.markPromptAnswered("$1")

    // Simulate push re-decrypt: same event arrives again.
    vm.items = [TimelineItem(id: "$1", kind: .askUser(eventID: "$1", prompt))]
    XCTAssertNil(vm.pendingAsk(), "answered prompt must not re-pop")
}

@MainActor
func test_answeredPromptIDs_persistAcrossLaunches() {
    let key = "matron.answeredPrompts.!room:server"
    UserDefaults.standard.removeObject(forKey: key)
    do {
        let vm = ChatViewModel(roomID: "!room:server", /* ... */)
        vm.markPromptAnswered("$persist-1")
    }
    // New ViewModel instance, same room → loads from UserDefaults.
    let vm2 = ChatViewModel(roomID: "!room:server", /* ... */)
    let prompt = AskUserEvent(prompt: "Q?", kind: .text, expiresAt: nil)
    vm2.items = [TimelineItem(id: "$persist-1", kind: .askUser(eventID: "$persist-1", prompt))]
    XCTAssertNil(vm2.pendingAsk())
    UserDefaults.standard.removeObject(forKey: key)
}
```

- [ ] **Step 4: ChatView presents the AskUserSheet for the most recent unanswered ask_user**

Add `@State private var pendingAsk: (eventID: String, AskUserEvent)?` and:

```swift
.onChange(of: viewModel.items) { _, _ in
    pendingAsk = viewModel.pendingAsk()
}
.sheet(item: Binding(
    get: { pendingAsk.map { AskUserSheetIdentifier(eventID: $0.eventID, event: $0.1) } },
    set: { _ in pendingAsk = nil }
)) { id in
    AskUserSheet(
        viewModel: AskUserSheetViewModel(
            event: id.event,
            promptEventID: id.eventID,
            timeline: timelineSvc,
            onClose: {
                viewModel.markPromptAnswered(id.eventID)
                pendingAsk = nil
            }
        ),
        onClose: {
            viewModel.markPromptAnswered(id.eventID)
            pendingAsk = nil
        }
    )
}
```

(Define `AskUserSheetIdentifier: Identifiable` locally — `id` = `eventID`.)

- [ ] **Step 5: ChatView shows SessionMetaHeader at the top**

Add `@State private var sessionMeta: SessionMetaEvent?`:

```swift
.task {
    sessionMeta = try? await chatService.sessionMeta(for: viewModel.roomID)
}
```

Render above the ScrollView when non-nil, passing the chat title:

```swift
if let meta = sessionMeta {
    SessionMetaHeader(event: meta, chatTitle: viewModel.chatTitle)
}
```

- [ ] **Step 6: Commit**

```bash
git commit -am "feat: ChatView renders ToolCallCard inline, AskUserSheet modal, SessionMetaHeader top"
git push
```

---

### Task 12: PushDecoder updates for new event types

**Files:**
- Modify: `MatronShared/Sources/Push/PushDecoder.swift`

- [ ] **Step 1: Recognise the matron event types**

In the body construction switch:

```swift
case MatronEventType.toolCall:
    body = "🔧 Tool call"
case MatronEventType.askUser:
    body = "❓ Question — needs your answer"
default:
    body = "New message"
```

(Use `event.kind` / `event.eventType()` per SDK API.)

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: PushDecoder shows tool-call / ask-user hints in notification body"
git push
```

---

### Task 13: Manual test additions

Append to `manual-tests.md`:

```markdown
## Phase 5 (Custom events)

### Tool call card

- [ ] Send a Claude prompt that triggers a `Read` tool. Expect a collapsed card with the tool name + arg summary.
- [ ] Tap to expand → arguments + result visible. Status icon matches outcome.
- [ ] Tool that fails → red ✗ icon; result shows the error string.
- [ ] Long-running tool → spinner icon; card updates in place when result arrives.

### Ask-user sheet

- [ ] Trigger Claude to call the ask-user MCP with a text prompt → half-sheet appears with text input.
- [ ] Trigger choice prompt → radio-button list. Pick one → Send → sheet closes, choice appears as a normal message in the chat.
- [ ] Trigger multi-choice → checkbox list. Pick multiple → sent as comma-separated.
- [ ] Trigger boolean → Yes/No buttons.
- [ ] Sheet auto-dismisses after `expires_at`.

### Session meta

- [ ] Start a new chat with Claude → SessionMetaHeader appears showing model + workdir.
- [ ] Tap to collapse → header shrinks but remains visible.

### Push notifications

- [ ] Receive a tool-call event while backgrounded → notification body shows "🔧 Tool call".
- [ ] Receive an ask-user event while backgrounded → notification body shows "❓ Question…".
```

Commit:

```bash
git add manual-tests.md
git commit -m "docs: phase 5 manual test additions"
git push
```

---

## Phase 5 acceptance

1. All 13 tasks committed and pushed.
2. CI green; snapshot tests for ToolCallCard pass.
3. Bridge-side spec (separate doc) drafted; bridge engineer can begin emitting events.
4. With bridge updated, manual checklist passes for tool-call cards, ask-user sheets, session-meta headers.
5. Without bridge updates, app continues to work — custom events fall back to `.unknown` rendering and chat is otherwise normal.

After acceptance, write Phase 6 plan (search).

---

## Plan self-review

- **§4.1 tool_call:** Tasks 2, 6, 8, 11. `ToolCallCard` takes an `expanded:` initializer parameter so snapshot tests can capture both states; production retains tap-toggle behaviour by defaulting to `false`.
- **§4.2 ask_user:** Tasks 3, 6, 9, 9b, 11. `m.in_reply_to` correlation is now actually wired: `TimelineService.sendText(_:inReplyTo:)` adds the `m.relates_to` block; `AskUserSheetViewModel.send()` passes `promptEventID`; `FakeTimelineService` records the reply target so tests can assert it (Task 9 Step 1).
- **§4.2 expiry:** `AskUserEvent.expiresAt` is honoured. The ViewModel exposes `isExpired`; the Sheet has a `.task(id: promptEventID)` that sleeps until `expiresAt` then calls `onClose`; controls are disabled when expired (Task 9 Steps 3–4).
- **§4.2 idempotency:** `ChatViewModel.answeredPromptIDs` is persisted to UserDefaults (`matron.answeredPrompts.<roomID>`) so a re-decrypted prompt does not re-pop the sheet (Task 11 Steps 2–3).
- **§4.3 session_meta:** Tasks 4, 7, 10, 11. `SessionMetaHeader` collapsed state shows only chat title + chevron; expanded shows model + workdir; both states have snapshot tests (Task 10).
- **§4.4 standard event types:** unchanged from Phase 2.
- **§4.5 sending side:** Composer remains text-only. `ask_user` replies use `sendText(_:inReplyTo:)` so the wire content includes `m.relates_to.m.in_reply_to.event_id`, matching spec §4.2.
- **§4.6 bridge changes implied:** Captured at the top of this plan; defer to a separate bridge-side spec.
- **§8.3 push body construction:** Updated in Task 12.
- **Snapshots:** ToolCallCard (collapsed × 3 statuses + expanded × 3 variants), AskUserSheetBody (4 input kinds × {light, dark, XXXL} + expired), SessionMetaHeader (collapsed + expanded).
- **TDD discipline:** Each behavioural change ships with a failing test first — sendText reply target, ViewModel `isExpired` + send no-op, sheet auto-dismiss, `pendingAsk` excludes answered prompts, `answeredPromptIDs` persistence.
- No placeholders. New types defined before first use. SDK API pseudocode flagged with implementer notes.
