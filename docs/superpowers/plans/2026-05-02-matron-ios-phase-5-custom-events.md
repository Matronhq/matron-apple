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
├── Matron/Features/Chat/Rendering/
│   ├── ToolCallCard.swift                 NEW
│   ├── AskUserSheet.swift                 NEW
│   ├── AskUserSheetViewModel.swift        NEW
│   └── SessionMetaHeader.swift            NEW
├── Matron/Features/Chat/
│   ├── TimelineItemView.swift             MODIFIED — switch over new cases
│   ├── ChatView.swift                     MODIFIED — present sheet, render header
│   └── ChatViewModel.swift                MODIFIED — replyToAskUser
├── MatronShared/Tests/EventsTests/
│   ├── ToolCallEventTests.swift           NEW
│   ├── AskUserEventTests.swift            NEW
│   └── SessionMetaEventTests.swift        NEW
└── MatronShared/Tests/DesignSystemSnapshotTests/
    ├── ToolCallCardSnapshotTests.swift    NEW
    └── AskUserSheetSnapshotTests.swift    NEW
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
            "workdir": "~/my-app",
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
    @State private var expanded = false

    public init(event: ToolCallEvent) {
        self.event = event
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

- [ ] **Step 1: ViewModel**

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

    func send() async {
        let body = constructReplyBody()
        guard !body.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            // Phase 5 minimal: send a normal text message. Future: include `m.in_reply_to: { event_id: promptEventID }`.
            // The bridge correlates by reading the most recent ask_user event.
            try await timeline.sendText(body)
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

- [ ] **Step 2: Sheet view**

```swift
import SwiftUI
import MatronEvents

struct AskUserSheet: View {
    @State var viewModel: AskUserSheetViewModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.event.prompt).font(.body)

                switch viewModel.event.kind {
                case .text:
                    TextField("Your answer…", text: $viewModel.textInput, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)

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
                    }
                    if allowOther {
                        TextField("Other…", text: $viewModel.textInput).textFieldStyle(.roundedBorder)
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
                    }
                    if allowOther {
                        TextField("Other…", text: $viewModel.textInput).textFieldStyle(.roundedBorder)
                    }

                case .boolean:
                    HStack {
                        Button("Yes") { viewModel.booleanAnswer = true }
                            .buttonStyle(viewModel.booleanAnswer == true ? .borderedProminent : .bordered)
                        Button("No") { viewModel.booleanAnswer = false }
                            .buttonStyle(viewModel.booleanAnswer == false ? .borderedProminent : .bordered)
                        Spacer()
                    }
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
                .disabled(viewModel.isSending)
            }
            .padding()
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Matron/Features/Chat/Rendering/AskUserSheet.swift \
        Matron/Features/Chat/Rendering/AskUserSheetViewModel.swift
git commit -m "feat: AskUserSheet half-sheet with text/choice/multi/boolean inputs"
git push
```

---

### Task 10: SessionMetaHeader

**Files:**
- Create: `Matron/Features/Chat/Rendering/SessionMetaHeader.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import MatronEvents

struct SessionMetaHeader: View {
    let event: SessionMetaEvent
    @State private var collapsed = false

    var body: some View {
        Button { collapsed.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2)
                if let model = event.model { Text(model).font(.caption).bold() }
                if let workdir = event.workdir { Text("· \(workdir)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text(event.startedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
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

- [ ] **Step 2: Commit**

```bash
git add Matron/Features/Chat/Rendering/SessionMetaHeader.swift
git commit -m "feat: SessionMetaHeader collapsible chat header"
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

- [ ] **Step 2: ChatView presents the AskUserSheet for the most recent unanswered ask_user**

Add `@State private var pendingAsk: (eventID: String, AskUserEvent)?` and:

```swift
.onChange(of: viewModel.items) { _, items in
    pendingAsk = items.reversed().compactMap { item -> (String, AskUserEvent)? in
        if case .askUser(let id, let evt) = item.kind { return (id, evt) }
        return nil
    }.first
}
.sheet(item: Binding(
    get: { pendingAsk.map { AskUserSheetIdentifier(eventID: $0.eventID, event: $0.1) } },
    set: { _ in pendingAsk = nil }
)) { id in
    AskUserSheet(viewModel: AskUserSheetViewModel(
        event: id.event,
        promptEventID: id.eventID,
        timeline: timelineSvc,
        onClose: { pendingAsk = nil }
    ))
}
```

(Define `AskUserSheetIdentifier: Identifiable` locally — `id` = `eventID`.)

- [ ] **Step 3: ChatView shows SessionMetaHeader at the top**

Add `@State private var sessionMeta: SessionMetaEvent?`:

```swift
.task {
    sessionMeta = try? await chatService.sessionMeta(for: viewModel.roomID)
}
```

Render above the ScrollView when non-nil.

- [ ] **Step 4: Commit**

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

- **§4.1 tool_call:** Tasks 2, 6, 8, 11.
- **§4.2 ask_user:** Tasks 3, 6, 9, 11.
- **§4.3 session_meta:** Tasks 4, 7, 10, 11.
- **§4.4 standard event types:** unchanged from Phase 2.
- **§4.5 sending side:** Composer remains text-only; `ask_user` reply is sent as plain text matching the user's selection (per spec note: bot correlates by `m.in_reply_to`; we'll add `m.in_reply_to` once the bridge expects it — captured in Task 9 step 1 note).
- **§4.6 bridge changes implied:** Captured at the top of this plan; defer to a separate bridge-side spec.
- **§8.3 push body construction:** Updated in Task 12.
- No placeholders. New types defined before first use. SDK API pseudocode flagged with implementer notes.
