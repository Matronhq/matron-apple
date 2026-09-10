# Missions & milestones — apps implementation plan (matron-apple)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give both apps a Missions tab (list + mission page), inline milestone cards that jump to their transcript anchor, a conversation-title tap that opens the mission page, a mission chip on Decisions rows — and retire the summaries UI.

**Architecture:** Clone the items tracker's client shape one layer at a time: models → marker events → a v10 store migration with `MissionRecord`/`MilestoneRecord` and `ValueObservation` streams → `MissionsAPI` (feature-detected by 404) → a `MissionsSync` actor (full list on connect, per-mission refetch on a marker) → two view models → navigation (`focusSeq` carried through the shell routes, `focusOrPark` reused) → views. Everything new lives in existing SPM targets and xcodegen-globbed folders; no manifest churn.

**Tech Stack:** Swift 6 / SwiftUI, GRDB (`DatabaseMigrator`, `ValueObservation`), XCTest + swift-snapshot-testing (`assertVariants`), xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-10-missions-milestones-design.md`. Requires the journal (matron-journal #75) and bridge (matron-bridge missions plan) to be deployed for end-to-end use; the apps must keep working against an old journal (tab hidden on 404).

## Global Constraints

- Migration identifier `v10`, registered after `v9` and before `return migrator`. Never reuse an identifier.
- New files go in: `MatronShared/Sources/Models/`, `Sources/Events/`, `Sources/Journal/`, `Sources/ViewModels/`, `Sources/DesignSystem/Missions/`, `Matron/Features/Missions/`, `MatronMac/Features/Missions/`. Run `xcodegen generate` after adding files.
- Tab order iOS: Coordinator · Missions · Decisions · Conversations? **No** — `AppTab.allCases` is the swipe order and the current order is Coordinator · Conversations · Decisions. Spec says the bar order is Coordinator · Missions · Decisions · Conversations. Use exactly that order for `AppTab.allCases` and the `TabView`; update `AppShellNavigationTests` swipe expectations to match.
- Mac nav order: Coordinator · Missions · Decisions · Conversations (`MacNav.allCases`).
- `MacChatListView.body` must not grow inline switch sites — extend `sidebarStack`, `sidebarWidths(for:)`, `detailContent`, `navChanged(from:to:)` (CI type-checker budget).
- Marker events `milestone` and `mission` are never mirrored as text; `fallback_for` suppression already hides any journal mirror.
- Mac tests only with `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport`; snapshot tests skippable with `MATRON_SKIP_SNAPSHOT_TESTS=1`; pre-existing local snapshot failures listed in memory are not regressions.
- `summary_entry`, its migrations (v4/v7) and ingest stay. Only the summaries **UI** is deleted.
- Commit after every task with `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit`. Never stage `Matron/App/Info.plist`.

## File map

| File | Responsibility |
|---|---|
| `MatronShared/Sources/Models/Mission.swift` | **new** `Mission`, `Milestone`, `MissionState`, `MilestoneKind`, `MissionLastMilestone`, JSON inits |
| `MatronShared/Sources/Models/TrackerItem.swift` | `missionID`, `missionNum` |
| `MatronShared/Sources/Events/MilestoneMarkerEvent.swift` | **new** `MilestoneMarkerEvent`, `MissionMarkerEvent` |
| `MatronShared/Sources/Journal/WireModels.swift` | `JournalEventType.milestone`, `.mission` |
| `MatronShared/Sources/Journal/JournalStore.swift` | `v10` migration |
| `MatronShared/Sources/Journal/JournalStore+Missions.swift` | **new** records, read helpers, streams, wipe |
| `MatronShared/Sources/Journal/JournalStore+Items.swift` | `ItemRecord.missionId`/`missionNum` |
| `MatronShared/Sources/Journal/JournalAPI+Missions.swift` | **new** `MissionsProviding` + `JournalAPI` conformance |
| `MatronShared/Sources/Journal/JournalSyncEngine.swift` | `missionMarkers()` stream, publish in `didApply`/`didApplyBatch` |
| `MatronShared/Sources/Journal/MissionsSync.swift` | **new** actor |
| `MatronShared/Sources/ViewModels/MissionsListViewModel.swift`, `MissionDetailViewModel.swift` | **new** |
| `MatronShared/Sources/ViewModels/ChatViewModel.swift` | `focus(seq:parkIfNeeded:)`, `FocusOwner.milestone` |
| `MatronShared/Sources/Chat/TimelineItem.swift`, `JournalTimelineMapper.swift` | `.milestone`, `.missionNotice` kinds |
| `MatronShared/Sources/DesignSystem/Missions/` | **new** `MissionGlyph`, `MissionRow`, `MissionsListView`, `MissionDetailView`, `MilestoneRow`, `MilestoneCard`, `MissionNotice` |
| `MatronShared/Sources/DesignSystem/Items/ItemRow.swift`, `DecisionsListView.swift` | mission chip |
| `Matron/App/AppShellNavigation.swift`, `AppShellView.swift`, `AppDependencies.swift`, `Matron/Features/Missions/MissionsTab.swift` (**new**), `Matron/Features/Chat/ChatView.swift`, `Rendering/TimelineItemView.swift` | iOS tab, routes, title tap, cards |
| `MatronMac/Features/Nav/MacNavColumn.swift`, `ChatList/MacChatListView.swift`, `App/AppDependencies.swift`, `Features/Missions/MacMissionsColumn.swift` (**new**), `Chat/MacChatToolbar.swift`, `Chat/MacChatView.swift`, `Chat/MacTimelineItemView.swift` | Mac nav, routes, title tap, cards |
| Deleted: `Matron/Features/Chat/SummariesSheet.swift`, `MatronMac/Features/Chat/MacSummariesPanel.swift`, `MatronTests/SummariesSheetBindingTests.swift`, `MatronMacTests/MacSummariesPanelSnapshotTests.swift` + its `__Snapshots__` dir | summaries UI |

---

### Task 1: Models

**Files:**
- Create: `MatronShared/Sources/Models/Mission.swift`
- Modify: `MatronShared/Sources/Models/TrackerItem.swift` (add `missionID: String?`, `missionNum: Int?` stored properties, init params defaulting to `nil`, parse `mission_id`/`mission_num` in `init(json:)`)
- Test: `MatronShared/Tests/ModelTests/MissionTests.swift` (new; if `ModelTests` target does not exist, put it in `JournalTests`)

**Interfaces (produces):**

```swift
public enum MissionState: String, Sendable, Codable { case open, closed }
public enum MilestoneKind: String, Sendable, Codable { case userInput = "user_input", progress }
public struct MissionLastMilestone: Equatable, Sendable { public let num: Int; public let title: String; public let kind: MilestoneKind; public let createdAt: Date }
public struct Mission: Equatable, Identifiable, Sendable {
    public let id: String; public let num: Int; public let state: MissionState; public let title: String; public let body: String
    public let closeSummary: String?; public let closedBy: ItemAuthor?; public let closedOverOpenItems: Int
    public let originConvoID: String; public let createdBy: ItemAuthor
    public let createdAt: Date; public let updatedAt: Date; public let lastMilestoneAt: Date?; public let closedAt: Date?
    public let openItems: Int; public let needsYou: Int; public let conversations: Int; public let milestones: Int
    public let lastMilestone: MissionLastMilestone?
    public init(id:num:state:title:body:closeSummary:closedBy:closedOverOpenItems:originConvoID:createdBy:createdAt:updatedAt:lastMilestoneAt:closedAt:openItems:needsYou:conversations:milestones:lastMilestone:)  // all with defaults except id, num, title, originConvoID
    public init?(json: [String: Any])
}
public struct Milestone: Equatable, Identifiable, Sendable {
    public let id: String; public let missionID: String; public let num: Int; public let kind: MilestoneKind
    public let title: String; public let body: String; public let convoID: String; public let seq: Int64
    public let createdBy: ItemAuthor; public let createdAt: Date
    public init(...)  // defaults for body "", createdBy .agent, createdAt .now
    public init?(json: [String: Any])
}
public struct MissionConversation: Equatable, Identifiable, Sendable { public let id: String; public let title: String; public let box: String?; public let state: String?; public init?(json:) }
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MatronModels

final class MissionTests: XCTestCase {
    func testMissionParsesJournalJSON() throws {
        let json: [String: Any] = [
            "id": "ms_1", "num": 61, "state": "open", "title": "Missions", "body": "goal", "close_summary": NSNull(),
            "closed_by": NSNull(), "closed_over_open_items": 0, "origin_convo_id": "c1", "created_by": "agent",
            "created_at": 1_700_000_000_000, "updated_at": 1_700_000_001_000, "last_milestone_at": NSNull(), "closed_at": NSNull(),
            "open_items": 2, "needs_you": 1, "conversations": 3, "milestones": 5,
            "last_milestone": ["num": 63, "title": "Landed", "kind": "progress", "created_at": 1_700_000_002_000],
        ]
        let m = try XCTUnwrap(Mission(json: json))
        XCTAssertEqual(m.num, 61); XCTAssertEqual(m.state, .open); XCTAssertEqual(m.needsYou, 1)
        XCTAssertEqual(m.lastMilestone?.kind, .progress); XCTAssertEqual(m.createdAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNil(m.closedBy)
        XCTAssertNil(Mission(json: ["id": "x"]))
    }
    func testMilestoneParsesJournalJSON() throws {
        let l = try XCTUnwrap(Milestone(json: ["id": "ml_1", "mission_id": "ms_1", "num": 63, "kind": "user_input", "title": "T", "body": "",
                                               "convo_id": "c1", "seq": 7350, "created_by": "agent", "created_at": 1_700_000_000_000]))
        XCTAssertEqual(l.kind, .userInput); XCTAssertEqual(l.seq, 7350)
        XCTAssertNil(Milestone(json: ["id": "ml_1", "kind": "bogus"]))
    }
    func testTrackerItemParsesMission() throws {
        var json = TrackerItem.sampleJSON  // if no sample exists, build the minimal item JSON the existing TrackerItem tests use
        json["mission_id"] = "ms_1"; json["mission_num"] = 61
        let i = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertEqual(i.missionID, "ms_1"); XCTAssertEqual(i.missionNum, 61)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && swift test --filter MissionTests`
Expected: FAIL to compile (`Mission` undefined).

- [ ] **Step 3: Implement**

`MatronShared/Sources/Models/Mission.swift`:

```swift
import Foundation

public enum MissionState: String, Sendable, Codable { case open, closed }
public enum MilestoneKind: String, Sendable, Codable { case userInput = "user_input", progress }

private func msDate(_ v: Any?) -> Date? {
    guard let n = (v as? NSNumber)?.doubleValue else { return nil }
    return Date(timeIntervalSince1970: n / 1000)
}

public struct MissionLastMilestone: Equatable, Sendable {
    public let num: Int; public let title: String; public let kind: MilestoneKind; public let createdAt: Date
    public init(num: Int, title: String, kind: MilestoneKind, createdAt: Date) { self.num = num; self.title = title; self.kind = kind; self.createdAt = createdAt }
    init?(json: [String: Any]) {
        guard let num = (json["num"] as? NSNumber)?.intValue, let title = json["title"] as? String,
              let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)), let at = msDate(json["created_at"]) else { return nil }
        self.init(num: num, title: title, kind: kind, createdAt: at)
    }
}

/// One piece of work, journal-owned (spec 2026-09-10). Counts are the
/// list decorations `GET /missions` returns; a detail fetch carries them too.
public struct Mission: Equatable, Identifiable, Sendable {
    public let id: String; public let num: Int; public let state: MissionState; public let title: String; public let body: String
    public let closeSummary: String?; public let closedBy: ItemAuthor?; public let closedOverOpenItems: Int
    public let originConvoID: String; public let createdBy: ItemAuthor
    public let createdAt: Date; public let updatedAt: Date; public let lastMilestoneAt: Date?; public let closedAt: Date?
    public let openItems: Int; public let needsYou: Int; public let conversations: Int; public let milestones: Int
    public let lastMilestone: MissionLastMilestone?

    public init(id: String, num: Int, state: MissionState = .open, title: String, body: String = "", closeSummary: String? = nil,
                closedBy: ItemAuthor? = nil, closedOverOpenItems: Int = 0, originConvoID: String, createdBy: ItemAuthor = .agent,
                createdAt: Date = .now, updatedAt: Date = .now, lastMilestoneAt: Date? = nil, closedAt: Date? = nil,
                openItems: Int = 0, needsYou: Int = 0, conversations: Int = 1, milestones: Int = 0, lastMilestone: MissionLastMilestone? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body; self.closeSummary = closeSummary
        self.closedBy = closedBy; self.closedOverOpenItems = closedOverOpenItems; self.originConvoID = originConvoID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastMilestoneAt = lastMilestoneAt; self.closedAt = closedAt
        self.openItems = openItems; self.needsYou = needsYou; self.conversations = conversations; self.milestones = milestones; self.lastMilestone = lastMilestone
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let state = (json["state"] as? String).flatMap(MissionState.init(rawValue:)),
              let title = json["title"] as? String, let origin = json["origin_convo_id"] as? String,
              let createdAt = msDate(json["created_at"]) else { return nil }
        let int = { (k: String) in (json[k] as? NSNumber)?.intValue ?? 0 }
        self.init(id: id, num: num, state: state, title: title, body: json["body"] as? String ?? "",
                  closeSummary: json["close_summary"] as? String,
                  closedBy: (json["closed_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
                  closedOverOpenItems: int("closed_over_open_items"), originConvoID: origin,
                  createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                  createdAt: createdAt, updatedAt: msDate(json["updated_at"]) ?? createdAt,
                  lastMilestoneAt: msDate(json["last_milestone_at"]), closedAt: msDate(json["closed_at"]),
                  openItems: int("open_items"), needsYou: int("needs_you"), conversations: int("conversations"), milestones: int("milestones"),
                  lastMilestone: (json["last_milestone"] as? [String: Any]).flatMap(MissionLastMilestone.init(json:)))
    }
}

public struct Milestone: Equatable, Identifiable, Sendable {
    public let id: String; public let missionID: String; public let num: Int; public let kind: MilestoneKind
    public let title: String; public let body: String; public let convoID: String; public let seq: Int64
    public let createdBy: ItemAuthor; public let createdAt: Date

    public init(id: String, missionID: String, num: Int, kind: MilestoneKind, title: String, body: String = "", convoID: String, seq: Int64,
                createdBy: ItemAuthor = .agent, createdAt: Date = .now) {
        self.id = id; self.missionID = missionID; self.num = num; self.kind = kind; self.title = title; self.body = body
        self.convoID = convoID; self.seq = seq; self.createdBy = createdBy; self.createdAt = createdAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let missionID = json["mission_id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)), let title = json["title"] as? String,
              let convoID = json["convo_id"] as? String, let seq = (json["seq"] as? NSNumber)?.int64Value, let createdAt = msDate(json["created_at"]) else { return nil }
        self.init(id: id, missionID: missionID, num: num, kind: kind, title: title, body: json["body"] as? String ?? "", convoID: convoID, seq: seq,
                  createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent, createdAt: createdAt)
    }
}

public struct MissionConversation: Equatable, Identifiable, Sendable {
    public let id: String; public let title: String; public let box: String?; public let state: String?
    public init(id: String, title: String, box: String? = nil, state: String? = nil) { self.id = id; self.title = title; self.box = box; self.state = state }
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", box: json["box"] as? String, state: json["state"] as? String)
    }
}
```

`TrackerItem.swift`: add `public let missionID: String?` and `public let missionNum: Int?`, thread them through the memberwise `init` (default `nil`) and `init(json:)` (`json["mission_id"] as? String`, `(json["mission_num"] as? NSNumber)?.intValue`).

- [ ] **Step 4: Run tests, commit**

Run: `swift test --filter MissionTests` → PASS. `git add MatronShared/Sources/Models/Mission.swift MatronShared/Sources/Models/TrackerItem.swift MatronShared/Tests/...` and commit `missions: models`.

---

### Task 2: Marker events + wire types

**Files:**
- Create: `MatronShared/Sources/Events/MilestoneMarkerEvent.swift`
- Modify: `MatronShared/Sources/Journal/WireModels.swift` (`public static let milestone = "milestone"`, `public static let mission = "mission"` next to `item`)
- Test: `MatronShared/Tests/EventsTests/MilestoneMarkerEventTests.swift` (new; use whichever test target already tests `ItemMarkerEvent`)

**Interfaces (produces):**

```swift
public struct MilestoneMarkerEvent: Equatable, Sendable {
    public let milestoneID: String; public let num: Int; public let kind: MilestoneKind; public let title: String; public let body: String
    public let missionID: String; public let missionNum: Int; public let missionTitle: String; public let by: ItemAuthor
    public static func parse(payload: [String: Any]) -> MilestoneMarkerEvent?
}
public struct MissionMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case created, joined, updated, closed }
    public let missionID: String; public let num: Int; public let title: String; public let action: Action; public let by: ItemAuthor; public let openItemNums: [Int]
    public static func parse(payload: [String: Any]) -> MissionMarkerEvent?
}
```

- [ ] **Step 1: Failing test**

```swift
import XCTest
import MatronModels
@testable import MatronEvents

final class MilestoneMarkerEventTests: XCTestCase {
    func testParsesMilestone() throws {
        let e = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: ["milestone_id": "ml_1", "num": 63, "kind": "user_input", "title": "T", "body": "b",
                                                                   "mission_id": "ms_1", "mission_num": 61, "mission_title": "M", "by": "agent"]))
        XCTAssertEqual(e.kind, .userInput); XCTAssertEqual(e.missionNum, 61)
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: ["milestone_id": "ml_1"]))
    }
    func testParsesMission() throws {
        let e = try XCTUnwrap(MissionMarkerEvent.parse(payload: ["mission_id": "ms_1", "num": 61, "title": "M", "action": "closed", "by": "user", "open_item_nums": [64, 70]]))
        XCTAssertEqual(e.action, .closed); XCTAssertEqual(e.openItemNums, [64, 70])
        XCTAssertEqual(MissionMarkerEvent.parse(payload: ["mission_id": "ms_1", "num": 61, "title": "M", "action": "created", "by": "agent"])?.openItemNums, [])
    }
}
```

- [ ] **Step 2: Run → compile failure.** **Step 3: Implement**

```swift
import Foundation
import MatronModels

/// The `milestone` journal event (spec 2026-09-10, Marker events). Its own
/// seq is the anchor the apps jump to; the payload renders the inline card.
public struct MilestoneMarkerEvent: Equatable, Sendable {
    public let milestoneID: String; public let num: Int; public let kind: MilestoneKind; public let title: String; public let body: String
    public let missionID: String; public let missionNum: Int; public let missionTitle: String; public let by: ItemAuthor
    public init(milestoneID: String, num: Int, kind: MilestoneKind, title: String, body: String = "", missionID: String, missionNum: Int, missionTitle: String, by: ItemAuthor = .agent) {
        self.milestoneID = milestoneID; self.num = num; self.kind = kind; self.title = title; self.body = body
        self.missionID = missionID; self.missionNum = missionNum; self.missionTitle = missionTitle; self.by = by
    }
    public static func parse(payload: [String: Any]) -> MilestoneMarkerEvent? {
        guard let id = payload["milestone_id"] as? String, let num = (payload["num"] as? NSNumber)?.intValue,
              let kind = (payload["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)), let title = payload["title"] as? String,
              let missionID = payload["mission_id"] as? String, let missionNum = (payload["mission_num"] as? NSNumber)?.intValue else { return nil }
        return MilestoneMarkerEvent(milestoneID: id, num: num, kind: kind, title: title, body: payload["body"] as? String ?? "",
                                    missionID: missionID, missionNum: missionNum, missionTitle: payload["mission_title"] as? String ?? "",
                                    by: (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent)
    }
}

/// The `mission` journal event — an invalidation signal plus a one-line notice.
public struct MissionMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case created, joined, updated, closed }
    public let missionID: String; public let num: Int; public let title: String; public let action: Action; public let by: ItemAuthor; public let openItemNums: [Int]
    public init(missionID: String, num: Int, title: String, action: Action, by: ItemAuthor = .agent, openItemNums: [Int] = []) {
        self.missionID = missionID; self.num = num; self.title = title; self.action = action; self.by = by; self.openItemNums = openItemNums
    }
    public static func parse(payload: [String: Any]) -> MissionMarkerEvent? {
        guard let id = payload["mission_id"] as? String, let num = (payload["num"] as? NSNumber)?.intValue, let title = payload["title"] as? String,
              let action = (payload["action"] as? String).flatMap(Action.init(rawValue:)) else { return nil }
        return MissionMarkerEvent(missionID: id, num: num, title: title, action: action,
                                  by: (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                                  openItemNums: (payload["open_item_nums"] as? [NSNumber])?.map(\.intValue) ?? [])
    }
}
```

- [ ] **Step 4: Run tests, commit** `missions: marker events`.

---

### Task 3: Store — v10 migration, records, streams

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (after the `v9` registration, before `return migrator`), `JournalStore+Items.swift` (`ItemRecord` gains `missionId: String?`, `missionNum: Int?` with `CodingKeys` `mission_id`/`mission_num`, mapped both ways)
- Create: `MatronShared/Sources/Journal/JournalStore+Missions.swift`
- Test: `MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift`

**Interfaces (produces):**

```swift
public struct MissionRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable { static let databaseTableName = "mission"; init(_ m: Mission); var mission: Mission }
public struct MilestoneRecord: ... { static let databaseTableName = "milestone"; init(_ l: Milestone); var milestone: Milestone }
public struct MissionConversationRecord: ... { "mission_conversation": missionId, convoId, title, box, state }
extension JournalStore {
    func upsertMissions(_: [Mission]) throws
    func replaceMissionDetail(missionID: String, milestones: [Milestone], conversations: [MissionConversation]) throws
    func missions(state: MissionState?) throws -> [Mission]
    func mission(id: String) throws -> Mission?
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func missionStream(id: String) -> AsyncStream<Mission?>
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]>      // newest first
    func milestones(convoID: String) throws -> [Milestone]                    // newest first
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]>
    func missionID(convoID: String) throws -> String?                          // from mission_conversation, else origin
    func missionIDStream(convoID: String) -> AsyncStream<String?>
    func missionItemsStream(missionID: String) -> AsyncStream<[TrackerItem]>  // open items, awaiting user first
    func wipeMissions() throws
}
```

- [ ] **Step 1: Failing tests**

```swift
import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreMissionsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(inMemoryOwnSender: "user:dan") }  // use the same factory JournalStoreItemsTests uses

    func testMigrationV10CreatesTablesAndItemColumns() throws {
        let store = try makeStore()
        let names = try store.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        XCTAssertTrue(names.contains("mission")); XCTAssertTrue(names.contains("milestone")); XCTAssertTrue(names.contains("mission_conversation"))
        let cols = try store.dbQueue.read { db in try db.columns(in: "item").map(\.name) }
        XCTAssertTrue(cols.contains("mission_id")); XCTAssertTrue(cols.contains("mission_num"))
    }

    func testMigrationV10UpgradesAV9DatabaseWithItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sqlite")
        let dbQueue = try DatabaseQueue(path: url.path)
        try JournalStore.migrator().migrate(dbQueue, upTo: "v9")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO item(id, num, kind, state, rank, title, body, origin_convo_id, created_by, created_at, updated_at)
                VALUES('it_1', 1, 'task', 'open', 1, 'T', '', 'c1', 'agent', 0, 0)
                """)
        }
        let upgraded = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let item = try XCTUnwrap(try upgraded.items(scope: .all).first)
        XCTAssertNil(item.missionID)
    }

    func testUpsertAndStreams() async throws {
        let store = try makeStore()
        let m = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", lastMilestoneAt: Date(timeIntervalSince1970: 10), needsYou: 1)
        let older = Mission(id: "ms_2", num: 62, title: "Old", originConvoID: "c2", lastMilestoneAt: Date(timeIntervalSince1970: 5))
        try store.upsertMissions([older, m])
        XCTAssertEqual(try store.missions(state: .open).map(\.id), ["ms_1", "ms_2"])
        XCTAssertEqual(try store.mission(id: "ms_1")?.needsYou, 1)
        let l1 = Milestone(id: "ml_1", missionID: "ms_1", num: 63, kind: .userInput, title: "one", convoID: "c1", seq: 10, createdAt: Date(timeIntervalSince1970: 1))
        let l2 = Milestone(id: "ml_2", missionID: "ms_1", num: 64, kind: .progress, title: "two", convoID: "c3", seq: 20, createdAt: Date(timeIntervalSince1970: 2))
        try store.replaceMissionDetail(missionID: "ms_1", milestones: [l1, l2], conversations: [.init(id: "c1", title: "C1", box: "dev-2", state: "running"), .init(id: "c3", title: "C3")])
        var it = store.milestonesStream(missionID: "ms_1").makeAsyncIterator()
        XCTAssertEqual(await it.next()?.map(\.num), [64, 63])
        XCTAssertEqual(try store.milestones(convoID: "c1").map(\.id), ["ml_1"])
        XCTAssertEqual(try store.missionID(convoID: "c3"), "ms_1")
        XCTAssertEqual(try store.missionID(convoID: "c2"), "ms_2")   // origin fallback
        XCTAssertNil(try store.missionID(convoID: "nope"))
        try store.wipeMissions()
        XCTAssertEqual(try store.missions(state: nil).count, 0)
    }
}
```

- [ ] **Step 2: Run → fail.** **Step 3: Implement**

`JournalStore.swift`, after v9:

```swift
        // v10: missions & milestones cache (spec 2026-09-10). Filled from
        // GET /missions and GET /missions/:id, never from the event log; the
        // `milestone`/`mission` markers are only invalidation signals
        // (MissionsSync). `item` gains the mission it belongs to.
        migrator.registerMigration("v10") { db in
            try db.create(table: "mission") { t in
                t.column("id", .text).primaryKey()
                t.column("num", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("close_summary", .text)
                t.column("closed_by", .text)
                t.column("closed_over_open_items", .integer).notNull().defaults(to: 0)
                t.column("origin_convo_id", .text).notNull()
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("last_milestone_at", .integer)
                t.column("closed_at", .integer)
                t.column("open_items", .integer).notNull().defaults(to: 0)
                t.column("needs_you", .integer).notNull().defaults(to: 0)
                t.column("conversations", .integer).notNull().defaults(to: 0)
                t.column("milestones", .integer).notNull().defaults(to: 0)
                t.column("last_milestone_json", .text)
            }
            try db.create(index: "mission_state_activity", on: "mission", columns: ["state", "last_milestone_at"])
            try db.create(table: "milestone") { t in
                t.column("id", .text).primaryKey()
                t.column("mission_id", .text).notNull().indexed()
                t.column("num", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("convo_id", .text).notNull().indexed()
                t.column("seq", .integer).notNull()
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "mission_conversation") { t in
                t.column("mission_id", .text).notNull().indexed()
                t.column("convo_id", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("box", .text)
                t.column("state", .text)
                t.primaryKey(["mission_id", "convo_id"])
            }
            try db.create(index: "mission_conversation_convo", on: "mission_conversation", columns: ["convo_id"])
            try db.alter(table: "item") { t in
                t.add(column: "mission_id", .text)
                t.add(column: "mission_num", .integer)
            }
            try db.create(index: "item_mission", on: "item", columns: ["mission_id", "state"])
        }
```

`JournalStore+Missions.swift` — records with the same `ms`/`date` shims as the items file (file-private copies), `MissionRecord` ↔ `Mission` (encode `last_milestone` as JSON in `last_milestone_json` via a small `Codable` struct), `MilestoneRecord`, `MissionConversationRecord`, and the helpers:

```swift
extension JournalStore {
    public func upsertMissions(_ missions: [Mission]) throws {
        try dbQueue.write { db in for m in missions { try MissionRecord(m).save(db) } }
    }
    public func replaceMissionDetail(missionID: String, milestones: [Milestone], conversations: [MissionConversation]) throws {
        try dbQueue.write { db in
            try MilestoneRecord.filter(Column("mission_id") == missionID).deleteAll(db)
            for l in milestones { try MilestoneRecord(l).save(db) }
            try MissionConversationRecord.filter(Column("mission_id") == missionID).deleteAll(db)
            for c in conversations { try MissionConversationRecord(missionID: missionID, c).save(db) }
        }
    }
    private static func missionsRequest(_ state: MissionState?) -> QueryInterfaceRequest<MissionRecord> {
        var r = MissionRecord.order(sql: "last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC")
        if let state { r = r.filter(Column("state") == state.rawValue) }
        return r
    }
    public func missions(state: MissionState?) throws -> [Mission] { try dbQueue.read { db in try Self.missionsRequest(state).fetchAll(db).map(\.mission) } }
    public func mission(id: String) throws -> Mission? { try dbQueue.read { db in try MissionRecord.fetchOne(db, key: id)?.mission } }
    public func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in try Self.missionsRequest(state).fetchAll(db).map(\.mission) }, in: dbQueue)
    }
    public func missionStream(id: String) -> AsyncStream<Mission?> {
        Self.stream(ValueObservation.tracking { db in try MissionRecord.fetchOne(db, key: id)?.mission }, in: dbQueue)
    }
    public func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> {
        Self.stream(ValueObservation.tracking { db in
            try MilestoneRecord.filter(Column("mission_id") == missionID).order(Column("created_at").desc, Column("seq").desc).fetchAll(db).map(\.milestone)
        }, in: dbQueue)
    }
    public func milestones(convoID: String) throws -> [Milestone] {
        try dbQueue.read { db in try MilestoneRecord.filter(Column("convo_id") == convoID).order(Column("seq").desc).fetchAll(db).map(\.milestone) }
    }
    public func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> {
        Self.stream(ValueObservation.tracking { db in
            try MissionConversationRecord.filter(Column("mission_id") == missionID).fetchAll(db).map(\.conversation)
        }, in: dbQueue)
    }
    private static func missionIDQuery(_ db: Database, convoID: String) throws -> String? {
        if let id = try String.fetchOne(db, sql: "SELECT mission_id FROM mission_conversation WHERE convo_id = ? LIMIT 1", arguments: [convoID]) { return id }
        return try String.fetchOne(db, sql: "SELECT id FROM mission WHERE origin_convo_id = ? LIMIT 1", arguments: [convoID])
    }
    public func missionID(convoID: String) throws -> String? { try dbQueue.read { db in try Self.missionIDQuery(db, convoID: convoID) } }
    public func missionIDStream(convoID: String) -> AsyncStream<String?> {
        Self.stream(ValueObservation.tracking { db in try Self.missionIDQuery(db, convoID: convoID) }, in: dbQueue)
    }
    public func missionItemsStream(missionID: String) -> AsyncStream<[TrackerItem]> {
        Self.stream(ValueObservation.tracking { db in
            try ItemRecord.filter(Column("mission_id") == missionID && Column("state") == "open")
                .order(sql: "(awaiting = 'user') DESC, updated_at DESC").fetchAll(db).map(\.item)
        }, in: dbQueue)
    }
    public func wipeMissions() throws {
        try dbQueue.write { db in
            try MilestoneRecord.deleteAll(db); try MissionConversationRecord.deleteAll(db); try MissionRecord.deleteAll(db)
            try db.execute(sql: "DELETE FROM meta WHERE key = 'missions_watermark'")
        }
    }
}
```

Call `wipeMissions()` wherever `wipeItems()` is called on sign-out/reset (grep `wipeItems(`).

- [ ] **Step 4: Run tests, commit** `missions: v10 store migration, records and streams`.

---

### Task 4: `MissionsProviding` + `JournalAPI` conformance

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Missions.swift`
- Test: `MatronShared/Tests/JournalTests/JournalAPIMissionsTests.swift` (use the same URLProtocol stub the items API tests use, if any; otherwise test the pure `MissionDetail` decoding via a `decode(json:)` helper)

**Interfaces (produces):**

```swift
public struct MissionDetail: Equatable, Sendable { public let mission: Mission; public let milestones: [Milestone]; public let items: [TrackerItem]; public let conversations: [MissionConversation] }
public protocol MissionsProviding: Sendable {
    func listMissions(state: MissionState?, since: Date?) async throws -> [Mission]
    func mission(id: String) async throws -> MissionDetail
    func milestones(convoID: String) async throws -> [Milestone]
    func closeMission(id: String, summary: String) async throws -> Mission
}
extension JournalAPI: MissionsProviding
```

- [ ] **Step 1–4:** Test that `MissionDetail.decode(_ obj: [String: Any])` (a `static func` used by `mission(id:)`) produces the right counts from a fixture dictionary, and that `listMissions` builds `?state=open&since=<ms>`. Implementation mirrors `JournalAPI+Items.swift`: `request(path: "/missions", query: [...])`, `request(path: "/missions/\(Self.pathSegment(id))")`, `request(path: "/milestones", query: [.init(name: "convo", value: convoID)])`, `request(path: "/missions/\(id)/close", method: "POST", body: ["summary": summary])`. The detail's `items` decode with `TrackerItem(json:)` — the journal sends a reduced item shape (`id,num,kind,state,awaiting,title,origin_convo_id,updated_at`); make sure `TrackerItem.init(json:)` tolerates missing `rank`/`body`/`created_at` (default `rank = 0`, `body = ""`, `createdAt = updatedAt`); adjust it if it currently requires them. Commit `missions: journal API`.

---

### Task 5: Sync engine marker stream + `MissionsSync` actor

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift` (add `missionMarkerContinuations`, `missionMarkers()`, `publishMissionMarker(_:)`, call it from `didApply` and `didApplyBatch`)
- Create: `MatronShared/Sources/Journal/MissionsSync.swift`
- Test: `MatronShared/Tests/JournalTests/MissionsSyncTests.swift`

**Interfaces (produces):**

```swift
public enum MissionMarker: Sendable { case milestone(convoID: String, MilestoneMarkerEvent); case mission(convoID: String, MissionMarkerEvent); public var missionID: String }
extension JournalSyncEngine { public nonisolated func missionMarkers() -> AsyncStream<MissionMarker> }
public actor MissionsSync {
    public init(api: any MissionsProviding, store: JournalStore, markers: @escaping @Sendable () -> AsyncStream<MissionMarker>, connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>)
    public private(set) var isSupported: Bool
    public func supportedStream() -> AsyncStream<Bool>
    public func start(); public func stop() async
    public func refresh() async                       // GET /missions (both states)
    public func refreshMission(id: String) async      // GET /missions/:id → upsert + replaceMissionDetail (coalesced like ItemsSync.refreshItem)
    public func refreshConversation(convoID: String) async   // GET /milestones?convo= → upsert those milestones only
}
```

- [ ] **Step 1: Failing tests** (clone the `FakeItems` lock-guarded fake shape):

```swift
final class MissionsSyncTests: XCTestCase {
    func testConnectFetchesTheListAndMarksSupported() async throws { /* .running → listMissions called once; store has rows; supportedStream yields true */ }
    func testMilestoneMarkerRefetchesThatMission() async throws { /* yield .milestone(...) for ms_1 → api.mission(id: "ms_1") called; store has its milestones */ }
    func testMissionMarkerRefetchesListAndDetail() async throws { /* .mission(action: .closed) → listMissions + mission(id:) */ }
    func testNotFoundOnListMarksUnsupportedAndKeepsCache() async throws { /* api.listMissions throws JournalAPIError.notFound → isSupported false, existing rows untouched */ }
    func testCoalescesConcurrentRefetchesOfOneMission() async throws { /* two markers while the first fetch is gated → exactly two api.mission calls, never three */ }
}
```

- [ ] **Step 2–4: Implement.** In `JournalSyncEngine`:

```swift
    private var missionMarkerContinuations: [UUID: AsyncStream<MissionMarker>.Continuation] = [:]
    public nonisolated func missionMarkers() -> AsyncStream<MissionMarker> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerMissionMarkers(id: id, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.unregisterMissionMarkers(id: id) } }
        }
    }
    private func registerMissionMarkers(id: UUID, continuation: AsyncStream<MissionMarker>.Continuation) { missionMarkerContinuations[id] = continuation }
    private func unregisterMissionMarkers(id: UUID) { missionMarkerContinuations.removeValue(forKey: id) }
    private func publishMissionMarker(_ event: JournalEvent) {
        let marker: MissionMarker
        if event.type == JournalEventType.milestone, let m = MilestoneMarkerEvent.parse(payload: event.payload) { marker = .milestone(convoID: event.convoID, m) }
        else if event.type == JournalEventType.mission, let m = MissionMarkerEvent.parse(payload: event.payload) { marker = .mission(convoID: event.convoID, m) }
        else { return }
        for c in missionMarkerContinuations.values { c.yield(marker) }
    }
```

and add `publishMissionMarker(event)` next to `publishItemMarker(event)` in both `didApply` and `didApplyBatch`.

`MissionsSync.swift` follows `ItemsSync` minus the outbox: `start()` subscribes to markers (`.milestone` → `refreshMission(id:)`; `.mission` → `refresh()` then `refreshMission(id:)`) and to connection states (`.running` → `refresh()`); `refresh()` calls `api.listMissions(state: nil, since: nil)`, `store.upsertMissions`, `setSupported(true)`; `catch JournalAPIError.notFound { setSupported(false) }`; `refreshMission(id:)` uses the same `inFlightRefetches`/`refetchAgain` coalescing as `ItemsSync.refreshItem`, then `store.upsertMissions([d.mission])` + `store.replaceMissionDetail(...)` + `store.upsertItems(d.items)` (items carry `mission_id`). `refreshConversation(convoID:)` upserts milestones only (used by the title tap when the conversation's mission is not cached yet). Commit `missions: sync engine marker stream + MissionsSync`.

---

### Task 6: Dependency wiring (both apps)

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (~line 196: create `MissionsSync(api: api, store: store, markers: { engine.missionMarkers() }, connectionStates: { engine.stateStream() })`, hold it on `JournalCore` as `missions`, start it like `items`; factories `missionsSync(for:)`, `missionsProvider(for:)`, `makeMissionsListViewModel(for:)`, `makeMissionDetailViewModel(for:missionID:)`), `MatronMac/App/AppDependencies.swift` (mirror at ~145/254/266/276)
- Test: existing `AppDependencies` tests, if any, gain one assertion that `missionsSync(for:)` returns the same instance twice.

- [ ] Implement, build both apps (`xcodebuild -scheme Matron -destination 'generic/platform=iOS Simulator' build`, `xcodebuild -scheme MatronMac build`), commit `missions: dependency wiring`.

---

### Task 7: View models

**Files:**
- Create: `MatronShared/Sources/ViewModels/MissionsListViewModel.swift`, `MissionDetailViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/MissionsListViewModelTests.swift`, `MissionDetailViewModelTests.swift`

**Interfaces (produces):**

```swift
public protocol MissionsStoreReading: Sendable {
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func missionStream(id: String) -> AsyncStream<Mission?>
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]>
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]>
    func missionItemsStream(missionID: String) -> AsyncStream<[TrackerItem]>
    func missionIDStream(convoID: String) -> AsyncStream<String?>
}
extension JournalStore: MissionsStoreReading {}
public protocol MissionsSyncing: Sendable { func refresh() async; func refreshMission(id: String) async; func supportedStream() async -> AsyncStream<Bool> }
extension MissionsSync: MissionsSyncing {}

@MainActor @Observable public final class MissionsListViewModel {
    public struct Sections: Equatable { public var open: [Mission]; public var closed: [Mission] }
    public private(set) var sections: Sections; public private(set) var isSupported = true; public private(set) var isRefreshing = false
    public var needsYouTotal: Int  // sum of open missions' needsYou
    public init(store: any MissionsStoreReading, sync: any MissionsSyncing)
    public func start(); public func stop(); public func refresh() async
    public static func sections(from: [Mission]) -> Sections   // open sorted by lastMilestoneAt desc nulls last then createdAt desc; closed by closedAt desc
}

@MainActor @Observable public final class MissionDetailViewModel {
    public let missionID: String
    public private(set) var mission: Mission?; public private(set) var milestones: [Milestone]; public private(set) var items: [TrackerItem]; public private(set) var conversations: [MissionConversation]
    public var showOnlyUserInput = false
    public var visibleMilestones: [Milestone]   // filtered by showOnlyUserInput
    public var error: String?
    public init(missionID: String, store: any MissionsStoreReading, api: any MissionsProviding, sync: any MissionsSyncing)
    public func start(); public func stop()
    public func close(summary: String) async -> Bool   // api.closeMission → sync.refreshMission; error → `error`
    public static func orderedItems(_: [TrackerItem]) -> [TrackerItem]   // awaiting user first, then updatedAt desc
}
```

- [ ] **Step 1: Failing tests** — `testSectionsRule` (open/closed split and sort), `testStartSubscribesAndRefreshes` (fake sync records one `refresh`), `testUnsupportedFlag` (supported stream `[true, false]` → `isSupported == false`), `testDetailFilterAndOrder` (`showOnlyUserInput` hides `.progress`; items ordered awaiting-user first), `testCloseCallsAPIThenRefetch` (fake API records summary; fake sync records `refreshMission`), `testCloseFailureSetsError`.
- [ ] **Step 2–4:** Implement following `ItemsPanelViewModel`'s task/`[weak self]` pattern exactly (start/stop cancel tasks; `observationGeneration` not needed here). Commit `missions: list and detail view models`.

---

### Task 8: Navigation — `focusSeq` through the shell, `FocusOwner.milestone`

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ChatViewModel.swift` (`FocusOwner` gains `case milestone`; add `public func focus(seq: Int64, parkIfNeeded: Bool) async { if parkIfNeeded { await focusOrPark(seq: seq, owner: .milestone) } else { await focus(seq: seq) } }`), `Matron/App/AppShellNavigation.swift`, `MatronMac/Features/ChatList/MacChatListView.swift`
- Test: `MatronTests/AppShellNavigationTests.swift`, `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`

**Interfaces (produces):**

```swift
// iOS
enum AppTab: Hashable, CaseIterable { case coordinator, missions, decisions, conversations }   // this order = bar + swipe order
enum MissionRoute: Hashable { case mission(String); case item(ItemRoute) }
final class AppShellNavigation {
    var missionsPath: [MissionRoute] = []
    /// A jump the next-mounted ChatView for `convoID` must perform once (consumed by `takePendingFocus(for:)`).
    var pendingFocus: (convoID: String, seq: Int64)?
    func openChat(_ roomID: String, focusSeq: Int64? = nil)
    func openConversation(fromDecisions convoID: String, focusSeq: Int64? = nil)
    func openMission(_ id: String)                       // tab = .missions; missionsPath = [.mission(id)]
    func takePendingFocus(for convoID: String) -> Int64?
}
// Mac (MacChatListView)
@State var pendingFocus: (convoID: String, seq: Int64)?
func showConversation(_ id: String, focusSeq: Int64?)   // sets nav = .conversations, selectedSummaryID, pendingFocus
func showMission(_ id: String)                         // nav = .missions, selectedMissionID = id
```

- [ ] **Step 1: Failing tests**
  - `AppShellNavigationTests`: `openChat("r", focusSeq: 5)` sets `tab == .conversations`, `chatPath == ["r"]`, `takePendingFocus(for: "r") == 5` then `nil`; `takePendingFocus(for: "other") == nil` and leaves it; `openMission("ms_1")` sets `tab == .missions`, `missionsPath == [.mission("ms_1")]`; swipe order tests updated to the new `allCases`.
  - `ChatViewModelTests`: `test_focusParkIfNeeded_parksBeforeFirstSnapshotAndFiresOnDelivery` (copy the shape of `test_jumpToLastOwnMessage_parksUntilFirstSnapshot`), and `test_endChatSearch_doesNotCancelMilestoneJump`.
- [ ] **Step 2–4:** Implement; in `ChatView` (iOS) add `.task(id: viewModel.roomID) { if let seq = nav.takePendingFocus(for: viewModel.roomID) { await viewModel.focus(seq: seq, parkIfNeeded: true) } }`; in `MacChatListView.chatDetail(for:)` pass `pendingFocus` into `MacChatView` as `initialFocusSeq: Int64?` consumed in its `.task` the same way, then cleared. Commit `missions: focusSeq navigation`.

---

### Task 9: Design-system views

**Files:**
- Create under `MatronShared/Sources/DesignSystem/Missions/`: `MissionGlyph.swift`, `MissionRow.swift`, `MissionsListView.swift`, `MilestoneRow.swift`, `MissionDetailView.swift`, `MilestoneCard.swift`, `MissionNotice.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift`

**Interfaces (produces):**

```swift
public enum MissionGlyph { static func symbol(_ kind: MilestoneKind) -> String  /* userInput: "person.fill", progress: "flag.fill" */; static let mission = "flag.checkered" }
public struct MissionRow: View { init(mission: Mission, boxes: [String]) }   // "#num title", last milestone title + relative age, NeedsYouBadge(count: needsYou) when > 0 else open-items count, BoxChips
public struct MissionsListView: View {
    public struct Model: Equatable { var open: [Mission]; var closed: [Mission]; var boxesByMission: [String: [String]]; var isSupported: Bool?; var isRefreshing: Bool }
    init(model:, onSelect: (String) -> Void, onRefresh: () async -> Void)
}   // same Mac header / iOS refreshable / placeholder shape as DecisionsListView; closed missions in a collapsed "Closed" DisclosureGroup; empty copy "No missions yet — an agent starts one with mission_start"
public struct MilestoneRow: View { init(milestone: Milestone, conversationTitle: String?, boxLetter: String?, colorScheme: ColorScheme) }  // "#num", kind glyph, title, body (2 lines), time, SessionTagText.run(...) tag
public struct MissionDetailView: View {
    public struct Model: Equatable { var mission: Mission?; var milestones: [Milestone]; var items: [TrackerItem]; var conversations: [MissionConversation]; var showOnlyUserInput: Bool; var conversationTitles: [String: String]; var boxLetters: [String: String] }
    init(model:, onToggleUserInput: (Bool) -> Void, onMilestone: (Milestone) -> Void, onItem: (String) -> Void, onConversation: (String) -> Void, onClose: () -> Void)
}   // header (#num, title, state pill, body, close summary), "My inputs only" toggle, milestones, "Open items", "Conversations", "Close mission" button (user path) hidden when closed
public struct MilestoneCard: View { init(marker: MilestoneMarkerEvent, onOpen: () -> Void) }   // inline transcript card, same chrome as ItemInlineCard: glyph, #num, title, body (3 lines), chevron
public struct MissionNotice: View { init(marker: MissionMarkerEvent) }   // one line: "🏁 Mission #61 started: title" / "joined mission #61" / "Mission #61 renamed" / "Mission #61 closed (N items still open)"
```

- [ ] **Step 1:** Snapshot tests: `MissionRow` (open with needs-you, closed), `MissionsListView` (populated, empty, unsupported — `.frame(width: 360, height: 500)`), `MissionDetailView` (open with two milestones + one item; closed with summary), `MilestoneCard` both kinds, `MissionNotice` all four actions. Record, then run twice.
- [ ] **Step 2–4:** Implement; commit `missions: design-system views`.

---

### Task 10: iOS Missions tab + mission page navigation

**Files:**
- Create: `Matron/Features/Missions/MissionsTab.swift` (`MissionsTabView`: `NavigationStack(path: $nav.missionsPath)` → `MissionsListView` → `.navigationDestination(for: MissionRoute.self)`: `.mission(id)` → `MissionPage(missionID:)` which owns a `MissionDetailViewModel` via `deps.makeMissionDetailViewModel`, maps to `MissionDetailView.Model`, wires `onMilestone: { nav.openChat($0.convoID, focusSeq: $0.seq) }`, `onItem: { nav.missionsPath.append(.item(ItemRoute(itemID: $0))) }`, `onConversation: { nav.openChat($0) }`, `onClose` → a sheet with a summary `TextEditor` and, when `model.items` is non-empty, a confirmation "Close with N items still open?"; `.item(route)` → the existing `ItemDetailHost`)
- Modify: `Matron/App/AppShellNavigation.swift` (done in Task 8), `Matron/App/AppShellView.swift` (insert the tab between Coordinator and Decisions with `.badge(missionsVM.needsYouTotal)`, `.tag(AppTab.missions)`; own `missionsVM` like `decisionsVM`; hide the tab entirely — `if missionsVM.isSupported` — for an old journal), `Matron/Features/Chat/ChatView.swift` (title button → `nav.openMission(missionID)` when `viewModel.missionID != nil`, else plain title; `showSummaries` and the sheet removed — Task 12 deletes the file)
- Test: `MatronTests/AppShellViewMissionsTests.swift` (tab present/absent by `isSupported`; title tap route) if the shell has a testable harness; otherwise rely on the navigation tests from Task 8.

`ChatViewModel` gains `public private(set) var missionID: String?` fed by `store.missionIDStream(convoID:)` (subscribe in `start()`, cancel in `stop()`; expose via `TimelineService` protocol as `missionIDStream()` with a default returning an empty stream, implemented by `JournalTimelineService`).

- [ ] Implement, `xcodegen generate`, build, run `MatronTests`, commit `missions: iOS tab, page, title tap`.

---

### Task 11: Mac Missions nav + detail

**Files:**
- Create: `MatronMac/Features/Missions/MacMissionsColumn.swift` (`MacMissionsColumn`: `MissionsListView` fed by `MissionsListViewModel`, `onSelect` → `selectedMissionID`), `MatronMac/Features/Missions/MacMissionPage.swift` (hosts `MissionDetailViewModel` + `MissionDetailView`; milestone tap → `showConversation(convoID, focusSeq:)`; item tap → sets the decisions-pane style detail (`MacItemDetailHost`) in a pushed state with a back affordance; close → sheet)
- Modify: `MatronMac/Features/Nav/MacNavColumn.swift` (`case missions` between `coordinator` and `decisions`, title "Missions", symbol `"flag.checkered"`; badge generalised: `let badges: [MacNav: Int]`, accessibility label per entry), `MatronMac/Features/ChatList/MacChatListView.swift` (`@State var selectedMissionID: String?`; `sidebarStack` case `.missions: missionsColumn`; `sidebarWidths(for:)` unchanged for `.missions`; `detailContent` case `.missions: missionDetail`; `navChanged` tears down the mission detail VM when leaving `.missions`; `MacNavColumn(selection: $nav, badges: [.decisions: decisionsVM?.awaitingYouCount ?? 0, .missions: missionsVM?.needsYouTotal ?? 0])`; when `missionsVM.isSupported == false` filter `.missions` out of the column's entries), `MatronMac/Features/Chat/MacChatToolbar.swift` (title button → `onOpenMission` callback when `missionID != nil`, else static `titleCluster`; drop `showSummaries`/`popoverContent`), `MatronMac/Features/Chat/MacChatView.swift` (drop `showSummaries`; pass `onOpenMission: { showMission(id) }` via a new `onOpenMission: ((String) -> Void)?` parameter hoisted from `MacChatListView`)
- Test: `MatronMacTests/MacSidebarWidthTests.swift` updated for the new `MacNavColumn` init; `MatronMacTests/MacChatToolbarTests.swift` `testToolbarCarriesSummariesBinding` replaced by `testToolbarTitleOpensMissionWhenPresent`.

- [ ] Implement, `xcodegen generate`, run `MatronMacTests` with the override env, commit `missions: Mac nav column, list, page, title tap`.

---

### Task 12: Transcript cards + delete the summaries UI

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift` (`case milestone(eventID: String, MilestoneMarkerEvent)`, `case missionNotice(eventID: String, MissionMarkerEvent)`), `JournalTimelineMapper.swift` (map `JournalEventType.milestone`/`.mission`; `nil` on parse failure), `Matron/Features/Chat/Rendering/TimelineItemView.swift` + `MatronMac/Features/Chat/MacTimelineItemView.swift` (render `MilestoneCard` with `onOpenMission?(marker.missionID)` and `MissionNotice`; add `onOpenMission: ((String) -> Void)?` next to `onOpenItem`), the row `Equatable` wrappers (`MacTimelineRowView`/`TimelineRowView`) so the new kinds compare by value
- Delete: `Matron/Features/Chat/SummariesSheet.swift`, `MatronMac/Features/Chat/MacSummariesPanel.swift`, `MatronTests/SummariesSheetBindingTests.swift`, `MatronMacTests/MacSummariesPanelSnapshotTests.swift`, `MatronMacTests/__Snapshots__/MacSummariesPanelSnapshotTests/`; remove `summaryEntries` from `ChatViewModel` and `summaryEntriesStream()` from `TimelineService`/`JournalTimelineService` **only if** nothing else reads them (grep first; `JournalStore.summaryEntries(convoID:)` and its tests stay)
- Test: `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift` gains `testMilestoneEventBecomesCard` and `testMissionEventBecomesNotice`; `ChatViewModelTests` loses the summary-entries tests that referenced the deleted VM property.

- [ ] Implement, `xcodegen generate` (deleted files must leave the project), build both, run all three suites, commit `missions: transcript cards; retire the summaries UI`.

---

### Task 13: Decisions chip

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/Items/ItemRow.swift` (after the origin label: `if let n = item.missionNum { Text("🏁 #\(n)").font(.caption2).foregroundStyle(.tertiary) }`), snapshot baselines for `ItemsListSnapshotTests.testRowVariants` (add one variant with `missionNum: 61`) and `DecisionsListSnapshotTests.testPopulated` (give one row `missionNum`).

- [ ] Implement, re-record the two affected baselines, second run green, commit `missions: mission chip on item rows`.

---

### Task 14: End-to-end and install

- [ ] With the journal and one bridge deployed: start a session, `mission_start`, post both milestone kinds, file an item; on iPhone and Mac: Missions tab shows the mission with the needs-you badge; the page lists both milestones newest first, the item, the conversation; tapping a milestone opens the conversation on the marker (parked focus fires after the first snapshot); the title tap opens the page; `mission_close` blocked by the open question renders the instruction in the transcript; closing from the app with the item open shows the confirmation and records `closed_over_open_items = 1`.
- [ ] Install Release builds per the memory recipe (`technique_mac_install_verification`); hash-verify.

## Self-review against the spec

- Shared core: v10 migration (T3), records + helpers + streams (T3), `MissionsSync` (T5), `MissionsAPI` feature-detected by 404 (T4/T5), view models with the spec'd sections/filter/awaiting-first/close (T7), navigation `focus(seq:parkIfNeeded:)` + `focusSeq` on `openChat`/`openConversation(fromDecisions:)` (T8), number resolution "item, mission, milestone in that order" — **gap**: `#N` link resolution in bodies is not a task. Added as Task 13b below.
- Missions tab iOS (T10) and Mac (T11), list row contents (T9), page contents incl. "My inputs only", user close with confirmation (T9/T10/T11), empty states / unsupported hides the tab (T9/T10/T11).
- Transcript: `milestone` card + `mission` notice (T12); title tap replaces summaries; summaries files deleted; `summary_entry` untouched (T12).
- Decisions chip (T13).
- Error handling: sync failures keep cached tables (T5 `refresh` catch); milestone tap on an uncached conversation opens at the tail (`openChat` always works; `takePendingFocus` fires only when the VM mounts; the `focus` fallback lands on the nearest earlier row).
- Testing section: migration up from v9 with items (T3), `MissionsSync` connect/marker/404 (T5), list VM sort/sections/badges + detail filter/order (T7), navigation carries `focusSeq` and parked focus fires (T8), snapshots (T9/T13), Mac override env (constraints).

### Task 13b: `#N` resolution in item and milestone bodies

**Files:**
- Modify: wherever item bodies render `#N` as a link today (grep `ItemRoute(pathValue:` and the `#\d+` regex in `ItemDetailView`/`MarkdownSource`); add `JournalStore.resolveNumber(_ n: Int) throws -> NumberTarget?` with `enum NumberTarget { case item(id: String), mission(id: String), milestone(id: String, convoID: String, seq: Int64) }` checking `item`, then `mission`, then `milestone`; the tap handler routes `.item` → item detail, `.mission` → mission page, `.milestone` → `openChat(convoID, focusSeq: seq)`.
- Test: `JournalStoreMissionsTests.testResolveNumberPrefersItemThenMissionThenMilestone` (numbers cannot collide, so the test seeds distinct numbers and asserts each resolves).

- [ ] Implement, commit `missions: #N resolves across items, missions and milestones`.
