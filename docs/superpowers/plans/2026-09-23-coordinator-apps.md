# Coordinator redesign — Apple apps (iOS + Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Coordinator setting onto the journal and turn the Coordinator from a tab / nav entry into a panel beside everything on the Mac and a sheet over everything on the iPhone, with an Unassigned missions section, `coordinator` timeline markers and Opus-1M new coordinator chats.

**Architecture:** A new `CoordinatorSync` actor (MatronJournal) owns the setting: it reads `GET /coordinator`, the `hello_ok` field and live `coordinator` events, writes `PUT /coordinator`, and mirrors the answer into the existing per-user `UserDefaults` key, so every view that already reads that key (`@AppStorage` on iOS, `UserDefaults.didChangeNotification` on Mac) stays live without change. `ChatListViewModel` hides the Coordinator's conversation from the Conversations list and publishes it separately. On the Mac a `MacCoordinatorPanelContainer` inside the split view's detail column (outside `detailContent`, so it survives every nav change and Back/Forward) hosts a second `MacChatView`; on the iPhone the tab becomes a sheet driven by `AppShellNavigation.isCoordinatorPresented`.

**Tech Stack:** Swift 5.10 language mode, SwiftUI (iOS 17+/macOS 14+), AppKit title-bar accessory, GRDB-backed `JournalStore`, XCTest, swift-snapshot-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-23-coordinator-redesign-design.md` (apps = §3). Cross-repo contract: `/tmp/coord-plan/contract.md` (binding names; journal and bridge are planned separately and assumed deployed).

## Global Constraints

- Journal API (contract, verbatim): `GET /coordinator` → `{"convo_id": string|null}`; `PUT /coordinator` body `{"convo_id": string|null}` (user token) → `{"convo_id": ...}`; a convo not owned by the user → 404.
- The ws hello frame gains `coordinator_convo_id` (string|null). Apps read it from the `hello_ok` control frame; a frame without the key means "journal predates the field", never "cleared".
- Timeline event type `"coordinator"`, payload `{"role":"assigned"}` / `{"role":"released"}`; marker copy exactly "This chat is now the Coordinator" / "This chat is no longer the Coordinator".
- "New coordinator chat…" sends the existing `start` rpc with `"model": "opus[1m]"`.
- First launch after upgrade (spec §3a): journal has none and this device has one cached → `PUT` it (first device wins); journal has one → adopt it, even if this device cached a different id.
- Unassigned mission = `state == .open && conversationCount == 0`, listed first in its own "Unassigned" section on both apps, labelled "from Coordinator" when `originConvoID` is the Coordinator.
- Mac panel: width min 320 pt, ideal 380 pt; toggled by a sidebar-toolbar button, **Go ▸ Coordinator** and **⌘0**; open/closed and width persist per window (`@SceneStorage`); overlays the detail's trailing edge when the detail would drop under 420 pt.
- Mac nav column is Missions, Decisions, Conversations; ⌘1 / ⌘2 / ⌘3 select them in that order; `MacPlace` has no Coordinator case; the panel is not part of Back/Forward.
- iPhone: no Coordinator tab; a floating Coordinator button (with the unread dot) only on the three tab ROOT screens; inside a chat the entries are a *Coordinator* row in the ⓘ `SessionStatusSheet` (handed off in `onDismiss`) and a button at the top of the tasks page; every entry presents one sheet with detents `.large` and `.medium`; no entry inside the Coordinator's own sheet.
- The Coordinator's conversation is left out of the Conversations list on both apps; search hits, notification taps and links into it open the panel / sheet.
- Android is out of scope.
- Run `xcodegen generate` after adding, renaming or deleting any file or folder under `Matron/`, `MatronMac/`, `MatronTests/`, `MatronMacTests/` (snapshot PNGs are project members too).
- Mac tests ONLY as `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/<Class>` — the override is a real environment variable before `xcodebuild`, never a trailing `KEY=value` argument (the test host once wiped the live journal store). Drop only the `SKIP_SNAPSHOT` variable when recording snapshots.
- Shared package tests: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter <Target>.<Class>`.
- iOS tests: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/<Class> CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"` — assert the "Executed N tests, with 0 failures" line; a grep/tail alone masks build failures. This Mac has iPhone 17 simulators, no iPhone 16.
- Nothing under the Mac chat header accessory may add toolbar items (they are clipped into the `»` overflow). The panel toggle lives in the SIDEBAR column's `.toolbar` with `.automatic` placement.
- The sidebar toolbar must never be empty (an empty one drops the NSToolbar: title bar 32 pt, 52 pt header cropped). After this plan it always carries Back/Forward, the Coordinator toggle and New Chat.
- Keep `.toolbar(removing: .sidebarToggle)` BEFORE `.navigationSplitViewColumnWidth(...)` (macOS 26 masks the width otherwise).
- No `NavigationStack` inside the Mac Coordinator panel: inside a `NavigationSplitView` detail it pushes onto the column's own stack (#2608).
- CI's Xcode 16.4 type-checker gives up on long modifier chains: every new modifier group on `MacChatListView` / `AppShellView` goes in its own `private func with…(_ content: some View) -> some View` helper or computed property.
- Commits: `git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "<subject>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Never `git config user.*` (the worktree shares `.git/config`).

## Review Focus

- **The Coordinator cleared on another device while this one still caches it** — this device must adopt "none", not re-`PUT` its stale cache on the next launch (the first-launch migration runs once per user). Pinned in Task 4 (`test_migratedDevice_adoptsAClearFromElsewhere_withoutPushing`).
- **A session the Coordinator just started auto-opens while the iPhone sheet is up** — the new conversation lands in Conversations underneath; the sheet stays where the user is. Pinned in Task 9 (`test_autoOpen_keepsTheCoordinatorSheetUp`).
- **Two chats on screen on the Mac (detail + panel) and ⌘K / ⌘R from the menu bar** — only the main chat reacts; the panel's palette must not pop open behind the user's back. Pinned in Task 14 (`test_panelChat_ignoresMenuBusCommands_mainChatStillAnswers`).
- **Toggling or resizing the Mac panel** — the main transcript keeps its identity (no remount, no lost scroll position, no multi-second rebuild of a large room). Pinned in Task 13 (`test_togglingThePanel_neverRemountsTheDetail`).
- **The Coordinator's own chat inside the iPhone sheet** — its ⓘ sheet and tasks page must not offer "open the Coordinator" (which would stack a second copy). Pinned in Task 10 (`test_insideTheCoordinatorSheet_entriesAreHidden`).

---

## File map

| File | Responsibility |
|---|---|
| `MatronShared/Sources/Events/CoordinatorMarkerEvent.swift` (new) | Parse the `coordinator` payload; marker copy |
| `MatronShared/Sources/Journal/WireModels.swift` | `JournalEventType.coordinator`; `HelloCoordinator`; `hello_ok` decode |
| `MatronShared/Sources/Journal/JournalConnection.swift` | Carry the hello's coordinator field |
| `MatronShared/Sources/Journal/JournalSyncEngine.swift` | `coordinatorUpdates()` stream |
| `MatronShared/Sources/Journal/JournalAPI+Coordinator.swift` (new) | `CoordinatorProviding`, GET/PUT |
| `MatronShared/Sources/Journal/CoordinatorSync.swift` (new) | Reconcile journal ⇄ cache, live events, user writes |
| `MatronShared/Sources/Models/CoordinatorSetting.swift` | Cache + migrated flag + pure reconcile rule + model constant |
| `MatronShared/Sources/Chat/TimelineItem.swift`, `JournalTimelineMapper.swift` | `.coordinatorMarker` kind |
| `MatronShared/Sources/DesignSystem/CoordinatorNotice.swift` (new) | One-line marker view |
| `MatronShared/Sources/ViewModels/ChatListViewModel.swift` | Hide the Coordinator, publish `hiddenSummary` |
| `MatronShared/Sources/ViewModels/NewChatViewModel.swift` | `pinnedModel` |
| `MatronShared/Sources/ViewModels/MissionsListViewModel.swift` | `unassigned`, attribution |
| `MatronShared/Sources/DesignSystem/Missions/MissionsListView.swift`, `MissionRowView.swift` | Unassigned section, attribution line |
| `Matron/App/AppShellNavigation.swift`, `AppShellView.swift`, `AppDependencies.swift` | iOS shell: no tab, sheet, button, wiring |
| `Matron/Features/Coordinator/CoordinatorSheet.swift` (renamed from `CoordinatorTabView.swift`) | The sheet's stack |
| `Matron/Features/Coordinator/CoordinatorEntry.swift` (new) | `OpenCoordinatorAction`, env key, floating + tasks-page buttons, `InsideCoordinatorSheet` |
| `Matron/Features/Chat/ChatView.swift`, `SessionStatusSheet.swift` | In-chat entries |
| `MatronMac/Features/Nav/*`, `MatronMac/App/Commands.swift` | Nav without Coordinator; ⌘1/2/3; Go ▸ Coordinator ⌘0 |
| `MatronMac/Features/Chat/MacChatHeaderAccessory.swift` | Header trailing inset (replaces the Coordinator header nav cluster) |
| `MatronMac/Features/Coordinator/MacCoordinatorPanelLayout.swift`, `MacCoordinatorPanelContainer.swift`, `MacCoordinatorPanel.swift`, `MacCoordinatorToolbarToggle.swift` (new) | Panel geometry, container, content, toolbar toggle |
| `MatronMac/Features/ChatList/MacChatListView.swift`, `MatronMac/Features/Chat/MacChatView.swift` | Mac wiring |

---

### Task 1: `coordinator` timeline marker (shared + both renderers)

**Files:**
- Create: `MatronShared/Sources/Events/CoordinatorMarkerEvent.swift`
- Create: `MatronShared/Sources/DesignSystem/CoordinatorNotice.swift`
- Modify: `MatronShared/Sources/Journal/WireModels.swift:28-35` (add the type constant after `milestone`)
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift:101-104` (new `Kind` case after `.missionMarker`)
- Modify: `MatronShared/Sources/Chat/JournalTimelineMapper.swift:52-55` (new case after `JournalEventType.mission`)
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift:398-403`
- Modify: `MatronMac/Features/Chat/MacTimelineItemView.swift:362-367`
- Test: `MatronShared/Tests/EventsTests/CoordinatorMarkerEventTests.swift` (new), `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`, `MatronTests/TimelineItemViewTests.swift`, `MatronMacTests/MacTimelineItemViewTests.swift`

**Interfaces:**
- Produces: `public struct CoordinatorMarkerEvent { enum Role: String { case assigned, released }; let role: Role; static func parse(payload: [String: Any]) -> CoordinatorMarkerEvent?; var text: String }` (MatronEvents); `JournalEventType.coordinator == "coordinator"` (MatronJournal); `TimelineItem.Kind.coordinatorMarker(eventID: String, CoordinatorMarkerEvent)`; `public struct CoordinatorNotice: View { init(marker:) }` (MatronDesignSystem).

- [ ] **Step 1: Write the failing tests**

`MatronShared/Tests/EventsTests/CoordinatorMarkerEventTests.swift`:

```swift
import XCTest
@testable import MatronEvents

final class CoordinatorMarkerEventTests: XCTestCase {
    func testParsesBothRoles() {
        XCTAssertEqual(CoordinatorMarkerEvent.parse(payload: ["role": "assigned"])?.role, .assigned)
        XCTAssertEqual(CoordinatorMarkerEvent.parse(payload: ["role": "released"])?.role, .released)
    }

    func testRejectsAnUnknownOrMissingRole() {
        XCTAssertNil(CoordinatorMarkerEvent.parse(payload: ["role": "promoted"]))
        XCTAssertNil(CoordinatorMarkerEvent.parse(payload: [:]))
    }

    /// Contract copy, verbatim.
    func testMarkerText() {
        XCTAssertEqual(CoordinatorMarkerEvent(role: .assigned).text, "This chat is now the Coordinator")
        XCTAssertEqual(CoordinatorMarkerEvent(role: .released).text, "This chat is no longer the Coordinator")
    }
}
```

Append to `JournalTimelineMapperTests` (it already has the `event(_:type:sender:ts:payload:)` and `map(_:)` helpers):

```swift
    func testCoordinatorEventMapsToAOneLineMarker() throws {
        let item = try XCTUnwrap(map(event(9, type: "coordinator", sender: "user:dan", payload: ["role": "assigned"])))
        guard case .coordinatorMarker(let eventID, let marker) = item.kind else { return XCTFail("got \(item.kind)") }
        XCTAssertEqual(eventID, "9")
        XCTAssertEqual(marker.role, .assigned)
    }

    func testMalformedCoordinatorEventIsSkipped() {
        XCTAssertNil(map(event(10, type: "coordinator", payload: ["role": "promoted"])),
                     "a half-understood marker is skipped rather than drawn as .unknown")
    }
```

Append to `MatronTests/TimelineItemViewTests.swift` (class body) and, with `MacTimelineItemView` in place of `TimelineItemView`, to `MatronMacTests/MacTimelineItemViewTests.swift`:

```swift
    func testCoordinatorMarkerRenders() {
        let item = TimelineItem(id: "77", sender: "user:dan", timestamp: Date(),
                                kind: .coordinatorMarker(eventID: "77", CoordinatorMarkerEvent(role: .assigned)),
                                isOwn: true)
        XCTAssertTrue(TimelineItemView.shouldRender(item))
    }
```

- [ ] **Step 2: Run the shared tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "EventsTests.CoordinatorMarkerEventTests|ChatTests.JournalTimelineMapperTests"`
Expected: build FAIL — `cannot find 'CoordinatorMarkerEvent' in scope`.

- [ ] **Step 3: Implement**

`MatronShared/Sources/Events/CoordinatorMarkerEvent.swift`:

```swift
import Foundation

/// The journal's `coordinator` event (Coordinator redesign spec §1a, §3e):
/// appended into the conversation that gained the role (`assigned`) and the
/// one that lost it (`released`). The timeline draws it as a one-line
/// marker; `CoordinatorSync` also reads it to keep the cached setting live.
public struct CoordinatorMarkerEvent: Equatable, Sendable {
    public enum Role: String, Sendable { case assigned, released }

    public let role: Role

    public init(role: Role) { self.role = role }

    public static func parse(payload: [String: Any]) -> CoordinatorMarkerEvent? {
        guard let role = (payload["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        return CoordinatorMarkerEvent(role: role)
    }

    /// The marker's one line — contract copy.
    public var text: String {
        switch role {
        case .assigned: return "This chat is now the Coordinator"
        case .released: return "This chat is no longer the Coordinator"
        }
    }
}
```

In `WireModels.swift`, after `public static let milestone = "milestone"`:

```swift
    /// Coordinator role change (Coordinator redesign contract). Like
    /// `mission`, deliberately NOT in `messageTypes`: a marker, not a message.
    public static let coordinator = "coordinator"
```

In `TimelineItem.swift`, after the `.missionMarker` case:

```swift
        /// The conversation gained or lost the Coordinator role — a one-line
        /// marker (Coordinator redesign §3e). `eventID` is the journal seq.
        case coordinatorMarker(eventID: String, CoordinatorMarkerEvent)
```

In `JournalTimelineMapper.timelineItem`, after the `JournalEventType.mission` case:

```swift
        case JournalEventType.coordinator:
            // Unparseable payload: skipped, like a malformed mission marker.
            guard let marker = CoordinatorMarkerEvent.parse(payload: payload) else { return nil }
            kind = .coordinatorMarker(eventID: String(event.seq), marker)
```

`MatronShared/Sources/DesignSystem/CoordinatorNotice.swift`:

```swift
import SwiftUI
import MatronEvents

/// The `coordinator` marker's inline row (Coordinator redesign §3e): one
/// quiet line, styled like `MissionNotice` but not a button — there is
/// nowhere to navigate to.
public struct CoordinatorNotice: View {
    let marker: CoordinatorMarkerEvent

    public init(marker: CoordinatorMarkerEvent) { self.marker = marker }

    public var body: some View {
        Label(marker.text, systemImage: "person.crop.circle.badge.checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}
```

In BOTH `TimelineItemView.swift` and `MacTimelineItemView.swift`, directly after the `.missionMarker` case of the kind switch:

```swift
        case .coordinatorMarker(_, let marker):
            HStack {
                CoordinatorNotice(marker: marker)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "EventsTests.CoordinatorMarkerEventTests|ChatTests.JournalTimelineMapperTests"`
Expected: PASS.

Run: `xcodegen generate`, then the iOS test command with `-only-testing:MatronTests/TimelineItemViewTests` → "Executed N tests, with 0 failures"; then the Mac test command with `-only-testing:MatronMacTests/MacTimelineItemViewTests` → same.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Events/CoordinatorMarkerEvent.swift MatronShared/Sources/DesignSystem/CoordinatorNotice.swift \
  MatronShared/Sources/Journal/WireModels.swift MatronShared/Sources/Chat/TimelineItem.swift \
  MatronShared/Sources/Chat/JournalTimelineMapper.swift Matron/Features/Chat/Rendering/TimelineItemView.swift \
  MatronMac/Features/Chat/MacTimelineItemView.swift MatronShared/Tests/EventsTests/CoordinatorMarkerEventTests.swift \
  MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift MatronTests/TimelineItemViewTests.swift \
  MatronMacTests/MacTimelineItemViewTests.swift Matron.xcodeproj
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "timeline: render coordinator events as a one-line marker" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(`Matron.xcodeproj` is only staged if it is tracked; skip it if `git status` does not list it.)

---

### Task 2: Hello field and engine `coordinatorUpdates()` stream

**Files:**
- Modify: `MatronShared/Sources/Journal/WireModels.swift:211` (`helloOK` case) and `:415-416` (decode)
- Modify: `MatronShared/Sources/Journal/JournalConnection.swift:1-35`
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift` — continuations near `:120`, streams near `:748`, hello at `:926-928`, `didApply` / `didApplyBatch` at `:1340-1353`
- Test: `MatronShared/Tests/JournalTests/WireModelsTests.swift:20-23`, `JournalConnectionTests.swift`, `JournalSyncEngineTests.swift`

**Interfaces:**
- Consumes: `JournalEventType.coordinator`, `CoordinatorMarkerEvent` (Task 1).
- Produces: `public enum HelloCoordinator: Equatable, Sendable { case absent; case known(String?) }`; `ServerFrame.helloOK(headSeq: Int64, coordinator: HelloCoordinator)`; `JournalConnection.coordinatorHello: HelloCoordinator`; `public enum CoordinatorUpdate: Equatable, Sendable { case snapshot(String?); case assigned(convoID: String); case released(convoID: String) }`; `JournalSyncEngine.coordinatorUpdates() -> AsyncStream<CoordinatorUpdate>` (nonisolated; replays the latest `.snapshot` to a late subscriber).

- [ ] **Step 1: Write the failing tests**

Replace the `hello_ok` block at the top of `WireModelsTests.testDecodeControlAndEphemeralFrames` with:

```swift
        guard case let .helloOK(head, coordinator)? = ServerFrame.decode(#"{"kind":"control","op":"hello_ok","seq":42}"#) else {
            return XCTFail("expected hello_ok")
        }
        XCTAssertEqual(head, 42)
        XCTAssertEqual(coordinator, .absent, "a journal predating the field says nothing, not 'none'")
```

Add to `WireModelsTests`:

```swift
    func testHelloCarriesTheCoordinator() {
        XCTAssertEqual(ServerFrame.decode(#"{"kind":"control","op":"hello_ok","seq":1,"coordinator_convo_id":"c9"}"#),
                       .helloOK(headSeq: 1, coordinator: .known("c9")))
        XCTAssertEqual(ServerFrame.decode(#"{"kind":"control","op":"hello_ok","seq":1,"coordinator_convo_id":null}"#),
                       .helloOK(headSeq: 1, coordinator: .known(nil)), "explicit null is an authoritative 'none'")
    }
```

Add to `JournalConnectionTests`:

```swift
    func testEstablishKeepsTheHelloCoordinator() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":7,"coordinator_convo_id":"c9"}"#)
        let (connection, _) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "tok", cursor: 0)
        XCTAssertEqual(connection.coordinatorHello, .known("c9"))
        connection.close()
    }
```

Add to `JournalSyncEngineTests` (uses the file's `journalLine`, `helloOK`, `makeEngine`, `seededStore`):

```swift
    private func coordinatorLine(_ seq: Int64, convo: String, role: String) -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"user:dan","type":"coordinator","payload":{"role":"\#(role)"}}"#
    }

    /// The hello lands before any subscriber exists (it is part of the
    /// handshake), so the engine replays it; live events follow in order.
    func testCoordinatorUpdatesReplayTheHelloThenFollowEvents() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":1,"coordinator_convo_id":"c1"}"#)
        socket.serve(journalLine(1))
        let engine = makeEngine(store: try seededStore(), connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()

        var iterator = engine.coordinatorUpdates().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .snapshot("c1"))
        socket.serve(coordinatorLine(2, convo: "c1", role: "released"))
        socket.serve(coordinatorLine(3, convo: "c2", role: "assigned"))
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(second, .released(convoID: "c1"))
        XCTAssertEqual(third, .assigned(convoID: "c2"))
        await engine.endSync()
    }

    func testCoordinatorUpdatesSkipAHelloWithoutTheField() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(1))
        socket.serve(journalLine(1))
        let engine = makeEngine(store: try seededStore(), connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()

        var iterator = engine.coordinatorUpdates().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(50))
        socket.serve(coordinatorLine(2, convo: "c1", role: "assigned"))
        let first = await iterator.next()
        XCTAssertEqual(first, .assigned(convoID: "c1"), "no snapshot is invented for an old journal")
        await engine.endSync()
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "JournalTests.WireModelsTests|JournalTests.JournalConnectionTests|JournalTests.JournalSyncEngineTests"`
Expected: build FAIL — `enum case 'helloOK' has one associated value`, `cannot find 'HelloCoordinator'`.

- [ ] **Step 3: Implement**

`WireModels.swift`, above `public enum ServerFrame`:

```swift
/// `coordinator_convo_id` on `hello_ok` (Coordinator redesign contract).
/// `.absent` is a journal predating the field — "unknown", never "cleared";
/// `.known(nil)` is an authoritative "no Coordinator".
public enum HelloCoordinator: Equatable, Sendable {
    case absent
    case known(String?)
}
```

Replace `case helloOK(headSeq: Int64)` with `case helloOK(headSeq: Int64, coordinator: HelloCoordinator)`, and the decode:

```swift
            case "hello_ok":
                // Key presence, not value: `as? String` folds absent and null.
                let coordinator: HelloCoordinator = obj.keys.contains("coordinator_convo_id")
                    ? .known(obj["coordinator_convo_id"] as? String) : .absent
                return .helloOK(headSeq: (obj["seq"] as? NSNumber)?.int64Value ?? 0, coordinator: coordinator)
```

`JournalConnection.swift`: add the stored property and an explicit init, and bind the new value in `establish`:

```swift
public struct JournalConnection: Sendable {
    private let socket: any WebSocketConnection
    /// The Coordinator the journal reported in this connection's `hello_ok`.
    public let coordinatorHello: HelloCoordinator

    private init(socket: any WebSocketConnection, coordinatorHello: HelloCoordinator) {
        self.socket = socket
        self.coordinatorHello = coordinatorHello
    }
```

```swift
                case .helloOK(let headSeq, let coordinator):
                    return (JournalConnection(socket: socket, coordinatorHello: coordinator), headSeq)
```

`JournalSyncEngine.swift` — above `public actor JournalSyncEngine` (file scope):

```swift
/// What `coordinatorUpdates()` carries (Coordinator redesign §3a).
/// `.snapshot` is the journal's whole answer (a `hello_ok` field);
/// `.assigned` / `.released` are live `coordinator` events, keyed by the
/// conversation they were appended to.
public enum CoordinatorUpdate: Equatable, Sendable {
    case snapshot(String?)
    case assigned(convoID: String)
    case released(convoID: String)
}
```

Next to `missionMarkerContinuations`:

```swift
    private var coordinatorContinuations: [UUID: AsyncStream<CoordinatorUpdate>.Continuation] = [:]
    /// The latest known whole answer, replayed to a late subscriber: the
    /// hello arrives during the handshake, before any subscriber can exist.
    private var lastCoordinatorSnapshot: CoordinatorUpdate?
```

After `publishMissionMarker(_:)`:

```swift
    /// The Coordinator setting's live feed — `CoordinatorSync` subscribes.
    /// Mirrors `missionMarkers()`, plus a replay of the latest snapshot.
    public nonisolated func coordinatorUpdates() -> AsyncStream<CoordinatorUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerCoordinatorUpdates(id: id, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.unregisterCoordinatorUpdates(id: id) } }
        }
    }
    private func registerCoordinatorUpdates(id: UUID, continuation: AsyncStream<CoordinatorUpdate>.Continuation) {
        coordinatorContinuations[id] = continuation
        if let lastCoordinatorSnapshot { continuation.yield(lastCoordinatorSnapshot) }
    }
    private func unregisterCoordinatorUpdates(id: UUID) { coordinatorContinuations.removeValue(forKey: id) }

    private func publishCoordinatorHello(_ hello: HelloCoordinator) {
        guard case .known(let convoID) = hello else { return }
        let update = CoordinatorUpdate.snapshot(convoID)
        lastCoordinatorSnapshot = update
        for c in coordinatorContinuations.values { c.yield(update) }
    }

    private func publishCoordinatorEvent(_ event: JournalEvent) {
        guard event.type == JournalEventType.coordinator,
              let marker = CoordinatorMarkerEvent.parse(payload: event.payload) else { return }
        let update: CoordinatorUpdate
        switch marker.role {
        case .assigned:
            update = .assigned(convoID: event.convoID)
            lastCoordinatorSnapshot = .snapshot(event.convoID)
        case .released:
            update = .released(convoID: event.convoID)
            if lastCoordinatorSnapshot == .snapshot(event.convoID) { lastCoordinatorSnapshot = .snapshot(nil) }
        }
        for c in coordinatorContinuations.values { c.yield(update) }
    }
```

In the connect loop, directly after `liveConnection = connection` (≈ line 928):

```swift
                publishCoordinatorHello(connection.coordinatorHello)
```

In `didApply(_:)` add `publishCoordinatorEvent(event)` after `publishMissionMarker(event)`; in `didApplyBatch(_:)` extend the loop body to `publishItemMarker(event); publishMissionMarker(event); publishCoordinatorEvent(event); confirmMediaSendIfNeeded(event)`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "JournalTests.WireModelsTests|JournalTests.JournalConnectionTests|JournalTests.JournalSyncEngineTests"`
Expected: PASS (all pre-existing engine/connection tests still pass: `case .helloOK, .unknownControl` at `:1194` binds nothing and compiles unchanged).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/WireModels.swift MatronShared/Sources/Journal/JournalConnection.swift \
  MatronShared/Sources/Journal/JournalSyncEngine.swift MatronShared/Tests/JournalTests/WireModelsTests.swift \
  MatronShared/Tests/JournalTests/JournalConnectionTests.swift MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "journal: read the hello's coordinator and publish coordinator updates" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `/coordinator` API and the migration rule

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Coordinator.swift`
- Modify: `MatronShared/Sources/Models/CoordinatorSetting.swift` (whole file below)
- Test: `MatronShared/Tests/JournalTests/CoordinatorAPITests.swift` (new), `MatronShared/Tests/ViewModelTests/CoordinatorSettingTests.swift`

**Interfaces:**
- Produces: `public protocol CoordinatorProviding: Sendable { func coordinator() async throws -> String?; func setCoordinator(_ convoID: String?) async throws -> String? }` with `JournalAPI` conforming; `CoordinatorSetting.migrated: Bool` (nonmutating set), `CoordinatorSetting.migratedKey(for:)`, `CoordinatorSetting.newChatModel == "opus[1m]"`, `enum CoordinatorSetting.Reconcile: Equatable { case adopt(String?); case push(String) }`, `static func reconcile(journal: String?, cached: String?, migrated: Bool) -> Reconcile`; `CoordinatorSetting: @unchecked Sendable`.

- [ ] **Step 1: Write the failing tests**

`MatronShared/Tests/JournalTests/CoordinatorAPITests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class CoordinatorAPITests: XCTestCase {
    private func makeStubbedAPI(status: Int, body: [String: Any]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    func testGetDecodesTheConvoOrNone() async throws {
        let set = try await makeStubbedAPI(status: 200, body: ["convo_id": "c9"]).coordinator()
        XCTAssertEqual(set, "c9")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/coordinator") == true)
        let none = try await makeStubbedAPI(status: 200, body: ["convo_id": NSNull()]).coordinator()
        XCTAssertNil(none)
    }

    func testPutSendsTheIdOrAnExplicitNull() async throws {
        let stored = try await makeStubbedAPI(status: 200, body: ["convo_id": "c9"]).setCoordinator("c9")
        XCTAssertEqual(stored, "c9")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "PUT")
        let sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any]
        XCTAssertEqual(sent?["convo_id"] as? String, "c9")

        _ = try await makeStubbedAPI(status: 200, body: ["convo_id": NSNull()]).setCoordinator(nil)
        let cleared = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any]
        XCTAssertTrue(cleared?["convo_id"] is NSNull, "clearing sends convo_id: null, not an empty body")
    }

    func testPutOfAConvoNotOwnedIsNotFound() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).setCoordinator("c-else")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }
}
```

Append to `CoordinatorSettingTests`:

```swift
    func testMigratedFlagIsPerUserAndDefaultsFalse() {
        let a = CoordinatorSetting(userID: "@a:s", defaults: defaults)
        XCTAssertFalse(a.migrated)
        a.migrated = true
        XCTAssertTrue(CoordinatorSetting(userID: "@a:s", defaults: defaults).migrated)
        XCTAssertFalse(CoordinatorSetting(userID: "@b:s", defaults: defaults).migrated)
        XCTAssertEqual(CoordinatorSetting.migratedKey(for: "@a:s"), "coordinator.migrated.@a:s")
    }

    /// Spec §3a: local only / journal only / both different / both empty /
    /// already migrated.
    func testReconcileRules() {
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: "cL", migrated: false), .push("cL"),
                       "journal has none, this device has one: first device wins")
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: "cJ", cached: nil, migrated: false), .adopt("cJ"))
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: "cJ", cached: "cL", migrated: false), .adopt("cJ"),
                       "a later device with a different cached id adopts the journal's")
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: nil, migrated: false), .adopt(nil))
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: "cL", migrated: true), .adopt(nil),
                       "after the first reconcile a journal 'none' is a clear from elsewhere, not a gap to fill")
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: "", migrated: false), .adopt(nil))
    }

    func testNewChatModelIsOpus1M() {
        XCTAssertEqual(CoordinatorSetting.newChatModel, "opus[1m]")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "JournalTests.CoordinatorAPITests|ViewModelTests.CoordinatorSettingTests"`
Expected: build FAIL — `value of type 'JournalAPI' has no member 'coordinator'`.

- [ ] **Step 3: Implement**

`MatronShared/Sources/Journal/JournalAPI+Coordinator.swift`:

```swift
import Foundation

/// `GET` / `PUT /coordinator` (Coordinator redesign contract): the user's one
/// Coordinator conversation, `nil` for none. A protocol so `CoordinatorSync`
/// tests fake it.
public protocol CoordinatorProviding: Sendable {
    func coordinator() async throws -> String?
    /// Returns what the journal stored. Throws `.notFound` for a conversation
    /// the user does not own.
    func setCoordinator(_ convoID: String?) async throws -> String?
}

extension JournalAPI: CoordinatorProviding {
    public func coordinator() async throws -> String? {
        Self.decodeCoordinator(try await request(path: "/coordinator"))
    }

    public func setCoordinator(_ convoID: String?) async throws -> String? {
        let body: [String: Any] = ["convo_id": convoID.map { $0 as Any } ?? NSNull()]
        return Self.decodeCoordinator(try await request(path: "/coordinator", method: "PUT", body: body))
    }

    static func decodeCoordinator(_ obj: [String: Any]) -> String? {
        guard let id = obj["convo_id"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
```

`MatronShared/Sources/Models/CoordinatorSetting.swift` (whole file):

```swift
import Foundation

/// This device's copy of the user's Coordinator conversation. Since the
/// Coordinator redesign (spec §3a) the journal holds the setting and
/// `CoordinatorSync` mirrors it here; views keep reading this key
/// (`@AppStorage` through `defaultsKey(for:)`, or
/// `UserDefaults.didChangeNotification`) so they stay live. Views never
/// write it directly — user picks go through `CoordinatorSync.set(_:)`.
public struct CoordinatorSetting {
    /// "New coordinator chat…" starts the session on this model (spec §2e).
    public static let newChatModel = "opus[1m]"

    public static func defaultsKey(for userID: String) -> String {
        "coordinator.convoID.\(userID)"
    }

    /// Set once this device has reconciled with a journal that knows the
    /// setting, so the first-launch "push my cached id" rule runs once.
    public static func migratedKey(for userID: String) -> String {
        "coordinator.migrated.\(userID)"
    }

    /// What a reconcile does with the journal's answer.
    public enum Reconcile: Equatable, Sendable {
        /// Take this value into the cache (nil clears it).
        case adopt(String?)
        /// `PUT` this cached id: the journal has none and this device is the
        /// first to upgrade.
        case push(String)
    }

    /// The spec §3a rule. The journal's value always wins; a cached id is
    /// pushed only before this device's first successful reconcile.
    public static func reconcile(journal: String?, cached: String?, migrated: Bool) -> Reconcile {
        if let journal { return .adopt(journal) }
        if !migrated, let cached, !cached.isEmpty { return .push(cached) }
        return .adopt(nil)
    }

    private let defaults: UserDefaults
    private let key: String
    private let migratedDefaultsKey: String

    public init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = Self.defaultsKey(for: userID)
        self.migratedDefaultsKey = Self.migratedKey(for: userID)
    }

    public var convoID: String? {
        get { defaults.string(forKey: key) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    public var migrated: Bool {
        get { defaults.bool(forKey: migratedDefaultsKey) }
        nonmutating set { defaults.set(newValue, forKey: migratedDefaultsKey) }
    }

    public static func clear(for userID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(for: userID))
        defaults.removeObject(forKey: migratedKey(for: userID))
    }
}

/// `UserDefaults` is thread-safe; the struct holds nothing else.
extension CoordinatorSetting: @unchecked Sendable {}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "JournalTests.CoordinatorAPITests|ViewModelTests.CoordinatorSettingTests"`
Expected: PASS (the pre-existing `CoordinatorSettingTests` cases are unchanged by the rewrite).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI+Coordinator.swift MatronShared/Sources/Models/CoordinatorSetting.swift \
  MatronShared/Tests/JournalTests/CoordinatorAPITests.swift MatronShared/Tests/ViewModelTests/CoordinatorSettingTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "coordinator: GET/PUT /coordinator and the first-launch reconcile rule" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `CoordinatorSync` actor

**Files:**
- Create: `MatronShared/Sources/Journal/CoordinatorSync.swift`
- Test: `MatronShared/Tests/JournalTests/CoordinatorSyncTests.swift` (new)

**Interfaces:**
- Consumes: `CoordinatorProviding` (Task 3), `CoordinatorSetting` + `reconcile` (Task 3), `CoordinatorUpdate` (Task 2).
- Produces: `public actor CoordinatorSync { init(api: any CoordinatorProviding, setting: CoordinatorSetting, updates: @escaping @Sendable () -> AsyncStream<CoordinatorUpdate>); func start() async; func stop(); func refresh() async; func set(_ convoID: String?) async throws; private(set) var isSupported: Bool? }`.

- [ ] **Step 1: Write the failing tests**

`MatronShared/Tests/JournalTests/CoordinatorSyncTests.swift`:

```swift
import XCTest
import MatronModels
@testable import MatronJournal

private final class FakeCoordinatorAPI: CoordinatorProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _journal: String?
    private var _getError: Error?
    private var _putError: Error?
    private var _puts: [String?] = []

    init(journal: String? = nil) { _journal = journal }

    var journal: String? { get { lock.withLock { _journal } } set { lock.withLock { _journal = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var putError: Error? { get { lock.withLock { _putError } } set { lock.withLock { _putError = newValue } } }
    var puts: [String?] { lock.withLock { _puts } }

    func coordinator() async throws -> String? {
        if let getError { throw getError }
        return journal
    }

    func setCoordinator(_ convoID: String?) async throws -> String? {
        lock.withLock { _puts.append(convoID) }
        if let putError { throw putError }
        journal = convoID
        return convoID
    }
}

final class CoordinatorSyncTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.coordinatorSync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func make(_ api: FakeCoordinatorAPI, cached: String? = nil, migrated: Bool = false)
        -> (CoordinatorSync, CoordinatorSetting, AsyncStream<CoordinatorUpdate>.Continuation) {
        let setting = CoordinatorSetting(userID: "@a:s", defaults: defaults)
        setting.convoID = cached
        setting.migrated = migrated
        let (stream, continuation) = AsyncStream<CoordinatorUpdate>.makeStream()
        return (CoordinatorSync(api: api, setting: setting, updates: { stream }), setting, continuation)
    }

    private func eventually(_ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func test_localOnly_isPushedToTheJournal() async {
        let api = FakeCoordinatorAPI(journal: nil)
        let (sync, setting, _) = make(api, cached: "cL")
        await sync.start()
        XCTAssertEqual(api.puts, ["cL"])
        XCTAssertEqual(setting.convoID, "cL")
        XCTAssertTrue(setting.migrated)
    }

    func test_journalOnly_isAdopted_withoutAPut() async {
        let api = FakeCoordinatorAPI(journal: "cJ")
        let (sync, setting, _) = make(api)
        await sync.start()
        XCTAssertEqual(api.puts, [])
        XCTAssertEqual(setting.convoID, "cJ")
    }

    func test_bothDifferent_theJournalWins() async {
        let api = FakeCoordinatorAPI(journal: "cJ")
        let (sync, setting, _) = make(api, cached: "cL")
        await sync.start()
        XCTAssertEqual(api.puts, [])
        XCTAssertEqual(setting.convoID, "cJ")
    }

    /// Review focus: a clear on another device must stick here too.
    func test_migratedDevice_adoptsAClearFromElsewhere_withoutPushing() async {
        let api = FakeCoordinatorAPI(journal: nil)
        let (sync, setting, _) = make(api, cached: "cOld", migrated: true)
        await sync.start()
        XCTAssertEqual(api.puts, [], "the stale cache must not resurrect the Coordinator")
        XCTAssertNil(setting.convoID)
    }

    func test_pushOfAConvoTheJournalRejects_clearsTheCache() async {
        let api = FakeCoordinatorAPI(journal: nil)
        api.putError = JournalAPIError.notFound
        let (sync, setting, _) = make(api, cached: "cGone")
        await sync.start()
        XCTAssertNil(setting.convoID)
        XCTAssertTrue(setting.migrated)
    }

    func test_offlineStart_keepsTheCache_andTheHelloRetries() async {
        let api = FakeCoordinatorAPI(journal: nil)
        api.getError = JournalAPIError.transport("offline")
        let (sync, setting, hello) = make(api, cached: "cL")
        await sync.start()
        XCTAssertEqual(setting.convoID, "cL")
        XCTAssertFalse(setting.migrated)
        hello.yield(.snapshot(nil))
        await eventually { api.puts == ["cL"] }
        XCTAssertEqual(api.puts, ["cL"])
        XCTAssertTrue(setting.migrated)
    }

    func test_oldJournal_isUnsupported_andUserPicksStayLocal() async throws {
        let api = FakeCoordinatorAPI()
        api.getError = JournalAPIError.notFound
        let (sync, setting, _) = make(api, cached: "cL")
        await sync.start()
        let supported = await sync.isSupported
        XCTAssertEqual(supported, false)
        try await sync.set("cNew")
        XCTAssertEqual(api.puts, [], "no PUT to a journal without the route")
        XCTAssertEqual(setting.convoID, "cNew")
    }

    func test_liveEvents_followTheRole() async {
        let api = FakeCoordinatorAPI(journal: "c1")
        let (sync, setting, events) = make(api)
        await sync.start()
        events.yield(.released(convoID: "c-other"))
        events.yield(.assigned(convoID: "c2"))
        await eventually { setting.convoID == "c2" }
        XCTAssertEqual(setting.convoID, "c2", "a release of some other chat changes nothing")
        events.yield(.released(convoID: "c2"))
        await eventually { setting.convoID == nil }
        XCTAssertNil(setting.convoID)
    }

    func test_set_writesTheJournalThenTheCache() async throws {
        let api = FakeCoordinatorAPI(journal: "c1")
        let (sync, setting, _) = make(api)
        await sync.start()
        try await sync.set("c2")
        XCTAssertEqual(api.puts, ["c2"])
        XCTAssertEqual(setting.convoID, "c2")
        try await sync.set(nil)
        XCTAssertNil(setting.convoID)
    }

    func test_set_failure_leavesTheCacheAlone() async {
        let api = FakeCoordinatorAPI(journal: "c1")
        let (sync, setting, _) = make(api)
        await sync.start()
        api.putError = JournalAPIError.notFound
        do { try await sync.set("c-else"); XCTFail("expected a throw") } catch {}
        XCTAssertEqual(setting.convoID, "c1")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter JournalTests.CoordinatorSyncTests`
Expected: build FAIL — `cannot find 'CoordinatorSync' in scope`.

- [ ] **Step 3: Implement**

`MatronShared/Sources/Journal/CoordinatorSync.swift`:

```swift
import Foundation
import os
import MatronModels

/// Keeps this device's cached Coordinator (`CoordinatorSetting`) in step
/// with the journal's (Coordinator redesign §3a). Reads: `GET /coordinator`
/// on start, the `hello_ok` field on every connect (`.snapshot`), and live
/// `coordinator` events. Writes: `set(_:)`, the user's own pick or clear.
/// The cache is what every view reads, so nothing else writes it.
public actor CoordinatorSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "coordinator-sync")

    private let api: any CoordinatorProviding
    private let setting: CoordinatorSetting
    private let updates: @Sendable () -> AsyncStream<CoordinatorUpdate>
    private var updatesTask: Task<Void, Never>?

    /// `nil` until the journal answers; `false` once `GET /coordinator`
    /// 404s — a journal predating the route, where the cache is the only
    /// store and `set(_:)` writes it alone.
    public private(set) var isSupported: Bool?

    public init(api: any CoordinatorProviding, setting: CoordinatorSetting,
                updates: @escaping @Sendable () -> AsyncStream<CoordinatorUpdate>) {
        self.api = api
        self.setting = setting
        self.updates = updates
    }

    public func start() async {
        guard updatesTask == nil else { return }
        let stream = updates()
        updatesTask = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { return }
                await self?.apply(update)
            }
        }
        await refresh()
    }

    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// `GET /coordinator` and reconcile. A transport failure leaves the cache
    /// as it is; the next connect's hello reconciles instead.
    public func refresh() async {
        do {
            let journal = try await api.coordinator()
            isSupported = true
            await reconcile(journal: journal)
        } catch JournalAPIError.notFound {
            isSupported = false
        } catch {
            Self.logger.warning("GET /coordinator failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user's pick or clear (Settings, choosers, the panel's empty
    /// state). The journal first; the cache follows its answer, so a failed
    /// `PUT` changes nothing locally and the error reaches the caller.
    public func set(_ convoID: String?) async throws {
        if isSupported == false {
            setting.convoID = convoID
            return
        }
        let stored = try await api.setCoordinator(convoID)
        setting.convoID = stored
        setting.migrated = true
    }

    private func apply(_ update: CoordinatorUpdate) async {
        switch update {
        case .snapshot(let journal):
            isSupported = true
            await reconcile(journal: journal)
        case .assigned(let convoID):
            setting.convoID = convoID
            setting.migrated = true
        case .released(let convoID):
            if setting.convoID == convoID { setting.convoID = nil }
            setting.migrated = true
        }
    }

    private func reconcile(journal: String?) async {
        switch CoordinatorSetting.reconcile(journal: journal, cached: setting.convoID, migrated: setting.migrated) {
        case .adopt(let id):
            setting.convoID = id
            setting.migrated = true
        case .push(let cached):
            do {
                setting.convoID = try await api.setCoordinator(cached)
                setting.migrated = true
            } catch JournalAPIError.notFound {
                // The cached chat is gone or not this user's: nothing to carry over.
                setting.convoID = nil
                setting.migrated = true
            } catch {
                // Stays unmigrated: the next hello tries again.
                Self.logger.warning("coordinator migration PUT failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter JournalTests.CoordinatorSyncTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/CoordinatorSync.swift MatronShared/Tests/JournalTests/CoordinatorSyncTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "coordinator: CoordinatorSync keeps the cached setting in step with the journal" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Wire `CoordinatorSync` into both apps; every pick goes through the journal

**Files:**
- Modify: `Matron/App/AppDependencies.swift` — `JournalCore` (`:110-146`), `core(for:)` (`:206-259`), accessors near `missionsSync(for:)` (`:376`), sign-out teardown (`:615-619`)
- Modify: `MatronMac/App/AppDependencies.swift` — `JournalCore` (`:50-85`), `core(for:)` (`:150-180`), accessors, sign-out (`:523-527`)
- Modify: `Matron/Features/Coordinator/CoordinatorSettingRow.swift`, `Matron/Features/Coordinator/CoordinatorTabView.swift:152-158`
- Modify: `MatronMac/Features/Coordinator/MacCoordinatorSettingRow.swift`, `MatronMac/Features/ChatList/MacChatListView.swift:504-518`
- Test: `MatronTests/AppDependenciesTests.swift`, `MatronMacTests/MacAppDependenciesTests.swift`

**Interfaces:**
- Consumes: `CoordinatorSync`, `CoordinatorSetting`, `JournalSyncEngine.coordinatorUpdates()`.
- Produces (both apps' `AppDependencies`): `func coordinatorSync(for session: UserSession) -> CoordinatorSync`; `@MainActor func setCoordinator(_ convoID: String?, for session: UserSession) async -> String?` (nil on success, else the message to show).

- [ ] **Step 1: Write the failing tests**

Append to `MatronTests/AppDependenciesTests.swift` and (identically) to `MatronMacTests/MacAppDependenciesTests.swift`:

```swift
    /// One `CoordinatorSync` per session — the chooser, the rows and the
    /// shell must all write through the same actor.
    func test_coordinatorSync_isCached_perSession() {
        deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        XCTAssertTrue(deps.coordinatorSync(for: session) === deps.coordinatorSync(for: session))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: the iOS test command with `-only-testing:MatronTests/AppDependenciesTests`.
Expected: build FAIL — `value of type 'AppDependencies' has no member 'coordinatorSync'`.

- [ ] **Step 3: Implement**

In BOTH `AppDependencies.swift` files:

`JournalCore` gains (after `missionsStartTask`):

```swift
        /// Keeps the cached Coordinator in step with the journal (Coordinator
        /// redesign §3a). Started right after construction, stopped on sign-out.
        let coordinator: CoordinatorSync
        var coordinatorStartTask: Task<Void, Never>?
```

and its `init` gains a `coordinator: CoordinatorSync` parameter after `missions:` (assign `self.coordinator = coordinator`).

In `core(for:)`, after `let missions = …`:

```swift
        let coordinator = CoordinatorSync(api: api, setting: CoordinatorSetting(userID: session.userID),
                                          updates: { engine.coordinatorUpdates() })
```

pass `coordinator: coordinator` to `JournalCore(...)`, and after `core.missionsStartTask = …`:

```swift
        core.coordinatorStartTask = Task { await coordinator.start() }
```

In `signOut()`, right after `await core.missions.stop()`:

```swift
                await core.coordinatorStartTask?.value
                await core.coordinator.stop()
```

Next to `missionsSync(for:)`:

```swift
    /// The session's `CoordinatorSync` — every Coordinator pick or clear
    /// goes through it (Coordinator redesign §3a).
    func coordinatorSync(for session: UserSession) -> CoordinatorSync {
        core(for: session).coordinator
    }

    /// The user's own Coordinator pick or clear, from any surface: the
    /// journal first, the cache follows. `nil` on success, otherwise the
    /// message to show.
    @MainActor func setCoordinator(_ convoID: String?, for session: UserSession) async -> String? {
        do {
            try await coordinatorSync(for: session).set(convoID)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
```

`Matron/Features/Coordinator/CoordinatorSettingRow.swift` — the rows keep READING `@AppStorage`; writes go through the journal. Add state + helper and replace the two writes:

```swift
    @State private var saveError: String?

    private func save(_ id: String?) {
        Task { @MainActor in saveError = await deps.setCoordinator(id, for: session) }
    }
```

`Button("Clear", role: .destructive) { convoID = nil }` → `Button("Clear", role: .destructive) { save(nil) }`; the chooser closure `convoID = id; showingChooser = false` → `showingChooser = false; save(id)`. Add after the `.sheet`:

```swift
        .alert("Coordinator", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
```

Make the identical change in `MatronMac/Features/Coordinator/MacCoordinatorSettingRow.swift`.

`CoordinatorTabView.swift` (renamed in Task 10, so the alert carries over): add `@State private var saveError: String?`, change the chooser closure to

```swift
            CoordinatorChooserSheet(deps: deps, session: session) { id in
                showingChooser = false
                Task { @MainActor in saveError = await deps.setCoordinator(id, for: session) }
            }
```

and add the same `.alert("Coordinator", …)` after that `.sheet`.

`MacChatListView.swift` — add `@State private var coordinatorError: String?` next to `showingCoordinatorChooser`, and replace the chooser sheet in `withNavigationListeners` (`:510-518`) with:

```swift
            .sheet(isPresented: $showingCoordinatorChooser) {
                if let deps, let session {
                    MacCoordinatorChooserSheet(deps: deps, session: session) { id in
                        showingCoordinatorChooser = false
                        // The cache (and so `coordinatorConvoID`, via the
                        // UserDefaults observer above) follows the journal.
                        Task { @MainActor in coordinatorError = await deps.setCoordinator(id, for: session) }
                    }
                }
            }
            .alert("Coordinator", isPresented: Binding(get: { coordinatorError != nil },
                                                       set: { if !$0 { coordinatorError = nil } })) {
                Button("OK") { coordinatorError = nil }
            } message: {
                Text(coordinatorError ?? "")
            }
```

- [ ] **Step 4: Run to verify they pass**

Run: the iOS test command with `-only-testing:MatronTests/AppDependenciesTests` → "Executed N tests, with 0 failures". Then the Mac test command with `-only-testing:MatronMacTests/MacAppDependenciesTests` → same.

- [ ] **Step 5: Commit**

```bash
git add Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift \
  Matron/Features/Coordinator/CoordinatorSettingRow.swift Matron/Features/Coordinator/CoordinatorTabView.swift \
  MatronMac/Features/Coordinator/MacCoordinatorSettingRow.swift MatronMac/Features/ChatList/MacChatListView.swift \
  MatronTests/AppDependenciesTests.swift MatronMacTests/MacAppDependenciesTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "coordinator: store the setting on the journal from both apps" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: "New coordinator chat…" starts on `opus[1m]`

**Files:**
- Modify: `MatronShared/Sources/ViewModels/NewChatViewModel.swift` — init (`:264-274`), `modelPickerVisible` (`:189-191`), `start(workdir:)` model line (`:517`)
- Modify: `Matron/Features/ChatList/NewChatSheet.swift:27-35`, `MatronMac/Features/ChatList/MacNewChatSheet.swift:67-76`
- Modify: `Matron/Features/Coordinator/CoordinatorChooserSheet.swift:73-78`, `MatronMac/Features/Coordinator/MacCoordinatorChooserSheet.swift:72-78`
- Test: `MatronShared/Tests/ViewModelTests/NewChatViewModelTests.swift`

**Interfaces:**
- Consumes: `CoordinatorSetting.newChatModel` (Task 3).
- Produces: `NewChatViewModel.init(api:capacityCache:pinnedModel: String? = nil, now:wakeSleep:)`, `public let pinnedModel: String?`; `NewChatSheet(deps:session:pinnedModel: String? = nil, onCreated:)`; `MacNewChatSheet(deps:session:windowSize:pinnedModel: String? = nil, onCreated:)`.

Why a pin rather than `selectedModel`: `adoptModelOptions` drops any selection the box does not list, and the contract sends `opus[1m]` whether or not a box lists it.

- [ ] **Step 1: Write the failing tests**

Append to `NewChatViewModelTests` (uses the file's `agent(_:connected:)` and `foldersReply(_:)` helpers):

```swift
    // MARK: Pinned model (Coordinator redesign §2e)

    func test_pinnedModel_isSent_evenWhenTheBoxDoesNotListIt() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[],"model_options":[{"value":"sonnet","label":"Sonnet"}]}
        """#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(), pinnedModel: "opus[1m]")
        await vm.load()
        XCTAssertFalse(vm.modelPickerVisible, "a pinned model hides the picker")
        await vm.start(workdir: "~/dev/app")
        XCTAssertEqual(fake.requests.last?.params["model"] as? String, "opus[1m]")
    }

    func test_noPin_keepsTheOldBehaviour() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        XCTAssertNil(vm.pinnedModel)
        await vm.load()
        await vm.start(workdir: "~/dev/app")
        XCTAssertNil(fake.requests.last?.params["model"])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ViewModelTests.NewChatViewModelTests`
Expected: build FAIL — `extra argument 'pinnedModel' in call`.

- [ ] **Step 3: Implement**

`NewChatViewModel.swift`, next to `selectedModel`:

```swift
    /// A model this sheet always starts on, bypassing the picker — set by
    /// "New coordinator chat…" (`CoordinatorSetting.newChatModel`). Sent even
    /// when the box's `model_options` do not list it: the bridge accepts
    /// `opus[1m]` regardless (contract).
    public let pinnedModel: String?
```

Init — add the parameter after `capacityCache` and assign it:

```swift
    public init(api: any AgentRPCProviding,
                capacityCache: any BoxCapacityCaching,
                pinnedModel: String? = nil,
                now: @escaping @Sendable () -> Date = Date.init,
                wakeSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.api = api
        self.capacityCache = capacityCache
        self.pinnedModel = pinnedModel
        self.now = now
        self.wakeSleep = wakeSleep
    }
```

`modelPickerVisible`:

```swift
    public var modelPickerVisible: Bool {
        pinnedModel == nil && !modelOptions.isEmpty && selectedAgent == AgentOption.claude
    }
```

In `start(workdir:)` replace the model line with:

```swift
        if selectedAgent == AgentOption.claude, let model = pinnedModel ?? selectedModel { params["model"] = model }
```

`NewChatSheet.init` and `MacNewChatSheet.init` gain `pinnedModel: String? = nil` immediately before `onCreated:` and pass it through: `NewChatViewModel(api: deps.agentRPCService(for: session), capacityCache: deps.boxCapacityCache(for: session), pinnedModel: pinnedModel)`.

The two choosers' "New coordinator chat…" sheets:

```swift
                NewChatSheet(deps: deps, session: session, pinnedModel: CoordinatorSetting.newChatModel) { convoID in
```

```swift
            MacNewChatSheet(deps: deps, session: session,
                            windowSize: NSApp.keyWindow?.contentLayoutRect.size,
                            pinnedModel: CoordinatorSetting.newChatModel) { convoID in
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ViewModelTests.NewChatViewModelTests` → PASS. Then the iOS command with `-only-testing:MatronTests/NewChatSheetBindingTests` and the Mac command with `-only-testing:MatronMacTests/MacNewChatSheetBindingTests` (build check; existing tests pass).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/NewChatViewModel.swift MatronShared/Tests/ViewModelTests/NewChatViewModelTests.swift \
  Matron/Features/ChatList/NewChatSheet.swift MatronMac/Features/ChatList/MacNewChatSheet.swift \
  Matron/Features/Coordinator/CoordinatorChooserSheet.swift MatronMac/Features/Coordinator/MacCoordinatorChooserSheet.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "coordinator: New coordinator chat starts on opus[1m]" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `ChatListViewModel` leaves the Coordinator out of the list

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ChatListViewModel.swift` (`:14-40`, `start()` `:60-78`, `derive` `:83-85`, `schedule` `:98-123`, `apply` `:128-135`)
- Test: `MatronShared/Tests/ViewModelTests/ChatListViewModelTests.swift`

**Interfaces:**
- Produces: `ChatListViewModel.hiddenConversationID: String?` (settable), `private(set) var hiddenSummary: ChatSummary?`, `var allSummaries: [ChatSummary]` (visible + hidden, for search), `nonisolated static func partition(_ snapshot: [ChatSummary], hiding: String?) -> (groups: [GroupedSummaries], totalUnread: Int, hidden: ChatSummary?)`. `totalUnread` still counts the hidden chat (dock / app badge).

- [ ] **Step 1: Write the failing tests**

Append to `ChatListViewModelTests`:

```swift
    private func waitForGroups(_ vm: ChatListViewModel) async {
        let start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Coordinator redesign §3b/§3c: the Coordinator's conversation is left
    /// out of the list but still counted and still findable.
    @MainActor
    func test_hiddenConversation_leavesTheList_butStaysCountedAndSearchable() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [[
            ChatSummary(id: "!coord:s", title: "Coordinator", bot: bot, lastActivity: .now, unreadCount: 2),
            ChatSummary(id: "!b:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 1),
        ]]
        let vm = ChatListViewModel(chat: fake, coalesceInterval: .zero)
        vm.hiddenConversationID = "!coord:s"
        vm.start()
        await waitForGroups(vm)
        XCTAssertEqual(vm.groups.flatMap(\.summaries).map(\.id), ["!b:s"])
        XCTAssertEqual(vm.hiddenSummary?.id, "!coord:s")
        XCTAssertEqual(vm.totalUnread, 3, "the badge still counts the Coordinator's unread")
        XCTAssertEqual(Set(vm.allSummaries.map(\.id)), ["!coord:s", "!b:s"])
    }

    /// Assigning or clearing re-partitions the latest snapshot at once, with
    /// no new snapshot needed.
    @MainActor
    func test_changingTheHiddenID_repartitionsImmediately() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [[
            ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: .now, unreadCount: 0),
            ChatSummary(id: "!b:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 0),
        ]]
        let vm = ChatListViewModel(chat: fake, coalesceInterval: .zero)
        vm.start()
        await waitForGroups(vm)
        vm.hiddenConversationID = "!a:s"
        XCTAssertEqual(vm.groups.flatMap(\.summaries).map(\.id), ["!b:s"])
        XCTAssertEqual(vm.hiddenSummary?.id, "!a:s")
        vm.hiddenConversationID = nil
        XCTAssertEqual(Set(vm.groups.flatMap(\.summaries).map(\.id)), ["!a:s", "!b:s"])
        XCTAssertNil(vm.hiddenSummary)
    }

    func test_partition_isAPureSplit() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let a = ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: nil, unreadCount: 4)
        let result = ChatListViewModel.partition([a], hiding: "!a:s")
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.hidden?.id, "!a:s")
        XCTAssertEqual(result.totalUnread, 4)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ViewModelTests.ChatListViewModelTests`
Expected: build FAIL — `value of type 'ChatListViewModel' has no member 'hiddenConversationID'`.

- [ ] **Step 3: Implement**

Add after `totalUnread`:

```swift
    /// The Coordinator's conversation (Coordinator redesign §3b/§3c): left
    /// out of `groups` — the Conversations list — but still counted in
    /// `totalUnread` and published as `hiddenSummary` for the Coordinator
    /// button's unread dot and the panel / sheet title. `nil` hides nothing.
    /// Changing it re-partitions the latest snapshot at once.
    public var hiddenConversationID: String? {
        didSet {
            guard hiddenConversationID != oldValue, let lastSnapshot else { return }
            // Supersedes any parked snapshot: `lastSnapshot` is the newest.
            flushTask?.cancel()
            flushTask = nil
            pending = nil
            let result = Self.partition(lastSnapshot, hiding: hiddenConversationID)
            apply(groups: result.groups, totalUnread: result.totalUnread, hidden: result.hidden)
        }
    }
    public private(set) var hiddenSummary: ChatSummary?
    /// Every chat including the hidden one — what search reads, so a hit in
    /// the Coordinator still opens it (in the panel / sheet).
    public var allSummaries: [ChatSummary] {
        groups.flatMap(\.summaries) + (hiddenSummary.map { [$0] } ?? [])
    }
    /// The newest raw snapshot, kept so `hiddenConversationID` can re-partition.
    private var lastSnapshot: [ChatSummary]?
```

Change `pending` to `private var pending: (groups: [GroupedSummaries], totalUnread: Int, hidden: ChatSummary?)?`.

`start()` loop body:

```swift
                for try await snapshot in chat.chatSummaries() {
                    if Task.isCancelled { return }
                    self.lastSnapshot = snapshot
                    let hiding = self.hiddenConversationID
                    let result = await Self.derive(from: snapshot, hiding: hiding)
                    if Task.isCancelled { return }
                    // The id changed while this derived: `didSet` already
                    // applied this same snapshot under the new id.
                    guard hiding == self.hiddenConversationID else { continue }
                    self.schedule(groups: result.groups, totalUnread: result.totalUnread, hidden: result.hidden)
                }
```

Replace `derive`:

```swift
    private nonisolated static func derive(from snapshot: [ChatSummary], hiding: String?) async
        -> (groups: [GroupedSummaries], totalUnread: Int, hidden: ChatSummary?) {
        partition(snapshot, hiding: hiding)
    }

    /// Splits the hidden chat out of a snapshot. Unread counts the whole
    /// snapshot: the app and dock badges include the Coordinator.
    public nonisolated static func partition(_ snapshot: [ChatSummary], hiding hiddenID: String?)
        -> (groups: [GroupedSummaries], totalUnread: Int, hidden: ChatSummary?) {
        let hidden = hiddenID.flatMap { id in snapshot.first { $0.id == id } }
        let visible = hiddenID.map { id in snapshot.filter { $0.id != id } } ?? snapshot
        return (group(summaries: visible), snapshot.reduce(0) { $0 + $1.unreadCount }, hidden)
    }
```

`schedule(groups:totalUnread:hidden:)` — thread `hidden` through: `pending = (grouped, unread, hidden)`, the flush calls `self.apply(groups: pending.groups, totalUnread: pending.totalUnread, hidden: pending.hidden)`, and the immediate path `apply(groups: grouped, totalUnread: unread, hidden: hidden)`.

`apply`:

```swift
    private func apply(groups grouped: [GroupedSummaries], totalUnread unread: Int, hidden: ChatSummary?) {
        lastApplied = .now
        if groups != grouped { groups = grouped }
        if hiddenSummary != hidden { hiddenSummary = hidden }
        let anyChat = !grouped.isEmpty || hidden != nil
        if hasChats != anyChat { hasChats = anyChat }
        if totalUnread != unread { totalUnread = unread }
        if isLoading { isLoading = false }
        if error != nil { error = nil }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ViewModelTests.ChatListViewModelTests`
Expected: PASS (new and existing).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/ChatListViewModel.swift MatronShared/Tests/ViewModelTests/ChatListViewModelTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "chat list: hide the Coordinator's conversation, keep it counted and searchable" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Missions — Unassigned section with "from Coordinator"

**Files:**
- Modify: `MatronShared/Sources/ViewModels/MissionsListViewModel.swift` (properties `:141-158`, `start()` `:196-205`, new statics)
- Modify: `MatronShared/Sources/DesignSystem/Missions/MissionsListView.swift` (Model, `List`, `row`)
- Modify: `MatronShared/Sources/DesignSystem/Missions/MissionRowView.swift`
- Modify: `Matron/Features/Missions/MissionsTabRoot.swift`, `MatronMac/Features/Missions/MacMissionsColumn.swift`
- Modify: `Matron/App/AppShellView.swift` (`missionsTab`, the origin-labels `.task` id), `MatronMac/Features/ChatList/MacChatListView.swift` (`missionsColumn`, the origin-labels `.task` id at `:554`)
- Test: `MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift`

**Interfaces:**
- Produces: `MissionsListViewModel.unassigned: [Mission]` (open, `conversationCount == 0`); `open` now holds only open missions WITH a conversation; `needsYouTotal` sums both; `static func splitUnassigned(_ open: [Mission]) -> (unassigned: [Mission], assigned: [Mission])`; `static func attribution(for: Mission, coordinatorConvoID: String?, originTitles: [String: String]) -> String?`; `static func attributions(for: [Mission], coordinatorConvoID: String?, originTitles: [String: String]) -> [String: String]`; `MissionsListView.Model(open:closed:isSupported:isRefreshing:unassigned: = [], attributions: = [:])`; `MissionRowView(mission:attribution: String? = nil)`; `MissionsTabRoot(viewModel:coordinatorConvoID:originTitles:onSelect:)`, `MacMissionsColumn(viewModel:coordinatorConvoID:originTitles:onSelect:)` (the two new params defaulted).

- [ ] **Step 1: Write the failing tests**

In `MissionsViewModelTests`, extend the `mission(...)` helper with `conversations: Int = 1` (passed as `conversationCount: conversations`) so existing fixtures stay "assigned", then append:

```swift
    func testOpenMissionsWithoutAConversationAreUnassigned() {
        let split = MissionsListViewModel.splitUnassigned([
            mission("ms_1", num: 61, lastMilestoneAt: 10, conversations: 0),
            mission("ms_2", num: 62, lastMilestoneAt: 20, conversations: 2),
        ])
        XCTAssertEqual(split.unassigned.map(\.id), ["ms_1"])
        XCTAssertEqual(split.assigned.map(\.id), ["ms_2"])
    }

    func testListPublishesUnassignedFirstAndCountsItsBadge() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionsListViewModel(store: store, sync: sync)
        vm.start()
        store.missionsContinuation.yield([
            mission("ms_1", num: 61, lastMilestoneAt: 10, needsYou: 1, conversations: 0),
            mission("ms_2", num: 62, lastMilestoneAt: 30, needsYou: 2),
            mission("ms_3", num: 63, state: .closed, lastMilestoneAt: 5, closedAt: 9, conversations: 0),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.unassigned.map(\.id), ["ms_1"])
        XCTAssertEqual(vm.open.map(\.id), ["ms_2"])
        XCTAssertEqual(vm.closed.map(\.id), ["ms_3"], "a closed mission is never Unassigned")
        XCTAssertEqual(vm.needsYouTotal, 3)
        vm.stop()
    }

    func testAttributionNamesTheCoordinatorThenTheOrigin() {
        let fromCoordinator = Mission(id: "ms_1", num: 61, title: "A", originConvoID: "c-coord")
        let fromElsewhere = Mission(id: "ms_2", num: 62, title: "B", originConvoID: "c-9")
        let unknown = Mission(id: "ms_3", num: 63, title: "C", originConvoID: "c-x")
        let titles = ["c-9": "Deploy box", "c-coord": "Planning"]
        XCTAssertEqual(MissionsListViewModel.attribution(for: fromCoordinator, coordinatorConvoID: "c-coord", originTitles: titles),
                       "from Coordinator")
        XCTAssertEqual(MissionsListViewModel.attribution(for: fromElsewhere, coordinatorConvoID: "c-coord", originTitles: titles),
                       "from Deploy box")
        XCTAssertNil(MissionsListViewModel.attribution(for: unknown, coordinatorConvoID: "c-coord", originTitles: titles))
        XCTAssertEqual(MissionsListViewModel.attributions(for: [fromCoordinator, unknown], coordinatorConvoID: "c-coord",
                                                          originTitles: titles),
                       ["ms_1": "from Coordinator"])
    }
```

Append to `MissionsSnapshotTests` (it already builds a `mission` fixture for `testMissionRow`; reuse the same construction):

```swift
    func testListModelCountsUnassignedAsContent() {
        let m = Mission(id: "ms_u", num: 70, title: "Rotate keys", originConvoID: "c-coord")
        XCTAssertFalse(MissionsListView.Model(open: [], closed: [], isSupported: true, isRefreshing: false,
                                              unassigned: [m]).isEmpty)
    }

    func testListWithUnassignedSection() {
        let m = Mission(id: "ms_u", num: 70, title: "Rotate keys", originConvoID: "c-coord")
        let model = MissionsListView.Model(open: [], closed: [], isSupported: true, isRefreshing: false,
                                           unassigned: [m], attributions: ["ms_u": "from Coordinator"])
        assertVariants(of: MissionsListView(model: model, onSelect: { _ in }, onRefresh: {})
                        .frame(width: 390, height: 300), named: "missions-unassigned")
    }
```

(Match `assertVariants`' signature to the one the file's `testMissionRow` already calls; the snapshot is skipped under `MATRON_SKIP_SNAPSHOT_TESTS=1` and recorded in Step 4.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "ViewModelTests.MissionsViewModelTests|DesignSystemSnapshotTests.MissionsSnapshotTests"`
Expected: build FAIL — `type 'MissionsListViewModel' has no member 'splitUnassigned'`.

- [ ] **Step 3: Implement**

`MissionsListViewModel.swift`:

```swift
    /// Open missions no conversation has joined yet (Coordinator redesign
    /// §3d) — handed out and waiting to be picked up. Shown first, in their
    /// own section; `open` holds the rest of the open missions.
    public private(set) var unassigned: [Mission] = []
```

Change `needsYouTotal` to `public var needsYouTotal: Int { (unassigned + open).reduce(0) { $0 + $1.needsYou } }`.

Statics (after `sections(from:)`):

```swift
    /// Spec §3d: unassigned = open with no member conversations. Derived
    /// from the `conversations` count the list and detail routes carry.
    public static func splitUnassigned(_ open: [Mission]) -> (unassigned: [Mission], assigned: [Mission]) {
        (open.filter { $0.conversationCount == 0 }, open.filter { $0.conversationCount > 0 })
    }

    /// Who created the mission, for the Unassigned rows: "from Coordinator"
    /// when it was born in the Coordinator's conversation, otherwise the
    /// origin conversation's title when this device knows it.
    public static func attribution(for mission: Mission, coordinatorConvoID: String?,
                                   originTitles: [String: String]) -> String? {
        if let coordinatorConvoID, !coordinatorConvoID.isEmpty, mission.originConvoID == coordinatorConvoID {
            return "from Coordinator"
        }
        guard let title = originTitles[mission.originConvoID], !title.isEmpty else { return nil }
        return "from \(title)"
    }

    public static func attributions(for missions: [Mission], coordinatorConvoID: String?,
                                    originTitles: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for mission in missions {
            if let label = attribution(for: mission, coordinatorConvoID: coordinatorConvoID, originTitles: originTitles) {
                result[mission.id] = label
            }
        }
        return result
    }
```

In `start()` replace the three assignments with:

```swift
                let sections = Self.sections(from: missions)
                let split = Self.splitUnassigned(sections.open)
                self.unassigned = split.unassigned
                self.open = split.assigned
                self.closed = sections.closed
```

`MissionsListView.Model`:

```swift
    public struct Model: Equatable {
        public var open: [Mission]
        public var closed: [Mission]
        public var isSupported: Bool
        public var isRefreshing: Bool
        /// Spec §3d: open missions with no conversation, listed first.
        public var unassigned: [Mission]
        /// Mission id → "from Coordinator" / "from <title>" for Unassigned rows.
        public var attributions: [String: String]
        public init(open: [Mission], closed: [Mission], isSupported: Bool, isRefreshing: Bool,
                    unassigned: [Mission] = [], attributions: [String: String] = [:]) {
            self.open = open; self.closed = closed; self.isSupported = isSupported; self.isRefreshing = isRefreshing
            self.unassigned = unassigned; self.attributions = attributions
        }
        public var isEmpty: Bool { unassigned.isEmpty && open.isEmpty && closed.isEmpty }
    }
```

In the `List`, before `if !model.open.isEmpty {`:

```swift
                    if !model.unassigned.isEmpty {
                        Section("Unassigned") {
                            ForEach(Array(model.unassigned.enumerated()), id: \.element.id) { index, mission in
                                row(mission, hideTopSeparator: index == 0)
                            }
                        }
                    }
```

and in `row(_:hideTopSeparator:)` pass the label: `MissionRowView(mission: mission, attribution: model.attributions[mission.id])`.

`MissionRowView`:

```swift
    let mission: Mission
    /// "from Coordinator" on Unassigned rows (spec §3d); nil elsewhere.
    let attribution: String?
    public init(mission: Mission, attribution: String? = nil) {
        self.mission = mission; self.attribution = attribution
    }
```

In the body, directly after `Text(mission.title)…lineLimit(2)`:

```swift
                if let attribution {
                    Text(attribution).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
```

and extend the accessibility label with `+ (attribution.map { ", \($0)" } ?? "")` before the needs-you clause.

`MissionsTabRoot` and `MacMissionsColumn` gain `var coordinatorConvoID: String? = nil` and `var originTitles: [String: String] = [:]` between `viewModel` and `onSelect`, and build the model as:

```swift
            model: .init(open: viewModel.open, closed: viewModel.closed,
                         isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
                         unassigned: viewModel.unassigned,
                         attributions: MissionsListViewModel.attributions(
                            for: viewModel.unassigned, coordinatorConvoID: coordinatorConvoID, originTitles: originTitles)),
```

Hosts: `AppShellView.missionsTab` → `MissionsTabRoot(viewModel: missionsVM, coordinatorConvoID: coordinatorConvoID, originTitles: originTitles, onSelect: { nav.pushMission($0) })`, and widen the origin-labels task id in `decisionsTab` to `.task(id: decisionsVM.awaitingYou.map(\.originConvoID) + missionsVM.unassigned.map(\.originConvoID))`. `MacChatListView.missionsColumn` → `MacMissionsColumn(viewModel: missionsVM, coordinatorConvoID: coordinatorConvoID, originTitles: decisionsOriginTitles, onSelect: { pickMission($0) })`, and widen the task id at `:554` to `(decisionsVM?.awaitingYou.map(\.originConvoID) ?? []) + (missionsVM?.unassigned.map(\.originConvoID) ?? [])`.

- [ ] **Step 4: Run to verify they pass, then record the snapshot**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "ViewModelTests.MissionsViewModelTests|DesignSystemSnapshotTests.MissionsSnapshotTests"` → PASS.
Record: `cd MatronShared && swift test --filter DesignSystemSnapshotTests.MissionsSnapshotTests/testListWithUnassignedSection` twice (first run writes the baselines and fails, second passes). Look at the three PNGs: an "Unassigned" header, the row with "from Coordinator" under the title.
Build both apps: the iOS command with `-only-testing:MatronTests/MissionsNavigationTests`; the Mac command with `-only-testing:MatronMacTests/MacMissionsNavTests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/MissionsListViewModel.swift MatronShared/Sources/DesignSystem/Missions \
  MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift MatronShared/Tests/DesignSystemSnapshotTests \
  Matron/Features/Missions/MissionsTabRoot.swift MatronMac/Features/Missions/MacMissionsColumn.swift \
  Matron/App/AppShellView.swift MatronMac/Features/ChatList/MacChatListView.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "missions: Unassigned section with who created each mission" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: iOS navigation — no Coordinator tab, a Coordinator sheet

**Files:**
- Modify: `Matron/App/AppShellNavigation.swift` (whole coordinator surface, see below)
- Test: `MatronTests/AppShellNavigationTests.swift`, `MatronTests/MissionsNavigationTests.swift`

**Interfaces:**
- Produces: `AppTab` = `.missions, .decisions, .conversations`; `AppShellNavigation.isCoordinatorPresented: Bool`; `func presentCoordinator()`; `func openChat(_ roomID: String, dismissingCoordinator: Bool = true)`; `setChatPath(_:)` / `setCoordinatorPath(_:)` redirect semantics below; `coordinatorPath` is the SHEET's stack. `redirectCoordinatorPush()` is deleted.

This task leaves the app not compiling until Task 10 (`AppShellView` still names `.coordinator`); run only the unit tests by building the test target together with Task 10, OR implement Tasks 9 and 10 in one sitting and commit separately. Recommended: do Step 1-3 here, then Task 10 Steps 1-3, then run both tasks' tests.

- [ ] **Step 1: Write the failing tests**

In `AppShellNavigationTests.swift`, replace `test_rootSwipe_left_goesToTheNextTab_andRight_comesBack`, `test_coordinatorConversation_alwaysRoutesToItsOwnTab`, `test_coordinatorIsNeverMountedTwice`, `test_stackSetters_redirectTheCoordinatorBeforeItIsStored`, `test_coordinatorTab_hasItsOwnStack` and `test_deepLink_leavesTheCoordinatorStackAlone` with:

```swift
    func test_rootSwipe_left_goesToTheNextTab_andRight_comesBack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: -120, height: 10)))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: -120, height: 10)), "nothing to the right of the last tab")
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertTrue(nav.swipeRoot(translation: CGSize(width: 120, height: 10)))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertFalse(nav.swipeRoot(translation: CGSize(width: 120, height: 10)),
                       "Missions is the first tab now the Coordinator tab is gone")
    }

    /// Spec §3c: every route into the Coordinator's conversation presents
    /// the sheet; nothing selects a tab for it.
    func test_everyRouteToTheCoordinator_presentsTheSheet() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.coordinatorPath = ["!child:s"]
        nav.openChat("!coord:s")
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.coordinatorPath, [], "a deep link lands at the Coordinator's root")
        XCTAssertEqual(nav.tab, .conversations, "the tab underneath is left alone")

        nav.isCoordinatorPresented = false
        nav.tab = .decisions
        nav.openConversation(fromDecisions: "!coord:s")
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.tab, .decisions)

        nav.isCoordinatorPresented = false
        nav.openConversation(fromMissions: "!coord:s")
        XCTAssertTrue(nav.isCoordinatorPresented)
    }

    /// An origin link pushing the Coordinator onto Conversations stores
    /// only what is beneath it and presents the sheet instead — one mount.
    func test_chatPathSetter_redirectsTheCoordinatorToTheSheet() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.setChatPath(["!other:s", "!coord:s", "item/abc"])
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertTrue(nav.isCoordinatorPresented)
        nav.isCoordinatorPresented = false
        nav.setChatPath(["!other:s", "item/abc"])
        XCTAssertEqual(nav.chatPath, ["!other:s", "item/abc"])
        XCTAssertFalse(nav.isCoordinatorPresented)
    }

    /// A second copy pushed onto the sheet's own stack pops it to its root.
    func test_coordinatorPathSetter_popsASecondCopyToTheRoot() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.setCoordinatorPath(["item/abc", "!coord:s"])
        XCTAssertEqual(nav.coordinatorPath, [])
        nav.setCoordinatorPath(["!child:s"])
        XCTAssertEqual(nav.coordinatorPath, ["!child:s"])
    }

    /// Presenting the sheet evicts the same conversation from Conversations
    /// first (it may be open there from before it became the Coordinator):
    /// two ChatViews would share one cached ChatViewModel.
    func test_presentingTheSheet_evictsTheSameChatFromConversations() {
        let nav = AppShellNavigation()
        nav.chatPath = ["!other:s", "!coord:s", "item/abc"]
        nav.coordinatorConvoID = "!coord:s"
        XCTAssertEqual(nav.chatPath, ["!other:s", "!coord:s", "item/abc"], "assignment alone yanks nothing")
        nav.presentCoordinator()
        XCTAssertEqual(nav.chatPath, ["!other:s"])
        XCTAssertTrue(nav.isCoordinatorPresented)
    }

    /// A new Coordinator starts at its root (Bugbot, PR #197).
    func test_changingTheCoordinator_resetsTheSheetStack() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!a:s"
        nav.coordinatorPath = ["!child:s"]
        nav.coordinatorConvoID = "!b:s"
        XCTAssertEqual(nav.coordinatorPath, [])
    }

    /// A tap on another conversation's notification leaves the sheet for it.
    func test_openingAnotherChat_dismissesTheSheet() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!r:s")
        XCTAssertFalse(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.chatPath, ["!r:s"])
    }

    /// Review focus: a session the Coordinator starts auto-opens underneath;
    /// the sheet stays where the user is.
    func test_autoOpen_keepsTheCoordinatorSheetUp() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "!coord:s"
        nav.presentCoordinator()
        nav.openChat("!spawned:s", dismissingCoordinator: false)
        XCTAssertTrue(nav.isCoordinatorPresented)
        XCTAssertEqual(nav.chatPath, ["!spawned:s"])
        XCTAssertEqual(nav.tab, .conversations)
    }
```

In `MissionsNavigationTests.swift`: `testTabOrderIsCoordinatorMissionsDecisionsConversations` → rename `testTabOrderIsMissionsDecisionsConversations` asserting `[.missions, .decisions, .conversations]`; `testOpenConversationFromMissionsRoutesTheCoordinatorToItsTab` → assert `nav.isCoordinatorPresented == true`, `nav.chatPath == []`, `nav.tab == .conversations`; in `testSwipeSkipsMissionsAndUnsupportedClampsOffIt` replace the first block with:

```swift
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.tab = .decisions
        XCTAssertFalse(nav.swipeRoot(translation: .init(width: 120, height: 5)), "Missions is skipped when unsupported")
        XCTAssertEqual(nav.tab, .decisions)
```

and replace `CoordinatorTabView.missionOpenConversationOutcome` with `CoordinatorSheet.missionOpenConversationOutcome` (renamed in Task 10).

- [ ] **Step 2: (Run together with Task 10 Step 2.)**

- [ ] **Step 3: Implement**

`AppShellNavigation.swift`:

```swift
/// The bottom tabs (app shell, spec §3), left to right in the bar — and
/// `allCases` order is the swipe order too. The Coordinator is a sheet
/// over any tab since the Coordinator redesign (§3c), not a tab.
enum AppTab: Hashable, CaseIterable {
    case missions
    case decisions
    case conversations
}
```

Replace the `coordinatorPath` doc with: "The Coordinator sheet's own stack (spec §3c): sub-chats, items and missions opened inside the sheet push here, so back returns to the Coordinator." Add after `missionsPath`:

```swift
    /// Whether the Coordinator sheet is up. Every entry — the floating
    /// button on a tab root, the ⓘ-sheet row and tasks-page button in a
    /// chat, a notification tap or link into the Coordinator's
    /// conversation — goes through `presentCoordinator()`.
    var isCoordinatorPresented = false
```

Replace `openChat`, the `coordinatorConvoID` property, `redirectCoordinatorPush`, `handOffToConversations`, `setChatPath`, `setCoordinatorPath`, `push(_:on:)` and `isAtRoot` with:

```swift
    /// Open a top-level conversation by REPLACING the Conversations path
    /// (Dan, 2026-08-06). The Coordinator's conversation presents the
    /// sheet instead. `dismissingCoordinator: false` is for the auto-open of
    /// a freshly started session: it lands underneath and the sheet stays.
    func openChat(_ roomID: String, dismissingCoordinator: Bool = true) {
        if roomID == coordinatorConvoID {
            presentCoordinator()
            return
        }
        if dismissingCoordinator { isCoordinatorPresented = false }
        tab = .conversations
        if chatPath != [roomID] { chatPath = [roomID] }
    }

    /// The designated Coordinator conversation, mirrored from the cached
    /// setting by the shell. A new one starts the sheet at its root.
    var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            coordinatorPath = []
        }
    }

    /// Presents the Coordinator sheet at its root. The same conversation
    /// open in Conversations (from before it became the Coordinator) is
    /// cut from that stack first: two ChatViews would share one cached
    /// ChatViewModel, and the first to leave stops the other's stream
    /// (Bugbot, PR #197).
    func presentCoordinator() {
        if let coordinator = coordinatorConvoID, let index = chatPath.firstIndex(of: coordinator) {
            chatPath.removeSubrange(index...)
        }
        coordinatorPath = []
        isCoordinatorPresented = true
    }

    private func handOffToConversations(_ convoID: String) {
        if convoID == coordinatorConvoID {
            presentCoordinator()
            return
        }
        tab = .conversations
        if chatPath.last != convoID { chatPath.append(convoID) }
    }

    /// The Conversations stack binding's setter: a push of the Coordinator
    /// (origin link, spawned-room Open) keeps only what is beneath it and
    /// presents the sheet, so it never mounts on this stack for a frame.
    func setChatPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, let index = new.firstIndex(of: coordinator) {
            chatPath = Array(new[..<index])
            presentCoordinator()
        } else {
            chatPath = new
        }
    }

    /// The sheet stack binding's setter: a second copy of the Coordinator
    /// pops the sheet to its root.
    func setCoordinatorPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, new.contains(coordinator) {
            coordinatorPath = []
        } else {
            coordinatorPath = new
        }
    }

    func push(_ value: String, on tab: AppTab) {
        switch tab {
        case .conversations: chatPath.append(value)
        case .decisions: if let route = ItemRoute(pathValue: value) { decisionsPath.append(route) }
        case .missions: missionsPath.append(value)
        }
    }

    var isAtRoot: Bool {
        switch tab {
        case .conversations: return chatPath.isEmpty
        case .decisions: return decisionsPath.isEmpty
        case .missions: return missionsPath.isEmpty
        }
    }
```

(`openConversation(fromDecisions:)`, `openMission`, `pushMission`, `pushMissionItem`, `openConversation(fromMissions:)`, `pushDecision`, `missionsSupported`, `tabs(missionsSupported:)` and `swipeRoot` are unchanged.)

- [ ] **Step 4: (Run together with Task 10 Step 4.)**

- [ ] **Step 5: Commit** (after Task 10 Step 4 is green)

```bash
git add Matron/App/AppShellNavigation.swift MatronTests/AppShellNavigationTests.swift MatronTests/MissionsNavigationTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "ios nav: the Coordinator is a sheet over any tab, not a tab" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: iOS shell — Coordinator sheet, floating button, list exclusion

**Files:**
- Rename: `Matron/Features/Coordinator/CoordinatorTabView.swift` → `Matron/Features/Coordinator/CoordinatorSheet.swift` (`git mv`), struct `CoordinatorTabView` → `CoordinatorSheet`
- Rename: `MatronTests/CoordinatorTabViewTests.swift` → `MatronTests/CoordinatorSheetTests.swift`
- Create: `Matron/Features/Coordinator/CoordinatorEntry.swift`
- Modify: `Matron/Features/Coordinator/CoordinatorSetupView.swift:10`
- Modify: `Matron/App/AppShellView.swift`
- Modify: `Matron/Features/ChatList/ChatListView.swift:86-88` (`allChatSummaries`)
- Test: `MatronTests/CoordinatorEntryTests.swift` (new), `MatronTests/AppShellViewTests.swift`, `MatronTests/CoordinatorSheetTests.swift`

**Interfaces:**
- Consumes: Task 9's `AppShellNavigation`; Task 7's `hiddenConversationID` / `hiddenSummary` / `allSummaries`; Task 5's `setCoordinator`.
- Produces: `struct OpenCoordinatorAction: Equatable { init(_ perform: @escaping @MainActor () -> Void); @MainActor func callAsFunction() }`; `EnvironmentValues.openCoordinator: OpenCoordinatorAction?` (nil = no entries); `struct InsideCoordinatorSheet<Content: View>: View` (sets it nil); `struct CoordinatorFloatingButton: View { init(hasUnread: Bool, action: @escaping () -> Void); static func accessibilityLabel(hasUnread: Bool) -> String }`; `struct CoordinatorEntryButton: View { init(action: @escaping () -> Void) }`; `CoordinatorSheet(session:deps:chatListVM:vmCache:path:convoID:)` with `convoID: String?` (read-only now), `CoordinatorSheet.root(for:)`, `CoordinatorSheet.missionOpenConversationOutcome(target:current:coordinatorConvoID:)`.

- [ ] **Step 1: Write the failing tests**

`MatronTests/CoordinatorEntryTests.swift`:

```swift
import XCTest
import SwiftUI
import UIKit
@testable import Matron

private final class EnvBox { var seen: [Bool] = [] }

private struct EnvProbe: View {
    let box: EnvBox
    @Environment(\.openCoordinator) private var openCoordinator
    var body: some View { Color.clear.onAppear { box.seen.append(openCoordinator != nil) } }
}

@MainActor
final class CoordinatorEntryTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    func test_openCoordinatorAction_runsItsBody() {
        var runs = 0
        let action = OpenCoordinatorAction { runs += 1 }
        action()
        XCTAssertEqual(runs, 1)
    }

    func test_outsideTheSheet_theShellActionReachesAChat() {
        let box = EnvBox()
        render(EnvProbe(box: box).environment(\.openCoordinator, OpenCoordinatorAction {}))
        XCTAssertEqual(box.seen, [true])
    }

    /// Review focus: the Coordinator's own chat offers no way to open the
    /// Coordinator (a second copy on its own stack).
    func test_insideTheCoordinatorSheet_entriesAreHidden() {
        let box = EnvBox()
        render(InsideCoordinatorSheet { EnvProbe(box: box) }.environment(\.openCoordinator, OpenCoordinatorAction {}))
        XCTAssertEqual(box.seen, [false])
    }

    func test_floatingButton_labelsTheUnreadDot_andTaps() {
        XCTAssertEqual(CoordinatorFloatingButton.accessibilityLabel(hasUnread: false), "Coordinator")
        XCTAssertEqual(CoordinatorFloatingButton.accessibilityLabel(hasUnread: true), "Coordinator, unread messages")
        var taps = 0
        CoordinatorFloatingButton(hasUnread: true) { taps += 1 }.action()
        XCTAssertEqual(taps, 1)
    }

    private func render<V: View>(_ view: V) {
        let hosting = UIHostingController(rootView: view)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        }
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
```

`MatronTests/CoordinatorSheetTests.swift` (after `git mv`): replace every `CoordinatorTabView` with `CoordinatorSheet` and rename the class `CoordinatorSheetTests`.

`AppShellViewTests.swift`: replace `test_shell_showsFourTabs_atTheRoot` with

```swift
    func test_shell_showsThreeTabs_atTheRoot() throws {
        // Missions, Decisions, Conversations — the Coordinator is a sheet
        // now (Coordinator redesign §3c).
        renderInWindow(makeShell(navigation: AppShellNavigation()))
        let bar = try XCTUnwrap(findTabBar(in: window), "TabView must bridge to a UITabBar")
        XCTAssertEqual(bar.items?.count, 3)
        XCTAssertFalse(bar.isHidden)
    }

    func test_presentingTheCoordinator_putsUpASheet() throws {
        let nav = AppShellNavigation()
        renderInWindow(makeShell(navigation: nav))
        nav.presentCoordinator()
        let end = Date().addingTimeInterval(3)
        while window.rootViewController?.presentedViewController == nil, Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(window.rootViewController?.presentedViewController, "the Coordinator sheet must present")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate`, then the iOS test command with `-only-testing:MatronTests/CoordinatorEntryTests -only-testing:MatronTests/AppShellNavigationTests -only-testing:MatronTests/MissionsNavigationTests -only-testing:MatronTests/AppShellViewTests -only-testing:MatronTests/CoordinatorSheetTests`.
Expected: build FAIL — `cannot find 'OpenCoordinatorAction' in scope`.

- [ ] **Step 3: Implement**

`Matron/Features/Coordinator/CoordinatorEntry.swift`:

```swift
import SwiftUI

/// "Open the Coordinator" as an environment value (Coordinator redesign
/// §3c): the shell installs it once; a chat's ⓘ-sheet row and tasks-page
/// button read it; `InsideCoordinatorSheet` clears it so the Coordinator's
/// own chat offers no entry. Equal to every other instance on purpose: it
/// is stored once per shell, and a closure SwiftUI cannot compare must not
/// invalidate every chat that reads it.
struct OpenCoordinatorAction: Equatable {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }

    @MainActor func callAsFunction() { perform() }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct OpenCoordinatorKey: EnvironmentKey {
    static let defaultValue: OpenCoordinatorAction? = nil
}

extension EnvironmentValues {
    var openCoordinator: OpenCoordinatorAction? {
        get { self[OpenCoordinatorKey.self] }
        set { self[OpenCoordinatorKey.self] = newValue }
    }
}

/// Wraps the Coordinator sheet's content: no Coordinator entry inside it.
struct InsideCoordinatorSheet<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.openCoordinator, nil)
    }
}

/// The floating Coordinator button on each tab's ROOT screen (spec §3c):
/// bottom trailing, above the tab bar, with the unread dot the tab had.
/// Never inside a chat — it would sit over the composer.
struct CoordinatorFloatingButton: View {
    let hasUnread: Bool
    let action: () -> Void

    init(hasUnread: Bool, action: @escaping () -> Void) {
        self.hasUnread = hasUnread
        self.action = action
    }

    static func accessibilityLabel(hasUnread: Bool) -> String {
        hasUnread ? "Coordinator, unread messages" : "Coordinator"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(hasUnread: hasUnread))
        .accessibilityIdentifier("coordinator.floatingButton")
    }
}

/// The Coordinator button at the top of a chat's tasks page (Dan, #2757).
struct CoordinatorEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("coordinator.tasksPageButton")
    }
}
```

`CoordinatorSheet.swift` (renamed file) — keep `Root`, `root(for:)`, `MissionConversationOutcome`, `missionOpenConversationOutcome` and the `navigationDestination` body as they are; change:
- the struct name to `CoordinatorSheet` and the doc to "The Coordinator sheet (Coordinator redesign §3c): its own `NavigationStack` whose root is the Coordinator's chat, or `CoordinatorSetupView` when none is set. Presented over any screen with detents `.large` and `.medium`; pushes land on `path`.";
- `@Binding var convoID: String?` → `let convoID: String?` (the cache follows the journal; picks go through `deps.setCoordinator`);
- `summary(for:)`:

```swift
    private func summary(for id: String) -> ChatSummary? {
        if let hidden = chatListVM.hiddenSummary, hidden.id == id { return hidden }
        return chatListVM.groups.flatMap(\.summaries).first { $0.id == id }
    }
```

- add `@State private var detent: PresentationDetent = .large`;
- wrap the body: `InsideCoordinatorSheet { NavigationStack(path: $path) { … } }` then, on the result, keep `.environment(\.chatNavigationPath, $path)`, DELETE `.onChange(of: convoID) { _, _ in path = [] }` (Task 9's `coordinatorConvoID.didSet` owns it), keep the chooser `.sheet` and `.alert` from Task 5, and add `.presentationDetents([.large, .medium], selection: $detent)`.

`CoordinatorSetupView.swift:10` copy → `Text("Pick one conversation to be your Coordinator. It hands work out as missions and never does the work itself.")`.

`AppShellView.swift`:

- init: build the navigation object once and the action from it:

```swift
    @State private var openCoordinator: OpenCoordinatorAction
```

```swift
        let navigation = navigation ?? AppShellNavigation()
        _nav = State(initialValue: navigation)
        _openCoordinator = State(initialValue: OpenCoordinatorAction { [weak navigation] in
            navigation?.presentCoordinator()
        })
```

- body: delete the `coordinatorTab` entry from the `TabView` (and the `coordinatorTab` property). After `.environment(\.currentSession, session)` add `.environment(\.openCoordinator, openCoordinator)` and `.sheet(isPresented: $nav.isCoordinatorPresented) { coordinatorSheet }`. Change the auto-open loop to `nav.openChat(roomID, dismissingCoordinator: false)` with the comment "A session the Coordinator just started lands underneath; the sheet stays." Replace the coordinator `.onChange` with:

```swift
        // Mirror the cached setting into the nav rules and the list filter.
        .onChange(of: coordinatorConvoID, initial: true) { _, id in
            nav.coordinatorConvoID = id
            chatListVM.hiddenConversationID = id
        }
```

- helpers:

```swift
    private var coordinatorHasUnread: Bool {
        (chatListVM.hiddenSummary?.unreadCount ?? 0) > 0
    }

    /// Spec §3c: the floating button on a tab's ROOT only — attached to the
    /// root view inside each stack, so any push covers it.
    private func withCoordinatorButton(_ root: some View) -> some View {
        root.overlay(alignment: .bottomTrailing) {
            CoordinatorFloatingButton(hasUnread: coordinatorHasUnread) { nav.presentCoordinator() }
                .padding(16)
        }
    }

    private var coordinatorSheet: some View {
        CoordinatorSheet(session: session, deps: deps, chatListVM: chatListVM, vmCache: vmCache,
                         path: coordinatorPath, convoID: coordinatorConvoID)
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)
    }
```

(`coordinatorPath` binding stays as it is.)

- wrap the three roots: in `conversationsTab`, `withCoordinatorButton(ChatListView(...).simultaneousGesture(rootSwipe))`; in `decisionsTab`, `withCoordinatorButton(DecisionsListView(...).simultaneousGesture(rootSwipe))` placed before `.navigationTitle("Decisions")`; in `missionsTab`, `withCoordinatorButton(MissionsTabRoot(...).simultaneousGesture(rootSwipe))` placed before `.navigationDestination`.

`ChatListView.swift:86-88`: `viewModel.groups.flatMap(\.summaries)` → `viewModel.allSummaries` (search still finds the Coordinator; a hit calls `onOpenChat` → `nav.openChat` → the sheet).

- [ ] **Step 4: Run to verify they pass**

Run: `xcodegen generate`, then the iOS test command with `-only-testing:MatronTests/CoordinatorEntryTests -only-testing:MatronTests/AppShellNavigationTests -only-testing:MatronTests/MissionsNavigationTests -only-testing:MatronTests/AppShellViewTests -only-testing:MatronTests/CoordinatorSheetTests`.
Expected: "Executed N tests, with 0 failures".
Manual: `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO`, run in the simulator: three tabs; the round button on each root, absent once a chat is pushed; tapping it slides the Coordinator up at full height; dragging to half height works; swiping down returns to the same screen.

- [ ] **Step 5: Commit** (commit Task 9 first, then this)

```bash
git add Matron/Features/Coordinator Matron/App/AppShellView.swift Matron/Features/ChatList/ChatListView.swift \
  MatronTests/CoordinatorEntryTests.swift MatronTests/CoordinatorSheetTests.swift MatronTests/AppShellViewTests.swift Matron.xcodeproj
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "ios: Coordinator sheet and floating button on the tab roots" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: iOS in-chat entries — ⓘ sheet row and tasks-page button

**Files:**
- Modify: `Matron/Features/Chat/SessionStatusSheet.swift:12-45` (property), `:62-76` (row)
- Modify: `Matron/Features/Chat/ChatView.swift` — environment near `:43`, state near `:362`, `tasksPage` (`:1006-1036`), the ⓘ `.sheet` (`:1200-1222`), new static helper near `pushItem` (`:225`)
- Test: `MatronTests/SessionStatusSheetSubagentsTests.swift`, `MatronTests/ChatPagerTests.swift`

**Interfaces:**
- Consumes: `OpenCoordinatorAction`, `EnvironmentValues.openCoordinator`, `CoordinatorEntryButton` (Task 10).
- Produces: `SessionStatusSheet.onOpenCoordinator: (() -> Void)?` (default nil = no row); `static func ChatView.coordinatorRowAction(_ open: OpenCoordinatorAction?, arm: @escaping () -> Void) -> (() -> Void)?`.

- [ ] **Step 1: Write the failing tests**

Append to `SessionStatusSheetSubagentsTests` (uses its `makeViewModel()` and `renderInWindow`/`uikitLabelTexts` helpers):

```swift
    // MARK: - Coordinator row (Coordinator redesign §3c)

    func test_onOpenCoordinator_defaultsToAbsent() {
        XCTAssertNil(SessionStatusSheet(viewModel: makeViewModel()).onOpenCoordinator)
    }

    func test_onOpenCoordinator_isWhatTheRowCalls() {
        var armed = 0
        let sheet = SessionStatusSheet(viewModel: makeViewModel(), onOpenCoordinator: { armed += 1 })
        sheet.onOpenCoordinator?()
        XCTAssertEqual(armed, 1, "the row only arms the intent; ChatView presents from onDismiss")
    }

    func test_sheet_withTheCoordinatorRow_rendersWithoutCrashing() {
        let hostView = renderInWindow(SessionStatusSheet(viewModel: makeViewModel(), onOpenCoordinator: {}))
        XCTAssertTrue(uikitLabelTexts(in: hostView).contains("Session"))
    }
```

Append to `ChatPagerTests` (it already tests `ChatView` statics):

```swift
    /// The ⓘ row exists only where the shell installed an action — never
    /// inside the Coordinator's own sheet.
    @MainActor
    func test_coordinatorRowAction_followsTheEnvironment() {
        XCTAssertNil(ChatView.coordinatorRowAction(nil, arm: {}))
        var armed = 0
        let action = ChatView.coordinatorRowAction(OpenCoordinatorAction {}, arm: { armed += 1 })
        action?()
        XCTAssertEqual(armed, 1)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: the iOS test command with `-only-testing:MatronTests/SessionStatusSheetSubagentsTests -only-testing:MatronTests/ChatPagerTests`.
Expected: build FAIL — `extra argument 'onOpenCoordinator' in call`.

- [ ] **Step 3: Implement**

`SessionStatusSheet.swift` — add after `onOpenSubagent`:

```swift
    /// Ride-along to the Coordinator sheet (Coordinator redesign §3c), on
    /// the same terms as `onOpenMedia`: the closure only FLAGS the intent
    /// and `ChatView` presents from its `onDismiss`. `nil` (the default, and
    /// always inside the Coordinator's own sheet) draws no row.
    var onOpenCoordinator: (() -> Void)? = nil
```

In `body`, as the FIRST child of the `VStack`, before `if onOpenMedia != nil {`:

```swift
                if let onOpenCoordinator {
                    Button {
                        onOpenCoordinator()
                        dismiss()
                    } label: {
                        Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .accessibilityIdentifier("session-coordinator-row")
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
```

`ChatView.swift`:

```swift
    /// "Open the Coordinator" from the shell (Coordinator redesign §3c);
    /// `nil` inside the Coordinator's own sheet, which hides both entries.
    @Environment(\.openCoordinator) private var openCoordinator
```

```swift
    /// Set by the info sheet's Coordinator row; consumed in its `onDismiss`
    /// (one sheet per presenter, like `pendingMediaOpen`).
    @State private var pendingCoordinatorOpen = false
```

Static helper next to `pushItem`:

```swift
    /// The ⓘ sheet's Coordinator row action: present only when the shell
    /// offers the Coordinator here. Static so a test pins the rule.
    static func coordinatorRowAction(_ open: OpenCoordinatorAction?, arm: @escaping () -> Void) -> (() -> Void)? {
        open == nil ? nil : arm
    }
```

`tasksPage`: directly after the `ItemsListView(...)` initializer's closing `)` and before `.task(id: itemsVM.scope)`:

```swift
            // Dan, #2757: the Coordinator is reachable from a chat's tasks
            // page. Absent inside the Coordinator's own sheet.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let openCoordinator {
                    CoordinatorEntryButton { openCoordinator() }
                }
            }
```

The ⓘ sheet — in `onDismiss`, after the `pendingChildOpen` block:

```swift
            // A Coordinator tap: present once the info sheet is gone.
            if pendingCoordinatorOpen {
                pendingCoordinatorOpen = false
                openCoordinator?()
            }
```

and pass the row into `SessionStatusSheet(...)`:

```swift
                onOpenSubagent: { id in pendingChildOpen = id },
                onOpenCoordinator: Self.coordinatorRowAction(openCoordinator) { pendingCoordinatorOpen = true }
```

- [ ] **Step 4: Run to verify they pass**

Run: the iOS test command with `-only-testing:MatronTests/SessionStatusSheetSubagentsTests -only-testing:MatronTests/ChatPagerTests -only-testing:MatronTests/ChatViewBindingTests`.
Expected: "Executed N tests, with 0 failures".
Manual (simulator): in an ordinary chat ⓘ → "Coordinator" row → the info sheet closes and the Coordinator sheet rises; the tasks page shows the Coordinator button at the top; inside the Coordinator sheet neither appears.

- [ ] **Step 5: Commit**

```bash
git add Matron/Features/Chat/SessionStatusSheet.swift Matron/Features/Chat/ChatView.swift \
  MatronTests/SessionStatusSheetSubagentsTests.swift MatronTests/ChatPagerTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "ios: open the Coordinator from a chat's info sheet and tasks page" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Mac — remove the Coordinator nav entry and place; remap ⌘1/⌘2/⌘3

**Files:**
- Modify: `MatronMac/Features/Nav/MacNavColumn.swift:4-27`
- Modify: `MatronMac/Features/Nav/MacNavigationHistory.swift:62-109` (`MacPlace`), `:155-195` (docs, delete `MacCoordinatorToolbarPlaceholder`)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` — `sidebarStack` `:188-208`, `sidebarWidths` `:210-219`, `place` `:226-238`, `paneRoute(_:landingOn:)` `:250-257`, `currentPlace` `:272-276`, `detailContent` `:325-339`, `splitView` `:347-401`, `withNavigationListeners` `:493`, `recordPlace` `:803`, `restore` `:827-829`, delete `coordinatorHeaderActions` `:869-874`, `navForShowingConversation` + `showConversation` `:988-1021`
- Modify: `MatronMac/App/Commands.swift` (enum `:12-26`, docs `:47`, View menu `:84-92`, `MacNavigationActions` `:131-155`)
- Modify: `MatronMac/Features/Chat/MacChatHeaderAccessory.swift` — `MacChatHeaderModel.navigation` `:10-12`, `bar` `:89-104`, `barContent` `:113-116`, delete `MacHeaderHistoryCluster` `:132-158`, link `:298-320`, host `:399-424`
- Test: `MatronMacTests/MacMissionsNavTests.swift`, `MacNavColumnSnapshotTests.swift` (+ its 6 PNGs), `MacNavigationShellTests.swift`, `MacNavigationHistoryTests.swift`, `MacSidebarWidthTests.swift`, `MacCommandsTests.swift`, `MacHistoryToolbarTests.swift`

**Interfaces:**
- Produces: `MacNav` = `.missions, .decisions, .conversations`; `MacPlace.Detail` without `.coordinator`; `MacPlace.displayedConversationID: String?` (property, no parameter); `MacChatListView.paneRoute(_:landingOn:)` (no coordinator parameter); `MacChatListView.sidebarWidths: (min: CGFloat, ideal: CGFloat, max: CGFloat)` (static let); `MatronCommand.showMissions` (replaces `.showCoordinator`); `MacNavigationActions(canGoBack:canGoForward:goBack:goForward:)` without `newChat`/`DrawnState`; `MacChatHeaderHost { … }` without `navigation:`.

- [ ] **Step 1: Write the failing tests (edit the existing ones)**

`MacMissionsNavTests.swift`: 

```swift
    func testNavOrderIsMissionsDecisionsConversations() {
        XCTAssertEqual(MacNav.allCases, [.missions, .decisions, .conversations])
        XCTAssertEqual(MacNav.missions.title, "Missions")
        XCTAssertEqual(MacNav.missions.symbol, "flag.checkered")
    }
```

delete `testSidebarWidthForMissionsMatchesTheOtherLists` and `testNavForShowingConversationKeepsTheCoordinatorEntryForItsOwnRoom`; in `testNavColumnBadgeMapCoversBothEntries` delete the `.coordinator` line; in `testNavColumnSnapshotEntriesRespectTheSupportedFilter` expect `[.decisions, .conversations]`.

`MacNavColumnSnapshotTests.testEntriesInBarOrder`: expect `[.missions, .decisions, .conversations]`.

`MacSidebarWidthTests.test_sidebarWidths_perNavSelection` → 

```swift
    /// One width triple for every entry now that no entry collapses the list.
    func test_sidebarWidths_areTheListPlusTheNavColumn() {
        XCTAssertEqual(MacChatListView.sidebarWidths.min, 260 + MacNavColumn.width)
        XCTAssertEqual(MacChatListView.sidebarWidths.ideal, 400 + MacNavColumn.width)
        XCTAssertEqual(MacChatListView.sidebarWidths.max, 600 + MacNavColumn.width)
    }
```

`MacNavigationShellTests`: `test_place_decisionsAndCoordinator` → `test_place_decisions` keeping only the decisions assertion; delete the `coordinatorConvoID:` argument from every `paneRoute(...)` call and delete the `.coordinator(pane: nil)` assertion in `test_paneRouteLandingOn_otherChatClaimsTheReset_ownerKeepsItsRoute`.

`MacNavigationHistoryTests`: in `test_place_navAndPaneAccessors` delete the two `.coordinator` lines; replace `test_place_displayedConversation` with

```swift
    func test_place_displayedConversation() {
        XCTAssertEqual(MacPlace(detail: .conversation(id: "c1", pane: nil)).displayedConversationID, "c1")
        XCTAssertNil(MacPlace(detail: .mission(id: "m")).displayedConversationID)
        XCTAssertNil(MacPlace(detail: .conversation(id: nil, pane: nil)).displayedConversationID)
    }
```

`MacCommandsTests.test_allCases_includes_phase2_set`: `.showCoordinator` → `.showMissions`, and add

```swift
    /// The Coordinator panel is per window: it is toggled through the key
    /// window's `MacNavigationActions`, never a bus post that moves every window.
    func test_noBusCommandTogglesTheCoordinator() {
        XCTAssertFalse(MatronCommand.allCases.map(\.rawValue).contains { $0.lowercased().contains("coordinator") })
    }
```

`MacHistoryToolbarTests`: delete `CoordinatorHarness` and `test_coordinator_headerCarriesTheChevrons_asAClickableCapsule` (the Coordinator's 72 pt sidebar no longer exists; the sidebar toolbar always carries the chevrons).

- [ ] **Step 2: Run to verify they fail**

Run: the Mac test command with `-only-testing:MatronMacTests/MacMissionsNavTests -only-testing:MatronMacTests/MacNavigationShellTests -only-testing:MatronMacTests/MacNavigationHistoryTests -only-testing:MatronMacTests/MacSidebarWidthTests -only-testing:MatronMacTests/MacCommandsTests`.
Expected: build FAIL — `type 'MatronCommand' has no member 'showMissions'`.

- [ ] **Step 3: Implement**

`MacNavColumn.swift`: `MacNav` cases `missions, decisions, conversations` (drop the `.coordinator` rows from `title` and `symbol`); doc "Top-level Mac navigation entries (app shell, spec §5), top to bottom. The Coordinator is a panel since the Coordinator redesign (§3b)."

`MacNavigationHistory.swift`:

```swift
struct MacPlace: Equatable {
    enum Detail: Equatable {
        /// `nil` id is the "Select a chat" empty state.
        case conversation(id: String?, pane: MacChatPaneRoute?)
        case mission(id: String?)
        case decision(id: String?)
    }

    var detail: Detail

    var nav: MacNav {
        switch detail {
        case .conversation: return .conversations
        case .mission: return .missions
        case .decision: return .decisions
        }
    }

    var pane: MacChatPaneRoute? {
        if case .conversation(_, let pane) = detail { return pane }
        return nil
    }

    /// The conversation the chat detail shows at this place, if any. The
    /// Coordinator panel is not part of a place (spec §3b).
    var displayedConversationID: String? {
        if case .conversation(let id, _) = detail { return id }
        return nil
    }
}
```

Delete `MacCoordinatorToolbarPlaceholder`; trim the `MacHistoryToolbarItems` doc's last sentence ("Coordinator's 72 pt sidebar…").

`MacChatListView.swift`:

```swift
    @ViewBuilder
    private var sidebarStack: some View {
        HStack(spacing: 0) {
            MacNavColumn(selection: $nav,
                         badges: [.decisions: decisionsVM?.awaitingYouCount ?? 0,
                                  .missions: missionsVM?.needsYouTotal ?? 0],
                         missionsSupported: missionsSupported)
            Divider()
            switch nav {
            case .conversations: sidebarColumn
            case .missions: missionsColumn
            case .decisions: decisionsColumn
            }
        }
    }

    /// Sidebar column min/ideal/max: the list's 260/400/600 plus the fixed
    /// 72 pt nav column (spec §5), the same for every entry.
    static let sidebarWidths: (min: CGFloat, ideal: CGFloat, max: CGFloat) =
        (260 + MacNavColumn.width, 400 + MacNavColumn.width, 600 + MacNavColumn.width)

    static func place(nav: MacNav, selectedSummaryID: String?, selectedMissionID: String?,
                      selectedDecisionID: String?, paneRoute: MacChatPaneRoute?) -> MacPlace {
        switch nav {
        case .conversations:
            return MacPlace(detail: .conversation(id: selectedSummaryID, pane: selectedSummaryID == nil ? nil : paneRoute))
        case .missions:
            return MacPlace(detail: .mission(id: selectedMissionID))
        case .decisions:
            return MacPlace(detail: .decision(id: selectedDecisionID))
        }
    }

    static func paneRoute(_ owned: MacOwnedPaneRoute, landingOn place: MacPlace) -> MacOwnedPaneRoute {
        guard let shown = place.displayedConversationID else {
            return owned.owner == nil ? owned : MacOwnedPaneRoute(owner: nil, route: owned.route)
        }
        guard shown != owned.owner else { return owned }
        return MacOwnedPaneRoute(owner: shown, route: owned.route(for: shown))
    }
```

`currentPlace`: `paneRoute: paneRoute.route(for: selectedSummaryID)`. `detailContent`: delete the `case .coordinator:` branch. `recordPlace`: `Self.paneRoute(paneRoute, landingOn: place)`. `restore`: delete the `.coordinator` case. Delete `coordinatorHeaderActions` and `navForShowingConversation`; `showConversation` becomes:

```swift
    private func showConversation(_ convoID: String) {
        nav = .conversations
        // A same-id assignment never runs `handleSelectionChange`, so the
        // search results panel would stay over the chat (Bugbot, PR #195).
        if searchQueryIsEmpty == false { searchModel?.query = "" }
        selectedSummaryID = convoID
    }
```

`splitView`:

```swift
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarStack
                .toolbar(removing: .sidebarToggle)
                // MUST come after `.toolbar(removing: .sidebarToggle)` (macOS 26).
                .navigationSplitViewColumnWidth(min: Self.sidebarWidths.min, ideal: Self.sidebarWidths.ideal,
                                                max: Self.sidebarWidths.max)
                .toolbar {
                    // Spec 2026-09-23 §5: Back/Forward top-left in the SIDEBAR section.
                    MacHistoryToolbarItems(history: history, goBack: goBack, goForward: goForward)
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNewChat = true } label: { Image(systemName: "square.and.pencil") }
                            .help("New chat")
                            .keyboardShortcut("n", modifiers: .command)
                    }
                }
        } detail: {
            // The chat header rides in the window's title bar — `MacChatHeaderHost`.
            MacChatHeaderHost { detailContent }
        }
    }
```

`withNavigationListeners`: replace the `.showCoordinator` receiver with

```swift
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showMissions))) { _ in
                // An old journal has no Missions entry to select.
                if missionsSupported { nav = .missions }
            }
```

`Commands.swift`: enum cases `showMissions, showDecisions, showConversations` (doc "nav-column selection — ⌘1 / ⌘2 / ⌘3, top to bottom"); the listener doc line → "`.showMissions/.showDecisions/.showConversations` — `MacChatListView` (sets `nav`)"; View menu:

```swift
            Button("Missions") { post(.showMissions) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Decisions") { post(.showDecisions) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Conversations") { post(.showConversations) }
                .keyboardShortcut("3", modifiers: .command)
```

`MacNavigationActions` becomes:

```swift
/// A window's Back/Forward, published to the menu bar with
/// `focusedSceneValue` so ⌘[ / ⌘] act on the key window only.
struct MacNavigationActions {
    var canGoBack: Bool
    var canGoForward: Bool
    var goBack: () -> Void
    var goForward: () -> Void
}
```

`MacChatHeaderAccessory.swift`: delete `MacChatHeaderModel.navigation`, `MacHeaderHistoryCluster`, `MacChatHeaderLink.latestNavigation` / `publishNavigation` (and the `accessory?.model.navigation = latestNavigation` line in `accessory.didSet`), the host's `navigation` property and its `.onChange(of: MacNavigationActions.DrawnState…)`. `bar` becomes `if let props = model.props { barContent(props: props) }` and the first `HStack` in `barContent` becomes `HStack(spacing: 10) { toolbar.modelItem }`.

Snapshot baselines: `rm MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/*.png` then `xcodegen generate`.

- [ ] **Step 4: Run to verify they pass; re-record the nav column**

Run: `xcodegen generate`, then the Mac test command with `-only-testing:MatronMacTests/MacMissionsNavTests -only-testing:MatronMacTests/MacNavigationShellTests -only-testing:MatronMacTests/MacNavigationHistoryTests -only-testing:MatronMacTests/MacSidebarWidthTests -only-testing:MatronMacTests/MacCommandsTests -only-testing:MatronMacTests/MacHistoryToolbarTests -only-testing:MatronMacTests/MacChatHeaderAccessoryTests -only-testing:MatronMacTests/MacItemsPaneStackTests`.
Expected: "Executed N tests, with 0 failures".
Record: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacNavColumnSnapshotTests` twice (first records and fails, second passes); `xcodegen generate` again so the new PNGs are members; eyeball them: three entries, no Coordinator.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Nav MatronMac/Features/ChatList/MacChatListView.swift MatronMac/App/Commands.swift \
  MatronMac/Features/Chat/MacChatHeaderAccessory.swift MatronMacTests Matron.xcodeproj
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "mac: drop the Coordinator nav entry; ⌘1/⌘2/⌘3 are Missions, Decisions, Conversations" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Mac — panel geometry, container, header inset

**Files:**
- Create: `MatronMac/Features/Coordinator/MacCoordinatorPanelLayout.swift`
- Create: `MatronMac/Features/Coordinator/MacCoordinatorPanelContainer.swift`
- Modify: `MatronMac/Features/Chat/MacChatHeaderAccessory.swift` (model, bar body, link, host)
- Test: `MatronMacTests/MacCoordinatorPanelLayoutTests.swift` (new), `MatronMacTests/MacChatHeaderAccessoryTests.swift`

**Interfaces:**
- Produces: `enum MacCoordinatorPanelLayout { static let minWidth = 320, idealWidth = 380, maxWidth = 720, detailMinWidth = 420; enum Mode { case closed, beside, overlay }; static func clamp(_:) -> CGFloat; static func mode(isOpen:containerWidth:panelWidth:) -> Mode; static func detailTrailingPadding(mode:panelWidth:) -> CGFloat; static func headerTrailingInset(isOpen:panelWidth:) -> CGFloat; static func resized(from:translation:) -> CGFloat }`; `struct MacCoordinatorPanelContainer<Detail: View, Panel: View>: View { init(isOpen: Bool, width: Binding<Double>, detail: () -> Detail, panel: () -> Panel) }`; `MacChatHeaderHost(trailingInset: CGFloat = 0) { … }`; `MacChatHeaderModel.trailingInset`.

- [ ] **Step 1: Write the failing tests**

`MatronMacTests/MacCoordinatorPanelLayoutTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac

private final class Counter { var appears = 0; var width: CGFloat = 0 }

private struct DetailProbe: View {
    let counter: Counter
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { counter.appears += 1; counter.width = geo.size.width }
                .onChange(of: geo.size.width) { _, width in counter.width = width }
        }
    }
}

private final class PanelModel: ObservableObject {
    @Published var isOpen = true
    @Published var width: Double = 380
}

private struct Harness: View {
    @ObservedObject var model: PanelModel
    let counter: Counter
    var body: some View {
        MacCoordinatorPanelContainer(isOpen: model.isOpen, width: $model.width) {
            DetailProbe(counter: counter)
        } panel: {
            Color.gray
        }
    }
}

@MainActor
final class MacCoordinatorPanelLayoutTests: XCTestCase {
    func test_clampKeepsTheSpecMinimum() {
        XCTAssertEqual(MacCoordinatorPanelLayout.clamp(100), 320)
        XCTAssertEqual(MacCoordinatorPanelLayout.clamp(380), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.clamp(5000), MacCoordinatorPanelLayout.maxWidth)
        XCTAssertEqual(MacCoordinatorPanelLayout.idealWidth, 380)
    }

    func test_modeSitsBesideUntilTheDetailWouldDropUnderItsMinimum() {
        XCTAssertEqual(MacCoordinatorPanelLayout.mode(isOpen: false, containerWidth: 1200, panelWidth: 380), .closed)
        XCTAssertEqual(MacCoordinatorPanelLayout.mode(isOpen: true, containerWidth: 800, panelWidth: 380), .beside)
        XCTAssertEqual(MacCoordinatorPanelLayout.mode(isOpen: true, containerWidth: 799, panelWidth: 380), .overlay)
    }

    func test_paddingAndInsetPerMode() {
        XCTAssertEqual(MacCoordinatorPanelLayout.detailTrailingPadding(mode: .beside, panelWidth: 380), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.detailTrailingPadding(mode: .overlay, panelWidth: 380), 0)
        XCTAssertEqual(MacCoordinatorPanelLayout.detailTrailingPadding(mode: .closed, panelWidth: 380), 0)
        XCTAssertEqual(MacCoordinatorPanelLayout.headerTrailingInset(isOpen: true, panelWidth: 380), 380)
        XCTAssertEqual(MacCoordinatorPanelLayout.headerTrailingInset(isOpen: false, panelWidth: 380), 0)
    }

    func test_dragOfTheLeadingEdgeResizes() {
        XCTAssertEqual(MacCoordinatorPanelLayout.resized(from: 380, translation: -50), 430, "dragging left widens")
        XCTAssertEqual(MacCoordinatorPanelLayout.resized(from: 380, translation: 200), 320, "never under the minimum")
    }

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    func test_besideThePanel_theDetailGetsTheRest_andOverlaysWhenNarrow() async {
        let counter = Counter()
        let window = mount(Harness(model: PanelModel(), counter: counter), width: 1000)
        await Self.settle(window)
        XCTAssertEqual(counter.width, 620, accuracy: 1)
        window.setContentSize(NSSize(width: 700, height: 400))
        await Self.settle(window)
        XCTAssertEqual(counter.width, 700, accuracy: 1, "under 420 pt of detail the panel overlays instead")
    }

    /// Review focus: toggling or resizing the panel must not remount the
    /// transcript underneath.
    func test_togglingThePanel_neverRemountsTheDetail() async {
        let counter = Counter()
        let model = PanelModel()
        let window = mount(Harness(model: model, counter: counter), width: 1000)
        await Self.settle(window)
        model.isOpen = false
        await Self.settle(window)
        model.isOpen = true
        model.width = 500
        await Self.settle(window)
        XCTAssertEqual(counter.appears, 1)
    }

    /// A real window: a windowless `NSHostingView` does not reliably run
    /// `onAppear`.
    private func mount<V: View>(_ view: V, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: width, height: 400))
        window.orderFront(nil)
        self.window = window
        return window
    }

    private static func settle(_ window: NSWindow) async {
        let end = Date().addingTimeInterval(0.4)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
```

Append to `MacChatHeaderAccessoryTests` — add `@Published var trailingInset: CGFloat = 0` to `HarnessModel`, change the harness's detail to `MacChatHeaderHost(trailingInset: model.trailingInset) { detail }`, and add:

```swift
    /// Spec §3b: with the Coordinator panel open the header keeps its
    /// capsules over the detail, clear of the panel below the title bar.
    func test_trailingInset_keepsTheCapsulesOffThePanel() async throws {
        let (window, model) = makeWindow()
        defer { window.close() }
        model.trailingInset = 380
        let accessory = try await settledAccessory(in: window, roomID: "room-a")
        let reported = await Self.poll(seconds: 10) { accessory.hitRegions.capsules.count >= 2 }
        XCTAssertTrue(reported)
        let rightmost = accessory.hitRegions.capsules.map(\.maxX).max() ?? .infinity
        XCTAssertLessThanOrEqual(rightmost, accessory.view.frame.width - 380 + 1)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate`, then the Mac test command with `-only-testing:MatronMacTests/MacCoordinatorPanelLayoutTests -only-testing:MatronMacTests/MacChatHeaderAccessoryTests`.
Expected: build FAIL — `cannot find 'MacCoordinatorPanelLayout' in scope`.

- [ ] **Step 3: Implement**

`MatronMac/Features/Coordinator/MacCoordinatorPanelLayout.swift`:

```swift
import CoreGraphics

/// Geometry of the window's Coordinator panel (Coordinator redesign §3b).
/// Pure so the rules are testable without a window.
enum MacCoordinatorPanelLayout {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 380
    static let maxWidth: CGFloat = 720
    /// The detail's floor beside the panel: `MacChatView`'s chat column
    /// minimum (420). Below it the panel overlays instead of squeezing.
    static let detailMinWidth: CGFloat = 420

    enum Mode: Equatable { case closed, beside, overlay }

    static func clamp(_ width: CGFloat) -> CGFloat { min(max(width, minWidth), maxWidth) }

    static func mode(isOpen: Bool, containerWidth: CGFloat, panelWidth: CGFloat) -> Mode {
        guard isOpen else { return .closed }
        return containerWidth - clamp(panelWidth) >= detailMinWidth ? .beside : .overlay
    }

    /// Trailing padding for the detail: the panel's width beside it, none
    /// under an overlay or with the panel closed.
    static func detailTrailingPadding(mode: Mode, panelWidth: CGFloat) -> CGFloat {
        mode == .beside ? clamp(panelWidth) : 0
    }

    /// How far the chat header keeps its capsules from the window's
    /// trailing edge: the panel's width whenever the panel shows.
    static func headerTrailingInset(isOpen: Bool, panelWidth: CGFloat) -> CGFloat {
        isOpen ? clamp(panelWidth) : 0
    }

    /// Width after dragging the panel's LEADING edge by `translation`
    /// (positive = rightwards, which narrows the panel).
    static func resized(from start: CGFloat, translation: CGFloat) -> CGFloat {
        clamp(start - translation)
    }
}
```

`MatronMac/Features/Coordinator/MacCoordinatorPanelContainer.swift`:

```swift
import SwiftUI
import AppKit

/// The detail column with the Coordinator panel at its trailing edge
/// (Coordinator redesign §3b). Sits OUTSIDE the per-nav detail content, so
/// the panel survives moving between Conversations, Missions and Decisions
/// and every Back/Forward. The detail keeps one structural position open
/// or closed (a `ZStack` child with trailing padding), so toggling or
/// resizing the panel never remounts the transcript. No `NavigationStack`
/// in here: inside a `NavigationSplitView` detail it would push onto the
/// column's own stack (#2608).
struct MacCoordinatorPanelContainer<Detail: View, Panel: View>: View {
    let isOpen: Bool
    @Binding var width: Double
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let panel: () -> Panel

    @State private var dragStart: CGFloat?

    init(isOpen: Bool, width: Binding<Double>,
         @ViewBuilder detail: @escaping () -> Detail, @ViewBuilder panel: @escaping () -> Panel) {
        self.isOpen = isOpen
        self._width = width
        self.detail = detail
        self.panel = panel
    }

    var body: some View {
        GeometryReader { geo in
            let panelWidth = MacCoordinatorPanelLayout.clamp(CGFloat(width))
            let mode = MacCoordinatorPanelLayout.mode(isOpen: isOpen, containerWidth: geo.size.width, panelWidth: panelWidth)
            ZStack(alignment: .trailing) {
                detail()
                    .padding(.trailing, MacCoordinatorPanelLayout.detailTrailingPadding(mode: mode, panelWidth: panelWidth))
                if mode != .closed {
                    panelColumn(width: min(panelWidth, geo.size.width), overlay: mode == .overlay)
                }
            }
        }
    }

    private func panelColumn(width: CGFloat, overlay: Bool) -> some View {
        HStack(spacing: 0) {
            resizeHandle
            panel()
        }
        .frame(width: width)
        .background(.background)
        .shadow(color: .black.opacity(overlay ? 0.18 : 0), radius: overlay ? 12 : 0, x: -2)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? CGFloat(width)
                        if dragStart == nil { dragStart = start }
                        width = Double(MacCoordinatorPanelLayout.resized(from: start, translation: value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
    }
}
```

`MacChatHeaderAccessory.swift`:

- `MacChatHeaderModel`: add

```swift
    /// Title-bar width at the trailing edge the header leaves empty: the
    /// Coordinator panel's width while it is open (spec §3b). The accessory
    /// still spans the whole detail column; only the bar is padded.
    var trailingInset: CGFloat = 0
```

- `MacChatHeaderBar.body`:

```swift
    var body: some View {
        bar
            .padding(.trailing, model.trailingInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(MacChatHeaderCapsuleFrames.self) { frames in
                MainActor.assumeIsolated { hitRegions.capsules = frames }
            }
    }
```

- `MacChatHeaderLink`: add `private var latestInset: CGFloat = 0`, set `accessory?.model.trailingInset = latestInset` in `accessory.didSet`, and

```swift
    func publishTrailingInset(_ inset: CGFloat) {
        latestInset = inset
        accessory?.model.trailingInset = inset
    }
```

- `MacChatHeaderHost`:

```swift
struct MacChatHeaderHost<Content: View>: View {
    /// See `MacChatHeaderModel.trailingInset`.
    var trailingInset: CGFloat = 0
    @ViewBuilder let content: Content
    @State private var link = MacChatHeaderLink()

    var body: some View {
        let link = link
        let inset = trailingInset
        content
            .onChange(of: inset, initial: true) { link.publishTrailingInset(inset) }
            .background {
                GeometryReader { geo in
                    MacChatHeaderAccessoryInstaller(link: link, width: geo.size.width)
                }
            }
            .onPreferenceChange(MacChatToolbarPreference.self) { props in
                MainActor.assumeIsolated { link.publish(props) }
            }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodegen generate`, then the Mac test command with `-only-testing:MatronMacTests/MacCoordinatorPanelLayoutTests -only-testing:MatronMacTests/MacChatHeaderAccessoryTests -only-testing:MatronMacTests/MacHistoryToolbarTests`.
Expected: "Executed N tests, with 0 failures".

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Coordinator/MacCoordinatorPanelLayout.swift MatronMac/Features/Coordinator/MacCoordinatorPanelContainer.swift \
  MatronMac/Features/Chat/MacChatHeaderAccessory.swift MatronMacTests/MacCoordinatorPanelLayoutTests.swift \
  MatronMacTests/MacChatHeaderAccessoryTests.swift Matron.xcodeproj
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "mac: Coordinator panel container and a header that clears it" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Mac — the Coordinator panel in every window

**Files:**
- Create: `MatronMac/Features/Coordinator/MacCoordinatorPanel.swift`
- Create: `MatronMac/Features/Coordinator/MacCoordinatorToolbarToggle.swift`
- Modify: `MatronMac/Features/Chat/MacChatView.swift` — new property after `onOpenMission` (`:412`), hidden ⌘K button (`:1321-1326`), bus receivers (`:1335-1345`)
- Modify: `MatronMac/App/Commands.swift` — `MacNavigationActions`, Go menu, Reset Font Size shortcut
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` — state, `splitView`, `detailContent` search hits (`:289-317`), `showConversation`, `navigationActions`, new `withCoordinatorPanel`, `body`, `MacChatSidebarList.onSummariesChange` source, `allChatSummaries`
- Test: `MatronMacTests/MacCoordinatorPanelTests.swift` (new), `MatronMacTests/MacMissionsNavTests.swift`, `MatronMacTests/MacHistoryToolbarTests.swift`

**Interfaces:**
- Consumes: `MacCoordinatorPanelContainer`, `MacCoordinatorPanelLayout`, `MacChatHeaderHost(trailingInset:)` (Task 13); `ChatListViewModel.hiddenConversationID` / `hiddenSummary` / `allSummaries` (Task 7); `deps.setCoordinator` (Task 5).
- Produces: `MacChatView.respondsToMenuCommands: Bool = true`; `struct MacCoordinatorPanel: View`; `struct MacCoordinatorPanelHeader: View { static func title(for: MacChatToolbarProps?) -> String }`; `struct MacCoordinatorToolbarToggle: ToolbarContent`; `MacNavigationActions.isCoordinatorOpen: Bool = false`, `.toggleCoordinator: (() -> Void)? = nil`; `enum MacChatListView.ConversationTarget { case panel, detail }`, `static func conversationTarget(_:coordinatorConvoID:) -> ConversationTarget`.

- [ ] **Step 1: Write the failing tests**

`MatronMacTests/MacCoordinatorPanelTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class PanelTimeline: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> { AsyncThrowingStream { _ in } }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class PanelMedia: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

private final class PanelChat: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class MacCoordinatorPanelTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    private func chat(_ roomID: String, respondsToMenuCommands: Bool) -> (MacChatView, ComposerViewModel) {
        let timeline = PanelTimeline()
        let chatVM = ChatViewModel(roomID: roomID, timeline: timeline, media: PanelMedia())
        let composer = ComposerViewModel(roomID: roomID, timeline: timeline, commands: [])
        let strip = SubChatStripViewModel(chat: PanelChat(), parentConvoID: roomID)
        let view = MacChatView(viewModel: chatVM, composerVM: composer, stripViewModel: strip,
                               subChatProvider: { _ in (chatVM, strip) }, chatTitle: roomID,
                               respondsToMenuCommands: respondsToMenuCommands)
        return (view, composer)
    }

    /// Review focus: with the panel open two chats are on screen; the menu
    /// bus (⌘K Slash Command, ⌘R) must reach the main chat only.
    func test_panelChat_ignoresMenuBusCommands_mainChatStillAnswers() async {
        let (main, mainComposer) = chat("main", respondsToMenuCommands: true)
        let (panel, panelComposer) = chat("coord", respondsToMenuCommands: false)
        let host = NSHostingController(rootView: HStack { main; panel }.frame(width: 1000, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        self.window = window
        try? await Task.sleep(nanoseconds: 500_000_000)

        NotificationCenter.default.post(name: .matronCommand(.slashCommand), object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(mainComposer.palettePinnedOpen)
        XCTAssertFalse(panelComposer.palettePinnedOpen)
    }

    func test_panelHeaderTitle_fallsBackToCoordinator() {
        XCTAssertEqual(MacCoordinatorPanelHeader.title(for: nil), "Coordinator")
    }
}
#endif
```

Append to `MacMissionsNavTests`:

```swift
    /// Spec §3b: a search hit, notification tap, milestone jump or "Open
    /// conversation" into the Coordinator's conversation opens the panel;
    /// every other conversation opens in the detail.
    func testConversationTarget_opensTheCoordinatorInThePanel() {
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: "c-coord"), .panel)
        XCTAssertEqual(MacChatListView.conversationTarget("c-other", coordinatorConvoID: "c-coord"), .detail)
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: nil), .detail)
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: ""), .detail)
    }
```

In `MacHistoryToolbarTests`, give `ShellToolbarHarness` the toggle and the container, and add a title-bar test:

```swift
private struct ShellToolbarHarness: View {
    let history: MacNavigationHistory
    let strip: SubChatStripViewModel
    var panelOpen = false

    var body: some View {
        NavigationSplitView {
            List { Text("sidebar") }
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 472, ideal: 472, max: 472)
                .toolbar {
                    MacHistoryToolbarItems(history: history, goBack: {}, goForward: {})
                    MacCoordinatorToolbarToggle(isOpen: panelOpen, toggle: {})
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) { Button("New") {} }
                }
        } detail: {
            MacChatHeaderHost(trailingInset: MacCoordinatorPanelLayout.headerTrailingInset(isOpen: panelOpen, panelWidth: 380)) {
                MacCoordinatorPanelContainer(isOpen: panelOpen, width: .constant(380)) {
                    Color.clear.preference(key: MacChatToolbarPreference.self, value: MacChatToolbarProps(
                        roomID: "r", publisher: UUID(), title: "Chat", boxName: nil, styledTitle: nil,
                        accessibilityTitle: nil, status: nil, stripViewModel: strip, missionID: nil,
                        needsYouCount: 0, itemsAvailable: true,
                        actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                                       showMediaBrowser: .constant(false), showItemsPane: .constant(false))))
                } panel: {
                    Color.gray
                }
            }
        }
    }
}
```

In `test_chevrons_areVisibleInTheSidebarSection_notFoldedIntoOverflow` change the expectation to `XCTAssertGreaterThanOrEqual(visibleButtons.count, 3, "Back, Forward and the Coordinator toggle must be visible inside the 472 pt sidebar section")`, and add:

```swift
    /// Spec testing: with the panel open the title bar stays 52 pt and no
    /// toolbar item is folded into »; the header clears the panel.
    func test_panelOpen_keepsTheTitleBar_andNothingOverflows() async throws {
        let strip = SubChatStripViewModel(chat: NoChildrenChat(), parentConvoID: "p")
        let host = NSHostingController(rootView: ShellToolbarHarness(history: MacNavigationHistory(), strip: strip, panelOpen: true))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1300, height: 600))
        window.orderFront(nil)
        defer { window.close() }

        let end = Date().addingTimeInterval(3)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        let titleBar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThanOrEqual(titleBar, MacChatHeaderAccessory.height)
        XCTAssertFalse(Self.hasClippedIndicator(in: window.contentView?.superview))
        let header = try XCTUnwrap(MacChatHeaderAccessory.existing(in: window))
        XCTAssertEqual(header.model.trailingInset, 380)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate`, then the Mac test command with `-only-testing:MatronMacTests/MacCoordinatorPanelTests -only-testing:MatronMacTests/MacMissionsNavTests -only-testing:MatronMacTests/MacHistoryToolbarTests`.
Expected: build FAIL — `extra argument 'respondsToMenuCommands' in call`.

- [ ] **Step 3: Implement**

`MacChatView.swift` — directly after `var onOpenMission: ((String) -> Void)? = nil`:

```swift
    /// `false` for the Coordinator panel's chat (Coordinator redesign §3b):
    /// with two chats on screen the menu bus (⌘K Slash Command, ⌘R) must
    /// reach the main chat only, and a second hidden ⌘K button would race it.
    var respondsToMenuCommands: Bool = true
```

Hidden ⌘K button:

```swift
        .background {
            if respondsToMenuCommands {
                Button("") { composerVM.palettePinnedOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
```

Bus receivers — first line of each closure: `guard respondsToMenuCommands else { return }`.

`MatronMac/Features/Coordinator/MacCoordinatorToolbarToggle.swift`:

```swift
import SwiftUI

/// The Coordinator panel's toolbar button (Coordinator redesign §3b). In
/// the SIDEBAR column's `.toolbar` with `.automatic` placement, beside
/// Back/Forward: an item under the chat header accessory would be clipped
/// into the `»` overflow (#2608).
struct MacCoordinatorToolbarToggle: ToolbarContent {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: toggle) { Image(systemName: "person.crop.circle.badge.checkmark") }
                .help(isOpen ? "Hide Coordinator (⌘0)" : "Show Coordinator (⌘0)")
                .accessibilityLabel(isOpen ? "Hide Coordinator" : "Show Coordinator")
        }
    }
}
```

`MatronMac/Features/Coordinator/MacCoordinatorPanel.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// The Coordinator panel's content (Coordinator redesign §3b): a compact
/// header over the Coordinator's `MacChatView`, or the chooser when none is
/// set. The chat's own header props are captured here and drawn in the
/// panel header — and stopped from reaching `MacChatHeaderHost`, which must
/// show the MAIN chat. Its pane route (Tasks toggle, sub-chat) is local:
/// the panel is not part of Back/Forward.
struct MacCoordinatorPanel: View {
    let coordinatorConvoID: String?
    let chatListVM: ChatListViewModel
    /// The panel's own cache: the main detail's LRU would evict (and stop)
    /// this on-screen view model after eight other rooms.
    let vmCache: ChatVMCache
    let onChoose: () -> Void
    let onClose: () -> Void
    let onOpenConversation: (String) -> Void
    let onOpenMission: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var paneRoute: MacChatPaneRoute?
    @State private var headerProps: MacChatToolbarProps?

    var body: some View {
        VStack(spacing: 0) {
            MacCoordinatorPanelHeader(props: headerProps, onClose: onClose)
            Divider()
            content
        }
        .frame(maxHeight: .infinity)
        // A new Coordinator starts with its pane closed and a fresh header.
        .onChange(of: coordinatorConvoID) { _, _ in
            paneRoute = nil
            headerProps = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let id = coordinatorConvoID, !id.isEmpty, let deps, let session {
            chat(id: id, deps: deps, session: session)
                .onPreferenceChange(MacChatToolbarPreference.self) { props in
                    MainActor.assumeIsolated { headerProps = props }
                }
                .transformPreference(MacChatToolbarPreference.self) { $0 = nil }
        } else {
            ContentUnavailableView {
                Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
            } description: {
                Text("Pick the conversation that hands out your work as missions.")
            } actions: {
                Button("Choose a conversation…", action: onChoose)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func chat(id: String, deps: AppDependencies, session: UserSession) -> some View {
        let summary = chatListVM.hiddenSummary?.id == id ? chatListVM.hiddenSummary : nil
        let (chatVM, composerVM) = vmCache.viewModels(for: id, deps: deps, session: session)
        MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            stripViewModel: vmCache.stripViewModel(forParent: id, deps: deps, session: session),
            subChatProvider: { childID in
                let parent = deps.parentConvoID(of: childID, for: session) ?? id
                return vmCache.subChatViewModels(for: childID, parentConvoID: parent, deps: deps, session: session)
            },
            paneRoute: $paneRoute,
            chatTitle: summary?.title ?? "",
            boxName: summary?.boxName,
            sessionShort: summary?.sessionShort,
            boxShort: summary?.boxShort,
            roomBoxNames: summary?.roomBoxNames ?? [],
            roomBoxShorts: summary?.roomBoxShorts ?? [],
            onOpenConversation: onOpenConversation,
            onOpenMission: onOpenMission,
            respondsToMenuCommands: false
        )
        .id(id)
    }
}

/// The panel's header row: the Coordinator's title, its media + Tasks
/// capsule (the chat's own Tasks toggle, spec §3b) and a close button.
struct MacCoordinatorPanelHeader: View {
    let props: MacChatToolbarProps?
    let onClose: () -> Void

    static func title(for props: MacChatToolbarProps?) -> String {
        guard let title = props?.title, !title.isEmpty else { return "Coordinator" }
        return title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
            Text(Self.title(for: props)).font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let props {
                MacChatToolbar(props: props).buttonsItem
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Hide Coordinator (⌘0)")
                .accessibilityLabel("Hide Coordinator")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}
```

`Commands.swift`:

```swift
struct MacNavigationActions {
    var canGoBack: Bool
    var canGoForward: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    /// The key window's Coordinator panel (spec §3b) — per window, like
    /// Back/Forward, so never a bus command.
    var isCoordinatorOpen: Bool = false
    var toggleCoordinator: (() -> Void)? = nil
}
```

Go menu, after Forward:

```swift
            Divider()
            Button(navigation?.isCoordinatorOpen == true ? "Hide Coordinator" : "Coordinator") {
                navigation?.toggleCoordinator?()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(navigation?.toggleCoordinator == nil)
```

and remove `.keyboardShortcut("0", modifiers: .command)` from "Reset Font Size" (its listener never landed; ⌘0 is the Coordinator's now).

`MacChatListView.swift`:

State (next to `showingCoordinatorChooser`):

```swift
    /// The Coordinator panel (spec §3b), per window: `SceneStorage` restores
    /// each window's own open/closed and width.
    @SceneStorage("coordinator.panel.open") private var coordinatorPanelOpen = false
    @SceneStorage("coordinator.panel.width") private var coordinatorPanelWidth: Double = Double(MacCoordinatorPanelLayout.idealWidth)
    /// The panel chat's own view models — see `MacCoordinatorPanel.vmCache`.
    @State private var coordinatorVMCache = ChatVMCache()
```

`allChatSummaries` → `viewModel.allSummaries` (search seeds and stale-restore see the Coordinator too); `MacChatSidebarList`'s `.onChange(of: viewModel.groups, initial: true)` body → `onSummariesChange(viewModel.allSummaries)`.

`splitView` toolbar: insert `MacCoordinatorToolbarToggle(isOpen: coordinatorPanelOpen) { toggleCoordinatorPanel() }` right after `MacHistoryToolbarItems(...)`. `detail:` becomes:

```swift
        } detail: {
            MacChatHeaderHost(trailingInset: coordinatorHeaderInset) {
                MacCoordinatorPanelContainer(isOpen: coordinatorPanelOpen, width: $coordinatorPanelWidth) {
                    detailContent
                } panel: {
                    coordinatorPanel
                }
            }
        }
```

Helpers:

```swift
    private var coordinatorHeaderInset: CGFloat {
        MacCoordinatorPanelLayout.headerTrailingInset(isOpen: coordinatorPanelOpen, panelWidth: CGFloat(coordinatorPanelWidth))
    }

    private func toggleCoordinatorPanel() { coordinatorPanelOpen.toggle() }

    private var coordinatorPanel: some View {
        MacCoordinatorPanel(
            coordinatorConvoID: coordinatorConvoID, chatListVM: viewModel, vmCache: coordinatorVMCache,
            onChoose: { showingCoordinatorChooser = true },
            onClose: { coordinatorPanelOpen = false },
            onOpenConversation: openFromCoordinator,
            onOpenMission: { showMission($0, from: nil) })
    }

    /// "Open" on a session the Coordinator started: shown in the detail,
    /// the panel stays.
    private func openFromCoordinator(_ roomID: String) {
        guard let deps, let session else { return }
        Task { @MainActor in
            await deps.prepareConversation(for: session, id: roomID)
            showConversation(roomID)
        }
    }

    /// Where "show me that conversation" lands (spec §3b). A pure helper so
    /// `MacMissionsNavTests` pins it.
    enum ConversationTarget: Equatable { case panel, detail }

    static func conversationTarget(_ convoID: String, coordinatorConvoID: String?) -> ConversationTarget {
        if let coordinatorConvoID, !coordinatorConvoID.isEmpty, convoID == coordinatorConvoID { return .panel }
        return .detail
    }

    /// Coordinator wiring: the list filter, the chooser and its error.
    /// Its own helper for CI's Xcode 16.4 type-checker budget.
    private func withCoordinatorPanel(_ content: some View) -> some View {
        content
            .onChange(of: coordinatorConvoID, initial: true) { _, id in viewModel.hiddenConversationID = id }
    }
```

Move the chooser `.sheet` + `.alert` from Task 5 out of `withNavigationListeners` into `withCoordinatorPanel` (after the `.onChange`). `body` → `withLifecycle(withCoordinatorPanel(withNavigationListeners(withCommandListeners(splitView))))`.

`showConversation`:

```swift
    private func showConversation(_ convoID: String) {
        if Self.conversationTarget(convoID, coordinatorConvoID: coordinatorConvoID) == .panel {
            coordinatorPanelOpen = true
            if searchQueryIsEmpty == false { searchModel?.query = "" }
            return
        }
        nav = .conversations
        if searchQueryIsEmpty == false { searchModel?.query = "" }
        selectedSummaryID = convoID
    }
```

Search hits in `detailContent` — `onSelectChat` becomes `showConversation(chat.id)` (after its log line), and `onSelectMessage`:

```swift
                    onSelectMessage: { group in
                        listLogger.notice("selection set by search-message-hit: \(group.roomID, privacy: .public)")
                        let query = searchModel.trimmedQuery
                        showConversation(group.roomID)
                        // Only top-level chats get the bar (review 2026-08-26);
                        // the Coordinator's view model lives in the panel's cache.
                        if let deps, let session,
                           allChatSummaries.contains(where: { $0.id == group.roomID }) {
                            let cache = group.roomID == coordinatorConvoID ? coordinatorVMCache : vmCache
                            let (chat, _) = cache.viewModels(for: group.roomID, deps: deps, session: session)
                            Task { await chat.beginChatSearch(query: query) }
                        }
                    }
```

`navigationActions`:

```swift
    private var navigationActions: MacNavigationActions {
        MacNavigationActions(canGoBack: history.canGoBack, canGoForward: history.canGoForward,
                             goBack: { goBack() }, goForward: { goForward() },
                             isCoordinatorOpen: coordinatorPanelOpen,
                             toggleCoordinator: { toggleCoordinatorPanel() })
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodegen generate`, then the Mac test command with `-only-testing:MatronMacTests/MacCoordinatorPanelTests -only-testing:MatronMacTests/MacMissionsNavTests -only-testing:MatronMacTests/MacHistoryToolbarTests -only-testing:MatronMacTests/MacChatListViewTests -only-testing:MatronMacTests/MacSidebarWidthTests -only-testing:MatronMacTests/MacItemsPaneStackTests -only-testing:MatronMacTests/MacPaneRouteSyncTests`.
Expected: "Executed N tests, with 0 failures".
Manual (Release build per the install memo, on a copy of nothing — just run it): ⌘0 opens the panel at 380 pt; switch Conversations → Missions → Decisions and Back/Forward — the panel and its scroll position stay; drag its edge (stops at 320); narrow the window — it overlays; close and reopen the window — width and open state return; the Tasks capsule in the panel header opens the Coordinator's steps inside the panel; the Coordinator is not in the Conversations list; a search hit on its title opens the panel; nothing sits in `»`.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Coordinator MatronMac/Features/Chat/MacChatView.swift MatronMac/App/Commands.swift \
  MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/MacCoordinatorPanelTests.swift \
  MatronMacTests/MacMissionsNavTests.swift MatronMacTests/MacHistoryToolbarTests.swift Matron.xcodeproj
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit \
  -m "mac: Coordinator panel beside every window (toolbar, Go ▸ Coordinator, ⌘0)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Whole-branch verification

**Files:** none new (fixes only, in the task that owns the code).

- [ ] **Step 1: Stale-reference sweep**

Run: `grep -rn "CoordinatorTabView\|MacCoordinatorToolbarPlaceholder\|showCoordinator\|navForShowingConversation\|redirectCoordinatorPush\|coordinatorHeaderActions\|MacHeaderHistoryCluster\|\.coordinator(pane" --include=*.swift . | grep -v "/docs/"`
Expected: no output.

- [ ] **Step 2: Shared package**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test 2>&1 | tail -5`
Expected: "Executed N tests, with 0 failures" (rerun once if it stalls at 0% CPU — known `swift test` hang).

- [ ] **Step 3: iOS**

Run: `xcodegen generate && set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: "** TEST SUCCEEDED **" and "Executed N tests, with 0 failures".

- [ ] **Step 4: Mac**

Run: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: "** TEST SUCCEEDED **".

- [ ] **Step 5: End-to-end smoke (needs the journal and bridge from their plans deployed)**

On the Mac, Settings → Coordinator → Choose… → New coordinator chat… on a box: the start request carries `"model":"opus[1m]"` (bridge log), the chat shows "This chat is now the Coordinator", the iPhone adopts it within one reconnect (sheet title matches) and neither Conversations list shows it. Ask it for a three-part job: three missions appear under **Unassigned** "from Coordinator" on both apps; after it starts a session on one, that mission leaves Unassigned. Clear the Coordinator on the iPhone; relaunch the Mac: it stays cleared.

- [ ] **Step 6: Commit any fixes** with the owning task's message style, then hand off for review.
