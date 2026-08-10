# Agent Box Rename — Apple Apps Implementation Plan (3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Repo:** `matron-apple`. Spec: `docs/superpowers/specs/2026-08-10-agent-box-rename-design.md`.

**Depends on:** plan 1 (journal) being deployed, or at least merged — the new
snapshot fields, `device_meta` frame and rename endpoint come from there. The
app code degrades safely against an older server (absent fields → no chips,
rename → 404).

**Goal:** Render which agent box owns each conversation as a live chip, and
let the user rename a box from Settings → Devices.

**Architecture:** The store learns two new things — `conversation.agent_device_id`
and an `agent` id→name table — from `GET /snapshot`, live `convo_meta` events,
and a new `device_meta` frame. `JournalChatService` joins them when building
`ChatSummary`, applying the "only when the user has ≥2 boxes" gate in one
place so every view stays dumb. The chip renders in the Mac and iOS chat-list
rows and in the chat header. Rename is a new `DevicesProviding` method with
UI on both Devices screens.

**Tech Stack:** Swift 6, SwiftUI, GRDB, swift-testing/XCTest in
`MatronShared/Tests`, XcodeGen (`xcodegen generate` before building the apps).

## Global Constraints

- **NEVER run `MatronMacTests` without `MATRON_APP_SUPPORT_OVERRIDE` set** —
  the test host has wiped the live journal store before. Prefer
  `swift test` in `MatronShared/`.
- Local shared-package test command:
  `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`
- The chip shows **only when the user has ≥2 agent boxes**. Single-box users
  see no chip anywhere. An unknown or nil `agent_device_id` (e.g. a revoked
  box) shows no chip.
- Device-name cap on the client is **40 characters**, matching the server's
  rejection threshold; the field prevents longer input rather than letting
  the server 400.
- Additive GRDB migration only (`v5`) — existing rows survive with NULL.
- Absent wire fields must never clear a value the client already learned
  (the `parent_convo_id` discipline in `upsertSummary`).

---

### Task 1: Store learns the owning box

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift`
  (`ConvoSummaryDTO` ~7-34, `ConversationRecord` ~36-66, migrations ~214-280,
  `upsertSummary` ~374-407, `convo_meta` apply ~496-515)
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift`
  (`SnapshotResponse` ~9-12, `snapshot()` ~272-291)
- Test: `MatronShared/Tests/JournalTests/JournalStoreTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ConvoSummaryDTO.agentDeviceID: Int64?` (init parameter
    `agentDeviceID: Int64? = nil`, last)
  - `ConversationRecord.agentDeviceID: Int64?` (column `agent_device_id`)
  - `AgentDTO { let id: Int64; let name: String }` in `JournalAPI.swift`
  - `SnapshotResponse.agents: [AgentDTO]`
  - GRDB migration `v5`: adds `conversation.agent_device_id`, creates table
    `agent(id INTEGER PRIMARY KEY, name TEXT NOT NULL)`
  - `JournalStore.conversation(id: String) throws -> ConversationRecord?` —
    single-row accessor (the store has `conversations()` and
    `conversationExists(_:)` but no by-id fetch; Task 5's resolver needs one)

- [ ] **Step 1: Write the failing test**

Append to `MatronShared/Tests/JournalTests/JournalStoreTests.swift`:

```swift
@Test func snapshotAndConvoMetaRecordTheOwningBox() throws {
    let store = try JournalStore(url: nil)
    try store.applyColdSnapshot([
        ConvoSummaryDTO(id: "c1", title: "Fix the parser", sessionState: "running",
                        lastSeq: 5, snippet: "", createdAt: 1, agentDeviceID: 7),
        ConvoSummaryDTO(id: "c2", title: "No box", sessionState: "running",
                        lastSeq: 6, snippet: "", createdAt: 1),
    ], headSeq: 6)

    #expect(try store.conversation(id: "c1")?.agentDeviceID == 7)
    #expect(try store.conversation(id: "c2")?.agentDeviceID == nil)

    // A later snapshot that omits the field must not clear what we know.
    try store.refreshSummaries([
        ConvoSummaryDTO(id: "c1", title: "Fix the parser", sessionState: "running",
                        lastSeq: 7, snippet: "", createdAt: 1),
    ])
    #expect(try store.conversation(id: "c1")?.agentDeviceID == 7)

    // A live convo_meta teaches the linkage for a convo we have never seen.
    let meta = JournalEvent(
        seq: 8, convoID: "c3", ts: Date(), sender: "agent:dev-y", type: "convo_meta",
        payloadData: try JSONSerialization.data(withJSONObject: [
            "title": "Brand new", "agent_device_id": 9,
        ]))
    try store.applyJournal(meta)
    #expect(try store.conversation(id: "c3")?.agentDeviceID == 9)

    // Re-pointing IS allowed: a session resumed on another box legitimately
    // changes owner, unlike parent_convo_id which is immutable.
    let moved = JournalEvent(
        seq: 9, convoID: "c3", ts: Date(), sender: "agent:dev-z", type: "convo_meta",
        payloadData: try JSONSerialization.data(withJSONObject: [
            "title": "Brand new", "agent_device_id": 11,
        ]))
    try store.applyJournal(moved)
    #expect(try store.conversation(id: "c3")?.agentDeviceID == 11)
}
```

`conversation(id:)` does not exist yet — Step 3 adds it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter snapshotAndConvoMetaRecordTheOwningBox`
Expected: FAIL to compile — `ConvoSummaryDTO` has no `agentDeviceID` parameter.

- [ ] **Step 3: Add the fields and migration**

In `JournalStore.swift`, add to `ConvoSummaryDTO` after `parentConvoID`:

```swift
    /// Which agent box (journal device id) currently manages this
    /// conversation, or `nil` when the server has never recorded one (a row
    /// predating the column, or a server predating this field). Unlike
    /// `parentConvoID` this is mutable — resuming a session on another box
    /// legitimately repoints it.
    public let agentDeviceID: Int64?
```

and to its `init` (last parameter, defaulted):

```swift
    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64, lastTS: Int64? = nil, parentConvoID: String? = nil, agentDeviceID: Int64? = nil) {
        …
        self.agentDeviceID = agentDeviceID
    }
```

Add to `ConversationRecord` after `parentConvoID`:

```swift
    /// The agent box that manages this conversation. Drives the box chip in
    /// the chat list and header. Mutable (see `ConvoSummaryDTO`).
    public var agentDeviceID: Int64?
```

and to `CodingKeys`:

```swift
        case agentDeviceID = "agent_device_id"
```

Register migration `v5` after `v4` (before `try migrator.migrate(dbQueue)`):

```swift
        // v5: agent-box attribution (spec: agent box rename). `agent` is the
        // id -> name mirror of the server's `agents` snapshot list; the
        // conversation column names which of those boxes owns the row.
        // Additive: existing rows keep NULL and simply render no chip until
        // the next snapshot fills them in.
        migrator.registerMigration("v5") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "agent_device_id", .integer)
            }
            try db.create(table: "agent") { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull()
            }
        }
```

In `upsertSummary`, add to the `existing` branch (after the `parentConvoID`
block):

```swift
            // Absent means "this server/row doesn't say", never "clear it" —
            // same discipline as parent_convo_id. Unlike parent, a PRESENT
            // value always wins: ownership legitimately moves between boxes.
            if let box = c.agentDeviceID {
                existing.agentDeviceID = box
            }
```

and to the insert branch's initialiser, after `parentConvoID: c.parentConvoID`:

```swift
                , agentDeviceID: c.agentDeviceID
```

In the `convo_meta` branch of `applyOne`, after the `parent_convo_id` block:

```swift
                // Which box owns this conversation, learned live so a
                // brand-new convo chips immediately. Re-pointed freely: a
                // session resumed on another box changes owner.
                if let box = (payload["agent_device_id"] as? NSNumber)?.int64Value {
                    convo.agentDeviceID = box
                }
```

Every other `ConversationRecord(...)` initialiser in the file needs the new
parameter — compile errors will name them; pass `agentDeviceID: nil`.

Add the single-row accessor beside `conversationExists(_:)` (~line 759):

```swift
    /// One conversation by id, or nil when this device has never seen it.
    /// The store has `conversations()` (whole list, list-filtered) and
    /// `conversationExists(_:)` (a bare bool) but nothing that hands back a
    /// single row — which the box-name resolver needs.
    public func conversation(id: String) throws -> ConversationRecord? {
        try dbQueue.read { db in
            try ConversationRecord.fetchOne(db, key: id)
        }
    }
```

- [ ] **Step 4: Parse the new snapshot fields**

In `JournalAPI.swift`, add above `SnapshotResponse`:

```swift
/// One of the user's agent boxes, as listed by `GET /snapshot`. Just
/// identity and label — the full device row (lag, cursor, last seen) is
/// `DeviceDTO` from `GET /devices`.
public struct AgentDTO: Equatable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}
```

Extend `SnapshotResponse`:

```swift
public struct SnapshotResponse: Equatable, Sendable {
    public let conversations: [ConvoSummaryDTO]
    /// The user's agent boxes, id → name. Empty on a server predating the
    /// field, which simply means no chips.
    public let agents: [AgentDTO]
    public let seq: Int64
}
```

In `snapshot()`, add the field to the `ConvoSummaryDTO` construction:

```swift
                parentConvoID: c["parent_convo_id"] as? String,
                // Which box manages this conversation. Absent on older
                // servers -> nil -> no chip.
                agentDeviceID: (c["agent_device_id"] as? NSNumber)?.int64Value
```

and replace the return:

```swift
        let agents = (obj["agents"] as? [[String: Any]] ?? []).compactMap { a -> AgentDTO? in
            guard let id = (a["device_id"] as? NSNumber)?.int64Value,
                  let name = a["name"] as? String else { return nil }
            return AgentDTO(id: id, name: name)
        }
        return SnapshotResponse(conversations: conversations, agents: agents,
                                seq: (obj["seq"] as? NSNumber)?.int64Value ?? 0)
```

Fix every other `SnapshotResponse(...)` construction the compiler flags
(fakes in tests) with `agents: []`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter JournalStoreTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal MatronShared/Tests/JournalTests
git commit -m "feat(journal): store which agent box owns each conversation"
```

---

### Task 2: Agent roster mirror + live `device_meta`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (new agent-table accessors)
- Modify: `MatronShared/Sources/Journal/WireModels.swift` (`ServerFrame` ~173-207)
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift`
  (frame switch ~839, `refreshSummaries()` ~596-600, `coldStartIfNeeded()` ~1065-1068)
- Test: `MatronShared/Tests/JournalTests/JournalStoreTests.swift`,
  `MatronShared/Tests/JournalTests/WireModelsTests.swift` (append to both)

**Interfaces:**
- Consumes: `AgentDTO`, migration `v5` from Task 1.
- Produces:
  - `JournalStore.replaceAgents(_ agents: [AgentDTO]) throws` — wholesale
    replace (delete-then-insert in one transaction), no-op when `agents` is
    empty so an older server can't wipe a good roster
  - `JournalStore.renameAgent(id: Int64, name: String) throws` — upsert one
  - `JournalStore.agentNames() throws -> [Int64: String]`
  - `ServerFrame.deviceMeta(id: Int64, name: String)`

- [ ] **Step 1: Write the failing tests**

Append to `JournalStoreTests.swift`:

```swift
@Test func agentRosterMirrorsSnapshotAndLiveRenames() throws {
    let store = try JournalStore(url: nil)
    #expect(try store.agentNames().isEmpty)

    try store.replaceAgents([AgentDTO(id: 7, name: "dev-y"), AgentDTO(id: 9, name: "dev-z")])
    #expect(try store.agentNames() == [7: "dev-y", 9: "dev-z"])

    // Wholesale replace: a box revoked server-side disappears here too.
    try store.replaceAgents([AgentDTO(id: 7, name: "dev-y")])
    #expect(try store.agentNames() == [7: "dev-y"])

    // An empty list is "this server doesn't say", not "you have no boxes".
    try store.replaceAgents([])
    #expect(try store.agentNames() == [7: "dev-y"])

    // A live rename patches one row without a re-snapshot.
    try store.renameAgent(id: 7, name: "dev-yellow")
    #expect(try store.agentNames() == [7: "dev-yellow"])

    // A rename for a box we have never seen inserts it.
    try store.renameAgent(id: 12, name: "dev-new")
    #expect(try store.agentNames()[12] == "dev-new")
}
```

Append to `WireModelsTests.swift`:

```swift
@Test func decodesDeviceMetaRenameFrame() {
    let frame = ServerFrame.decode(#"{"kind":"device_meta","device_id":7,"name":"dev-y"}"#)
    #expect(frame == .deviceMeta(id: 7, name: "dev-y"))
    // Malformed frames are skipped, not crashed on.
    #expect(ServerFrame.decode(#"{"kind":"device_meta","name":"dev-y"}"#) == nil)
    #expect(ServerFrame.decode(#"{"kind":"device_meta","device_id":7}"#) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter "agentRosterMirrors|decodesDeviceMeta"`
Expected: FAIL to compile — `replaceAgents` and `.deviceMeta` don't exist.

- [ ] **Step 3: Add the store accessors**

In `JournalStore.swift`, add a `// MARK: Agent roster` section after the
snapshot section:

```swift
    // MARK: Agent roster

    /// Mirrors `GET /snapshot`'s `agents` list. Wholesale replace so a box
    /// revoked server-side stops resolving here too. An EMPTY list is
    /// ignored: a server predating the field sends nothing, and wiping the
    /// roster would silently drop every chip.
    public func replaceAgents(_ agents: [AgentDTO]) throws {
        guard !agents.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM agent")
            for a in agents {
                try db.execute(sql: "INSERT INTO agent(id, name) VALUES(?, ?)",
                               arguments: [a.id, a.name])
            }
        }
    }

    /// Applies one live `device_meta` rename. Upsert, not update: the rename
    /// may name a box this device has not snapshotted yet.
    public func renameAgent(id: Int64, name: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO agent(id, name) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name",
                arguments: [id, name])
        }
    }

    /// id → name for every known box. The chat list joins against this to
    /// label rows, and its COUNT is the "does this user have ≥2 boxes" gate.
    public func agentNames() throws -> [Int64: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM agent")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["name"] as String) })
        }
    }
```

- [ ] **Step 4: Add the frame case and decode**

In `WireModels.swift`, add to `ServerFrame`:

```swift
    /// A device was renamed (`POST /devices/:id/rename`). Transient — not a
    /// journal event, carries no seq. A client that misses it picks the name
    /// up from the next snapshot's `agents` list.
    case deviceMeta(id: Int64, name: String)
```

and to the `switch kind` in `decode`:

```swift
        case "device_meta":
            guard let id = (obj["device_id"] as? NSNumber)?.int64Value,
                  let name = obj["name"] as? String else { return nil }
            return .deviceMeta(id: id, name: name)
```

- [ ] **Step 5: Wire the engine**

In `JournalSyncEngine.swift`, add to the frame `switch` (~line 839, alongside
`case .journal`):

```swift
                    case .deviceMeta(let id, let name):
                        try? store.renameAgent(id: id, name: name)
```

In `refreshSummaries()` after `try? store.refreshSummaries(snapshot.conversations)`:

```swift
        try? store.replaceAgents(snapshot.agents)
```

In `coldStartIfNeeded()` after `try store.applyColdSnapshot(...)`:

```swift
        try store.replaceAgents(snapshot.agents)
```

If the frame `switch` is exhaustive over `ServerFrame`, the compiler will also
flag any other switch on it — handle `deviceMeta` there by ignoring it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter JournalTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Journal MatronShared/Tests/JournalTests
git commit -m "feat(journal): mirror the agent roster and apply live device_meta renames"
```

---

### Task 3: `ChatSummary.boxName` and the ≥2-boxes gate

**Files:**
- Modify: `MatronShared/Sources/Chat/ChatSummary.swift`
- Modify: `MatronShared/Sources/Chat/JournalChatService.swift` (~30-80)
- Test: `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift` (append)

**Interfaces:**
- Consumes: `JournalStore.agentNames()`, `ConversationRecord.agentDeviceID`.
- Produces:
  - `ChatSummary.boxName: String?` (init parameter `boxName: String? = nil`, last)
  - `JournalChatService.summary(from:boxNames:) -> ChatSummary` (static,
    internal — replaces the current `summary(from:)`)
  - Gate rule: `boxName` is non-nil **only** when `boxNames.count >= 2` AND
    the record's `agentDeviceID` resolves in `boxNames`.

- [ ] **Step 1: Write the failing test**

Append to `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift`:

```swift
@Test func boxNameOnlyResolvesWhenTheUserHasTwoOrMoreBoxes() {
    let owned = ConversationRecord(
        id: "c1", title: "Fix the parser", sessionState: "running", lastSeq: 1,
        snippet: "", createdAt: 1, lastActivityTS: 1, muted: false, hidden: false,
        readUpToSeq: 0, unreadCount: 0, parentConvoID: nil, agentDeviceID: 7)
    let orphan = ConversationRecord(
        id: "c2", title: "No box", sessionState: "running", lastSeq: 1,
        snippet: "", createdAt: 1, lastActivityTS: 1, muted: false, hidden: false,
        readUpToSeq: 0, unreadCount: 0, parentConvoID: nil, agentDeviceID: nil)

    // One box: no chip anywhere — a single-box user has nothing to
    // disambiguate and shouldn't pay for the clutter.
    #expect(JournalChatService.summary(from: owned, boxNames: [7: "dev-y"]).boxName == nil)

    // Two boxes: the owning box is named.
    let two: [Int64: String] = [7: "dev-y", 9: "dev-z"]
    #expect(JournalChatService.summary(from: owned, boxNames: two).boxName == "dev-y")
    // …but a conversation with no recorded box still shows nothing.
    #expect(JournalChatService.summary(from: orphan, boxNames: two).boxName == nil)
    // …and an id that resolves to nothing (revoked box) shows nothing.
    let stale = ConversationRecord(
        id: "c3", title: "Old", sessionState: "done", lastSeq: 1,
        snippet: "", createdAt: 1, lastActivityTS: 1, muted: false, hidden: false,
        readUpToSeq: 0, unreadCount: 0, parentConvoID: nil, agentDeviceID: 999)
    #expect(JournalChatService.summary(from: stale, boxNames: two).boxName == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter boxNameOnlyResolves`
Expected: FAIL to compile — no `boxNames:` parameter, no `boxName` property.

- [ ] **Step 3: Add `boxName` to `ChatSummary`**

In `ChatSummary.swift`, after `parentConvoID`:

```swift
    /// Display name of the agent box that owns this conversation, or `nil`
    /// when no chip should be shown — which covers all three of: the user
    /// has fewer than two boxes (nothing to disambiguate), the conversation
    /// has no recorded box, and the recorded box no longer exists. Resolving
    /// the gate here keeps every row view a dumb renderer.
    public let boxName: String?
```

and to `init` as the last parameter, `boxName: String? = nil`, with
`self.boxName = boxName`.

- [ ] **Step 4: Resolve it in `JournalChatService`**

Replace `summary(from:)` with:

```swift
    /// `boxNames` is the id → name map of the user's agent boxes. The chip
    /// gate lives here: fewer than two boxes means no chip on any row.
    static func summary(from record: ConversationRecord, boxNames: [Int64: String]) -> ChatSummary {
        let activityMS = record.lastActivityTS ?? (record.createdAt > 0 ? record.createdAt : nil)
        return ChatSummary(
            id: record.id,
            title: record.title.isEmpty ? record.id : record.title,
            bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
            lastActivity: activityMS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            unreadCount: record.unreadCount,
            snippet: record.snippet,
            parentConvoID: record.parentConvoID,
            boxName: boxNames.count >= 2 ? record.agentDeviceID.flatMap { boxNames[$0] } : nil
        )
    }
```

In the `chats()` stream's consumer, read the roster once per emission (a
handful of rows; the map is rebuilt only when a snapshot batch lands):

```swift
            let consumer = Task {
                for await records in latest {
                    let boxNames = (try? store.agentNames()) ?? [:]
                    continuation.yield(records.map { Self.summary(from: $0, boxNames: boxNames) })
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ChatTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Chat MatronShared/Tests/ChatTests
git commit -m "feat(chat): resolve the owning box name, gated on having 2+ boxes"
```

---

### Task 4: The chip in both chat lists

**Files:**
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`MacChatRow` ~578-621)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (`ChatRow` ~464-502)
- Create: `MatronShared/Sources/DesignSystem/BoxChip.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift`

**Interfaces:**
- Consumes: `ChatSummary.boxName`.
- Produces: `public struct BoxChip: View { public init(_ name: String) }`.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift`:

```swift
import SwiftUI
import Testing
@testable import MatronDesignSystem

@Suite struct BoxChipTests {
    /// The chip must never grow a row: it renders on the title line, capped
    /// to one line. Rows in this app have a hard fixed-height invariant
    /// (ChatRowHeightTests) that a wrapping chip would break.
    @Test func chipIsSingleLineAndTruncates() {
        let chip = BoxChip("a-very-long-box-name-that-will-not-fit")
        #expect(chip.displayName == "a-very-long-box-name-that-will-not-fit")
        #expect(chip.lineLimit == 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter BoxChipTests`
Expected: FAIL to compile — no `BoxChip`.

- [ ] **Step 3: Create the chip**

Create `MatronShared/Sources/DesignSystem/BoxChip.swift`:

```swift
import SwiftUI

/// The agent box that owns a conversation, as a small capsule beside the
/// title. Shown only when the user has two or more boxes — the decision is
/// made upstream in `JournalChatService`, so this view just renders whatever
/// name it is handed.
///
/// Single-line and truncating by construction: chat rows have a fixed-height
/// invariant (see `ChatRowHeightTests`) and a wrapping chip would break it.
public struct BoxChip: View {
    let displayName: String
    let lineLimit = 1

    public init(_ name: String) {
        self.displayName = name
    }

    public var body: some View {
        Text(displayName)
            .font(.caption2.weight(.medium))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Agent box \(displayName)")
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter BoxChipTests`
Expected: PASS.

- [ ] **Step 5: Render it in the Mac row**

In `MacChatListView.swift`, replace `MacChatRow`'s title line (line 585):

```swift
                HStack(spacing: 6) {
                    Text(summary.title).font(.system(size: 14)).lineLimit(1)
                    if let boxName = summary.boxName {
                        BoxChip(boxName)
                    }
                }
```

Add `import MatronDesignSystem` at the top if it isn't already there.

- [ ] **Step 6: Render it in the iOS row**

In `ChatListView.swift`, replace `ChatRow`'s title line (line 470):

```swift
                HStack(spacing: 6) {
                    Text(summary.title).font(.body).lineLimit(1)
                    if let boxName = summary.boxName {
                        BoxChip(boxName)
                    }
                }
```

- [ ] **Step 7: Build both apps**

Run:
```bash
xcodegen generate
xcodebuild -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' build | tail -5
xcodebuild -scheme MatronMac -destination 'platform=macOS' build | tail -5
```
Expected: `BUILD SUCCEEDED` for both. (This machine has iPhone 17 simulators,
not iPhone 16 — a wrong destination reads as a pass in a piped command.)

- [ ] **Step 8: Verify the row-height invariant still holds**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`
Expected: PASS, `ChatRowHeightTests` included. If row-height tests live in the
app test targets instead, run them with
`xcodebuild test -scheme MatronMac -only-testing:MatronMacTests` **and**
`MATRON_APP_SUPPORT_OVERRIDE` set to a scratch directory — never without it.

- [ ] **Step 9: Commit**

```bash
git add MatronShared/Sources/DesignSystem/BoxChip.swift MatronShared/Tests/DesignSystemSnapshotTests/BoxChipTests.swift MatronMac/Features/ChatList/MacChatListView.swift Matron/Features/ChatList/ChatListView.swift
git commit -m "feat(chat list): show the owning agent box as a chip"
```

---

### Task 5: Box name in the chat header

**Files:**
- Modify: `MatronShared/Sources/Chat/JournalChatService.swift` (add the resolver)
- Modify: `MatronMac/Features/Chat/MacChatToolbar.swift` (`titleSubtitle` ~224-233)
- Modify: `Matron/Features/Chat/SessionStatusSheet.swift` (~54-70)
- Test: `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift` (append),
  `MatronMacTests/MacChatToolbarTests.swift` (append)

**Interfaces:**
- Consumes: `JournalStore.agentNames()`, `ConversationRecord.agentDeviceID`.
- Produces:
  - `JournalChatService.boxName(for record: ConversationRecord?, boxNames: [Int64: String]) -> String?`
    (static, internal — the pure rule, same ≥2 gate as `ChatSummary.boxName`)
  - `JournalChatService.boxName(forConvoID: String) -> String?` (instance,
    public — reads the store and delegates to the static)
  - `MacChatToolbar.boxName: String?`, a stored property placed FIRST in
    `titleSubtitle`'s parts

**Why a static:** `JournalChatService.init` requires a live
`JournalSyncEngine` (`init(store:engine:coalesceInterval:)`), which a unit
test has no business constructing. The rule is pure, so it is tested pure.

- [ ] **Step 1: Write the failing tests**

Append to `JournalChatServiceTests.swift`:

```swift
@Test func boxNameForConvoUsesTheSameTwoBoxGate() {
    let owned = ConversationRecord(
        id: "c1", title: "Fix", sessionState: "running", lastSeq: 1,
        snippet: "", createdAt: 1, lastActivityTS: 1, muted: false, hidden: false,
        readUpToSeq: 0, unreadCount: 0, parentConvoID: nil, agentDeviceID: 7)

    // One box: no chip, same gate as the list rows.
    #expect(JournalChatService.boxName(for: owned, boxNames: [7: "dev-y"]) == nil)
    let two: [Int64: String] = [7: "dev-y", 9: "dev-z"]
    #expect(JournalChatService.boxName(for: owned, boxNames: two) == "dev-y")
    // Unknown conversation (never synced) and unresolvable box both go quiet.
    #expect(JournalChatService.boxName(for: nil, boxNames: two) == nil)
    let stale = ConversationRecord(
        id: "c3", title: "Old", sessionState: "done", lastSeq: 1,
        snippet: "", createdAt: 1, lastActivityTS: 1, muted: false, hidden: false,
        readUpToSeq: 0, unreadCount: 0, parentConvoID: nil, agentDeviceID: 999)
    #expect(JournalChatService.boxName(for: stale, boxNames: two) == nil)
}
```

Append to `MatronMacTests/MacChatToolbarTests.swift`:

```swift
func testTitleSubtitleLeadsWithTheBoxName() {
    let toolbar = MacChatToolbar(title: "Fix the parser", boxName: "dev-y", status: nil)
    XCTAssertEqual(toolbar.titleSubtitle, "dev-y")
}

func testTitleSubtitleOmitsTheBoxNameWhenAbsent() {
    let toolbar = MacChatToolbar(title: "Fix the parser", boxName: nil, status: nil)
    XCTAssertNil(toolbar.titleSubtitle)
}
```

Match the real `MacChatToolbar` initialiser — pass whatever other arguments it
requires; only `boxName` is new.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter boxNameForConvo`
Expected: FAIL to compile — no `boxName(forConvoID:)`.

- [ ] **Step 3: Add the resolver**

In `JournalChatService.swift`:

```swift
    /// The chip rule for a single conversation: named only when the user has
    /// two or more boxes AND this conversation's box resolves. Pure, so it
    /// is unit-testable without a live sync engine.
    static func boxName(for record: ConversationRecord?, boxNames: [Int64: String]) -> String? {
        guard boxNames.count >= 2, let id = record?.agentDeviceID else { return nil }
        return boxNames[id]
    }

    /// The owning box's display name for one conversation, or `nil` when no
    /// chip should show. Synchronous: both callers are view bodies reading a
    /// handful of rows.
    public func boxName(forConvoID convoID: String) -> String? {
        Self.boxName(for: try? store.conversation(id: convoID),
                     boxNames: (try? store.agentNames()) ?? [:])
    }
```

`try? store.conversation(id:)` yields `ConversationRecord??`; flatten it with
`(try? store.conversation(id: convoID)) ?? nil` if the compiler complains.

- [ ] **Step 4: Show it in the Mac toolbar**

In `MacChatToolbar.swift`, add the stored property beside `title`:

```swift
    /// Which agent box this session runs on, or `nil` when the user has
    /// fewer than two boxes (resolved by `JournalChatService.boxName`).
    /// Leads the subtitle: it answers "which machine am I talking to",
    /// which outranks the path and the account.
    let boxName: String?
```

and update `titleSubtitle`:

```swift
    var titleSubtitle: String? {
        var parts: [String] = []
        if let boxName {
            parts.append(boxName)
        }
        if let workdir = status?.workdir {
            parts.append(UsageMetersFormat.homeAbbreviated(workdir))
        }
        if let email = status?.email {
            parts.append(email)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
```

Pass it at the call site (`grep -rn "MacChatToolbar(" MatronMac`) as
`boxName: chatService.boxName(forConvoID: convoID)`.

- [ ] **Step 5: Show it on iOS**

In `SessionStatusSheet.swift`, add a `let boxName: String?` property and
render it as the first line of the metadata block (the `if let workdir`
group at ~line 66):

```swift
                                if let boxName {
                                    Text(boxName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
```

Include `boxName != nil` in the sheet's has-anything-to-show condition at
lines 23 and 54, and pass it at the call site
(`grep -rn "SessionStatusSheet(" Matron`).

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ChatTests
```
and, for the toolbar test, from the repo root with the guard variable set:
```bash
MATRON_APP_SUPPORT_OVERRIDE="$(mktemp -d)" xcodebuild test -scheme MatronMac \
  -destination 'platform=macOS' -only-testing:MatronMacTests/MacChatToolbarTests 2>&1 | tail -20
```
Expected: PASS, and the xcodebuild output must show a non-zero
"Executed N tests" line — a destination or scheme error otherwise reads as a
pass through a `tail` pipe.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Chat MatronShared/Tests/ChatTests MatronMac/Features/Chat/MacChatToolbar.swift Matron/Features/Chat/SessionStatusSheet.swift MatronMacTests/MacChatToolbarTests.swift
git commit -m "feat(chat header): name the agent box this session runs on"
```

---

### Task 6: Rename a box from Settings → Devices

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift` (~378-402, beside `revokeDevice`)
- Modify: `MatronShared/Sources/ViewModels/DevicesViewModel.swift`
- Modify: `MatronMac/Features/Settings/MacDevicesView.swift`
- Modify: `Matron/Features/Settings/DevicesView.swift`
- Test: `MatronShared/Tests/ViewModelTests/DevicesViewModelTests.swift` (append)

**Interfaces:**
- Consumes: `POST /devices/:id/rename` (journal plan, Task 1).
- Produces:
  - `JournalAPI.renameDevice(id: Int64, name: String) async throws -> DeviceDTO`
  - `DevicesProviding.renameDevice(id:name:)` (protocol requirement — every
    fake in the test suite must implement it)
  - `DevicesViewModel.rename(_ device: DeviceDTO, to name: String) async`
  - `DevicesViewModel.validate(name:) -> String?` (nil when acceptable, else
    the reason to show)

- [ ] **Step 1: Write the failing test**

Append to `MatronShared/Tests/ViewModelTests/DevicesViewModelTests.swift`
(extend the existing fake with `renameDevice`, recording calls and echoing a
renamed `DeviceDTO`):

```swift
@Test func renameUpdatesTheRosterAndSurfacesFailures() async {
    let fake = FakeDevicesAPI(devices: [
        DeviceDTO(id: 7, kind: "agent", name: "dev-9", createdAt: 1, cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false),
    ])
    let vm = DevicesViewModel(api: fake, onSelfRevoked: {})
    await vm.refresh()

    await vm.rename(vm.devices[0], to: "dev-y")
    #expect(fake.renamed == [(7, "dev-y")])
    #expect(vm.devices.first?.name == "dev-y")
    #expect(vm.errorMessage == nil)

    // A server refusal leaves the roster alone and explains itself.
    fake.renameError = JournalAPIError.forbidden
    await vm.rename(vm.devices[0], to: "dev-z")
    #expect(vm.devices.first?.name == "dev-y")
    #expect(vm.errorMessage?.contains("dev-y") == true)
}

@Test func nameValidationMatchesTheServerRules() {
    // Mirrors the journal's own check so the user gets told before a 400.
    #expect(DevicesViewModel.validate(name: "dev-y") == nil)
    #expect(DevicesViewModel.validate(name: String(repeating: "y", count: 40)) == nil)
    #expect(DevicesViewModel.validate(name: "") != nil)
    #expect(DevicesViewModel.validate(name: "   ") != nil)
    #expect(DevicesViewModel.validate(name: String(repeating: "y", count: 41)) != nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter DevicesViewModelTests`
Expected: FAIL to compile — no `renameDevice`, no `rename`, no `validate`.

- [ ] **Step 3: Add the API call**

In `JournalAPI.swift`, beside `revokeDevice`:

```swift
    /// Renames a device. Client tokens only (the server 403s an agent), and
    /// 404 covers both "not yours" and "gone".
    public func renameDevice(id: Int64, name: String) async throws -> DeviceDTO {
        let obj = try await request(path: "/devices/\(id)/rename", method: "POST", body: ["name": name])
        guard let d = obj["device"] as? [String: Any],
              let deviceID = (d["device_id"] as? NSNumber)?.int64Value,
              let newName = d["name"] as? String
        else { throw JournalAPIError.http(status: 200, message: "malformed rename response") }
        // Partial DTO: the rename response carries only identity and the new
        // name. Callers re-fetch the roster for the full row rather than
        // trusting these zeros — see DevicesViewModel.rename.
        return DeviceDTO(id: deviceID, kind: "", name: newName, createdAt: 0,
                         cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false)
    }
```

`JournalAPIError` has no malformed-response case; `.http(status:message:)` is
the repo's catch-all and is already `LocalizedError`-rendered in banners.

- [ ] **Step 4: Extend the protocol and view model**

In `DevicesViewModel.swift`, add to `DevicesProviding`:

```swift
    func renameDevice(id: Int64, name: String) async throws -> DeviceDTO
```

and to the view model:

```swift
    /// Name rules, mirrored from the server so the field can refuse before a
    /// round-trip: non-empty after trimming, at most 40 characters.
    /// Returns nil when acceptable, else the reason to show.
    public static func validate(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Give the device a name." }
        if trimmed.count > Self.nameCap { return "Names are at most \(Self.nameCap) characters." }
        return nil
    }

    public static let nameCap = 40

    /// Renames `device`. The roster is re-fetched on success rather than
    /// patched, so a name the server sanitised (control characters
    /// flattened) is what the user ends up seeing.
    public func rename(_ device: DeviceDTO, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.validate(name: trimmed) {
            errorMessage = problem
            return
        }
        do {
            _ = try await api.renameDevice(id: device.id, name: trimmed)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "Couldn't rename \(device.name) — \(Self.describe(error))"
        }
    }
```

Add `renameDevice` to every `DevicesProviding` fake the compiler flags.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ViewModelTests`
Expected: PASS.

- [ ] **Step 6: Add the Mac UI**

In `MacDevicesView.swift`, add state and a rename alert:

```swift
    @State private var renaming: DeviceDTO?
    @State private var draftName = ""
```

Give `DeviceRow` an `onRename: () -> Void` and a second button:

```swift
            Button("Rename…", action: onRename)
                .controlSize(.small)
```

Pass it at the `DeviceRow` call site:

```swift
                DeviceRow(device: device, onRevoke: { confirming = device },
                          onRename: { draftName = device.name; renaming = device })
```

and add the alert next to the existing revoke alert:

```swift
        .alert("Rename device", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let device = renaming {
                    Task { await viewModel.rename(device, to: draftName) }
                }
                renaming = nil
            }
        } message: {
            Text("This name labels the box everywhere — in Devices and on the chip beside each conversation.")
        }
```

- [ ] **Step 7: Add the iOS UI**

In `DevicesView.swift`, add the same `@State private var renaming: DeviceDTO?`
and `@State private var draftName = ""`, a swipe action and context-menu item:

```swift
        .swipeActions(edge: .leading) {
            Button("Rename") {
                draftName = device.name
                renaming = device
            }
        }
```

```swift
            Button("Rename “\(device.name)”") {
                draftName = device.name
                renaming = device
            }
```

and the same `.alert("Rename device", isPresented:)` block as the Mac,
attached to the `List`.

- [ ] **Step 8: Build both apps**

Run:
```bash
xcodegen generate
xcodebuild -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' build | tail -5
xcodebuild -scheme MatronMac -destination 'platform=macOS' build | tail -5
```
Expected: `BUILD SUCCEEDED` for both.

- [ ] **Step 9: Run the full shared suite**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`
Expected: PASS, with a non-zero executed-test count.

- [ ] **Step 10: Commit**

```bash
git add MatronShared/Sources MatronShared/Tests MatronMac/Features/Settings Matron/Features/Settings
git commit -m "feat(devices): rename an agent box from Settings"
```

---

## Manual verification (before opening the PR)

Against a journal with plan 1 deployed and at least two agent boxes paired:

1. Chat list shows a chip on each conversation naming its box.
2. Settings → Devices → Rename one box; the chip updates live in the open
   list without a relaunch (that is the `device_meta` path).
3. Relaunch: the chip still shows the new name (that is the snapshot path).
4. With only one box paired, no chips appear anywhere.

## Self-review notes

- Spec §3.1 (data layer) → Tasks 1 and 2. §3.2 (chip UI, both surfaces,
  ≥2 gate) → Tasks 3, 4, 5. §3.3 (rename UI) → Task 6.
- The gate is implemented once, in `JournalChatService`, and consumed by
  three views — `ChatSummary.boxName` and `boxName(forConvoID:)` share the
  same rule and both are tested for it.
- The spec's "snapshot tests for the chip row states" is deliberately
  implemented as a logic test (`BoxChipTests`) plus the existing row-height
  invariant instead: the Mac snapshot harness has an outstanding appearance
  chore, so a new snapshot test would land red for reasons unrelated to this
  feature. Manual verification below covers the visual side.
- `ConvoSummaryDTO.agentDeviceID`, `ConversationRecord.agentDeviceID`,
  `AgentDTO`, `SnapshotResponse.agents`, `ServerFrame.deviceMeta`,
  `ChatSummary.boxName`, `BoxChip`, `DevicesViewModel.rename` and
  `validate(name:)` are named identically wherever they appear across tasks.
- Android is deliberately out of scope (spec §4) — it ports afterwards.
