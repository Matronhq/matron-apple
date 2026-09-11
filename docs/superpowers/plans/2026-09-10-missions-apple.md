# Missions & milestones — matron-apple implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give both apps a Missions surface — a Missions tab with a list and a mission page, inline `milestone`/`mission` cards in the transcript that jump to their anchor seq, a conversation title that opens its mission, and a mission `#num` chip on Decisions rows — all fed by a new local mission cache kept fresh by a `MissionsSync` actor.

**Architecture:** Clone the shipped items-tracker client stack one layer at a time: models (`MatronModels`) → marker events (`MatronEvents`) → a GRDB `v10` migration with `MissionRecord`/`MilestoneRecord`/`MissionConversationRecord` and `ValueObservation` streams (`MatronJournal`) → `MissionsProviding` on `JournalAPI`, feature-detected by a 404 → a `MissionsSync` actor whose refreshes coalesce exactly like `ItemsSync`'s → two `@Observable` view models → leaf design-system views → per-platform hosts. Marker events are **invalidation signals only**: the store never learns a mission's title from a marker, because the journal omits `title`/`mission_title` on markers written across the privacy boundary.

**Tech Stack:** Swift 5.10 language mode, SwiftUI, GRDB 6 (`DatabaseMigrator`, `ValueObservation`), XCTest, swift-snapshot-testing (`assertVariants`), xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-10-missions-milestones-design.md`. The journal's shipped contract — `matron-journal` `docs/protocol.md`, section "Missions & milestones", and the conformance fixture `test/fixtures/conformance/15_missions_roundtrip.json` — **supersedes the spec wherever they differ**; every such difference is listed under "Conflicts resolved" at the end of this plan. This is plan 3 of 3; the journal and bridge halves are merged and deployed.

## Global Constraints

- **The GRDB schema migration is additive.** One new identifier, `v10`, registered after `v9` and before `return migrator` in `JournalStore.migrator()`. Never edit an existing migration body — GRDB records identifiers, not bodies, so an edited `v9` silently never runs on an installed device.
- **The store never trusts a marker's title.** `mission.title` and `MissionConversationRecord.title` are written only from `GET /missions` / `GET /missions/:id` responses. A marker's `title` / `mission_title` is optional on the wire (omitted when the marker crosses the privacy boundary), so rendering falls back to `#N` (`MissionMarkerEvent.missionLabel` / `MilestoneMarkerEvent.missionLabel`) and `MissionsSync` fetches the mission for its real title.
- **Numbers are shared across items, missions and milestones.** `#63` may be any of the three; they are drawn from one per-user counter, so they cannot collide. Never render a number with a type-specific prefix, and never assume `#N` is an item.
- **Never stage `Matron/App/Info.plist`.** It is modified in the working tree by builds; `git add` exactly the files each step lists, never `git add -A` or `git add .`.
- **Run `xcodegen generate` after adding or deleting any file** under `Matron/`, `MatronMac/`, `MatronTests/` or `MatronMacTests/` — the xcodegen targets glob those directories, so a new file is invisible to `xcodebuild` until the project is regenerated.
- **MatronMacTests only with `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport`** (and `MATRON_APP_SUPPORT_OVERRIDE` set to the same path — `xcodebuild` forwards only `TEST_RUNNER_*` into the runner, while the SPM bundles that ride along read the unprefixed name). The Mac test host has wiped the live journal store before. Always scope with `-only-testing:MatronMacTests`.
- **Snapshot tests are skipped locally with `MATRON_SKIP_SNAPSHOT_TESTS=1`** (`TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1` for the Mac scheme). Drop the variable only in the steps that explicitly record baselines.
- **Assert the `Executed N tests, with 0 failures` line.** A `| tail`/`| grep` pipeline hides a non-zero `xcodebuild` exit code; read the count, do not infer success from a quiet log.
- **`push`/unread stay untouched.** `mission` and `milestone` are not in `JournalEventType.messageTypes` and the journal's `classify()` returns `nil` for both. No badge, snippet or push code changes anywhere in this plan.
- **Commits.** Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  ```
  and every commit is made as `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit …` — never `git config user.*` inside this worktree (the `.git/config` is shared with the main clone).
- **`item_move` is agent-only.** The apps read `items.mission_id` / `items.mission_num` and display them. No app-side `PATCH /items/:id {mission}`, no move affordance.
- **`summary_entry`, its migrations and its ingest stay.** Only the summaries *UI* is deleted (spec decision #26).

## File map

| File | Responsibility |
|---|---|
| `MatronShared/Sources/Models/Mission.swift` | **new** — `MissionState`, `MilestoneKind`, `Mission`, `Milestone`, `MissionConversation`, `MissionLastMilestone`, JSON inits |
| `MatronShared/Sources/Models/TrackerItem.swift` | `missionID` / `missionNum` on `TrackerItem` |
| `MatronShared/Sources/Events/MissionMarkerEvent.swift` | **new** — `MissionMarkerEvent`, `MilestoneMarkerEvent`, `MissionMarker` (the union carried on one stream) |
| `MatronShared/Sources/Journal/WireModels.swift` | `JournalEventType.mission` / `.milestone` constants |
| `MatronShared/Sources/Journal/JournalStore.swift` | `v10` migration; `wipe()` clears the three new tables |
| `MatronShared/Sources/Journal/JournalStore+Missions.swift` | **new** — records, reads, `ValueObservation` streams, watermark, `wipeMissions()` |
| `MatronShared/Sources/Journal/JournalStore+Items.swift` | `ItemRecord` gains `mission_id` / `mission_num`; `items(missionID:)` |
| `MatronShared/Sources/Journal/JournalAPI+Missions.swift` | **new** — `MissionsListQuery`, `MissionDetail`, `MissionsProviding`, `JournalAPI` conformance |
| `MatronShared/Sources/Journal/JournalSyncEngine.swift` | `missionMarkers()` stream + `publishMissionMarker` in `didApply`/`didApplyBatch` |
| `MatronShared/Sources/Journal/MissionsSync.swift` | **new** — the actor (list refresh, per-mission refetch, coalescing, `isSupported`) |
| `MatronShared/Sources/ViewModels/MissionsListViewModel.swift` | **new** |
| `MatronShared/Sources/ViewModels/MissionDetailViewModel.swift` | **new** |
| `MatronShared/Sources/ViewModels/ChatViewModel.swift` | `FocusOwner.milestone` + public `jumpToMilestone(seq:)` |
| `MatronShared/Sources/DesignSystem/Missions/MissionGlyph.swift` | **new** — symbols/labels/tints |
| `MatronShared/Sources/DesignSystem/Missions/MissionRowView.swift` | **new** |
| `MatronShared/Sources/DesignSystem/Missions/MissionsListView.swift` | **new** — leaf list + empty/unsupported states |
| `MatronShared/Sources/DesignSystem/Missions/MissionDetailView.swift` | **new** — leaf page |
| `MatronShared/Sources/DesignSystem/Missions/MilestoneCard.swift` | **new** — `MilestoneCard`, `MissionNotice` (inline timeline rendering) |
| `MatronShared/Sources/DesignSystem/Items/ItemRow.swift` | mission `#num` chip |
| `MatronShared/Sources/Chat/TimelineItem.swift` | `.milestoneMarker` / `.missionMarker` kinds |
| `MatronShared/Sources/Chat/JournalTimelineMapper.swift` | map both event types |
| `Matron/App/AppShellNavigation.swift`, `AppShellView.swift`, `MissionRoute.swift` | iOS Missions tab, routes, milestone hand-off |
| `Matron/Features/Missions/MissionsTabRoot.swift`, `MissionDetailHost.swift` | **new** — iOS hosts |
| `Matron/Features/Chat/ChatView.swift` | title → mission; `onOpenMission` into the timeline rows |
| `Matron/Features/Chat/Rendering/TimelineItemView.swift` | render the two new kinds |
| `MatronMac/Features/Nav/MacNavColumn.swift` | `MacNav.missions` + generalised badges |
| `MatronMac/Features/ChatList/MacChatListView.swift` | missions column + detail, wired through the hoisted helpers |
| `MatronMac/Features/Missions/MacMissionsColumn.swift`, `MacMissionPage.swift` | **new** — Mac hosts |
| `MatronMac/Features/Chat/MacChatToolbar.swift`, `MacChatView.swift`, `MacTimelineItemView.swift` | title → mission; render the two new kinds |
| `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift` | `MissionsSync` in `JournalCore`; VM factories |
| Deleted | `Matron/Features/Chat/SummariesSheet.swift`, `MatronMac/Features/Chat/MacSummariesPanel.swift`, `MatronTests/SummariesSheetBindingTests.swift`, `MatronMacTests/MacSummariesPanelSnapshotTests.swift` + its `__Snapshots__` folder |

---

### Task 1: Models — `Mission`, `Milestone`, and mission fields on `TrackerItem`

**Files:**
- Create: `MatronShared/Sources/Models/Mission.swift`
- Modify: `MatronShared/Sources/Models/TrackerItem.swift`
- Modify: `MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift` (the private `TrackerItem.with(rank:)` helper enumerates every field)
- Test: `MatronShared/Tests/JournalTests/MissionModelTests.swift` (new)

**Interfaces:**
- Produces: `MissionState`, `MilestoneKind`, `MissionLastMilestone`, `Mission`, `Milestone`, `MissionConversation` in `MatronModels`; `TrackerItem.missionID: String?` and `TrackerItem.missionNum: Int?`.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/MissionModelTests.swift`. The JSON literals are copied from the journal's conformance fixture `15_missions_roundtrip.json` and the row shapes documented in `docs/protocol.md`.

```swift
import XCTest
import MatronModels
@testable import MatronJournal

final class MissionModelTests: XCTestCase {
    /// Exactly the mission row `POST /missions` returns in the journal's
    /// conformance fixture (15_missions_roundtrip.json), plus the counts
    /// `GET /missions` adds. `idem_key` is never returned by the journal.
    static let missionJSON: [String: Any] = [
        "id": "ms_a1", "user_id": 1, "num": 61, "state": "open",
        "title": "Missions & milestones", "body": "Ship it",
        "close_summary": NSNull(), "closed_by": NSNull(), "closed_over_open_items": 0,
        "origin_convo_id": "c1", "origin_device_id": 3, "created_by": "agent",
        "created_at": 1_700_000_000_000, "updated_at": 1_700_000_005_000,
        "last_milestone_at": 1_700_000_004_000, "closed_at": NSNull(),
        "open_items": 2, "needs_you": 1, "conversations": 3, "milestones": 4,
        "last_milestone": ["num": 63, "title": "Wired the migration", "kind": "user_input", "created_at": 1_700_000_004_000],
    ]

    static let milestoneJSON: [String: Any] = [
        "id": "ml_b2", "mission_id": "ms_a1", "user_id": 1, "num": 63, "kind": "user_input",
        "title": "Dan asked for missions", "body": "the brief", "convo_id": "c1", "seq": 4210,
        "device_id": 3, "created_by": "agent", "created_at": 1_700_000_004_000,
    ]

    func testMissionDecodesIncludingCountsAndLastMilestone() throws {
        let m = try XCTUnwrap(Mission(json: Self.missionJSON))
        XCTAssertEqual(m.id, "ms_a1"); XCTAssertEqual(m.num, 61); XCTAssertEqual(m.state, .open)
        XCTAssertEqual(m.title, "Missions & milestones"); XCTAssertEqual(m.body, "Ship it")
        XCTAssertNil(m.closeSummary); XCTAssertNil(m.closedBy); XCTAssertEqual(m.closedOverOpenItems, 0)
        XCTAssertEqual(m.originConvoID, "c1"); XCTAssertEqual(m.createdBy, .agent)
        XCTAssertEqual(m.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(m.lastMilestoneAt, Date(timeIntervalSince1970: 1_700_000_004))
        XCTAssertNil(m.closedAt)
        XCTAssertEqual(m.openItems, 2); XCTAssertEqual(m.needsYou, 1)
        XCTAssertEqual(m.conversationCount, 3); XCTAssertEqual(m.milestoneCount, 4)
        XCTAssertEqual(m.lastMilestone?.num, 63)
        XCTAssertEqual(m.lastMilestone?.kind, .userInput)
        XCTAssertEqual(m.lastMilestone?.title, "Wired the migration")
    }

    /// A mission row with none of the `GET /missions` counts (the shape
    /// `POST /missions/:id/close` and `PATCH` return) must still decode —
    /// the counts default to zero rather than failing the whole row.
    func testMissionDecodesWithoutCounts() throws {
        var bare = Self.missionJSON
        for key in ["open_items", "needs_you", "conversations", "milestones", "last_milestone"] { bare.removeValue(forKey: key) }
        let m = try XCTUnwrap(Mission(json: bare))
        XCTAssertEqual(m.openItems, 0); XCTAssertEqual(m.needsYou, 0)
        XCTAssertEqual(m.conversationCount, 0); XCTAssertEqual(m.milestoneCount, 0)
        XCTAssertNil(m.lastMilestone)
    }

    func testMissionRejectsUnknownStateAndMissingKeys() {
        var bad = Self.missionJSON; bad["state"] = "paused"
        XCTAssertNil(Mission(json: bad))
        bad = Self.missionJSON; bad.removeValue(forKey: "num")
        XCTAssertNil(Mission(json: bad))
        bad = Self.missionJSON; bad.removeValue(forKey: "origin_convo_id")
        XCTAssertNil(Mission(json: bad))
    }

    func testClosedMissionCarriesSummaryAndOverride() throws {
        var closed = Self.missionJSON
        closed["state"] = "closed"; closed["close_summary"] = "Done."; closed["closed_by"] = "user"
        closed["closed_over_open_items"] = 2; closed["closed_at"] = 1_700_000_009_000
        let m = try XCTUnwrap(Mission(json: closed))
        XCTAssertEqual(m.state, .closed); XCTAssertEqual(m.closeSummary, "Done.")
        XCTAssertEqual(m.closedBy, .user); XCTAssertEqual(m.closedOverOpenItems, 2)
        XCTAssertEqual(m.closedAt, Date(timeIntervalSince1970: 1_700_000_009))
    }

    func testMilestoneDecodesAndKeepsItsAnchorSeq() throws {
        let ms = try XCTUnwrap(Milestone(json: Self.milestoneJSON))
        XCTAssertEqual(ms.id, "ml_b2"); XCTAssertEqual(ms.missionID, "ms_a1"); XCTAssertEqual(ms.num, 63)
        XCTAssertEqual(ms.kind, .userInput); XCTAssertEqual(ms.title, "Dan asked for missions")
        XCTAssertEqual(ms.body, "the brief"); XCTAssertEqual(ms.convoID, "c1")
        XCTAssertEqual(ms.seq, 4210); XCTAssertEqual(ms.deviceID, 3); XCTAssertEqual(ms.createdBy, .agent)
        XCTAssertEqual(ms.createdAt, Date(timeIntervalSince1970: 1_700_000_004))
    }

    func testMilestoneRejectsUnknownKind() {
        var bad = Self.milestoneJSON; bad["kind"] = "vibes"
        XCTAssertNil(Milestone(json: bad))
        bad = Self.milestoneJSON; bad.removeValue(forKey: "seq")
        XCTAssertNil(Milestone(json: bad), "a milestone with no anchor is unusable — reject it")
    }

    func testMissionConversationDecodes() throws {
        let c = try XCTUnwrap(MissionConversation(json: ["id": "c1", "title": "Session", "box": "dev-2", "state": "running"]))
        XCTAssertEqual(c.id, "c1"); XCTAssertEqual(c.title, "Session")
        XCTAssertEqual(c.box, "dev-2"); XCTAssertEqual(c.state, "running")
        let noBox = try XCTUnwrap(MissionConversation(json: ["id": "c2", "title": "Other", "box": NSNull(), "state": "idle"]))
        XCTAssertNil(noBox.box)
    }

    /// `items.mission_id` / `mission_num` ride the ordinary item row (the
    /// journal's DECORATE adds them). Both are optional: an item filed in a
    /// conversation with no mission has neither.
    func testTrackerItemCarriesMissionIdentity() throws {
        var json = ItemsAPITests.itemJSON
        json["mission_id"] = "ms_a1"; json["mission_num"] = 61
        let item = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertEqual(item.missionID, "ms_a1"); XCTAssertEqual(item.missionNum, 61)
        let unassigned = try XCTUnwrap(TrackerItem(json: ItemsAPITests.itemJSON))
        XCTAssertNil(unassigned.missionID); XCTAssertNil(unassigned.missionNum)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionModelTests`
Expected: FAIL — `cannot find 'Mission' in scope`.

- [ ] **Step 3: Write `MatronShared/Sources/Models/Mission.swift`**

```swift
import Foundation

/// A mission's lifecycle. Mirrors the journal's `missions.state` CHECK.
public enum MissionState: String, Codable, Sendable, CaseIterable { case open, closed }

/// Why a milestone was posted. `user_input` is the one that answers Dan's
/// stated pain ("get back to my last input"); `progress` is the agent's own
/// checkpoint and has no cap.
public enum MilestoneKind: String, Codable, Sendable, CaseIterable {
    case userInput = "user_input"
    case progress
}

private func msDate(_ v: Any?) -> Date? {
    guard let n = v as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000)
}

/// The `last_milestone` summary the journal attaches to each `GET /missions`
/// row — enough for the list row without a second fetch. For a filtered
/// (ordinary agent) caller the journal sieves this; for a client device it is
/// the real newest one.
public struct MissionLastMilestone: Equatable, Hashable, Sendable, Codable {
    public let num: Int
    public let title: String
    public let kind: MilestoneKind
    public let createdAt: Date
    public init(num: Int, title: String, kind: MilestoneKind, createdAt: Date) {
        self.num = num; self.title = title; self.kind = kind; self.createdAt = createdAt
    }
    public init?(json: [String: Any]) {
        guard let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let createdAt = msDate(json["created_at"]) else { return nil }
        self.init(num: num, title: json["title"] as? String ?? "", kind: kind, createdAt: createdAt)
    }
}

/// One mission — the human-readable record of a piece of work, numbered from
/// the same per-user counter as items and milestones (`#61` names exactly one
/// thing). `idem_key` is internal to the journal and never on the wire.
public struct Mission: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let state: MissionState
    public let title: String
    public let body: String
    public let closeSummary: String?
    public let closedBy: ItemAuthor?
    /// Count of items still open when a user forced the close. Includes
    /// items this caller cannot see (protocol, "Accepted exception —
    /// numbers, never words"), so it can exceed `openItems`.
    public let closedOverOpenItems: Int
    public let originConvoID: String
    public let originDeviceID: Int64
    public let createdBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date
    /// The list's sort key. `nil` for a mission with no milestones yet.
    public let lastMilestoneAt: Date?
    public let closedAt: Date?
    // Counts, present only on `GET /missions` rows; zero elsewhere.
    public let openItems: Int
    public let needsYou: Int
    public let conversationCount: Int
    public let milestoneCount: Int
    public let lastMilestone: MissionLastMilestone?

    public init(id: String, num: Int, state: MissionState = .open, title: String, body: String = "",
                closeSummary: String? = nil, closedBy: ItemAuthor? = nil, closedOverOpenItems: Int = 0,
                originConvoID: String, originDeviceID: Int64 = 0, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(), lastMilestoneAt: Date? = nil,
                closedAt: Date? = nil, openItems: Int = 0, needsYou: Int = 0, conversationCount: Int = 0,
                milestoneCount: Int = 0, lastMilestone: MissionLastMilestone? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body
        self.closeSummary = closeSummary; self.closedBy = closedBy; self.closedOverOpenItems = closedOverOpenItems
        self.originConvoID = originConvoID; self.originDeviceID = originDeviceID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastMilestoneAt = lastMilestoneAt
        self.closedAt = closedAt; self.openItems = openItems; self.needsYou = needsYou
        self.conversationCount = conversationCount; self.milestoneCount = milestoneCount
        self.lastMilestone = lastMilestone
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let state = (json["state"] as? String).flatMap(MissionState.init(rawValue:)),
              let title = json["title"] as? String,
              let origin = json["origin_convo_id"] as? String,
              let createdAt = msDate(json["created_at"]), let updatedAt = msDate(json["updated_at"])
        else { return nil }
        self.init(
            id: id, num: num, state: state, title: title, body: json["body"] as? String ?? "",
            closeSummary: json["close_summary"] as? String,
            closedBy: (json["closed_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
            closedOverOpenItems: (json["closed_over_open_items"] as? NSNumber)?.intValue ?? 0,
            originConvoID: origin, originDeviceID: (json["origin_device_id"] as? NSNumber)?.int64Value ?? 0,
            createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
            createdAt: createdAt, updatedAt: updatedAt,
            lastMilestoneAt: msDate(json["last_milestone_at"]), closedAt: msDate(json["closed_at"]),
            openItems: (json["open_items"] as? NSNumber)?.intValue ?? 0,
            needsYou: (json["needs_you"] as? NSNumber)?.intValue ?? 0,
            conversationCount: (json["conversations"] as? NSNumber)?.intValue ?? 0,
            milestoneCount: (json["milestones"] as? NSNumber)?.intValue ?? 0,
            lastMilestone: (json["last_milestone"] as? [String: Any]).flatMap(MissionLastMilestone.init(json:)))
    }

    /// What the mission is called wherever a number alone would be opaque.
    public var label: String { "#\(num) \(title)" }
}

/// One checkpoint. `seq` is the anchor: the `milestone` marker event's own
/// seq in `convoID`, and the only way back to where it happened.
public struct Milestone: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let missionID: String
    public let num: Int
    public let kind: MilestoneKind
    public let title: String
    public let body: String
    public let convoID: String
    public let seq: Int64
    public let deviceID: Int64
    public let createdBy: ItemAuthor
    public let createdAt: Date

    public init(id: String, missionID: String, num: Int, kind: MilestoneKind, title: String, body: String = "",
                convoID: String, seq: Int64, deviceID: Int64 = 0, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date()) {
        self.id = id; self.missionID = missionID; self.num = num; self.kind = kind; self.title = title
        self.body = body; self.convoID = convoID; self.seq = seq; self.deviceID = deviceID
        self.createdBy = createdBy; self.createdAt = createdAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let missionID = json["mission_id"] as? String,
              let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let title = json["title"] as? String, let convoID = json["convo_id"] as? String,
              // No seq, no anchor — and a milestone with no anchor is worse
              // than none (spec, "Milestone anchor").
              let seq = (json["seq"] as? NSNumber)?.int64Value,
              let createdAt = msDate(json["created_at"]) else { return nil }
        self.init(id: id, missionID: missionID, num: num, kind: kind, title: title,
                  body: json["body"] as? String ?? "", convoID: convoID, seq: seq,
                  deviceID: (json["device_id"] as? NSNumber)?.int64Value ?? 0,
                  createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                  createdAt: createdAt)
    }
}

/// A conversation belonging to a mission, as `GET /missions/:id` returns it.
/// Not a `ChatSummary`: it carries only what the mission page shows, and its
/// rows can name conversations this device has never synced.
public struct MissionConversation: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let box: String?
    public let state: String
    public init(id: String, title: String, box: String?, state: String) {
        self.id = id; self.title = title; self.box = box; self.state = state
    }
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", box: json["box"] as? String,
                  state: json["state"] as? String ?? "")
    }
}
```

- [ ] **Step 4: Add the mission fields to `TrackerItem`**

In `MatronShared/Sources/Models/TrackerItem.swift`, inside `struct TrackerItem`, add after `public let hasImage: Bool`:

```swift
    /// The mission this item belongs to, defaulted by the journal from the
    /// origin conversation and repointable by an agent (`item_move`). The
    /// apps only ever DISPLAY it. Both are `nil` for an item filed in a
    /// conversation with no mission — and `missionID` can be present while
    /// the mission itself is invisible to this caller (protocol, "Accepted
    /// exception"), so never assume a local `mission` row exists for it.
    public let missionID: String?
    public let missionNum: Int?
```

Extend the memberwise `init` — add `missionID: String? = nil, missionNum: Int? = nil` after `hasImage: Bool = false` and assign both in the body — and extend `init?(json:)`'s `self.init(...)` call with:

```swift
            missionID: json["mission_id"] as? String,
            missionNum: (json["mission_num"] as? NSNumber)?.intValue)
```

- [ ] **Step 5: Carry the new fields through `TrackerItem.with(rank:)`**

`MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift` has a private extension that rebuilds a `TrackerItem` field by field. Add the two fields to its `TrackerItem(...)` call so an optimistic reorder cannot drop an item's mission:

```swift
                    hasImage: hasImage, missionID: missionID, missionNum: missionNum)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "MissionModelTests|ItemsAPITests|ItemsPanelViewModelTests"`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Models/Mission.swift MatronShared/Sources/Models/TrackerItem.swift \
        MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift \
        MatronShared/Tests/JournalTests/MissionModelTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: Mission, Milestone and mission identity on TrackerItem" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Marker events — `MissionMarkerEvent`, `MilestoneMarkerEvent`, and the `#N` fallback

**Files:**
- Create: `MatronShared/Sources/Events/MissionMarkerEvent.swift`
- Modify: `MatronShared/Sources/Journal/WireModels.swift` (`JournalEventType`)
- Test: `MatronShared/Tests/EventsTests/MissionMarkerEventTests.swift` (new)

**Interfaces:**
- Consumes: `MilestoneKind`, `ItemAuthor` (Task 1).
- Produces: `MissionMarkerEvent` (`missionID`, `num`, `title: String?`, `action`, `by`, `openItemNums: [Int]`, `missionLabel`), `MilestoneMarkerEvent` (`milestoneID`, `num`, `kind`, `title`, `body`, `missionID`, `missionNum`, `missionTitle: String?`, `by`, `missionLabel`), and `MissionMarker` — the union both are delivered as on one stream. `JournalEventType.mission` / `.milestone`.

**Why the titles are optional:** the journal drops `title` (on `mission`) and `mission_title` (on `milestone`) at write time whenever the marker lands in a conversation that is not private-owned while the mission's origin conversation is. `num` / `mission_num` always survive. So every consumer renders `missionLabel` — the title when it is there, `#N` when it is not — and `MissionsSync` fetches the mission to learn the real title.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/EventsTests/MissionMarkerEventTests.swift`:

```swift
import XCTest
import MatronModels
@testable import MatronEvents

final class MissionMarkerEventTests: XCTestCase {
    /// The milestone payload exactly as the journal's conformance fixture
    /// (15_missions_roundtrip.json) shows it on GET /convo/:id/messages.
    static let milestonePayload: [String: Any] = [
        "milestone_id": "ml_b2", "num": 63, "kind": "user_input",
        "title": "Dan asked for missions", "body": "the brief",
        "mission_id": "ms_a1", "mission_num": 61, "mission_title": "Missions & milestones",
        "by": "agent",
    ]

    static let missionPayload: [String: Any] = [
        "mission_id": "ms_a1", "num": 61, "title": "Missions & milestones",
        "action": "created", "by": "agent",
    ]

    func testMilestoneMarkerParses() throws {
        let m = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: Self.milestonePayload))
        XCTAssertEqual(m.milestoneID, "ml_b2"); XCTAssertEqual(m.num, 63)
        XCTAssertEqual(m.kind, .userInput); XCTAssertEqual(m.title, "Dan asked for missions")
        XCTAssertEqual(m.body, "the brief"); XCTAssertEqual(m.missionID, "ms_a1")
        XCTAssertEqual(m.missionNum, 61); XCTAssertEqual(m.missionTitle, "Missions & milestones")
        XCTAssertEqual(m.by, .agent); XCTAssertEqual(m.missionLabel, "Missions & milestones")
    }

    /// Protocol, "Markers written across the boundary carry numbers only":
    /// a marker written into a public conversation for a private-origin
    /// mission omits `mission_title`. It must still parse, and it must
    /// render as `#61` — never as an empty string.
    func testMilestoneMarkerWithoutMissionTitleFallsBackToTheNumber() throws {
        var sieved = Self.milestonePayload
        sieved.removeValue(forKey: "mission_title")
        let m = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: sieved))
        XCTAssertNil(m.missionTitle)
        XCTAssertEqual(m.missionLabel, "#61")
        XCTAssertEqual(m.missionNum, 61, "the number always crosses the boundary")
        XCTAssertEqual(m.title, "Dan asked for missions", "the milestone's OWN title is that conversation's content and stays")
    }

    func testMilestoneMarkerRejectsMissingIdentityAndUnknownKind() {
        var bad = Self.milestonePayload; bad["kind"] = "vibes"
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: bad))
        bad = Self.milestonePayload; bad.removeValue(forKey: "mission_id")
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: bad))
        bad = Self.milestonePayload; bad.removeValue(forKey: "mission_num")
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: bad), "with no number there is nothing to fall back to")
    }

    func testMissionMarkerParsesEveryAction() throws {
        for action in ["created", "joined", "updated", "closed"] {
            var payload = Self.missionPayload; payload["action"] = action
            let m = try XCTUnwrap(MissionMarkerEvent.parse(payload: payload), action)
            XCTAssertEqual(m.action.rawValue, action)
            XCTAssertEqual(m.missionID, "ms_a1"); XCTAssertEqual(m.num, 61)
            XCTAssertEqual(m.missionLabel, "Missions & milestones")
            XCTAssertTrue(m.openItemNums.isEmpty)
        }
        var unknown = Self.missionPayload; unknown["action"] = "vaporised"
        XCTAssertNil(MissionMarkerEvent.parse(payload: unknown))
    }

    func testMissionMarkerWithoutTitleFallsBackToTheNumber() throws {
        var sieved = Self.missionPayload
        sieved["action"] = "joined"; sieved.removeValue(forKey: "title")
        let m = try XCTUnwrap(MissionMarkerEvent.parse(payload: sieved))
        XCTAssertNil(m.title)
        XCTAssertEqual(m.missionLabel, "#61")
    }

    /// A user-forced close records which item numbers were still open.
    func testMissionCloseMarkerCarriesOpenItemNumbers() throws {
        var payload = Self.missionPayload
        payload["action"] = "closed"; payload["by"] = "user"; payload["open_item_nums"] = [64, 70]
        let m = try XCTUnwrap(MissionMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.action, .closed); XCTAssertEqual(m.by, .user)
        XCTAssertEqual(m.openItemNums, [64, 70])
    }

    /// One stream carries both kinds — `MissionsSync` needs the mission id
    /// out of either without switching at every call site.
    func testMissionMarkerUnionExposesTheMissionID() throws {
        let milestone = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: Self.milestonePayload))
        let mission = try XCTUnwrap(MissionMarkerEvent.parse(payload: Self.missionPayload))
        XCTAssertEqual(MissionMarker.milestone(milestone).missionID, "ms_a1")
        XCTAssertEqual(MissionMarker.mission(mission).missionID, "ms_a1")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionMarkerEventTests`
Expected: FAIL — `cannot find 'MilestoneMarkerEvent' in scope`.

- [ ] **Step 3: Write `MatronShared/Sources/Events/MissionMarkerEvent.swift`**

```swift
import Foundation
import MatronModels

/// The `milestone` journal event (protocol: "Marker events"). Its own `seq`
/// is the anchor — the row that renders it IS the jump target — so the
/// mapper keeps the event seq alongside it.
///
/// `missionTitle` is OPTIONAL on purpose. The journal drops it at write time
/// whenever the mission's origin conversation is private-owned and the
/// conversation being written to is not, so an ordinary agent replaying that
/// conversation never reads the private mission's name. `missionNum` always
/// survives; render `missionLabel`, never `missionTitle ?? ""`.
public struct MilestoneMarkerEvent: Equatable, Sendable {
    public let milestoneID: String
    public let num: Int
    public let kind: MilestoneKind
    public let title: String
    public let body: String
    public let missionID: String
    public let missionNum: Int
    public let missionTitle: String?
    public let by: ItemAuthor

    public init(milestoneID: String, num: Int, kind: MilestoneKind, title: String, body: String = "",
                missionID: String, missionNum: Int, missionTitle: String? = nil, by: ItemAuthor = .agent) {
        self.milestoneID = milestoneID; self.num = num; self.kind = kind; self.title = title
        self.body = body; self.missionID = missionID; self.missionNum = missionNum
        self.missionTitle = missionTitle; self.by = by
    }

    /// How to name the mission in the UI: its title when the marker carried
    /// one, otherwise its number. Never an empty string.
    public var missionLabel: String { missionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(missionNum)" }

    public static func parse(payload: [String: Any]) -> MilestoneMarkerEvent? {
        guard let milestoneID = payload["milestone_id"] as? String,
              let num = (payload["num"] as? NSNumber)?.intValue,
              let kind = (payload["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let title = payload["title"] as? String,
              let missionID = payload["mission_id"] as? String,
              let missionNum = (payload["mission_num"] as? NSNumber)?.intValue,
              let by = (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:))
        else { return nil }
        return MilestoneMarkerEvent(milestoneID: milestoneID, num: num, kind: kind, title: title,
                                    body: payload["body"] as? String ?? "", missionID: missionID,
                                    missionNum: missionNum, missionTitle: payload["mission_title"] as? String, by: by)
    }
}

/// The `mission` journal event. Purely an invalidation signal plus a
/// one-line inline notice — the apps re-read the mission over HTTP rather
/// than trusting anything here beyond the number and the action.
public struct MissionMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case created, joined, updated, closed }
    public let missionID: String
    public let num: Int
    /// Optional for the same boundary reason as `MilestoneMarkerEvent.missionTitle`.
    public let title: String?
    public let action: Action
    public let by: ItemAuthor
    /// Only on a user-forced close: the numbers of items still open at the
    /// time, hidden ones included (the user's own record of their override).
    public let openItemNums: [Int]

    public init(missionID: String, num: Int, title: String? = nil, action: Action,
                by: ItemAuthor = .agent, openItemNums: [Int] = []) {
        self.missionID = missionID; self.num = num; self.title = title
        self.action = action; self.by = by; self.openItemNums = openItemNums
    }

    public var missionLabel: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(num)" }

    public static func parse(payload: [String: Any]) -> MissionMarkerEvent? {
        guard let missionID = payload["mission_id"] as? String,
              let num = (payload["num"] as? NSNumber)?.intValue,
              let action = (payload["action"] as? String).flatMap(Action.init(rawValue:)),
              let by = (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:))
        else { return nil }
        return MissionMarkerEvent(missionID: missionID, num: num, title: payload["title"] as? String,
                                  action: action, by: by,
                                  openItemNums: (payload["open_item_nums"] as? [NSNumber])?.map(\.intValue) ?? [])
    }
}

/// Both marker types on one stream — `MissionsSync` reacts to either by
/// refetching the same mission, so a single feed keeps the engine's
/// publishing site and the actor's subscription simple.
public enum MissionMarker: Equatable, Sendable {
    case mission(MissionMarkerEvent)
    case milestone(MilestoneMarkerEvent)

    public var missionID: String {
        switch self {
        case .mission(let m): return m.missionID
        case .milestone(let m): return m.missionID
        }
    }
}
```

- [ ] **Step 4: Add the event-type constants**

In `MatronShared/Sources/Journal/WireModels.swift`, inside `enum JournalEventType`, after the `item` constant:

```swift
    /// Mission lifecycle marker (spec 2026-09-10). Like `item`, deliberately
    /// NOT in `messageTypes`: the journal's `classify()` returns nil for it,
    /// so it never bumps unread, sets a snippet, or pushes.
    public static let mission = "mission"
    /// Milestone marker. Its own `seq` is the milestone's anchor — the row
    /// IS the jump target. Also outside `messageTypes`, for the same reason.
    public static let milestone = "milestone"
```

- [ ] **Step 5: Pin that neither type is a message type**

Append to `MatronShared/Tests/JournalTests/WireModelsTests.swift`:

```swift
    /// push/unread stay untouched (spec, "Marker events"): the journal
    /// never pushes these and never snippets them, so the client mirror
    /// must not either.
    func testMissionAndMilestoneAreNotMessageTypes() {
        XCTAssertFalse(JournalEventType.messageTypes.contains(JournalEventType.mission))
        XCTAssertFalse(JournalEventType.messageTypes.contains(JournalEventType.milestone))
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "MissionMarkerEventTests|WireModelsTests"`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Events/MissionMarkerEvent.swift MatronShared/Sources/Journal/WireModels.swift \
        MatronShared/Tests/EventsTests/MissionMarkerEventTests.swift MatronShared/Tests/JournalTests/WireModelsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: mission and milestone marker events, with the #N title fallback" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Store — the additive `v10` migration, records, queries and streams

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (`migrator()`, `wipe()`)
- Create: `MatronShared/Sources/Journal/JournalStore+Missions.swift`
- Modify: `MatronShared/Sources/Journal/JournalStore+Items.swift` (`ItemRecord` columns, `items(missionID:)`)
- Test: `MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift` (new)

**Interfaces:**
- Consumes: `Mission`, `Milestone`, `MissionConversation`, `TrackerItem.missionID` (Task 1).
- Produces on `JournalStore`: `upsertMissions(_:)`, `missions(state:)`, `missionsStream(state:)`, `mission(id:)`, `mission(num:)`, `missionStream(id:)`, `replaceMilestones(missionID:_:)`, `milestones(missionID:)`, `milestonesStream(missionID:)`, `milestones(convoID:)`, `replaceMissionConversations(missionID:_:)`, `missionConversations(missionID:)`, `missionConversationsStream(missionID:)`, `missionID(convoID:)`, `missionIDStream(convoID:)`, `items(missionID:)`, `itemsStream(missionID:)`, `missionsWatermark()`, `setMissionsWatermark(_:)`, `wipeMissions()`, `static wipeMissionTables(_:)` (the one SQL site for clearing the cache, shared with `wipe()`). Record types `MissionRecord`, `MilestoneRecord`, `MissionConversationRecord`.

**`missionID(convoID:)` is derived locally.** `GET /snapshot` does not carry `conversations.mission_id`, so there is no column to mirror. A conversation's mission is whichever local mission it is the origin of, else the mission of any milestone posted in it. Both facts arrive with the missions fetch, so the answer is empty until the first `MissionsSync.refresh()` lands — which is exactly when the title-tap affordance should appear.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift`:

```swift
import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreMissionsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    private func mission(_ id: String, num: Int, state: MissionState = .open, convo: String = "c1",
                         lastMilestoneAt: TimeInterval? = 10, needsYou: Int = 0,
                         closedAt: TimeInterval? = nil) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", body: "goal", originConvoID: convo,
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: lastMilestoneAt.map { Date(timeIntervalSince1970: $0) },
                closedAt: closedAt.map { Date(timeIntervalSince1970: $0) },
                openItems: needsYou, needsYou: needsYou, conversationCount: 1, milestoneCount: 1,
                lastMilestone: MissionLastMilestone(num: num + 1, title: "step", kind: .progress,
                                                    createdAt: Date(timeIntervalSince1970: lastMilestoneAt ?? 0)))
    }

    private func milestone(_ id: String, mission: String, num: Int, convo: String = "c1",
                           seq: Int64, kind: MilestoneKind = .progress, created: TimeInterval) -> Milestone {
        Milestone(id: id, missionID: mission, num: num, kind: kind, title: "T\(num)", body: "b",
                  convoID: convo, seq: seq, createdAt: Date(timeIntervalSince1970: created))
    }

    func testMigrationV10CreatesTablesAndItemColumns() throws {
        let store = try makeStore()
        let names = try store.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        XCTAssertTrue(names.contains("mission"))
        XCTAssertTrue(names.contains("milestone"))
        XCTAssertTrue(names.contains("mission_conversation"))
        let itemCols = try store.dbQueue.read { db in try Row.fetchAll(db, sql: "PRAGMA table_info(item)").map { $0["name"] as String } }
        XCTAssertTrue(itemCols.contains("mission_id"))
        XCTAssertTrue(itemCols.contains("mission_num"))
    }

    /// The migration is additive: a database already at v9 with real item
    /// rows must gain the columns without losing anything.
    func testV10MigratesUpFromV9WithExistingItems() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "v9")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO item(id, num, kind, state, rank, title, body, labels_json, links_json,
                                 attachments_json, origin_convo_id, created_by, created_at, updated_at,
                                 comment_count, has_image)
                VALUES('it_1', 5, 'task', 'open', 1024, 'Existing', '', '[]', '[]', '[]', 'c1', 'agent', 1, 2, 0, 0)
                """)
        }
        try JournalStore.migrator().migrate(queue)   // up to the head, i.e. v10
        let row = try queue.read { db in try Row.fetchOne(db, sql: "SELECT title, mission_id, mission_num FROM item WHERE id='it_1'") }
        XCTAssertEqual(row?["title"], "Existing")
        XCTAssertNil(row?["mission_id"] as String?)
        XCTAssertNil(row?["mission_num"] as Int?)
    }

    func testMissionsRoundTripAndSortByLatestMilestone() throws {
        let store = try makeStore()
        try store.upsertMissions([
            mission("ms_1", num: 61, lastMilestoneAt: 10),
            mission("ms_2", num: 62, convo: "c2", lastMilestoneAt: 30, needsYou: 2),
            mission("ms_3", num: 63, convo: "c3", lastMilestoneAt: nil),
            mission("ms_4", num: 64, state: .closed, convo: "c4", lastMilestoneAt: 20, closedAt: 40),
        ])
        // Open, newest milestone first, a mission with no milestone last.
        XCTAssertEqual(try store.missions(state: .open).map(\.id), ["ms_2", "ms_1", "ms_3"])
        XCTAssertEqual(try store.missions(state: .closed).map(\.id), ["ms_4"])
        XCTAssertEqual(try store.missions(state: nil).count, 4)
        XCTAssertEqual(try store.mission(id: "ms_2")?.needsYou, 2)
        XCTAssertEqual(try store.mission(id: "ms_2")?.lastMilestone?.title, "step")
        XCTAssertEqual(try store.mission(num: 63)?.id, "ms_3")
        XCTAssertNil(try store.mission(num: 999))

        // Upsert replaces in place — the fetched row wins, no duplicates.
        try store.upsertMissions([mission("ms_1", num: 61, state: .closed, lastMilestoneAt: 10, closedAt: 50)])
        XCTAssertEqual(try store.missions(state: nil).count, 4)
        XCTAssertEqual(try store.mission(id: "ms_1")?.state, .closed)
    }

    func testMilestonesAreReplacedWholesaleAndReadNewestFirst() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMilestones(missionID: "ms_1", [
            milestone("ml_1", mission: "ms_1", num: 62, seq: 100, created: 1),
            milestone("ml_2", mission: "ms_1", num: 63, seq: 200, kind: .userInput, created: 5),
        ])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_2", "ml_1"])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").first?.seq, 200)
        try store.replaceMilestones(missionID: "ms_1", [milestone("ml_2", mission: "ms_1", num: 63, seq: 200, created: 5)])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_2"], "a replace drops rows the server no longer returns")
    }

    func testMilestonesByConversationAreNewestFirst() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMilestones(missionID: "ms_1", [
            milestone("ml_1", mission: "ms_1", num: 62, convo: "c1", seq: 100, created: 1),
            milestone("ml_2", mission: "ms_1", num: 63, convo: "c9", seq: 900, created: 9),
            milestone("ml_3", mission: "ms_1", num: 64, convo: "c1", seq: 300, created: 3),
        ])
        XCTAssertEqual(try store.milestones(convoID: "c1").map(\.id), ["ml_3", "ml_1"])
        XCTAssertEqual(try store.milestones(convoID: "nope"), [])
    }

    /// A conversation's mission: origin first, then any milestone posted in
    /// it (the join / inheritance cases, which the snapshot never carries).
    func testMissionIDForConversationPrefersOriginThenMilestone() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61, convo: "c1")])
        try store.replaceMilestones(missionID: "ms_1", [milestone("ml_1", mission: "ms_1", num: 62, convo: "c7", seq: 10, created: 1)])
        XCTAssertEqual(try store.missionID(convoID: "c1"), "ms_1", "origin conversation")
        XCTAssertEqual(try store.missionID(convoID: "c7"), "ms_1", "joined conversation, learned from its milestone")
        XCTAssertNil(try store.missionID(convoID: "c8"))
    }

    func testMissionConversationsAreReplacedWholesale() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running"),
            MissionConversation(id: "c2", title: "Other", box: nil, state: "idle"),
        ])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1").map(\.id), ["c1", "c2"])
        XCTAssertNil(try store.missionConversations(missionID: "ms_1").last?.box)
        try store.replaceMissionConversations(missionID: "ms_1", [MissionConversation(id: "c2", title: "Other", box: nil, state: "idle")])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1").map(\.id), ["c2"])
    }

    /// The mission page's open items come from the local item cache, with
    /// the ones awaiting the user first.
    func testItemsForMissionPutAwaitingYouFirst() throws {
        let store = try makeStore()
        try store.upsertItems([
            TrackerItem(id: "it_1", num: 1, kind: .task, awaiting: .agent, title: "agent one",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 9), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_2", num: 2, kind: .question, awaiting: .user, title: "needs you",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 1), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_3", num: 3, kind: .task, state: .closed, title: "done",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 8), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_4", num: 4, kind: .task, awaiting: .agent, title: "other mission",
                        originConvoID: "c2", updatedAt: Date(timeIntervalSince1970: 7), missionID: "ms_9", missionNum: 99),
        ])
        XCTAssertEqual(try store.items(missionID: "ms_1").map(\.id), ["it_2", "it_1"],
                       "awaiting-you first, then updatedAt desc; closed items are excluded")
    }

    func testMissionsStreamEmitsOnWrite() async throws {
        let store = try makeStore()
        var iterator = store.missionsStream(state: .open).makeAsyncIterator()
        _ = await iterator.next()   // initial (empty) value
        try store.upsertMissions([mission("ms_1", num: 61)])
        let next = await iterator.next()
        XCTAssertEqual(next??.map(\.id) ?? [], ["ms_1"])
    }

    func testWipeClearsTheMissionCache() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMilestones(missionID: "ms_1", [milestone("ml_1", mission: "ms_1", num: 62, seq: 1, created: 1)])
        try store.replaceMissionConversations(missionID: "ms_1", [MissionConversation(id: "c1", title: "S", box: nil, state: "idle")])
        try store.setMissionsWatermark(Date(timeIntervalSince1970: 100))
        try store.wipe()
        XCTAssertEqual(try store.missions(state: nil), [])
        XCTAssertEqual(try store.milestones(missionID: "ms_1"), [])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1"), [])
        XCTAssertNil(try store.missionsWatermark())
    }

    func testMissionsWatermarkRoundTrips() throws {
        let store = try makeStore()
        XCTAssertNil(try store.missionsWatermark())
        try store.setMissionsWatermark(Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(try store.missionsWatermark(), Date(timeIntervalSince1970: 1234))
        try store.wipeMissions()
        XCTAssertNil(try store.missionsWatermark())
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreMissionsTests`
Expected: FAIL — `value of type 'JournalStore' has no member 'upsertMissions'`.

- [ ] **Step 3: Register the `v10` migration**

In `MatronShared/Sources/Journal/JournalStore.swift`, immediately after the `v9` block and before `return migrator`:

```swift
        // v10: mission cache (spec 2026-09-10 missions-milestones). Purely
        // ADDITIVE — three new tables plus two nullable columns on `item`.
        // Filled from GET /missions and GET /missions/:id, never from the
        // event log: the `mission`/`milestone` markers are invalidation
        // signals, and the journal omits their titles when they cross the
        // privacy boundary, so a marker is never a source of truth for a
        // name (MissionsSync).
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
                t.column("origin_device_id", .integer).notNull().defaults(to: 0)
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("last_milestone_at", .integer)
                t.column("closed_at", .integer)
                t.column("open_items", .integer).notNull().defaults(to: 0)
                t.column("needs_you", .integer).notNull().defaults(to: 0)
                t.column("conversation_count", .integer).notNull().defaults(to: 0)
                t.column("milestone_count", .integer).notNull().defaults(to: 0)
                t.column("last_milestone_json", .text)
            }
            try db.create(index: "mission_state_activity", on: "mission", columns: ["state", "last_milestone_at"])
            try db.create(index: "mission_origin", on: "mission", columns: ["origin_convo_id"])
            try db.create(table: "milestone") { t in
                t.column("id", .text).primaryKey()
                t.column("mission_id", .text).notNull()
                t.column("num", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("convo_id", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("device_id", .integer).notNull().defaults(to: 0)
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "milestone_mission", on: "milestone", columns: ["mission_id", "created_at"])
            try db.create(index: "milestone_convo", on: "milestone", columns: ["convo_id", "seq"])
            try db.create(table: "mission_conversation") { t in
                t.column("mission_id", .text).notNull()
                t.column("convo_id", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("box", .text)
                t.column("state", .text).notNull().defaults(to: "")
                t.primaryKey(["mission_id", "convo_id"])
            }
            try db.alter(table: "item") { t in
                t.add(column: "mission_id", .text)
                t.add(column: "mission_num", .integer)
            }
            try db.create(index: "item_mission", on: "item", columns: ["mission_id", "state", "awaiting"])
        }
```

In `wipe()`, extend the tracker-cache line (the same transaction, for the same nested-write reason its comment gives). The table list itself lives in exactly one place — `JournalStore.wipeMissionTables(_:)`, written with the rest of the mission store in step 4 — so `wipe()` and `wipeMissions()` cannot come to clear different sets of tables:

```swift
            try db.execute(sql: "DELETE FROM item; DELETE FROM item_comment;")
            // Mission cache — same rule as the tracker cache above: cleared
            // inline, because this method is already inside `dbQueue.write`
            // and cannot nest another. One bootstrap later, `GET /missions`
            // refills it.
            try Self.wipeMissionTables(db)
```

(`wipe()` already does `DELETE FROM meta`, which clears the missions watermark key with it.)

- [ ] **Step 4: Write `MatronShared/Sources/Journal/JournalStore+Missions.swift`**

```swift
import Foundation
import GRDB
import MatronModels

// Mission cache (spec 2026-09-10 missions-milestones). Records and queries
// for the `mission` / `milestone` / `mission_conversation` tables created by
// migration v10 (JournalStore.swift). Filled from GET /missions and
// GET /missions/:id by `MissionsSync` — never from the event log.

private let missionsEncoder = JSONEncoder()
private let missionsDecoder = JSONDecoder()

private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
private func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }
private func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
private func date(_ v: Int64?) -> Date? { v.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

/// The `?since=` watermark for `GET /missions`, advanced only after a fully
/// successful refresh — same discipline as `items_watermark_all`.
private let missionsWatermarkKey = "missions_watermark"

public struct MissionRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "mission"
    public var id: String; public var num: Int; public var state: String
    public var title: String; public var body: String
    public var closeSummary: String?; public var closedBy: String?; public var closedOverOpenItems: Int
    public var originConvoId: String; public var originDeviceId: Int64; public var createdBy: String
    public var createdAt: Int64; public var updatedAt: Int64
    public var lastMilestoneAt: Int64?; public var closedAt: Int64?
    public var openItems: Int; public var needsYou: Int; public var conversationCount: Int
    public var milestoneCount: Int; public var lastMilestoneJson: String?

    enum CodingKeys: String, CodingKey {
        case id, num, state, title, body
        case closeSummary = "close_summary", closedBy = "closed_by", closedOverOpenItems = "closed_over_open_items"
        case originConvoId = "origin_convo_id", originDeviceId = "origin_device_id", createdBy = "created_by"
        case createdAt = "created_at", updatedAt = "updated_at", lastMilestoneAt = "last_milestone_at"
        case closedAt = "closed_at", openItems = "open_items", needsYou = "needs_you"
        case conversationCount = "conversation_count", milestoneCount = "milestone_count"
        case lastMilestoneJson = "last_milestone_json"
    }

    /// Codable mirror of `MissionLastMilestone` with wire-shaped keys, so
    /// the stored JSON reads the same as the payload it came from.
    private struct LastMilestone: Codable {
        var num: Int; var title: String; var kind: String; var createdAt: Int64
        enum CodingKeys: String, CodingKey { case num, title, kind; case createdAt = "created_at" }
    }

    public init(_ m: Mission) {
        id = m.id; num = m.num; state = m.state.rawValue; title = m.title; body = m.body
        closeSummary = m.closeSummary; closedBy = m.closedBy?.rawValue; closedOverOpenItems = m.closedOverOpenItems
        originConvoId = m.originConvoID; originDeviceId = m.originDeviceID; createdBy = m.createdBy.rawValue
        createdAt = ms(m.createdAt); updatedAt = ms(m.updatedAt)
        lastMilestoneAt = ms(m.lastMilestoneAt); closedAt = ms(m.closedAt)
        openItems = m.openItems; needsYou = m.needsYou; conversationCount = m.conversationCount
        milestoneCount = m.milestoneCount
        lastMilestoneJson = m.lastMilestone.flatMap {
            let l = LastMilestone(num: $0.num, title: $0.title, kind: $0.kind.rawValue, createdAt: ms($0.createdAt))
            return (try? String(data: missionsEncoder.encode(l), encoding: .utf8)) ?? nil
        }
    }

    public var mission: Mission {
        let last = lastMilestoneJson
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? missionsDecoder.decode(LastMilestone.self, from: $0) }
            .flatMap { l -> MissionLastMilestone? in
                guard let kind = MilestoneKind(rawValue: l.kind) else { return nil }
                return MissionLastMilestone(num: l.num, title: l.title, kind: kind, createdAt: date(l.createdAt))
            }
        return Mission(id: id, num: num, state: MissionState(rawValue: state) ?? .open, title: title, body: body,
                       closeSummary: closeSummary, closedBy: closedBy.flatMap(ItemAuthor.init(rawValue:)),
                       closedOverOpenItems: closedOverOpenItems, originConvoID: originConvoId,
                       originDeviceID: originDeviceId, createdBy: ItemAuthor(rawValue: createdBy) ?? .agent,
                       createdAt: date(createdAt), updatedAt: date(updatedAt),
                       lastMilestoneAt: date(lastMilestoneAt), closedAt: date(closedAt),
                       openItems: openItems, needsYou: needsYou, conversationCount: conversationCount,
                       milestoneCount: milestoneCount, lastMilestone: last)
    }
}

public struct MilestoneRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "milestone"
    public var id: String; public var missionId: String; public var num: Int; public var kind: String
    public var title: String; public var body: String; public var convoId: String; public var seq: Int64
    public var deviceId: Int64; public var createdBy: String; public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, num, kind, title, body, seq
        case missionId = "mission_id", convoId = "convo_id", deviceId = "device_id"
        case createdBy = "created_by", createdAt = "created_at"
    }

    public init(_ m: Milestone) {
        id = m.id; missionId = m.missionID; num = m.num; kind = m.kind.rawValue; title = m.title
        body = m.body; convoId = m.convoID; seq = m.seq; deviceId = m.deviceID
        createdBy = m.createdBy.rawValue; createdAt = ms(m.createdAt)
    }

    public var milestone: Milestone {
        Milestone(id: id, missionID: missionId, num: num, kind: MilestoneKind(rawValue: kind) ?? .progress,
                  title: title, body: body, convoID: convoId, seq: seq, deviceID: deviceId,
                  createdBy: ItemAuthor(rawValue: createdBy) ?? .agent, createdAt: date(createdAt))
    }
}

public struct MissionConversationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "mission_conversation"
    public var missionId: String; public var convoId: String
    public var title: String; public var box: String?; public var state: String
    enum CodingKeys: String, CodingKey {
        case title, box, state
        case missionId = "mission_id", convoId = "convo_id"
    }
    public init(missionID: String, _ c: MissionConversation) {
        missionId = missionID; convoId = c.id; title = c.title; box = c.box; state = c.state
    }
    public var conversation: MissionConversation {
        MissionConversation(id: convoId, title: title, box: box, state: state)
    }
}

extension JournalStore {
    // MARK: Missions

    /// Open missions sort newest-activity first with never-checkpointed
    /// missions last (`last_milestone_at DESC NULLS LAST, created_at DESC`,
    /// the journal's own order); closed ones sort newest-closed first.
    /// SQLite has no NULLS LAST, so the `IS NULL` term does it.
    private static func missionsRequest(_ state: MissionState?) -> SQLRequest<MissionRecord> {
        switch state {
        case .some(.closed):
            return SQLRequest<MissionRecord>(sql: "SELECT * FROM mission WHERE state = 'closed' ORDER BY closed_at DESC, num DESC")
        case .some(.open):
            return SQLRequest<MissionRecord>(sql: """
                SELECT * FROM mission WHERE state = 'open'
                ORDER BY last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """)
        case .none:
            return SQLRequest<MissionRecord>(sql: """
                SELECT * FROM mission
                ORDER BY state, last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """)
        }
    }

    public func upsertMissions(_ missions: [Mission]) throws {
        guard !missions.isEmpty else { return }
        try dbQueue.write { db in for m in missions { try MissionRecord(m).save(db) } }
    }

    public func missions(state: MissionState?) throws -> [Mission] {
        try dbQueue.read { db in try Self.missionsRequest(state).fetchAll(db).map(\.mission) }
    }

    public func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in try Self.missionsRequest(state).fetchAll(db).map(\.mission) }, in: dbQueue)
    }

    public func mission(id: String) throws -> Mission? {
        try dbQueue.read { db in try MissionRecord.fetchOne(db, key: id)?.mission }
    }

    /// Lookup by the human-facing `#N`. Numbers are unique across items,
    /// missions and milestones, so at most one row can match.
    public func mission(num: Int) throws -> Mission? {
        try dbQueue.read { db in try MissionRecord.filter(Column("num") == num).order(Column("id")).fetchOne(db)?.mission }
    }

    public func missionStream(id: String) -> AsyncStream<Mission?> {
        Self.stream(ValueObservation.tracking { db in try MissionRecord.fetchOne(db, key: id)?.mission }, in: dbQueue)
    }

    // MARK: Milestones

    /// Wholesale replace for one mission, mirroring `replaceComments`: the
    /// detail fetch is the authority, so a milestone the server no longer
    /// returns (sieved, or the mission repointed) must not linger.
    public func replaceMilestones(missionID: String, _ milestones: [Milestone]) throws {
        try dbQueue.write { db in
            try MilestoneRecord.filter(Column("mission_id") == missionID).deleteAll(db)
            for m in milestones { try MilestoneRecord(m).insert(db) }
        }
    }

    private static func milestonesForMission(_ missionID: String) -> QueryInterfaceRequest<MilestoneRecord> {
        MilestoneRecord.filter(Column("mission_id") == missionID)
            .order(Column("created_at").desc, Column("num").desc)
    }

    public func milestones(missionID: String) throws -> [Milestone] {
        try dbQueue.read { db in try Self.milestonesForMission(missionID).fetchAll(db).map(\.milestone) }
    }

    public func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> {
        Self.stream(ValueObservation.tracking { db in try Self.milestonesForMission(missionID).fetchAll(db).map(\.milestone) }, in: dbQueue)
    }

    /// The per-conversation view (`GET /milestones?convo=`), newest first.
    public func milestones(convoID: String) throws -> [Milestone] {
        try dbQueue.read { db in
            try MilestoneRecord.filter(Column("convo_id") == convoID).order(Column("seq").desc).fetchAll(db).map(\.milestone)
        }
    }

    // MARK: Conversations of a mission

    public func replaceMissionConversations(missionID: String, _ conversations: [MissionConversation]) throws {
        try dbQueue.write { db in
            try MissionConversationRecord.filter(Column("mission_id") == missionID).deleteAll(db)
            for c in conversations { try MissionConversationRecord(missionID: missionID, c).insert(db) }
        }
    }

    private static func missionConversationsRequest(_ missionID: String) -> QueryInterfaceRequest<MissionConversationRecord> {
        MissionConversationRecord.filter(Column("mission_id") == missionID).order(Column("convo_id"))
    }

    public func missionConversations(missionID: String) throws -> [MissionConversation] {
        try dbQueue.read { db in try Self.missionConversationsRequest(missionID).fetchAll(db).map(\.conversation) }
    }

    public func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> {
        Self.stream(ValueObservation.tracking { db in
            try Self.missionConversationsRequest(missionID).fetchAll(db).map(\.conversation)
        }, in: dbQueue)
    }

    // MARK: A conversation's mission

    /// Which mission a conversation belongs to, derived locally.
    ///
    /// `GET /snapshot` does NOT carry `conversations.mission_id`, so there is
    /// no column to mirror. Origin first (`missions.origin_convo_id`), then
    /// any milestone posted in that conversation — which covers `join` and
    /// inheritance. `nil` until the first missions refresh lands, which is
    /// exactly when the title-tap affordance should appear.
    private static func missionIDQuery(_ db: Database, _ convoID: String) throws -> String? {
        if let origin = try String.fetchOne(db, sql: "SELECT id FROM mission WHERE origin_convo_id = ? ORDER BY id LIMIT 1", arguments: [convoID]) {
            return origin
        }
        return try String.fetchOne(db, sql: "SELECT mission_id FROM milestone WHERE convo_id = ? ORDER BY seq DESC LIMIT 1", arguments: [convoID])
    }

    public func missionID(convoID: String) throws -> String? {
        try dbQueue.read { db in try Self.missionIDQuery(db, convoID) }
    }

    public func missionIDStream(convoID: String) -> AsyncStream<String?> {
        Self.stream(ValueObservation.tracking { db in try Self.missionIDQuery(db, convoID) }, in: dbQueue)
    }

    // MARK: Watermark / wipe

    public func missionsWatermark() throws -> Date? {
        try dbQueue.read { db in
            date(try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [missionsWatermarkKey]))
        }
    }

    public func setMissionsWatermark(_ value: Date) throws {
        try dbQueue.write { db in
            let msValue: Int64 = ms(value)
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [missionsWatermarkKey, msValue])
        }
    }

    /// Sign-out clear for the mission cache alone. `wipe()` clears the same
    /// tables inline (it cannot nest another `dbQueue.write`) — both go
    /// through `wipeMissionTables`, so "the mission cache" is defined once.
    public func wipeMissions() throws {
        try dbQueue.write { db in
            try Self.wipeMissionTables(db)
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [missionsWatermarkKey])
        }
    }

    /// The mission cache's three tables, cleared inside a transaction the
    /// caller already owns. `JournalStore.wipe()` calls it from the middle
    /// of its own `dbQueue.write`; `wipeMissions()` opens one of its own.
    /// Internal (same module as `wipe()`), and `static` so neither caller
    /// needs an instance hop mid-transaction.
    static func wipeMissionTables(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM mission; DELETE FROM milestone; DELETE FROM mission_conversation;")
    }
}
```

- [ ] **Step 5: Extend `ItemRecord` and add `items(missionID:)`**

In `MatronShared/Sources/Journal/JournalStore+Items.swift`:

Add to `ItemRecord`'s stored properties (after `hasImage`):

```swift
    public var missionId: String?; public var missionNum: Int?
```

Add to its `CodingKeys`:

```swift
        case missionId = "mission_id", missionNum = "mission_num"
```

Set them in `init(_ i: TrackerItem)`:

```swift
        missionId = i.missionID; missionNum = i.missionNum
```

and read them back in `var item: TrackerItem` (extend the trailing arguments):

```swift
                    commentCount: commentCount, lastCommentAt: date(lastCommentAt), hasImage: hasImage,
                    missionID: missionId, missionNum: missionNum)
```

Then append these two methods inside `extension JournalStore` in the same file:

```swift
    /// The mission page's open items: awaiting-you first (that is the
    /// section the page leads with), then newest activity. Closed items are
    /// excluded — the page shows what is still outstanding.
    private static func missionItemsRequest(_ missionID: String) -> SQLRequest<ItemRecord> {
        SQLRequest<ItemRecord>(sql: """
            SELECT * FROM item
            WHERE mission_id = ? AND state = 'open'
            ORDER BY (awaiting = 'user') DESC, updated_at DESC, num DESC
            """, arguments: [missionID])
    }

    public func items(missionID: String) throws -> [TrackerItem] {
        try dbQueue.read { db in try Self.missionItemsRequest(missionID).fetchAll(db).map(\.item) }
    }

    public func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]> {
        Self.stream(ValueObservation.tracking { db in try Self.missionItemsRequest(missionID).fetchAll(db).map(\.item) }, in: dbQueue)
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "JournalStoreMissionsTests|JournalStoreItemsTests|JournalStoreTests"`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Sources/Journal/JournalStore+Missions.swift \
        MatronShared/Sources/Journal/JournalStore+Items.swift MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: additive v10 mission cache with records, queries and streams" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `MissionsProviding` on `JournalAPI`

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Missions.swift`
- Test: `MatronShared/Tests/JournalTests/MissionsAPITests.swift` (new)

**Interfaces:**
- Consumes: `Mission`, `Milestone`, `MissionConversation`, `TrackerItem` (Task 1); `JournalAPI.request(path:method:body:query:authenticated:accept:headers:)` and `JournalAPI.pathSegment(_:)`.
- Produces: `MissionsListQuery` (`state`, `since`), `MissionDetail` (`mission`, `milestones`, `items`, `conversations`), `protocol MissionsProviding { listMissions(_:) ; mission(id:) ; milestones(convoID:) ; closeMission(id:summary:) }`, `extension JournalAPI: MissionsProviding`.

**Scope note:** the apps read, and the *user* closes. Creating, joining, renaming and `item_move` are agent-only (bridge tools), so they are deliberately absent from this protocol.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/MissionsAPITests.swift`. Where a test needs a stubbed server, copy `ItemsAPITests`' own `makeStubbedAPI(status:body:)` helper (and the `ItemsStubURLProtocol` it drives) rather than inventing a second one — read that file first. The assertions below only depend on the request path/query and the decoded result.

```swift
import XCTest
import MatronModels
@testable import MatronJournal

final class MissionsAPITests: XCTestCase {
    func testMissionsListQueryBuildsStateAndSince() {
        var q = MissionsListQuery()
        XCTAssertEqual(q.queryItems, [])
        q.state = .open
        q.since = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(q.queryItems, [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "since", value: "1700000000000"),
        ])
    }

    func testDecodeMissionsListDropsMalformedRowsButKeepsTheRest() throws {
        let obj: [String: Any] = ["missions": [
            MissionModelTests.missionJSON,
            ["id": "ms_broken"],                       // no num/state/title — skipped
        ]]
        let missions = JournalAPI.decodeMissions(obj)
        XCTAssertEqual(missions.map(\.id), ["ms_a1"])
    }

    func testDecodeMissionDetail() throws {
        let obj: [String: Any] = [
            "mission": MissionModelTests.missionJSON,
            "milestones": [MissionModelTests.milestoneJSON],
            "items": [ItemsAPITests.itemJSON],
            "conversations": [["id": "c1", "title": "Session", "box": "dev-2", "state": "running"]],
        ]
        let detail = try JournalAPI.decodeMissionDetail(obj)
        XCTAssertEqual(detail.mission.id, "ms_a1")
        XCTAssertEqual(detail.milestones.map(\.id), ["ml_b2"])
        XCTAssertEqual(detail.items.map(\.id), ["it_1"])
        XCTAssertEqual(detail.conversations.map(\.id), ["c1"])
    }

    func testDecodeMissionDetailWithoutAMissionIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeMissionDetail(["milestones": []])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
    }

    func testMissionPathSegmentEncodesANumberReference() {
        // `:id` accepts `ms_…` or a bare number; a `#61` reference must be
        // percent-encoded or the `#` truncates the URL into a fragment.
        XCTAssertEqual(JournalAPI.pathSegment("#61"), "%2361")
        XCTAssertEqual(JournalAPI.pathSegment("ms_a1"), "ms_a1")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionsAPITests`
Expected: FAIL — `cannot find 'MissionsListQuery' in scope`.

- [ ] **Step 3: Write `MatronShared/Sources/Journal/JournalAPI+Missions.swift`**

```swift
import Foundation
import MatronModels

public struct MissionsListQuery: Equatable, Sendable {
    /// Omitted means "both states" — the journal has no `state=any`.
    public var state: MissionState?
    /// `?since=<ms>`. The journal matches the STORED `updated_at`, so a
    /// hidden milestone can make a mission match; the row that comes back is
    /// fully sieved either way (protocol, "Accepted exception").
    public var since: Date?
    public init() {}

    var queryItems: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let state { q.append(.init(name: "state", value: state.rawValue)) }
        if let since { q.append(.init(name: "since", value: String(Int64(since.timeIntervalSince1970 * 1000)))) }
        return q
    }
}

/// What `GET /missions/:id` returns. `conversations` has no local equivalent
/// anywhere else — the snapshot never says which conversations a mission
/// owns — so this is the only source for the mission page's chat list.
public struct MissionDetail: Equatable, Sendable {
    public let mission: Mission
    public let milestones: [Milestone]
    public let items: [TrackerItem]
    public let conversations: [MissionConversation]
    public init(mission: Mission, milestones: [Milestone], items: [TrackerItem], conversations: [MissionConversation]) {
        self.mission = mission; self.milestones = milestones; self.items = items; self.conversations = conversations
    }
}

/// The read surface the apps need, plus the one write they are allowed:
/// a USER close. Creating, joining, renaming and moving items are agent-only
/// (bridge tools) and deliberately absent.
public protocol MissionsProviding: Sendable {
    func listMissions(_ query: MissionsListQuery) async throws -> [Mission]
    func mission(id: String) async throws -> MissionDetail
    func milestones(convoID: String) async throws -> [Milestone]
    func closeMission(id: String, summary: String) async throws -> Mission
}

extension JournalAPI: MissionsProviding {
    /// Internal (not private) so `MissionsAPITests` can pin the decoding
    /// without standing up an HTTP stub for every shape.
    static func decodeMissions(_ obj: [String: Any]) -> [Mission] {
        (obj["missions"] as? [[String: Any]] ?? []).compactMap(Mission.init(json:))
    }

    static func decodeMission(_ obj: [String: Any]) throws -> Mission {
        guard let mission = (obj["mission"] as? [String: Any]).flatMap(Mission.init(json:)) else {
            throw JournalAPIError.transport("malformed mission response")
        }
        return mission
    }

    static func decodeMissionDetail(_ obj: [String: Any]) throws -> MissionDetail {
        MissionDetail(
            mission: try decodeMission(obj),
            milestones: (obj["milestones"] as? [[String: Any]] ?? []).compactMap(Milestone.init(json:)),
            items: (obj["items"] as? [[String: Any]] ?? []).compactMap(TrackerItem.init(json:)),
            conversations: (obj["conversations"] as? [[String: Any]] ?? []).compactMap(MissionConversation.init(json:)))
    }

    public func listMissions(_ query: MissionsListQuery) async throws -> [Mission] {
        Self.decodeMissions(try await request(path: "/missions", query: query.queryItems))
    }

    public func mission(id: String) async throws -> MissionDetail {
        try Self.decodeMissionDetail(try await request(path: "/missions/\(Self.pathSegment(id))"))
    }

    public func milestones(convoID: String) async throws -> [Milestone] {
        let obj = try await request(path: "/milestones", query: [.init(name: "convo", value: convoID)])
        return (obj["milestones"] as? [[String: Any]] ?? []).compactMap(Milestone.init(json:))
    }

    /// A device close always succeeds server-side, even over open items —
    /// the journal records `closed_over_open_items` and names the numbers in
    /// the close marker. The 409s in the protocol's *Closing* section apply
    /// to AGENT callers, so this method never has to render one.
    public func closeMission(id: String, summary: String) async throws -> Mission {
        try Self.decodeMission(try await request(path: "/missions/\(Self.pathSegment(id))/close",
                                                 method: "POST", body: ["summary": summary]))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "MissionsAPITests|ItemsAPITests"`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI+Missions.swift MatronShared/Tests/JournalTests/MissionsAPITests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: MissionsProviding read surface plus the user close" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `MissionsSync` — the actor, the engine's marker stream, and dependency wiring

**Files:**
- Create: `MatronShared/Sources/Journal/MissionsSync.swift`
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift`
- Modify: `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift`
- Test: `MatronShared/Tests/JournalTests/MissionsSyncTests.swift` (new)

**Interfaces:**
- Consumes: `MissionsProviding` (Task 4), `MissionMarker` (Task 2), the store writes from Task 3, `SyncConnectionState`.
- Produces: `MissionsRefreshFailure`, `MissionsRefreshOutcome`, `actor MissionsSync` with `start()`, `stop() async`, `refresh() -> MissionsRefreshOutcome`, `refreshMission(id:) async`, `refreshMilestones(convoID:) async`, `closeMission(id:summary:) async throws -> Mission`, `supportedStream() -> AsyncStream<Bool>`, `isSupported`. On `JournalSyncEngine`: `nonisolated func missionMarkers() -> AsyncStream<(convoID: String, marker: MissionMarker)>`. On both `AppDependencies`: `func missionsSync(for:) -> MissionsSync` and `JournalCore.missions`.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/MissionsSyncTests.swift`:

```swift
import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeMissions: MissionsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [Mission] = []
    private var _listCalls = 0
    private var _listError: Error?
    private var _details: [String: MissionDetail] = [:]
    private var _detailCalls: [String] = []
    private var _closed: [(String, String)] = []
    /// Holds the NEXT `mission(id:)` open so a test can prove a second,
    /// coalesced refetch joins the first instead of issuing its own GET.
    private var _blockNextDetail = false
    private var _detailGate: CheckedContinuation<Void, Never>?

    var list: [Mission] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var details: [String: MissionDetail] { get { lock.withLock { _details } } set { lock.withLock { _details = newValue } } }
    var detailCalls: [String] { lock.withLock { _detailCalls } }
    var closed: [(String, String)] { lock.withLock { _closed } }
    var blockNextDetail: Bool { get { lock.withLock { _blockNextDetail } } set { lock.withLock { _blockNextDetail = newValue } } }
    var isDetailGated: Bool { lock.withLock { _detailGate != nil } }
    func releaseDetailGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _detailGate = nil }; return _detailGate }
        c?.resume()
    }

    func listMissions(_ query: MissionsListQuery) async throws -> [Mission] {
        lock.withLock { _listCalls += 1 }
        if let e = listError { throw e }
        return list
    }

    func mission(id: String) async throws -> MissionDetail {
        lock.withLock { _detailCalls.append(id) }
        if blockNextDetail {
            blockNextDetail = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _detailGate = c } }
        }
        guard let d = details[id] else { throw JournalAPIError.notFound }
        return d
    }

    func milestones(convoID: String) async throws -> [Milestone] { [] }

    func closeMission(id: String, summary: String) async throws -> Mission {
        lock.withLock { _closed.append((id, summary)) }
        guard let m = details[id]?.mission else { throw JournalAPIError.notFound }
        return Mission(id: m.id, num: m.num, state: .closed, title: m.title, body: m.body,
                       closeSummary: summary, closedBy: .user, closedOverOpenItems: 1,
                       originConvoID: m.originConvoID, createdAt: m.createdAt, updatedAt: m.updatedAt,
                       closedAt: Date(timeIntervalSince1970: 99))
    }
}

final class MissionsSyncTests: XCTestCase {
    private func mission(_ id: String, num: Int) -> Mission {
        Mission(id: id, num: num, title: "M\(num)", originConvoID: "c1",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: Date(timeIntervalSince1970: 3))
    }

    private func make(api: FakeMissions) throws -> (MissionsSync, JournalStore,
                                                    AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation,
                                                    AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: MissionMarker)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = MissionsSync(api: api, store: store, markers: { markers }, connectionStates: { states })
        return (sync, store, mc, sc)
    }

    func testReconnectFetchesTheWholeListIntoTheStore() async throws {
        let api = FakeMissions()
        api.list = [mission("ms_1", num: 61), mission("ms_2", num: 62)]
        let (sync, store, _, states) = try make(api: api)
        await sync.start()
        states.yield(.running)
        try await waitUntil { try store.missions(state: nil).count == 2 }
        XCTAssertEqual(try store.missions(state: nil).map(\.id).sorted(), ["ms_1", "ms_2"])
        await sync.stop()
    }

    func testMarkerForAMissionRefetchesThatMissionOnly() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(
            mission: mission("ms_1", num: 61),
            milestones: [Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .userInput, title: "step",
                                   convoID: "c1", seq: 400, createdAt: Date(timeIntervalSince1970: 4))],
            items: [], conversations: [MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running")])]
        let (sync, store, markers, _) = try make(api: api)
        await sync.start()
        markers.yield((convoID: "c1", marker: .milestone(MilestoneMarkerEvent(
            milestoneID: "ml_1", num: 62, kind: .userInput, title: "step",
            missionID: "ms_1", missionNum: 61, missionTitle: nil, by: .agent))))
        try await waitUntil { try store.mission(id: "ms_1") != nil }
        XCTAssertEqual(api.detailCalls, ["ms_1"])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.seq), [400])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1").map(\.id), ["c1"])
        // The marker carried NO mission_title — the store still learned the
        // real title, because it came from the fetch, not the marker.
        XCTAssertEqual(try store.mission(id: "ms_1")?.title, "M61")
        await sync.stop()
    }

    func testConcurrentRefetchesForOneMissionCoalesceIntoOneRequest() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(mission: mission("ms_1", num: 61), milestones: [], items: [], conversations: [])]
        let (sync, _, _, _) = try make(api: api)
        api.blockNextDetail = true
        async let first: Void = sync.refreshMission(id: "ms_1")
        try await waitUntil { api.isDetailGated }
        async let second: Void = sync.refreshMission(id: "ms_1")
        api.releaseDetailGate()
        _ = await (first, second)
        XCTAssertEqual(api.detailCalls.filter { $0 == "ms_1" }.count, 1,
                       "a joiner awaits the run in flight rather than issuing its own GET")
        await sync.stop()
    }

    func testA404MarksTheJournalUnsupportedAndPublishesIt() async throws {
        let api = FakeMissions()
        api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        var seen: [Bool] = []
        let stream = await sync.supportedStream()
        let watcher = Task { for await v in stream { seen.append(v); if seen.count == 2 { return } } }
        XCTAssertEqual(await sync.refresh(), .unsupported)
        _ = await watcher.value
        XCTAssertEqual(seen, [true, false])
        await sync.stop()
    }

    /// A failed refresh must leave the cached tables exactly as they were —
    /// the mission list keeps showing what it had (spec, Error handling).
    func testAFailedRefreshKeepsTheCacheAndReportsTheFailure() async throws {
        let api = FakeMissions()
        api.list = [mission("ms_1", num: 61)]
        let (sync, store, _, _) = try make(api: api)
        XCTAssertEqual(await sync.refresh(), .succeeded)
        api.listError = JournalAPIError.transport("offline")
        guard case .failed = await sync.refresh() else { return XCTFail("expected .failed") }
        XCTAssertEqual(try store.missions(state: nil).map(\.id), ["ms_1"])
        await sync.stop()
    }

    func testCloseWritesTheReturnedMissionStraightIntoTheStore() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(mission: mission("ms_1", num: 61), milestones: [], items: [], conversations: [])]
        let (sync, store, _, _) = try make(api: api)
        try store.upsertMissions([mission("ms_1", num: 61)])
        let closed = try await sync.closeMission(id: "ms_1", summary: "Done.")
        XCTAssertEqual(closed.state, .closed)
        XCTAssertEqual(api.closed.map(\.1), ["Done."])
        XCTAssertEqual(try store.mission(id: "ms_1")?.state, .closed)
        XCTAssertEqual(try store.mission(id: "ms_1")?.closedOverOpenItems, 1)
        await sync.stop()
    }

    /// Polls a condition rather than sleeping a fixed interval.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionsSyncTests`
Expected: FAIL — `cannot find 'MissionsSync' in scope`.

- [ ] **Step 3: Publish mission markers from the sync engine**

In `MatronShared/Sources/Journal/JournalSyncEngine.swift`, beside the existing item-marker plumbing:

Add the storage next to `itemMarkerContinuations`:

```swift
    private var missionMarkerContinuations: [UUID: AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation] = [:]
```

Add the stream and publisher directly after `publishItemMarker`:

```swift
    /// Mission markers (`mission` and `milestone` events) as they are
    /// applied — the invalidation feed for `MissionsSync`. One stream for
    /// both types: the actor's reaction to either is the same, refetch that
    /// mission. Mirrors `itemMarkers()`.
    public nonisolated func missionMarkers() -> AsyncStream<(convoID: String, marker: MissionMarker)> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerMissionMarkers(id: id, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.unregisterMissionMarkers(id: id) } }
        }
    }
    private func registerMissionMarkers(id: UUID, continuation: AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation) { missionMarkerContinuations[id] = continuation }
    private func unregisterMissionMarkers(id: UUID) { missionMarkerContinuations.removeValue(forKey: id) }
    private func publishMissionMarker(_ event: JournalEvent) {
        let marker: MissionMarker
        switch event.type {
        case JournalEventType.milestone:
            guard let m = MilestoneMarkerEvent.parse(payload: event.payload) else { return }
            marker = .milestone(m)
        case JournalEventType.mission:
            guard let m = MissionMarkerEvent.parse(payload: event.payload) else { return }
            marker = .mission(m)
        default:
            return
        }
        for c in missionMarkerContinuations.values { c.yield((convoID: event.convoID, marker: marker)) }
    }
```

Call it from both apply hooks:

```swift
    private func didApply(_ event: JournalEvent) {
        publishItemMarker(event)
        publishMissionMarker(event)
        confirmMediaSendIfNeeded(event)
        indexForSearch(event)
    }
```

and in `didApplyBatch`:

```swift
        for event in events { publishItemMarker(event); publishMissionMarker(event); confirmMediaSendIfNeeded(event) }
```

- [ ] **Step 4: Write `MatronShared/Sources/Journal/MissionsSync.swift`**

```swift
import Foundation
import os
import MatronModels
import MatronEvents

/// Why a refresh could not fetch, in a form that can leave the actor —
/// same reasoning as `ItemsRefreshFailure`: the outcome travels out through
/// a `Task` value, whose success type must be `Sendable`, and `any Error`
/// is not. The concrete error stays in the log line beside it.
public struct MissionsRefreshFailure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ error: any Error) { self.message = error.localizedDescription }
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What a `refresh()` pass actually did. `.unsupported` is a real answer
/// from an old journal (404 on `GET /missions`), not a transport fault —
/// the Missions tab hides itself on it.
public enum MissionsRefreshOutcome: Equatable, Sendable {
    case succeeded
    case unsupported
    case stopped
    case failed(MissionsRefreshFailure)
}

/// Keeps the local mission cache fresh (spec: Apps → Shared core). Three
/// triggers refetch: a `mission`/`milestone` marker (refetch THAT mission),
/// a reconnect (full list), and an explicit refresh from a view model.
/// Markers are invalidation signals only — nothing they carry is written to
/// the store, because a marker written across the privacy boundary has no
/// title at all.
///
/// There is no outbox: the one write the apps can make (a user close) is an
/// interactive, foreground action that reports its own failure.
public actor MissionsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "missions-sync")

    private let api: any MissionsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// List-refresh coalescing, mirroring `ItemsSync.refresh(scope:)`: a
    /// reconnect, a tab open and a pull-to-refresh landing together each
    /// ran their own full GET over the same rows. There is only one scope
    /// here, so one slot suffices.
    private var inFlightRefresh: Task<MissionsRefreshOutcome, Never>?
    /// Per-mission refetch coalescing, mirroring `ItemsSync.refreshItem`: a
    /// joiner AWAITS the run already in flight (callers take "refreshMission
    /// returned" to mean the store now holds the server's page), and the
    /// running pass repeats once more if another was requested meanwhile.
    private var inFlightRefetches: [String: Task<Void, Never>] = [:]
    private var refetchAgain: Set<String> = []
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Set by `stop()`, cleared by `start()`. Every write site re-checks it
    /// immediately after its await, so a call suspended in the network when
    /// sign-out lands cannot resume and write into a wiped store.
    private var stopped = false

    public init(api: any MissionsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
    }

    public func supportedStream() -> AsyncStream<Bool> {
        AsyncStream { c in
            let id = UUID()
            supportedContinuations[id] = c
            c.yield(isSupported)
            c.onTermination = { _ in Task { await self.dropSupported(id) } }
        }
    }
    private func dropSupported(_ id: UUID) { supportedContinuations.removeValue(forKey: id) }
    private func setSupported(_ v: Bool) {
        guard v != isSupported else { return }
        isSupported = v
        for c in supportedContinuations.values { c.yield(v) }
    }

    public func start() {
        stopped = false
        guard markerTask == nil else { return }
        let markers = markers()
        markerTask = Task { [weak self] in
            for await (_, marker) in markers {
                guard let self else { return }
                await self.refreshMission(id: marker.missionID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                // No `setSupported(true)` here: publishing "supported"
                // before the probe would flash true→false for an old
                // journal that 404s. `refresh` publishes the real answer.
                if case .running = state { await self.refresh() }
            }
        }
    }

    /// Awaits every in-flight task before returning, so a caller that
    /// follows this with a store wipe cannot be raced by a suspended
    /// network call resuming into a write. Same contract as `ItemsSync.stop`.
    public func stop() async {
        stopped = true
        let mt = markerTask; let st = stateTask
        markerTask = nil; stateTask = nil
        mt?.cancel(); st?.cancel()
        let refresh = inFlightRefresh
        refresh?.cancel()
        let refetches = Array(inFlightRefetches.values)
        for t in refetches { t.cancel() }
        await mt?.value; await st?.value
        _ = await refresh?.value
        for t in refetches { await t.value }
    }

    /// Full `GET /missions` (both states — the list shows open and a
    /// collapsed Closed section). Joiners of a coalesced run get the SAME
    /// outcome, so two triggers racing one fetch cannot disagree.
    @discardableResult
    public func refresh() async -> MissionsRefreshOutcome {
        if let running = inFlightRefresh { return await running.value }
        var run: Task<MissionsRefreshOutcome, Never>!
        run = Task { [self] in
            let outcome = await refreshOnce()
            // Deregister with no suspension between the last line of the
            // run and the removal, and only if the slot still holds THIS
            // task — a `stop()` racing a `start()` + `refresh()` must not
            // let this task delete a newer registration on its way out.
            if inFlightRefresh == run { inFlightRefresh = nil }
            return outcome
        }
        inFlightRefresh = run
        return await run.value
    }

    private func refreshOnce() async -> MissionsRefreshOutcome {
        var query = MissionsListQuery()
        // One second of overlap, exactly as the items refresh does: a
        // strictly-greater `since` can drop a row written in the same
        // millisecond as the watermark.
        if let mark = try? store.missionsWatermark() { query.since = mark.addingTimeInterval(-1) }
        do {
            let missions = try await api.listMissions(query)
            guard !stopped, !Task.isCancelled else { return .stopped }
            try store.upsertMissions(missions)
            if let newest = missions.map(\.updatedAt).max() {
                do { try store.setMissionsWatermark(newest) } catch {
                    Self.logger.error("setMissionsWatermark failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            setSupported(true)
            return .succeeded
        } catch JournalAPIError.notFound {
            // The journal has no /missions routes. Not a transport fault:
            // the server answered, and the tab hides itself.
            setSupported(false)
            return .unsupported
        } catch {
            Self.logger.warning("missions refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    /// `GET /missions/:id` — the mission row, its milestones, its open items
    /// and its conversations, all written in one pass. Called on a marker
    /// and whenever a mission page opens.
    public func refreshMission(id: String) async {
        if let running = inFlightRefetches[id] {
            refetchAgain.insert(id)
            await running.value
            return
        }
        let run = Task { [self] in
            await refreshMissionOnce(id: id)
            while refetchAgain.remove(id) != nil { await refreshMissionOnce(id: id) }
            // Deregister here, with no suspension between the final
            // `refetchAgain` check and the removal, so a joiner can never
            // await a task that has already finished AND deregistered.
            inFlightRefetches[id] = nil
        }
        inFlightRefetches[id] = run
        await run.value
    }

    private func refreshMissionOnce(id: String) async {
        do {
            let detail = try await api.mission(id: id)
            guard !stopped else { return }
            try store.upsertMissions([detail.mission])
            try store.replaceMilestones(missionID: detail.mission.id, detail.milestones)
            try store.replaceMissionConversations(missionID: detail.mission.id, detail.conversations)
            // The detail's items are ordinary tracker rows carrying
            // `mission_id`; upserting them keeps the tracker cache and the
            // mission page in agreement without a second /items fetch.
            if !detail.items.isEmpty { try store.upsertItems(detail.items) }
            setSupported(true)
        } catch JournalAPIError.notFound {
            // Unknown, or invisible to this caller. Not a support signal —
            // `refresh()` owns `isSupported`.
            Self.logger.notice("mission \(id, privacy: .public) not found or not visible")
        } catch {
            Self.logger.warning("mission refetch \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `GET /milestones?convo=` — the per-conversation view. Merged into the
    /// same `milestone` table, scoped by the mission the rows name, so the
    /// mission page and the conversation view never disagree.
    public func refreshMilestones(convoID: String) async {
        do {
            let fetched = try await api.milestones(convoID: convoID)
            guard !stopped, let missionID = fetched.first?.missionID else { return }
            await refreshMission(id: missionID)
        } catch {
            Self.logger.warning("milestones for \(convoID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user's own close. Throws so the view model can surface the real
    /// message; the returned row is written straight to the store so the
    /// page flips to "closed" without waiting for a marker round-trip.
    @discardableResult
    public func closeMission(id: String, summary: String) async throws -> Mission {
        let mission = try await api.closeMission(id: id, summary: summary)
        guard !stopped else { return mission }
        try store.upsertMissions([mission])
        return mission
    }
}
```

- [ ] **Step 5: Wire it into both `AppDependencies`**

Apply the same three edits to `Matron/App/AppDependencies.swift` and `MatronMac/App/AppDependencies.swift` (the two files mirror each other). The duplication is deliberate: these two files already carry the identical `ItemsSync` wiring — property, construction, teardown — and matching the shipped pattern beats hoisting one of the five parallel blocks into `MatronShared` as a side-effect of this plan.

In `final class JournalCore`, beside `items`:

```swift
        /// Keeps the local mission cache fresh for this session (spec
        /// 2026-09-10). Started right after construction, stopped with the
        /// rest of the session's teardown on sign-out.
        let missions: MissionsSync
        var missionsStartTask: Task<Void, Never>?
```

extend its `init` with `missions: MissionsSync` and `self.missions = missions`.

In `core(for:)`, after the `ItemsSync` construction:

```swift
        let missions = MissionsSync(api: api, store: store, markers: { engine.missionMarkers() },
                                    connectionStates: { engine.stateStream() })
        let core = JournalCore(api: api, store: store, engine: engine, items: items, missions: missions)
        core.itemsStartTask = Task { await items.start() }
        core.missionsStartTask = Task { await missions.start() }
```

Beside `itemsSync(for:)`:

```swift
    /// The session's `MissionsSync` actor — marker refetches and the
    /// reconnect list refresh. One per session, same instance the view-model
    /// factories hand out.
    func missionsSync(for session: UserSession) -> MissionsSync {
        core(for: session).missions
    }
```

In the sign-out teardown, mirror the two `items` lines exactly (`await core.missionsStartTask?.value` before `await core.missions.stop()`), next to where `itemsStartTask` / `items.stop()` already appear.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "MissionsSyncTests|JournalSyncEngineTests"`
Expected: PASS — `Executed N tests, with 0 failures`.

Then: `xcodegen generate && xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

Then: `xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Journal/MissionsSync.swift MatronShared/Sources/Journal/JournalSyncEngine.swift \
        Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift \
        MatronShared/Tests/JournalTests/MissionsSyncTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: MissionsSync actor, engine marker stream and session wiring" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: View models — `MissionsListViewModel` and `MissionDetailViewModel`

**Files:**
- Create: `MatronShared/Sources/ViewModels/MissionsListViewModel.swift`
- Create: `MatronShared/Sources/ViewModels/MissionDetailViewModel.swift`
- Create: `MatronShared/Sources/Models/SessionTagInputs.swift`
- Modify: `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift` (factories)
- Test: `MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift` (new)

**Interfaces:**
- Consumes: the store streams from Task 3, `MissionsSync` from Task 5.
- Produces: `SessionTagInputs` (`boxLetter`, `boxName`, `sessionShort` — the three halves `SessionTagText.run` needs, carried as one value); `MissionsStoreReading` and `MissionsSyncing` protocols (so tests fake them, mirroring `ItemsStoreReading`/`ItemsSyncing`); `MissionsListViewModel` (`open`, `closed`, `isSupported`, `isRefreshing`, `error`, `needsYouTotal`, `start()`, `stop()`, `refresh()`, `static sections(from:)`); `MissionDetailViewModel` (`missionID`, `mission`, `milestones`, `sessionTags`, `showOnlyUserInput`, `openItems`, `conversations`, `closeSummaryDraft`, `closeConfirmation`, `isBusy`, `error`, `start()`, `stop()`, `refresh()`, `close()`, `static filtered(_:showOnlyUserInput:)`); factories `makeMissionsListViewModel(for:)` and `makeMissionDetailViewModel(for:missionID:)` on both `AppDependencies`.

**Where the `A:bc` session tag comes from.** A mission page lists milestones posted in several conversations, so each row names its own — the same colored `A:bc` run the chat header and the chat rows draw (`SessionTagText.run(boxLetter:boxName:sessionShort:colorScheme:)`, a `Text` factory, not a view). None of those halves live on a `Milestone`: they are derived from the conversation's cached row plus the box roster. So the store surface grows one read, `sessionTag(convoID:)`, and the detail view model publishes `sessionTags` keyed by conversation id. A conversation this device has never synced simply has no entry — the row then renders with no tag, never a placeholder.

**Layering note (why the view model publishes values, not a view `Model`).** `MissionDetailView.Model` is built in ONE place so the iOS and Mac pages cannot drift — but that place is a convenience `init` on the model itself (Task 7, `MissionDetailView.Model.init(mission:milestones:sessionTags:openItems:conversations:showOnlyUserInput:closeSummary:isBusy:)`), not a computed property on the view model. Two reasons, both structural: `MatronViewModels` is declared as a no-SwiftUI-views target and `MatronDesignSystem` must stay a leaf (a `detailModel` property would make the view model depend on the design system's view types), and this task runs BEFORE the task that defines `MissionDetailView`, so a property returning that type could not compile here. `SessionTagInputs` is a plain value type and lives in `MatronModels`, which every target already depends on — no package dependency changes anywhere in this plan.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift`:

```swift
import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

private final class FakeMissionsStore: MissionsStoreReading, @unchecked Sendable {
    let missionsContinuation: AsyncStream<[Mission]>.Continuation
    let missionContinuation: AsyncStream<Mission?>.Continuation
    let milestonesContinuation: AsyncStream<[Milestone]>.Continuation
    let itemsContinuation: AsyncStream<[TrackerItem]>.Continuation
    let conversationsContinuation: AsyncStream<[MissionConversation]>.Continuation
    private let missionsStreamValue: AsyncStream<[Mission]>
    private let missionStreamValue: AsyncStream<Mission?>
    private let milestonesStreamValue: AsyncStream<[Milestone]>
    private let itemsStreamValue: AsyncStream<[TrackerItem]>
    private let conversationsStreamValue: AsyncStream<[MissionConversation]>

    init() {
        (missionsStreamValue, missionsContinuation) = AsyncStream<[Mission]>.makeStream()
        (missionStreamValue, missionContinuation) = AsyncStream<Mission?>.makeStream()
        (milestonesStreamValue, milestonesContinuation) = AsyncStream<[Milestone]>.makeStream()
        (itemsStreamValue, itemsContinuation) = AsyncStream<[TrackerItem]>.makeStream()
        (conversationsStreamValue, conversationsContinuation) = AsyncStream<[MissionConversation]>.makeStream()
    }

    /// The cached `A:bc` tags, by conversation id. A conversation missing
    /// from this map is one this device never synced.
    var tags: [String: SessionTagInputs] = [:]

    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missionsStreamValue }
    func missionStream(id: String) -> AsyncStream<Mission?> { missionStreamValue }
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> { milestonesStreamValue }
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]> { itemsStreamValue }
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> { conversationsStreamValue }
    func sessionTag(convoID: String) -> SessionTagInputs? { tags[convoID] }
}

private final class FakeMissionsSync: MissionsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshes = 0
    private var _refetches: [String] = []
    private var _closes: [(String, String)] = []
    var closeError: Error?
    var supported: [Bool] = [true]
    var refreshes: Int { lock.withLock { _refreshes } }
    var refetches: [String] { lock.withLock { _refetches } }
    var closes: [(String, String)] { lock.withLock { _closes } }

    func refresh() async -> MissionsRefreshOutcome { lock.withLock { _refreshes += 1 }; return .succeeded }
    func refreshMission(id: String) async { lock.withLock { _refetches.append(id) } }
    func closeMission(id: String, summary: String) async throws -> Mission {
        lock.withLock { _closes.append((id, summary)) }
        if let closeError { throw closeError }
        return Mission(id: id, num: 61, state: .closed, title: "M61", closeSummary: summary, originConvoID: "c1")
    }
    func supportedStream() async -> AsyncStream<Bool> {
        let values = supported
        return AsyncStream { c in for v in values { c.yield(v) }; c.finish() }
    }
}

@MainActor
final class MissionsViewModelTests: XCTestCase {
    private func mission(_ id: String, num: Int, state: MissionState = .open, lastMilestoneAt: TimeInterval?,
                         needsYou: Int = 0, closedAt: TimeInterval? = nil) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: "c1",
                createdAt: Date(timeIntervalSince1970: TimeInterval(num)),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: lastMilestoneAt.map { Date(timeIntervalSince1970: $0) },
                closedAt: closedAt.map { Date(timeIntervalSince1970: $0) },
                openItems: needsYou, needsYou: needsYou)
    }

    func testSectionsSortOpenByActivityAndClosedByCloseTime() {
        let sections = MissionsListViewModel.sections(from: [
            mission("ms_1", num: 61, lastMilestoneAt: 10),
            mission("ms_2", num: 62, lastMilestoneAt: 30),
            mission("ms_3", num: 63, lastMilestoneAt: nil),
            mission("ms_4", num: 64, state: .closed, lastMilestoneAt: 20, closedAt: 40),
            mission("ms_5", num: 65, state: .closed, lastMilestoneAt: 5, closedAt: 50),
        ])
        XCTAssertEqual(sections.open.map(\.id), ["ms_2", "ms_1", "ms_3"], "newest milestone first, never-checkpointed last")
        XCTAssertEqual(sections.closed.map(\.id), ["ms_5", "ms_4"], "newest close first")
    }

    func testListPublishesSectionsBadgeAndSupport() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionsListViewModel(store: store, sync: sync)
        vm.start()
        store.missionsContinuation.yield([
            mission("ms_1", num: 61, lastMilestoneAt: 10, needsYou: 2),
            mission("ms_2", num: 62, state: .closed, lastMilestoneAt: 5, closedAt: 9),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.open.map(\.id), ["ms_1"])
        XCTAssertEqual(vm.closed.map(\.id), ["ms_2"])
        XCTAssertEqual(vm.needsYouTotal, 2)
        XCTAssertTrue(vm.isSupported)
        vm.stop()
    }

    func testUnsupportedJournalFlipsTheFlagThatHidesTheTab() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        sync.supported = [true, false]
        let vm = MissionsListViewModel(store: store, sync: sync)
        vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(vm.isSupported)
        vm.stop()
    }

    func testDetailFiltersMilestonesToUserInputOnly() {
        let all = [
            Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .progress, title: "landed", convoID: "c1", seq: 10),
            Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Dan said", convoID: "c1", seq: 20),
        ]
        XCTAssertEqual(MissionDetailViewModel.filtered(all, showOnlyUserInput: false).map(\.id), ["ml_1", "ml_2"])
        XCTAssertEqual(MissionDetailViewModel.filtered(all, showOnlyUserInput: true).map(\.id), ["ml_2"])
    }

    func testDetailRefetchesOnStartAndPublishesEveryStream() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        // `c9` is deliberately absent: a milestone posted in a conversation
        // this device never synced must still render, just without a tag.
        store.tags = ["c1": SessionTagInputs(boxLetter: "D", boxName: "dev-2", sessionShort: "bc")]
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        store.missionContinuation.yield(mission("ms_1", num: 61, lastMilestoneAt: 10))
        store.milestonesContinuation.yield([
            Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Dan said", convoID: "c1", seq: 20),
            Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .progress, title: "landed", convoID: "c9", seq: 10),
        ])
        store.itemsContinuation.yield([
            TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user, title: "needs you", originConvoID: "c1"),
        ])
        store.conversationsContinuation.yield([MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.mission?.id, "ms_1")
        XCTAssertEqual(vm.milestones.map(\.id), ["ml_2", "ml_1"])
        XCTAssertEqual(vm.openItems.map(\.id), ["it_1"])
        XCTAssertEqual(vm.conversations.map(\.id), ["c1"])
        XCTAssertEqual(sync.refetches, ["ms_1"], "opening a page always refetches it")
        XCTAssertEqual(vm.sessionTags["c1"]?.boxLetter, "D")
        XCTAssertEqual(vm.sessionTags["c1"]?.sessionShort, "bc")
        XCTAssertNil(vm.sessionTags["c9"], "an unsynced conversation carries no tag rather than an empty one")
        vm.showOnlyUserInput = true
        XCTAssertEqual(vm.milestones.map(\.id), ["ml_2"])
        vm.stop()
    }

    /// The user's close is always allowed; the confirmation copy names how
    /// many items stay open so the override is deliberate and visible.
    func testCloseSendsTheSummaryAndReportsHowManyItemsWereOpen() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        store.missionContinuation.yield(mission("ms_1", num: 61, lastMilestoneAt: 10, needsYou: 2))
        store.itemsContinuation.yield([
            TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user, title: "a", originConvoID: "c1"),
            TrackerItem(id: "it_2", num: 65, kind: .task, awaiting: .agent, title: "b", originConvoID: "c1"),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.closeConfirmation, "Close with 2 items still open?")
        vm.closeSummaryDraft = "  Shipped.  "
        await vm.close()
        XCTAssertEqual(sync.closes.map(\.0), ["ms_1"])
        XCTAssertEqual(sync.closes.map(\.1), ["Shipped."], "the summary is trimmed before it is sent")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isBusy)
        vm.stop()
    }

    func testCloseRefusesAnEmptySummaryAndSurfacesAServerFailure() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        vm.closeSummaryDraft = "   "
        await vm.close()
        XCTAssertEqual(sync.closes.count, 0)
        XCTAssertEqual(vm.error, "Write a short summary before closing the mission.")

        vm.error = nil
        vm.closeSummaryDraft = "Done."
        sync.closeError = JournalAPIError.transport("offline")
        await vm.close()
        XCTAssertEqual(sync.closes.count, 1)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isBusy)
        vm.stop()
    }

    /// With nothing open the confirmation is skipped entirely.
    func testNoConfirmationWhenNothingIsOpen() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        store.itemsContinuation.yield([])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(vm.closeConfirmation)
        vm.stop()
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionsViewModelTests`
Expected: FAIL — `cannot find 'MissionsStoreReading' in scope`.

- [ ] **Step 3: Add `SessionTagInputs` and `MissionsListViewModel.swift`**

First create `MatronShared/Sources/Models/SessionTagInputs.swift` (in `MatronModels`, NOT the design system: view models publish it and `MatronViewModels` must not depend on `MatronDesignSystem`). `SessionTagText` in the design system is an `enum` of `Text` factories (`run(boxLetter:boxName:sessionShort:colorScheme:)`) with nowhere to hang a value, so the value type lives one layer down:

```swift
import Foundation

/// The three halves `SessionTagText.run` needs, carried as one value so a
/// leaf view can draw a conversation's `A:bc` tag without reaching for a
/// store. Any half may be missing: single-box users have no letter (the
/// same gate `BoxChip` uses), and seed titles / pre-#224 conversations
/// have no session short. A `nil` `SessionTagInputs` means "no tag at
/// all" — never an empty placeholder.
public struct SessionTagInputs: Equatable, Hashable, Sendable {
    public var boxLetter: String?
    public var boxName: String?
    public var sessionShort: String?
    public init(boxLetter: String?, boxName: String?, sessionShort: String?) {
        self.boxLetter = boxLetter
        self.boxName = boxName
        self.sessionShort = sessionShort
    }
}
```

Then create `MatronShared/Sources/ViewModels/MissionsListViewModel.swift`:

```swift
import Foundation
import Observation
import MatronChat
import MatronModels
import MatronJournal

/// The store reads the missions surfaces need, as a protocol so tests fake
/// the store (`JournalStore` conforms; the conformance is declared here
/// because `MatronJournal` cannot import this module).
public protocol MissionsStoreReading: Sendable {
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func missionStream(id: String) -> AsyncStream<Mission?>
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]>
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]>
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]>
    /// The `A:bc` tag halves for one conversation, or `nil` when this
    /// device has no cached row for it (a milestone can name a
    /// conversation that has never synced here — it renders untagged).
    func sessionTag(convoID: String) -> SessionTagInputs?
}

extension JournalStore: MissionsStoreReading {
    /// Derived from three reads the store already has: the conversation row
    /// (`conversation(id:)`), the box roster (`agentNames()`) and the
    /// journal-held tag overrides (`agentTagChars()`). This is the same
    /// derivation `JournalChatService.summary(from:boxNames:boxLetters:)`
    /// runs for a chat-list row — restated here because that one is
    /// internal to `MatronChat` — including its two gates: a box letter
    /// only means something when the user has two or more boxes, and the
    /// session short is peeled off the stored title by
    /// `SessionTag.splitTitle`. Cheap enough to call on the main actor
    /// (a handful of indexed row reads), like `conversationOriginLabels()`.
    public func sessionTag(convoID: String) -> SessionTagInputs? {
        guard let record = try? conversation(id: convoID) else { return nil }
        let names = (try? agentNames()) ?? [:]
        let letters = SessionTag.boxLetters(for: names, overrides: (try? agentTagChars()) ?? [:])
        let boxName = names.count >= 2 ? record.agentDeviceID.flatMap { names[$0] } : nil
        let boxLetter = boxName != nil ? record.agentDeviceID.flatMap { letters[$0] } : nil
        let sessionShort = SessionTag.splitTitle(record.title).sessionShort
        guard boxLetter != nil || sessionShort != nil else { return nil }
        return SessionTagInputs(boxLetter: boxLetter, boxName: boxName, sessionShort: sessionShort)
    }
}

/// The write/refresh surface, mirroring `ItemsSyncing`. `supportedStream` is
/// `async` because `MissionsSync` is an actor and the method is isolated.
public protocol MissionsSyncing: Sendable {
    @discardableResult
    func refresh() async -> MissionsRefreshOutcome
    func refreshMission(id: String) async
    @discardableResult
    func closeMission(id: String, summary: String) async throws -> Mission
    func supportedStream() async -> AsyncStream<Bool>
}
extension MissionsSync: MissionsSyncing {}

/// Backs the Missions tab's list (spec: Apps → Missions tab). Open missions
/// sorted by latest milestone; closed ones in a collapsed section.
@MainActor @Observable
public final class MissionsListViewModel {
    public private(set) var open: [Mission] = []
    public private(set) var closed: [Mission] = []
    /// `false` once the journal has answered 404 on `GET /missions` — the
    /// hosts hide the tab entirely on it.
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    public var error: String?
    /// The tab / nav badge: how many items across every open mission are
    /// waiting on the user.
    public var needsYouTotal: Int { open.reduce(0) { $0 + $1.needsYou } }

    private let store: any MissionsStoreReading
    private let sync: any MissionsSyncing
    private var missionsTask: Task<Void, Never>?
    private var supportedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(store: any MissionsStoreReading, sync: any MissionsSyncing) {
        self.store = store; self.sync = sync
    }

    /// Open: `lastMilestoneAt` desc with never-checkpointed missions last,
    /// `createdAt` desc as the tiebreak — the journal's own order, restated
    /// here so a cache assembled from several fetches still agrees with it.
    /// Closed: newest close first.
    public static func sections(from missions: [Mission]) -> (open: [Mission], closed: [Mission]) {
        let open = missions.filter { $0.state == .open }.sorted { a, b in
            switch (a.lastMilestoneAt, b.lastMilestoneAt) {
            case let (l?, r?): return l == r ? a.createdAt > b.createdAt : l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.createdAt > b.createdAt
            }
        }
        let closed = missions.filter { $0.state == .closed }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        return (open, closed)
    }

    public func start() {
        stop()
        missionsTask = Task { [weak self] in
            guard let stream = self?.store.missionsStream(state: nil) else { return }
            for await missions in stream {
                guard let self, !Task.isCancelled else { return }
                let sections = Self.sections(from: missions)
                self.open = sections.open
                self.closed = sections.closed
            }
        }
        supportedTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.sync.supportedStream()
            for await v in stream {
                guard !Task.isCancelled else { return }
                self.isSupported = v
            }
        }
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    public func stop() {
        missionsTask?.cancel(); missionsTask = nil
        supportedTask?.cancel(); supportedTask = nil
        refreshTask?.cancel(); refreshTask = nil
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // A failed refresh leaves the cached tables alone; the banner is the
        // only visible consequence (spec, Error handling).
        if case .failed(let failure) = await sync.refresh() { error = failure.message }
    }
}
```

- [ ] **Step 4: Write `MatronShared/Sources/ViewModels/MissionDetailViewModel.swift`**

```swift
import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs one mission page (spec: Apps → Missions tab → Page). Reads flow
/// from the local store's streams; the single write — the user's close —
/// goes through `MissionsSyncing`.
@MainActor @Observable
public final class MissionDetailViewModel {
    public let missionID: String
    public private(set) var mission: Mission?
    /// Newest first, already filtered by `showOnlyUserInput`.
    public private(set) var milestones: [Milestone] = []
    /// "My inputs only" — the toggle that turns the page into a list of the
    /// user's own redirections.
    public var showOnlyUserInput = false { didSet { if showOnlyUserInput != oldValue { applyFilter() } } }
    /// Open items in this mission, awaiting-you first (the store's order).
    public private(set) var openItems: [TrackerItem] = []
    public private(set) var conversations: [MissionConversation] = []
    /// The `A:bc` tag halves for every conversation the milestones name,
    /// keyed by conversation id — a mission spans several sessions, so each
    /// row says which one it came from. A conversation this device has not
    /// cached has no entry, and its rows render untagged (never a
    /// placeholder). Rebuilt whenever the milestone list changes.
    public private(set) var sessionTags: [String: SessionTagInputs] = [:]
    public var closeSummaryDraft = ""
    public private(set) var isBusy = false
    public var error: String?

    /// The confirmation to show before a close, or `nil` when nothing is
    /// open and the close needs no extra ceremony.
    public var closeConfirmation: String? {
        guard !openItems.isEmpty else { return nil }
        return "Close with \(openItems.count) item\(openItems.count == 1 ? "" : "s") still open?"
    }

    private let store: any MissionsStoreReading
    private let sync: any MissionsSyncing
    /// Unfiltered, as the store delivered it — `applyFilter` derives
    /// `milestones` from this, so toggling the filter needs no refetch.
    private var allMilestones: [Milestone] = []
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?

    public init(missionID: String, store: any MissionsStoreReading, sync: any MissionsSyncing) {
        self.missionID = missionID; self.store = store; self.sync = sync
    }

    public static func filtered(_ milestones: [Milestone], showOnlyUserInput: Bool) -> [Milestone] {
        showOnlyUserInput ? milestones.filter { $0.kind == .userInput } : milestones
    }

    private func applyFilter() { milestones = Self.filtered(allMilestones, showOnlyUserInput: showOnlyUserInput) }

    /// One store read per DISTINCT conversation in the unfiltered list, so
    /// toggling "My inputs only" costs nothing and a 40-milestone mission
    /// posted in three sessions does three reads, not forty.
    private func refreshSessionTags() {
        var tags: [String: SessionTagInputs] = [:]
        for convoID in Set(allMilestones.map(\.convoID)) {
            if let tag = store.sessionTag(convoID: convoID) { tags[convoID] = tag }
        }
        sessionTags = tags
    }

    public func start() {
        stop()
        let id = missionID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.missionStream(id: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.mission = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.milestonesStream(missionID: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.allMilestones = v
                self.applyFilter()
                self.refreshSessionTags()
            }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemsStream(missionID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.openItems = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.missionConversationsStream(missionID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.conversations = v }
        })
        // Conversations and the full milestone list only reach the local
        // cache through a detail fetch — opening the page must trigger one.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        refreshTask?.cancel(); refreshTask = nil
    }

    public func refresh() async { await sync.refreshMission(id: missionID) }

    /// The user's close. Always permitted server-side, even over open items
    /// — the journal records the override and the close marker names the
    /// numbers. The host shows `closeConfirmation` first when it is non-nil.
    public func close() async {
        let summary = closeSummaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            error = "Write a short summary before closing the mission."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await sync.closeMission(id: missionID, summary: summary)
            closeSummaryDraft = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Add the factories to both `AppDependencies`**

Beside `makeDecisionsViewModel(for:)` in `Matron/App/AppDependencies.swift` and `MatronMac/App/AppDependencies.swift`:

```swift
    /// The Missions tab's list view model — one per signed-in session,
    /// created and started by the shell, stopped when the shell leaves.
    @MainActor func makeMissionsListViewModel(for session: UserSession) -> MissionsListViewModel {
        let c = core(for: session)
        return MissionsListViewModel(store: c.store, sync: c.missions)
    }

    /// One mission page.
    @MainActor func makeMissionDetailViewModel(for session: UserSession, missionID: String) -> MissionDetailViewModel {
        let c = core(for: session)
        return MissionDetailViewModel(missionID: missionID, store: c.store, sync: c.missions)
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionsViewModelTests`
Expected: PASS — `Executed 8 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/ViewModels/MissionsListViewModel.swift \
        MatronShared/Sources/ViewModels/MissionDetailViewModel.swift \
        MatronShared/Sources/Models/SessionTagInputs.swift \
        Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift \
        MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: list and detail view models" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Design-system views — glyphs, row, list, page, and the inline cards

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionGlyph.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionRowView.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionsListView.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionDetailView.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/MilestoneCard.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift` (new)

**Interfaces:**
- Consumes: `Mission`, `Milestone`, `MissionConversation`, `TrackerItem`, `MilestoneKind` (Task 1); `MilestoneMarkerEvent`, `MissionMarkerEvent` (Task 2); `SessionTagInputs` (Task 6); the existing `NeedsYouBadge`, `ItemRow`, `BoxChip`, `MarkdownText`, `SessionTagText`.
- Produces: `MissionGlyph` (`symbol(_:)`/`label(_:)`/`tint(_:)` over both `MissionState` and `MilestoneKind`); `MissionRowView(mission:)`; `MissionsListView(model:onSelect:onRefresh:)` with `MissionsListView.Model { open, closed, isSupported, isRefreshing }`; `MissionDetailView(model:onToggleUserInputOnly:onOpenMilestone:onOpenItem:onOpenConversation:onEditCloseSummary:onClose:)` — seven labels, in that order — with `MissionDetailView.Model { mission, milestones: [MilestoneRow], openItems, conversations, showOnlyUserInput, closeSummary, isBusy }`, its nested `Model.MilestoneRow { milestone, sessionTag: SessionTagInputs? }`, and the mapping init `Model.init(mission:milestones:sessionTags:openItems:conversations:showOnlyUserInput:closeSummary:isBusy:)` that both hosts call; `MilestoneCard(marker:onOpen:)`; `MissionNotice(marker:onOpen:)`.

These are **leaf views** — `MatronDesignSystem` may depend on Models/Events/Search but never on Journal or ViewModels, so every host maps its view model into a `Model` exactly as `DecisionsListView` already requires.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronModels
import MatronEvents
@testable import MatronDesignSystem

final class MissionsSnapshotTests: XCTestCase {
    private let mission = Mission(
        id: "ms_1", num: 61, title: "Missions & milestones", body: "Give every piece of work a readable record.",
        originConvoID: "c1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
        lastMilestoneAt: Date(timeIntervalSince1970: 1_700_000_400),
        openItems: 3, needsYou: 1, conversationCount: 2, milestoneCount: 5,
        lastMilestone: MissionLastMilestone(num: 63, title: "Wired the journal migration",
                                            kind: .userInput, createdAt: Date(timeIntervalSince1970: 1_700_000_400)))

    private let milestones = [
        Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Dan asked for missions",
                  body: "the brief", convoID: "c1", seq: 4210, createdAt: Date(timeIntervalSince1970: 1_700_000_400)),
        Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .progress, title: "Journal half merged",
                  body: "", convoID: "c1", seq: 3100, createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
    ]

    // MARK: Pure logic

    func testGlyphsAreDistinctPerKindAndState() {
        XCTAssertNotEqual(MissionGlyph.symbol(MilestoneKind.userInput), MissionGlyph.symbol(MilestoneKind.progress))
        XCTAssertEqual(MissionGlyph.label(MilestoneKind.userInput), "Your input")
        XCTAssertEqual(MissionGlyph.label(MilestoneKind.progress), "Progress")
        XCTAssertEqual(MissionGlyph.label(MissionState.open), "Open")
        XCTAssertEqual(MissionGlyph.label(MissionState.closed), "Closed")
    }

    /// A marker whose `mission_title` was sieved away must still name the
    /// mission — as `#61`, never as an empty string.
    func testInlineCardsNameTheMissionEvenWithoutATitle() {
        let sieved = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .userInput,
                                          title: "Dan asked for missions", body: "the brief",
                                          missionID: "ms_1", missionNum: 61, missionTitle: nil, by: .agent)
        XCTAssertEqual(MilestoneCard.subtitle(for: sieved), "Your input · #61")
        let titled = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .progress, title: "t",
                                          missionID: "ms_1", missionNum: 61, missionTitle: "Missions & milestones", by: .agent)
        XCTAssertEqual(MilestoneCard.subtitle(for: titled), "Progress · Missions & milestones")
    }

    func testMissionNoticeText() {
        let created = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones", action: .created, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: created), "🏁 Mission #61 started · Missions & milestones")
        let joined = MissionMarkerEvent(missionID: "ms_1", num: 61, title: nil, action: .joined, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: joined), "🏁 Joined mission #61")
        let closed = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones",
                                        action: .closed, by: .user, openItemNums: [64, 70])
        XCTAssertEqual(MissionNotice.text(for: closed), "🏁 Mission #61 closed over #64, #70")
        let updated = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Renamed", action: .updated, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: updated), "🏁 Mission #61 renamed · Renamed")
    }

    func testListModelEmptyState() {
        let empty = MissionsListView.Model(open: [], closed: [], isSupported: true, isRefreshing: false)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(MissionsListView.Model(open: [mission], closed: [], isSupported: true, isRefreshing: false).isEmpty)
    }

    // MARK: Snapshots

    func testMissionRow() {
        assertVariants(of: MissionRowView(mission: mission).frame(width: 380).padding(), named: "mission-row")
    }

    func testMissionsList() {
        let model = MissionsListView.Model(
            open: [mission],
            closed: [Mission(id: "ms_0", num: 55, state: .closed, title: "Items tracker",
                             // Declaration order (Task 1): closeSummary /
                             // closedBy / closedOverOpenItems come BEFORE
                             // originConvoID.
                             closeSummary: "Shipped.", closedBy: .agent, originConvoID: "c0",
                             closedAt: Date(timeIntervalSince1970: 1_600_000_000))],
            isSupported: true, isRefreshing: false)
        assertVariants(of: MissionsListView(model: model, onSelect: { _ in }, onRefresh: {})
            .frame(width: 380, height: 420), named: "missions-list")
    }

    func testMissionsListUnsupported() {
        let model = MissionsListView.Model(open: [], closed: [], isSupported: false, isRefreshing: false)
        assertVariants(of: MissionsListView(model: model, onSelect: { _ in }, onRefresh: {})
            .frame(width: 380, height: 260), named: "missions-list-unsupported")
    }

    func testMissionDetail() {
        let model = MissionDetailView.Model(
            mission: mission,
            // One row tagged (its conversation is cached on this device),
            // one untagged — the two states the page has to draw.
            milestones: [
                .init(milestone: milestones[0],
                      sessionTag: SessionTagInputs(boxLetter: "D", boxName: "dev-2", sessionShort: "bc")),
                .init(milestone: milestones[1], sessionTag: nil),
            ],
            openItems: [TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Which order for the tabs?", originConvoID: "c1")],
            conversations: [MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running")],
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        assertVariants(of: MissionDetailView(model: model, onToggleUserInputOnly: { _ in },
                                             onOpenMilestone: { _ in }, onOpenItem: { _ in },
                                             onOpenConversation: { _ in }, onEditCloseSummary: { _ in },
                                             onClose: {})
            .frame(width: 420, height: 640), named: "mission-detail")
    }

    func testMilestoneCardAndMissionNotice() {
        let marker = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .userInput,
                                          title: "Dan asked for missions", body: "Make the work readable.",
                                          missionID: "ms_1", missionNum: 61, missionTitle: "Missions & milestones", by: .agent)
        assertVariants(of: MilestoneCard(marker: marker, onOpen: {}).frame(width: 360).padding(), named: "milestone-card")
        let notice = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones", action: .closed, by: .user)
        assertVariants(of: MissionNotice(marker: notice, onOpen: {}).frame(width: 360).padding(), named: "mission-notice")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionsSnapshotTests`
Expected: FAIL — `cannot find 'MissionGlyph' in scope`.

- [ ] **Step 3: Write `MissionGlyph.swift`**

```swift
import SwiftUI
import MatronModels

/// Symbols, labels and tints for missions and milestones — the single place
/// the two vocabularies are named, so a row, a card and a page can never
/// disagree. Sibling of `ItemGlyph`.
public enum MissionGlyph {
    public static func symbol(_ state: MissionState) -> String {
        switch state { case .open: return "flag.checkered"; case .closed: return "flag.checkered.circle.fill" }
    }
    public static func label(_ state: MissionState) -> String {
        switch state { case .open: return "Open"; case .closed: return "Closed" }
    }
    public static func tint(_ state: MissionState) -> Color {
        switch state { case .open: return .accentColor; case .closed: return .secondary }
    }
    /// `user_input` gets the person glyph — the spec's "kind glyph (person
    /// for `user_input`)" — because finding Dan's own inputs is the point.
    public static func symbol(_ kind: MilestoneKind) -> String {
        switch kind { case .userInput: return "person.fill"; case .progress: return "circle.fill" }
    }
    public static func label(_ kind: MilestoneKind) -> String {
        switch kind { case .userInput: return "Your input"; case .progress: return "Progress" }
    }
    public static func tint(_ kind: MilestoneKind) -> Color {
        switch kind { case .userInput: return .orange; case .progress: return .secondary }
    }
}
```

- [ ] **Step 4: Write `MissionRowView.swift`**

```swift
import SwiftUI
import MatronModels

/// One row in the Missions list: `#num`, title, the last milestone with its
/// relative age, and the needs-you badge.
public struct MissionRowView: View {
    let mission: Mission
    public init(mission: Mission) { self.mission = mission }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: MissionGlyph.symbol(mission.state))
                .foregroundStyle(MissionGlyph.tint(mission.state))
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(mission.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(mission.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if let last = mission.lastMilestone {
                    HStack(spacing: 5) {
                        Image(systemName: MissionGlyph.symbol(last.kind))
                            .font(.caption2)
                            .foregroundStyle(MissionGlyph.tint(last.kind))
                        Text(last.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        RelativeMinuteTimeView(date: last.createdAt)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if mission.state == .open {
                    Text("No milestones yet").font(.subheadline).foregroundStyle(.tertiary)
                }
                if mission.state == .closed, let summary = mission.closeSummary, !summary.isEmpty {
                    Text(summary.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            NeedsYouBadge(count: mission.needsYou)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mission \(mission.num), \(mission.title)\(mission.needsYou > 0 ? ", \(mission.needsYou) need you" : "")")
    }
}
```

- [ ] **Step 5: Write `MissionsListView.swift`**

```swift
import SwiftUI
import MatronModels

/// Every mission, open first, closed in a collapsed section (spec: Apps →
/// Missions tab → List). A pure leaf view: hosts map
/// `MissionsListViewModel` into `Model`, so this is snapshot-testable
/// without a view model — the same contract `DecisionsListView` uses.
public struct MissionsListView: View {
    public struct Model: Equatable {
        public var open: [Mission]
        public var closed: [Mission]
        /// `false` shows the unsupported message; hosts hide the tab too.
        public var isSupported: Bool
        public var isRefreshing: Bool
        public init(open: [Mission], closed: [Mission], isSupported: Bool, isRefreshing: Bool) {
            self.open = open; self.closed = closed; self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
        public var isEmpty: Bool { open.isEmpty && closed.isEmpty }
    }

    let model: Model
    let onSelect: (String) -> Void
    let onRefresh: () async -> Void
    @State private var showClosed = false

    public init(model: Model, onSelect: @escaping (String) -> Void, onRefresh: @escaping () async -> Void) {
        self.model = model; self.onSelect = onSelect; self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Text("Missions").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
                Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
            }
            .padding(.horizontal).padding(.vertical, 8)
            #endif
            if !model.isSupported {
                placeholder(ContentUnavailableView("Missions not available", systemImage: "exclamationmark.triangle",
                                                   description: Text("Update the journal server to use missions.")))
            } else if model.isEmpty {
                // The copy must not imply the app can start one: only an
                // agent can, through `mission_start` (spec #74).
                placeholder(ContentUnavailableView("No missions yet", systemImage: "flag.checkered",
                                                   description: Text("An agent starts one with mission_start, then posts milestones as the work goes.")))
            } else {
                List {
                    if !model.open.isEmpty {
                        Section("Open") {
                            ForEach(model.open) { mission in row(mission) }
                        }
                    }
                    if !model.closed.isEmpty {
                        Section(isExpanded: $showClosed) {
                            ForEach(model.closed) { mission in row(mission) }
                        } header: {
                            Text("Closed (\(model.closed.count))")
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .refreshable { await onRefresh() }
                #else
                .listStyle(.sidebar)
                #endif
            }
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    private func row(_ mission: Mission) -> some View {
        Button { onSelect(mission.id) } label: { MissionRowView(mission: mission) }
            .buttonStyle(.plain)
            // iOS List Buttons inherit the accent tint unless reset.
            .foregroundStyle(Color.primary)
    }

    /// Same shape as `DecisionsListView.placeholder`: on iOS the empty
    /// states still answer pull-to-refresh, because there is no header
    /// refresh button there.
    @ViewBuilder
    private func placeholder<Content: View>(_ content: Content) -> some View {
        #if os(iOS)
        GeometryReader { geo in
            ScrollView { content.frame(width: geo.size.width, height: geo.size.height) }
                .refreshable { await onRefresh() }
        }
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
```

- [ ] **Step 6: Write `MissionDetailView.swift`**

```swift
import SwiftUI
import MatronModels

/// One mission page (spec: Apps → Missions tab → Page). Leaf view: header,
/// milestones newest first with a "My inputs only" toggle, open items, and
/// the conversations the mission owns, plus the user's close control.
public struct MissionDetailView: View {
    public struct Model: Equatable {
        /// One milestone as the page draws it: the record, plus the `A:bc`
        /// tag of the conversation it was posted in — a mission spans
        /// several sessions, so each row says which one it came from.
        /// `nil` when this device has no cached row for that conversation:
        /// the row then renders with no tag, never a placeholder.
        public struct MilestoneRow: Identifiable, Equatable {
            public var milestone: Milestone
            public var sessionTag: SessionTagInputs?
            public var id: String { milestone.id }
            public init(milestone: Milestone, sessionTag: SessionTagInputs? = nil) {
                self.milestone = milestone
                self.sessionTag = sessionTag
            }
        }

        public var mission: Mission?
        public var milestones: [MilestoneRow]
        public var openItems: [TrackerItem]
        public var conversations: [MissionConversation]
        public var showOnlyUserInput: Bool
        public var closeSummary: String
        public var isBusy: Bool
        public init(mission: Mission?, milestones: [MilestoneRow], openItems: [TrackerItem],
                    conversations: [MissionConversation], showOnlyUserInput: Bool,
                    closeSummary: String, isBusy: Bool) {
            self.mission = mission; self.milestones = milestones; self.openItems = openItems
            self.conversations = conversations; self.showOnlyUserInput = showOnlyUserInput
            self.closeSummary = closeSummary; self.isBusy = isBusy
        }

        /// The ONE mapping from a `MissionDetailViewModel`'s published
        /// values into this model. Both hosts call it — `MissionDetailHost`
        /// (Task 9) and `MacMissionPage` (Task 10) — so the two platforms'
        /// mission pages cannot drift. It takes plain values rather than
        /// the view model itself because `MatronDesignSystem` is a leaf: it
        /// may depend on Models/Events, never on `MatronViewModels`.
        public init(mission: Mission?, milestones: [Milestone],
                    sessionTags: [String: SessionTagInputs], openItems: [TrackerItem],
                    conversations: [MissionConversation], showOnlyUserInput: Bool,
                    closeSummary: String, isBusy: Bool) {
            self.init(mission: mission,
                      milestones: milestones.map {
                          MilestoneRow(milestone: $0, sessionTag: sessionTags[$0.convoID])
                      },
                      openItems: openItems,
                      conversations: conversations,
                      showOnlyUserInput: showOnlyUserInput,
                      closeSummary: closeSummary,
                      isBusy: isBusy)
        }
    }

    let model: Model
    let onToggleUserInputOnly: (Bool) -> Void
    /// The milestone's conversation and its anchor seq — the host opens the
    /// transcript there.
    let onOpenMilestone: (Milestone) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void
    let onEditCloseSummary: (String) -> Void
    let onClose: () -> Void
    @State private var showingClose = false
    /// `SessionTagText` tints a box letter with `BoxChip.textTint(for:in:)`,
    /// which needs the scheme — the same environment read `ChatView`'s
    /// header does for its own tag.
    @Environment(\.colorScheme) private var colorScheme

    public init(model: Model, onToggleUserInputOnly: @escaping (Bool) -> Void,
                onOpenMilestone: @escaping (Milestone) -> Void, onOpenItem: @escaping (String) -> Void,
                onOpenConversation: @escaping (String) -> Void, onEditCloseSummary: @escaping (String) -> Void,
                onClose: @escaping () -> Void) {
        self.model = model; self.onToggleUserInputOnly = onToggleUserInputOnly
        self.onOpenMilestone = onOpenMilestone; self.onOpenItem = onOpenItem
        self.onOpenConversation = onOpenConversation; self.onEditCloseSummary = onEditCloseSummary
        self.onClose = onClose
    }

    public var body: some View {
        if let mission = model.mission {
            List {
                Section { header(mission) }
                Section {
                    if model.milestones.isEmpty {
                        Text(model.showOnlyUserInput ? "No milestones from you yet." : "No milestones yet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.milestones) { row in
                            Button { onOpenMilestone(row.milestone) } label: { milestoneRow(row) }
                                .buttonStyle(.plain).foregroundStyle(Color.primary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Milestones")
                        Spacer()
                        Toggle("My inputs only", isOn: Binding(
                            get: { model.showOnlyUserInput },
                            set: { onToggleUserInputOnly($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("My inputs only")
                    }
                }
                if !model.openItems.isEmpty {
                    Section("Open items") {
                        ForEach(model.openItems) { item in
                            Button { onOpenItem(item.id) } label: { ItemRow(item: item) }
                                .buttonStyle(.plain).foregroundStyle(Color.primary)
                        }
                    }
                }
                if !model.conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(model.conversations) { convo in
                            Button { onOpenConversation(convo.id) } label: { conversationRow(convo) }
                                .buttonStyle(.plain).foregroundStyle(Color.primary)
                        }
                    }
                }
                if mission.state == .open {
                    Section("Close this mission") { closeControls }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MatronTimelineBackground())
            #else
            .listStyle(.inset)
            #endif
            .confirmationDialog(confirmationTitle, isPresented: $showingClose, titleVisibility: .visible) {
                Button("Close mission", role: .destructive) { onClose() }
                Button("Keep it open", role: .cancel) {}
            } message: {
                Text("The items stay open and keep their mission. The close is recorded on it.")
            }
        } else {
            ContentUnavailableView("Mission not on this device yet", systemImage: "flag.checkered",
                                   description: Text("It will appear once this device syncs it."))
        }
    }

    private var confirmationTitle: String {
        model.openItems.isEmpty
            ? "Close this mission?"
            : "Close with \(model.openItems.count) item\(model.openItems.count == 1 ? "" : "s") still open?"
    }

    private func header(_ mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#\(mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(mission.title).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Text(MissionGlyph.label(mission.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MissionGlyph.tint(mission.state))
            }
            if !mission.body.isEmpty { MarkdownText(mission.body).font(.subheadline) }
            if let summary = mission.closeSummary, !summary.isEmpty {
                Divider()
                Text("Closed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MarkdownText(summary).font(.subheadline)
                if mission.closedOverOpenItems > 0 {
                    Text("Closed over \(mission.closedOverOpenItems) open item\(mission.closedOverOpenItems == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func milestoneRow(_ row: Model.MilestoneRow) -> some View {
        let milestone = row.milestone
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: MissionGlyph.symbol(milestone.kind))
                .font(.caption)
                .foregroundStyle(MissionGlyph.tint(milestone.kind))
                .frame(width: 16).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(milestone.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(milestone.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if !milestone.body.isEmpty {
                    Text(milestone.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    RelativeMinuteTimeView(date: milestone.createdAt).font(.caption2).foregroundStyle(.tertiary)
                    // `SessionTagText` is an enum of `Text` factories, not a
                    // view: `run` composes the letter (in the box's hue) and
                    // the `:bc` short into one `Text`, and answers `nil`
                    // when there is nothing to show. No cached conversation
                    // ⇒ no `sessionTag` ⇒ nothing rendered, no empty gap.
                    // Do NOT restyle the result with `.foregroundStyle` —
                    // that would flatten the per-run box color.
                    if let tag = row.sessionTag,
                       let tagRun = SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                                       sessionShort: tag.sessionShort,
                                                       colorScheme: colorScheme) {
                        tagRun.font(.caption2)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(MissionGlyph.label(milestone.kind)) \(milestone.num), \(milestone.title)"
                            + (row.sessionTag?.boxName.map { ", \($0)" } ?? ""))
        .accessibilityHint("Opens the conversation at this point")
    }

    private func conversationRow(_ convo: MissionConversation) -> some View {
        HStack(spacing: 8) {
            if let box = convo.box { BoxChip(name: box) }
            Text(convo.title.isEmpty ? convo.id : convo.title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
            Text(convo.state).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var closeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("How it went", text: Binding(get: { model.closeSummary }, set: { onEditCloseSummary($0) }),
                      axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Closing summary")
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Close mission") { showingClose = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.closeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
```

- [ ] **Step 7: Write `MilestoneCard.swift`**

```swift
import SwiftUI
import MatronModels
import MatronEvents

/// Inline timeline rendering of a `milestone` marker: the card IS the jump
/// target's own row, so it needs no navigation of its own beyond opening the
/// mission page.
///
/// The mission is named through `marker.missionLabel`, which falls back to
/// `#N` when the journal sieved `mission_title` away at write time. Never
/// render `missionTitle` directly.
public struct MilestoneCard: View {
    let marker: MilestoneMarkerEvent
    let onOpen: () -> Void
    public init(marker: MilestoneMarkerEvent, onOpen: @escaping () -> Void) {
        self.marker = marker; self.onOpen = onOpen
    }

    /// "Your input · Missions & milestones" / "Progress · #61". Static so the
    /// fallback is unit-testable without rendering.
    public static func subtitle(for marker: MilestoneMarkerEvent) -> String {
        "\(MissionGlyph.label(marker.kind)) · \(marker.missionLabel)"
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: MissionGlyph.symbol(marker.kind))
                    .foregroundStyle(MissionGlyph.tint(marker.kind))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("#\(marker.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(marker.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    if !marker.body.isEmpty {
                        Text(marker.body.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text(Self.subtitle(for: marker))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(marker.kind == .userInput ? Color.orange.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Milestone \(marker.num), \(marker.title). \(Self.subtitle(for: marker))")
        .accessibilityHint("Opens the mission")
    }
}

/// Inline rendering of a `mission` marker — a one-line notice, not a card.
/// Same title-fallback rule as `MilestoneCard`.
public struct MissionNotice: View {
    let marker: MissionMarkerEvent
    let onOpen: () -> Void
    public init(marker: MissionMarkerEvent, onOpen: @escaping () -> Void) {
        self.marker = marker; self.onOpen = onOpen
    }

    public static func text(for marker: MissionMarkerEvent) -> String {
        let named = marker.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        switch marker.action {
        case .created: return "🏁 Mission #\(marker.num) started\(named)"
        case .joined:  return "🏁 Joined mission #\(marker.num)\(named)"
        case .updated: return "🏁 Mission #\(marker.num) renamed\(named)"
        case .closed:
            guard !marker.openItemNums.isEmpty else { return "🏁 Mission #\(marker.num) closed\(named)" }
            return "🏁 Mission #\(marker.num) closed over " + marker.openItemNums.map { "#\($0)" }.joined(separator: ", ")
        }
    }

    public var body: some View {
        Button(action: onOpen) {
            Text(Self.text(for: marker)).font(.caption).lineLimit(2).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.text(for: marker))
    }
}
```

- [ ] **Step 8: Record the snapshot baselines, then verify**

Run (records, and fails on first run by design): `swift test --package-path MatronShared --filter MissionsSnapshotTests`
Expected: FAIL with `Record mode is on` / newly-written `__Snapshots__/MissionsSnapshotTests/*.png`.

Run again: `swift test --package-path MatronShared --filter MissionsSnapshotTests`
Expected: PASS — `Executed 9 tests, with 0 failures`.

Then the skip-path, which is what CI runs: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter MissionsSnapshotTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Missions \
        MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: design-system row, list, page and inline cards" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Timeline — map the two marker events and render them on both platforms

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift`
- Modify: `MatronShared/Sources/Chat/JournalTimelineMapper.swift`
- Modify: `MatronShared/Sources/ViewModels/ChatViewModel.swift` (`FocusOwner.milestone`, `jumpToMilestone(seq:)`)
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift`, `Matron/Features/Chat/ChatView.swift`
- Modify: `MatronMac/Features/Chat/MacTimelineItemView.swift`, `MatronMac/Features/Chat/MacChatView.swift`
- Test: `MatronShared/Tests/ChatTests/JournalTimelineMapperMissionsTests.swift` (new), `MatronTests/TimelineItemViewTests.swift`, `MatronMacTests/MacTimelineItemViewTests.swift`, `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`

**Interfaces:**
- Consumes: `MilestoneMarkerEvent`, `MissionMarkerEvent` (Task 2); `MilestoneCard`, `MissionNotice` (Task 7).
- Produces: `TimelineItem.Kind.milestoneMarker(eventID: String, MilestoneMarkerEvent)` and `.missionMarker(eventID: String, MissionMarkerEvent)`; `onOpenMission: ((String) -> Void)?` on `TimelineItemView`, `MacTimelineItemView`, `TimelineListContent` and its Mac twin; `ChatViewModel.jumpToMilestone(seq:) async`.

**The scroll-to-seq path, named:** `ChatViewModel.focusOrPark(seq:owner:)` decides between running now and parking until the first snapshot; `focus(seq:)` pages history backward until the target row is loaded and then writes `pendingFocusID`; `ChatView`'s `.onChange(of: viewModel.pendingFocusID, initial: true)` (and `MacChatView`'s twin) disengages tail-follow, calls `ensureWindowContains(target)`, `proxy.scrollTo(target, anchor: .top)`, `clearPendingFocus()`, and re-asserts after 200ms. A milestone jump reuses all of it — the only new thing is a `FocusOwner` case so dismissing the search bar cannot kill it.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/ChatTests/JournalTimelineMapperMissionsTests.swift`:

```swift
import XCTest
import MatronEvents
import MatronJournal
import MatronModels
@testable import MatronChat

final class JournalTimelineMapperMissionsTests: XCTestCase {
    private func event(_ type: String, _ payload: [String: Any], seq: Int64 = 4210) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:dev-2",
                     type: type, payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testMilestoneEventBecomesACardKeyedByItsOwnSeq() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.milestone, [
                "milestone_id": "ml_2", "num": 63, "kind": "user_input", "title": "Dan asked",
                "body": "the brief", "mission_id": "ms_1", "mission_num": 61,
                "mission_title": "Missions & milestones", "by": "agent",
            ]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .milestoneMarker(let eventID, let marker) = item.kind else {
            return XCTFail("expected .milestoneMarker, got \(item.kind)")
        }
        // The event's OWN seq is the anchor, so it is also the row id the
        // transcript scrolls to.
        XCTAssertEqual(eventID, "4210")
        XCTAssertEqual(item.id, "4210")
        XCTAssertEqual(marker.num, 63)
        XCTAssertEqual(marker.missionLabel, "Missions & milestones")
    }

    func testMilestoneEventWithoutMissionTitleStillRenders() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.milestone, [
                "milestone_id": "ml_2", "num": 63, "kind": "progress", "title": "landed",
                "mission_id": "ms_1", "mission_num": 61, "by": "agent",
            ]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .milestoneMarker(_, let marker) = item.kind else { return XCTFail("expected .milestoneMarker") }
        XCTAssertEqual(marker.missionLabel, "#61")
    }

    func testMissionEventBecomesANotice() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.mission, [
                "mission_id": "ms_1", "num": 61, "title": "Missions & milestones",
                "action": "closed", "by": "user", "open_item_nums": [64, 70],
            ]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .missionMarker(_, let marker) = item.kind else { return XCTFail("expected .missionMarker") }
        XCTAssertEqual(marker.action, .closed)
        XCTAssertEqual(marker.openItemNums, [64, 70])
    }

    func testMalformedMarkersAreSkippedRatherThanRenderedAsUnknown() {
        XCTAssertNil(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.milestone, ["milestone_id": "ml_2"]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        XCTAssertNil(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.mission, ["mission_id": "ms_1", "num": 61, "action": "exploded", "by": "agent"]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
    }
}
```

Append to `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`, **inside `final class ChatViewModelTests`** — the two tests use that class's own private `row(_ seq: Int, own: Bool)` helper and the `PagingFakeTimelineService` / `FakeMediaService` fakes declared at the top of that file. (There is no `makeViewModel()` in this file; that helper belongs to `ChatViewModelAgentChatTests`, against a different fake. The suite's own helpers are `row(_:own:)`, `makeVMWithMessages(seqs:)`, `makeVMWithPagedHistory(loaded:olderPages:)` and `makeLongTimelineVM(count:)`.)

```swift
    /// A milestone tap made before the transcript is live parks and fires on
    /// the first snapshot — the same gate in-conversation search uses, for
    /// the same reason: sampling paginate growth against a stream nobody is
    /// subscribed to falsely latches `reachedHistoryStart`. And because the
    /// jump is owned by `FocusOwner.milestone`, dismissing the search bar
    /// must not kill it (only search's own jump dies there).
    @MainActor
    func test_jumpToMilestone_parksUntilLive_andSurvivesSearchDismissal() async throws {
        let fake = PagingFakeTimelineService(loaded: [row(120, own: false), row(121, own: false)],
                                             olderPages: [])
        let vm = ChatViewModel(roomID: "r1", timeline: fake, media: FakeMediaService())

        await vm.jumpToMilestone(seq: 120)
        XCTAssertNil(vm.pendingFocusID, "no jump before the stream is live")
        XCTAssertFalse(vm.reachedHistoryStart, "a pre-start jump must not latch history-start")

        vm.endChatSearch()

        _ = await vm.start()
        // The parked jump fires off the first snapshot's Task hop.
        let deadline = Date().addingTimeInterval(2)
        while vm.pendingFocusID == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.pendingFocusID, "120", "the parked milestone jump fired once the stream was live")
        XCTAssertFalse(vm.reachedHistoryStart)
        vm.stop()
    }

    /// The warm case: the stream is already live, so the jump runs at once
    /// and lands on the milestone marker's own row (its seq IS the row id).
    @MainActor
    func test_jumpToMilestone_onALiveStreamLandsImmediately() async throws {
        let fake = PagingFakeTimelineService(loaded: [row(120, own: false), row(121, own: false)],
                                             olderPages: [])
        let vm = ChatViewModel(roomID: "r1", timeline: fake, media: FakeMediaService())
        _ = await vm.start()

        await vm.jumpToMilestone(seq: 121)
        XCTAssertEqual(vm.pendingFocusID, "121")
        XCTAssertEqual(fake.paginateCalls, 0, "the target row is already loaded — nothing to page in")
        vm.stop()
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "JournalTimelineMapperMissionsTests|ChatViewModelTests"`
Expected: FAIL — `type 'TimelineItem.Kind' has no member 'milestoneMarker'`.

- [ ] **Step 3: Add the two `TimelineItem.Kind` cases**

In `MatronShared/Sources/Chat/TimelineItem.swift`, after `case itemMarker(eventID: String, ItemMarkerEvent)`:

```swift
        /// Mission milestone marker (spec 2026-09-10). The event's own seq
        /// is the milestone's anchor, so this row IS the jump target — a
        /// `focus(seq:)` for that seq lands exactly here. `eventID` is the
        /// journal seq, as for `.itemMarker`.
        case milestoneMarker(eventID: String, MilestoneMarkerEvent)
        /// Mission lifecycle marker — a one-line inline notice. Apps use it
        /// only as an invalidation signal beyond that.
        case missionMarker(eventID: String, MissionMarkerEvent)
```

- [ ] **Step 4: Map both event types**

In `MatronShared/Sources/Chat/JournalTimelineMapper.swift`, after the `case JournalEventType.item:` branch:

```swift
        case JournalEventType.milestone:
            // The marker's own seq is the anchor (protocol, "Marker
            // events"), and `TimelineItem.id` is that seq — so nothing
            // extra is needed to make a milestone tap land here. A payload
            // that won't parse is skipped rather than rendered as
            // `.unknown`: a half-drawn navigation affordance is worse than
            // no row.
            guard let marker = MilestoneMarkerEvent.parse(payload: payload) else { return nil }
            kind = .milestoneMarker(eventID: String(event.seq), marker)

        case JournalEventType.mission:
            guard let marker = MissionMarkerEvent.parse(payload: payload) else { return nil }
            kind = .missionMarker(eventID: String(event.seq), marker)
```

- [ ] **Step 5: Give `ChatViewModel` a public milestone jump**

In `MatronShared/Sources/ViewModels/ChatViewModel.swift`, extend the private owner enum:

```swift
    private enum FocusOwner { case search, lastOwnMessage, milestone }
```

and add, next to `jumpToLastOwnMessage()`:

```swift
    // MARK: Jump to a milestone

    /// Scrolls the transcript to a milestone's anchor — the `seq` of its own
    /// `milestone` marker event (spec 2026-09-10). Rides the same
    /// park-until-live jump as in-conversation search and the
    /// last-own-message jump, so a tap made from the Missions tab *before*
    /// this room's stream is up lands once the first snapshot arrives.
    ///
    /// Its own `FocusOwner` case matters: `endChatSearch()` cancels only
    /// search's jump, so dismissing the search bar cannot kill a milestone
    /// jump that happens to be in flight. A seq that no longer exists lands
    /// on the nearest earlier row (`focus(seq:)`'s existing fallback).
    public func jumpToMilestone(seq: Int64) async {
        await focusOrPark(seq: seq, owner: .milestone)
    }
```

- [ ] **Step 6: Render both kinds on iOS**

In `Matron/Features/Chat/Rendering/TimelineItemView.swift`, add the callback beside `onOpenItem`:

```swift
    /// Opens the mission page for a tapped `.milestoneMarker` /
    /// `.missionMarker` — same "fixed per screen, `nil` where there is
    /// nowhere to navigate" convention as `onOpenItem`.
    var onOpenMission: ((String) -> Void)? = nil
```

and, after the `case .itemMarker` branch in `renderedBody`:

```swift
        case .milestoneMarker(_, let marker):
            HStack {
                MilestoneCard(marker: marker) { onOpenMission?(marker.missionID) }
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)

        case .missionMarker(_, let marker):
            HStack {
                MissionNotice(marker: marker) { onOpenMission?(marker.missionID) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
```

Thread `onOpenMission` through `TimelineListContent` and the sub-chat list content in `Matron/Features/Chat/ChatView.swift` exactly as `onOpenItem` is threaded today (`let onOpenMission: ((String) -> Void)?` on each container, passed down at both `TimelineItemView(...)` call sites, and `nil` at the preview/test call site at the bottom of the file). `ChatView` supplies it with:

```swift
    /// A tapped milestone card opens its mission on whichever stack this
    /// chat is mounted in — the same rule `openItem` follows.
    private func openMission(_ missionID: String) {
        Self.pushMission(missionID, onto: navigationPath)
    }
```

(`pushMission` is added in Task 9 alongside `MissionRoute`; until then this task's build step is the SPM package only.)

- [ ] **Step 7: Render both kinds on the Mac**

Apply the same two edits to `MatronMac/Features/Chat/MacTimelineItemView.swift` (`var onOpenMission: ((String) -> Void)? = nil` beside `onOpenItem`, and the two `case` branches after `.itemMarker`), and thread it through `MacChatView`'s two timeline containers the same way `onOpenItem` is threaded. `MacChatView` gains:

```swift
    /// Set by `MacChatListView` — opens the mission page in the detail
    /// column. `nil` in previews and tests leaves the cards inert.
    var onOpenMission: ((String) -> Void)? = nil
```

- [ ] **Step 8: Pin the render contract on both shells**

Append to `MatronTests/TimelineItemViewTests.swift`:

```swift
    /// Both mission kinds are visible rows — they are navigation
    /// affordances, so filtering them out would make a milestone
    /// unreachable from the transcript.
    func testMissionKindsRender() {
        let milestone = TimelineItem(id: "4210", sender: "agent:dev-2", timestamp: Date(),
                                     kind: .milestoneMarker(eventID: "4210", MilestoneMarkerEvent(
                                        milestoneID: "ml_2", num: 63, kind: .userInput, title: "Dan asked",
                                        missionID: "ms_1", missionNum: 61, missionTitle: nil, by: .agent)),
                                     isOwn: false)
        let mission = TimelineItem(id: "4211", sender: "agent:dev-2", timestamp: Date(),
                                   kind: .missionMarker(eventID: "4211", MissionMarkerEvent(
                                      missionID: "ms_1", num: 61, title: nil, action: .closed, by: .user)),
                                   isOwn: false)
        XCTAssertTrue(TimelineItemView.shouldRender(milestone))
        XCTAssertTrue(TimelineItemView.shouldRender(mission))
    }
```

Append the identical test (with `MacTimelineItemView.shouldRender`) to `MatronMacTests/MacTimelineItemViewTests.swift`.

- [ ] **Step 9: Run everything to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "JournalTimelineMapperMissionsTests|ChatViewModelTests"`
Expected: PASS — `Executed N tests, with 0 failures`.

(The two shell test files are compiled and run at the end of Tasks 9 and 10, which add `pushMission` and the Mac host.)

- [ ] **Step 10: Commit**

```bash
git add MatronShared/Sources/Chat/TimelineItem.swift MatronShared/Sources/Chat/JournalTimelineMapper.swift \
        MatronShared/Sources/ViewModels/ChatViewModel.swift \
        MatronShared/Tests/ChatTests/JournalTimelineMapperMissionsTests.swift \
        MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift \
        Matron/Features/Chat/Rendering/TimelineItemView.swift Matron/Features/Chat/ChatView.swift \
        MatronMac/Features/Chat/MacTimelineItemView.swift MatronMac/Features/Chat/MacChatView.swift \
        MatronTests/TimelineItemViewTests.swift MatronMacTests/MacTimelineItemViewTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: milestone cards and mission notices in the transcript" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: iOS — the Missions tab, the mission page, the title tap, and retiring the summaries sheet

**Files:**
- Create: `Matron/App/PathPrefixedRoute.swift`
- Create: `Matron/App/MissionRoute.swift`
- Create: `Matron/Features/Missions/MissionsTabRoot.swift`
- Create: `Matron/Features/Missions/MissionDetailHost.swift`
- Modify: `Matron/App/ItemRoute.swift` (adopts the shared protocol; its public surface is unchanged)
- Modify: `Matron/App/AppShellNavigation.swift`, `Matron/App/AppShellView.swift`, `Matron/Features/Chat/ChatView.swift`, `Matron/Features/ChatList/ChatListView.swift`
- Delete: `Matron/Features/Chat/SummariesSheet.swift`, `MatronTests/SummariesSheetBindingTests.swift`
- Test: `MatronTests/AppShellNavigationTests.swift` (extend), `MatronTests/MissionsNavigationTests.swift` (new)

**Interfaces:**
- Consumes: `MissionsListViewModel`, `MissionDetailViewModel` (Task 6); `MissionsListView`, `MissionDetailView` (Task 7); `ChatViewModel.jumpToMilestone(seq:)` (Task 8).
- Produces: `PathPrefixedRoute` (static `pathPrefix`, `id`, `init(id:)`, with `pathValue` and `init?(pathValue:)` defaulted in an extension); `MissionRoute` (`pathPrefix = "mission/"`) and `ItemRoute` conforming to it; `AppTab.missions`; `AppShellNavigation.missionsPath`, `openMission(_:)`, `pushMission(_:)`, `openConversation(fromMissions:)`; `ChatView.pushMission(_:onto:)`; `AppShellView.openMilestone(convoID:seq:)`.

**Tab order.** The spec fixes the bar as **Coordinator · Missions · Decisions · Conversations**, and `AppTab.allCases` is both the bar order and the root swipe order. That reorders the existing bar (Conversations moves to last); `AppShellNavigationTests`' swipe expectations move with it. The app still *opens* on `.conversations`.

- [ ] **Step 1: Write the failing tests**

Create `MatronTests/MissionsNavigationTests.swift`:

```swift
import XCTest
@testable import Matron

@MainActor
final class MissionsNavigationTests: XCTestCase {
    func testTabOrderIsCoordinatorMissionsDecisionsConversations() {
        XCTAssertEqual(AppTab.allCases, [.coordinator, .missions, .decisions, .conversations])
    }

    /// Both routes ride the one `PathPrefixedRoute` round-trip, and their
    /// prefixes are disjoint — which is what lets a single `[String]` stack
    /// carry conversations, items and missions and decode them by trying
    /// each route in turn.
    func testPathPrefixedRoutesRoundTripAndRejectEachOther() {
        XCTAssertEqual(MissionRoute(id: "ms_1").pathValue, "mission/ms_1")
        XCTAssertEqual(MissionRoute(pathValue: "mission/ms_1"), MissionRoute(id: "ms_1"))
        XCTAssertEqual(ItemRoute(id: "it_1").pathValue, "item/it_1")
        XCTAssertEqual(ItemRoute(pathValue: "item/it_1"), ItemRoute(id: "it_1"))

        XCTAssertNil(MissionRoute(pathValue: "ms_1"), "a bare conversation id is not a mission route")
        XCTAssertNil(ItemRoute(pathValue: "cv_1"), "nor an item route")
        XCTAssertNil(MissionRoute(pathValue: "mission/"), "an empty id is not a route")
        XCTAssertNil(ItemRoute(pathValue: "item/"))
        XCTAssertNil(MissionRoute(pathValue: "item/it_1"), "an item route is not a mission route")
        XCTAssertNil(ItemRoute(pathValue: "mission/ms_1"), "and a mission route is not an item route")
    }

    func testOpenMissionSelectsTheTabAndReplacesItsPath() {
        let nav = AppShellNavigation()
        nav.missionsPath = ["mission/ms_old", "item/it_1"]
        nav.openMission("ms_1")
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1"])
    }

    func testPushMissionAppendsWithoutChangingTheTab() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.openMission("ms_1")
        nav.pushMission("ms_2")
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1", "mission/ms_2"])
    }

    /// A milestone tap hands off to Conversations and pushes, exactly as a
    /// Decisions origin link does — so Back returns to the mission page.
    func testOpenConversationFromMissionsSwitchesTabThenPushes() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.openConversation(fromMissions: "c1")
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1"])
        // Idempotent on the same target.
        nav.openConversation(fromMissions: "c1")
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    /// The coordinator conversation always goes to its own tab, whoever
    /// asked — otherwise two `ChatView`s share one cached view model.
    func testOpenConversationFromMissionsRoutesTheCoordinatorToItsTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "c-coord"
        nav.openConversation(fromMissions: "c-coord")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
        XCTAssertEqual(nav.chatPath, [])
    }

    func testSwipeAtRootWalksTheNewBarOrder() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.swipeRoot(translation: .init(width: -120, height: 5)))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertTrue(nav.swipeRoot(translation: .init(width: 120, height: 5)))
        XCTAssertEqual(nav.tab, .missions)
    }

    func testIsAtRootCoversTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        XCTAssertTrue(nav.isAtRoot)
        nav.pushMission("ms_1")
        XCTAssertFalse(nav.isAtRoot)
    }
}
```

Update the existing swipe expectations in `MatronTests/AppShellNavigationTests.swift` to the new `allCases` order (Coordinator · Missions · Decisions · Conversations) — a swipe left from `.coordinator` now lands on `.missions`, and a swipe left from `.decisions` lands on `.conversations`.

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/MissionsNavigationTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL to compile — `cannot find 'MissionRoute' in scope`.

- [ ] **Step 3: Add the shared route protocol, then `MissionRoute`**

`MissionRoute` is `ItemRoute` with a different prefix — same id, same
round-trip, same empty-id guard. Rather than copy the type, hoist the
shared shape into a protocol and let both adopt it.

Create `Matron/App/PathPrefixedRoute.swift`:

```swift
import Foundation

/// A typed destination that rides a `[String]` navigation stack as
/// `"<prefix><id>"`. The chat stacks stay `[String]` (the sub-chat
/// switcher and `pushSpawnedRoom` rely on array semantics
/// `NavigationPath` doesn't offer), so anything that is not a
/// conversation has to encode itself into a string and decode back out.
/// One protocol means the two routes cannot drift on the prefix
/// round-trip or the empty-id guard.
///
/// Prefixes must be unique across conforming types: a decoder tries each
/// route in turn (`if let mission = MissionRoute(pathValue: v) … else if
/// let item = ItemRoute(pathValue: v)`), and a bare conversation id —
/// which never carries a prefix — falls through both.
protocol PathPrefixedRoute: Hashable {
    /// `"item/"`, `"mission/"`. Unique per conforming type.
    static var pathPrefix: String { get }
    var id: String { get }
    init(id: String)
}

extension PathPrefixedRoute {
    /// This route as a stack entry.
    var pathValue: String { Self.pathPrefix + id }

    /// Decodes a stack entry, or `nil` when it is not this route's: no
    /// prefix (a conversation id), another route's prefix, or an empty id.
    init?(pathValue: String) {
        guard pathValue.hasPrefix(Self.pathPrefix) else { return nil }
        let id = String(pathValue.dropFirst(Self.pathPrefix.count))
        guard !id.isEmpty else { return nil }
        self.init(id: id)
    }
}
```

Create `Matron/App/MissionRoute.swift`:

```swift
import Foundation

/// A mission page pushed onto a `[String]` navigation stack — the Missions
/// tab's own stack, or whichever chat stack a milestone card was tapped on.
struct MissionRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "mission/"

    init(id: String) { self.id = id }
}
```

And reduce `Matron/App/ItemRoute.swift` to the same shape — its public
surface (`ItemRoute(id:)`, `ItemRoute(pathValue:)`, `pathValue`,
`Hashable`, and the `[ItemRoute]` Decisions stack) is unchanged, so no
call site moves:

```swift
import Foundation

/// A tracker item pushed onto a navigation stack (app shell, spec §3/§4).
/// The Decisions tab's stack is `[ItemRoute]`; the chat stacks stay
/// `[String]`, so on those an item rides as `pathValue` and the `String`
/// destination decodes it with `init?(pathValue:)` — both defaulted by
/// `PathPrefixedRoute`. Conversation ids never carry the prefix.
struct ItemRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "item/"

    init(id: String) { self.id = id }
}
```

- [ ] **Step 4: Extend `AppShellNavigation`**

In `Matron/App/AppShellNavigation.swift`:

```swift
enum AppTab: Hashable, CaseIterable {
    case coordinator
    case missions
    case decisions
    case conversations
}
```

Add the stack and its operations:

```swift
    /// Missions tab stack: `MissionRoute.pathValue` entries, plus
    /// `ItemRoute.pathValue` for an item opened from a mission page.
    var missionsPath: [String] = []

    /// Open a mission from anywhere: select the tab and REPLACE the stack,
    /// so the page is never stacked on a stale copy of itself.
    func openMission(_ missionID: String) {
        tab = .missions
        let route = MissionRoute(id: missionID).pathValue
        if missionsPath != [route] { missionsPath = [route] }
    }

    /// Push a mission onto the Missions stack without changing the tab —
    /// e.g. a `#N` that resolves to another mission from a mission page.
    func pushMission(_ missionID: String) {
        missionsPath.append(MissionRoute(id: missionID).pathValue)
    }

    func pushMissionItem(_ itemID: String) {
        missionsPath.append(ItemRoute(id: itemID).pathValue)
    }

    /// "Open the conversation" from a Missions row or a milestone: switch to
    /// Conversations first, then push, in that order and in one transaction
    /// so the push lands in the visible stack.
    func openConversation(fromMissions convoID: String) { handOffToConversations(convoID) }

    /// Shared body of `openConversation(fromDecisions:)` and
    /// `openConversation(fromMissions:)` — one rule, so the two entry points
    /// cannot drift on the coordinator special case.
    private func handOffToConversations(_ convoID: String) {
        if convoID == coordinatorConvoID {
            tab = .coordinator
            coordinatorPath = []
            return
        }
        tab = .conversations
        if chatPath.last != convoID { chatPath.append(convoID) }
    }
```

Rewrite `openConversation(fromDecisions:)`'s body to `handOffToConversations(convoID)`, and extend `push(_:on:)` and `isAtRoot` with the `.missions` case (`missionsPath.append(value)` / `missionsPath.isEmpty`).

- [ ] **Step 5: Build the iOS hosts**

Create `Matron/Features/Missions/MissionsTabRoot.swift`:

```swift
import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// The Missions tab's root list. The view model is owned by `AppShellView`
/// (its badge is read while another tab shows), so this view only maps it
/// into the leaf view's `Model` and reports selections.
struct MissionsTabRoot: View {
    let viewModel: MissionsListViewModel
    let onSelect: (String) -> Void

    var body: some View {
        MissionsListView(
            model: .init(open: viewModel.open, closed: viewModel.closed,
                         isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
            onSelect: onSelect,
            onRefresh: { await viewModel.refresh() })
        .navigationTitle("Missions")
        .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}
```

Create `Matron/Features/Missions/MissionDetailHost.swift`:

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One mission page on iOS. Owns its `MissionDetailViewModel` for the life
/// of the pushed screen and maps it into `MissionDetailView.Model`.
struct MissionDetailHost: View {
    let missionID: String
    let session: UserSession
    /// Opens a milestone's conversation at its anchor seq.
    let onOpenMilestone: (String, Int64) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                MissionDetailView(
                    // The mapping itself lives on the model (Task 7) — the
                    // Mac page calls the same init, so the two platforms'
                    // pages cannot drift.
                    model: .init(mission: viewModel.mission, milestones: viewModel.milestones,
                                 sessionTags: viewModel.sessionTags,
                                 openItems: viewModel.openItems, conversations: viewModel.conversations,
                                 showOnlyUserInput: viewModel.showOnlyUserInput,
                                 closeSummary: viewModel.closeSummaryDraft, isBusy: viewModel.isBusy),
                    onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
                    onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                    onOpenItem: onOpenItem,
                    onOpenConversation: onOpenConversation,
                    onEditCloseSummary: { viewModel.closeSummaryDraft = $0 },
                    onClose: { Task { await viewModel.close() } })
                .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                        set: { if !$0 { viewModel.error = nil } })) {
                    Button("OK") { viewModel.error = nil }
                } message: {
                    Text(viewModel.error ?? "")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel?.mission.map { "#\($0.num)" } ?? "Mission")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: missionID) {
            guard let deps else { return }
            viewModel?.stop()
            let vm = deps.makeMissionDetailViewModel(for: session, missionID: missionID)
            viewModel = vm
            vm.start()
        }
        .onDisappear { viewModel?.stop() }
    }
}
```

- [ ] **Step 6: Mount the tab in `AppShellView`**

In `Matron/App/AppShellView.swift`: add `@State private var missionsVM: MissionsListViewModel` (initialised in `init` with `deps.makeMissionsListViewModel(for: session)`), start it in a `.task { missionsVM.start() }` and stop it in `.onDisappear { missionsVM.stop() }` beside `decisionsVM`.

Insert the tab between Coordinator and Decisions in the `TabView`, hidden entirely when the journal has no missions routes:

```swift
            if missionsVM.isSupported {
                missionsTab
                    .tabItem { Label("Missions", systemImage: "flag.checkered") }
                    .badge(missionsVM.needsYouTotal)
                    .tag(AppTab.missions)
            }
```

and add the tab body plus the milestone hand-off:

```swift
    private var missionsPath: Binding<[String]> {
        Binding(get: { nav.missionsPath }, set: { nav.missionsPath = $0 })
    }

    private var missionsTab: some View {
        NavigationStack(path: missionsPath) {
            MissionsTabRoot(viewModel: missionsVM, onSelect: { nav.pushMission($0) })
                .simultaneousGesture(rootSwipe)
                .navigationDestination(for: String.self) { value in
                    if let mission = MissionRoute(pathValue: value) {
                        MissionDetailHost(missionID: mission.id, session: session,
                                          onOpenMilestone: openMilestone,
                                          onOpenItem: { nav.pushMissionItem($0) },
                                          onOpenConversation: { nav.openConversation(fromMissions: $0) })
                    } else if let item = ItemRoute(pathValue: value) {
                        ItemDetailHost(itemID: item.id, session: session, currentConvoID: nil,
                                       onOpenConversation: { nav.openConversation(fromMissions: $0) },
                                       onOpenItem: { nav.pushMissionItem($0) })
                    }
                }
        }
        .environment(\.chatNavigationPath, missionsPath)
    }

    /// A milestone tap: open its conversation, then park the jump on that
    /// room's cached `ChatViewModel`. Parking (rather than passing a seq
    /// through the route) is what makes the tap work before the room's
    /// stream is up — `focusOrPark` fires it on the first snapshot, and a
    /// seq that no longer exists lands on the nearest earlier row.
    private func openMilestone(convoID: String, seq: Int64) {
        nav.openConversation(fromMissions: convoID)
        let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
        Task { await chat.jumpToMilestone(seq: seq) }
    }
```

- [ ] **Step 7: Title tap → mission; delete the summaries sheet**

In `Matron/Features/Chat/ChatView.swift`:

- Add `@State private var missionID: String?` and fill it from the store:

```swift
        // Which mission this conversation belongs to (spec: Transcript and
        // title). Derived locally from the mission cache — the snapshot
        // never carries it — so it is nil until the first missions refresh,
        // which is exactly when the affordance should appear.
        .task(id: viewModel.roomID) {
            guard let deps, let session else { return }
            for await id in deps.journalStore(for: session).missionIDStream(convoID: viewModel.roomID) {
                missionID = id
            }
        }
```

- Replace the principal toolbar item's `Button { showSummaries = true }` with a mission-aware title: when `missionID != nil` the title is a `Button { openMission(id) }` with `.accessibilityHint("Opens this conversation's mission")`; when it is `nil` the same `VStack` renders as plain, non-tappable content (spec: "With no mission the title is not a button"). Keep the `chatContextLine` subtitle in both branches.
- Delete `@State private var showSummaries = false` and the `.sheet(isPresented: $showSummaries) { SummariesSheet(viewModel: viewModel) }` modifier.
- Add the push helpers beside `openItem` / `pushItem`:

```swift
    private func openMission(_ missionID: String) {
        Self.pushMission(missionID, onto: navigationPath)
    }

    /// Static twin of `pushItem` — a mission rides the same `[String]`
    /// stack the chat itself is mounted on.
    static func pushMission(_ missionID: String, onto path: Binding<[String]>?) {
        path?.wrappedValue.append(MissionRoute(id: missionID).pathValue)
    }
```

- Pass `onOpenMission: openMission` into `TimelineListContent` (the parameter added in Task 8).

In `Matron/Features/ChatList/ChatListView.swift`, extend the `[String]` `navigationDestination` so a `MissionRoute` on a chat stack resolves to `MissionDetailHost` — the same `if let … else if let …` shape the item route already uses, with `onOpenMilestone` calling `chatNavigationPath?.wrappedValue.append(convoID)` and then the cached view model's `jumpToMilestone(seq:)` via `vmCache`.

Then delete the retired files:

```bash
git rm Matron/Features/Chat/SummariesSheet.swift MatronTests/SummariesSheetBindingTests.swift
```

`ChatViewModel.summaryEntries` and `TimelineService.summaryEntriesStream()` stay — the Mac panel still reads them until Task 10, and the `summary_entry` mirror is explicitly retained by the spec.

- [ ] **Step 8: Run the iOS suite to verify it passes**

Run (no `| tail` — a pipeline replaces `xcodebuild`'s exit code with the pipe's, per Global Constraints):

```bash
xcodegen generate
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO > /tmp/missions-ios-suite.log 2>&1; echo "exit=$?"
grep -E "Executed [0-9]+ tests" /tmp/missions-ios-suite.log
```

Expected: `exit=0`, and the grep prints `Executed N tests, with 0 failures` (N covers `MatronTests` including the new `MissionsNavigationTests`). Anything else — a non-zero `exit=`, no matching line at all, or a non-zero failure count — is a failure, however quiet the log looks.

- [ ] **Step 9: Commit**

```bash
git add Matron/App/PathPrefixedRoute.swift Matron/App/MissionRoute.swift Matron/App/ItemRoute.swift \
        Matron/App/AppShellNavigation.swift Matron/App/AppShellView.swift \
        Matron/Features/Missions Matron/Features/Chat/ChatView.swift Matron/Features/ChatList/ChatListView.swift \
        MatronTests/MissionsNavigationTests.swift MatronTests/AppShellNavigationTests.swift \
        Matron/Features/Chat/SummariesSheet.swift MatronTests/SummariesSheetBindingTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: iOS Missions tab, mission page and title tap; retire the summaries sheet" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(`git add` on the deleted paths stages the deletions. `project.yml` is deliberately absent: `xcodegen generate` reads it and never writes it, so this task cannot have changed it — staging it would only sweep in unrelated working-tree edits. **Do not stage `Matron/App/Info.plist`.**)

---

### Task 10: Mac — the Missions nav entry, column, page, title tap, and retiring the summaries panel

**Files:**
- Create: `MatronMac/Features/Missions/MacMissionsColumn.swift`, `MatronMac/Features/Missions/MacMissionPage.swift`
- Modify: `MatronMac/Features/Nav/MacNavColumn.swift`, `MatronMac/Features/ChatList/MacChatListView.swift`, `MatronMac/Features/Chat/MacChatToolbar.swift`, `MatronMac/Features/Chat/MacChatView.swift`
- Delete: `MatronMac/Features/Chat/MacSummariesPanel.swift`, `MatronMacTests/MacSummariesPanelSnapshotTests.swift`, `MatronMacTests/__Snapshots__/MacSummariesPanelSnapshotTests/`
- Test: `MatronMacTests/MacMissionsNavTests.swift` (new), `MatronMacTests/MacNavColumnSnapshotTests.swift` (call sites + re-recorded baselines under `MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/`), `MatronMacTests/MacChatToolbarTests.swift`. `MatronMacTests/MacSidebarWidthTests.swift` needs no edit: it only reads `MacNavColumn.width` and `MacChatListView.sidebarWidths(for:)`, and never constructs a `MacNavColumn`.

**Interfaces:**
- Consumes: Tasks 6–8.
- Produces: `MacNav.missions`; `MacNavColumn(selection:badges:missionsSupported:)` (replacing `decisionsCount:`, with `missionsSupported` defaulted `true`) plus its statics `badgeCount(_:for:)` and `entries(missionsSupported:)`; on `MacChatListView`: `missionsColumn`, `missionDetail`, `showMission(_:from:)`, `@State selectedMissionID`, `@State missionBackConvoID`; on `MacChatToolbar`: `missionID` and `onOpenMission` (replacing `showSummaries:` and `popoverContent:`) and the pure `static titleOpensMission(missionID:) -> Bool` its body uses to decide button-vs-plain-text.

**Type-checker budget.** `MacChatListView.body` must not gain inline branches — every new switch site goes in the existing hoisted helpers `sidebarStack`, `sidebarWidths(for:)`, `detailContent` and `navChanged(from:to:)`. CI's Xcode has timed out on `body` twice already.

- [ ] **Step 1: Write the failing test**

Create `MatronMacTests/MacMissionsNavTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import MatronMac

@MainActor
final class MacMissionsNavTests: XCTestCase {
    func testNavOrderIsCoordinatorMissionsDecisionsConversations() {
        XCTAssertEqual(MacNav.allCases, [.coordinator, .missions, .decisions, .conversations])
        XCTAssertEqual(MacNav.missions.title, "Missions")
        XCTAssertEqual(MacNav.missions.symbol, "flag.checkered")
    }

    /// The sidebar keeps the list width for Missions — only Coordinator
    /// collapses to the bare nav column.
    func testSidebarWidthForMissionsMatchesTheOtherLists() {
        let missions = MacChatListView.sidebarWidths(for: .missions)
        let decisions = MacChatListView.sidebarWidths(for: .decisions)
        XCTAssertEqual(missions.min, decisions.min)
        XCTAssertEqual(missions.ideal, decisions.ideal)
        XCTAssertEqual(missions.max, decisions.max)
        let coordinator = MacChatListView.sidebarWidths(for: .coordinator)
        XCTAssertEqual(coordinator.min, MacNavColumn.width)
    }

    /// The badge map generalises the old `decisionsCount`: two entries can
    /// carry a count at once, and zero hides.
    func testNavColumnBadgeMapCoversBothEntries() {
        let badges: [MacNav: Int] = [.decisions: 3, .missions: 1, .conversations: 0]
        XCTAssertEqual(MacNavColumn.badgeCount(badges, for: .decisions), 3)
        XCTAssertEqual(MacNavColumn.badgeCount(badges, for: .missions), 1)
        XCTAssertNil(MacNavColumn.badgeCount(badges, for: .conversations), "zero hides the badge")
        XCTAssertNil(MacNavColumn.badgeCount(badges, for: .coordinator))
    }

    func testNavColumnSnapshotEntriesRespectTheSupportedFilter() {
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: true), MacNav.allCases)
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: false),
                       [.coordinator, .decisions, .conversations],
                       "an old journal hides the Missions entry entirely")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:

```bash
xcodegen generate
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests/MacMissionsNavTests \
  CODE_SIGNING_ALLOWED=NO > /tmp/missions-mac-navtests.log 2>&1; echo "exit=$?"
grep -E "Executed [0-9]+ tests" /tmp/missions-mac-navtests.log
```

Expected: `exit=65` and no `Executed` line — the bundle does not compile yet (`type 'MacNav' has no member 'missions'`, findable with `grep -n "has no member" /tmp/missions-mac-navtests.log`).

- [ ] **Step 3: Extend `MacNavColumn`**

In `MatronMac/Features/Nav/MacNavColumn.swift`:

```swift
enum MacNav: Hashable, CaseIterable {
    case coordinator
    case missions
    case decisions
    case conversations

    var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .missions: return "Missions"
        case .decisions: return "Decisions"
        case .conversations: return "Conversations"
        }
    }

    var symbol: String {
        switch self {
        case .coordinator: return "person.crop.circle.badge.checkmark"
        case .missions: return "flag.checkered"
        case .decisions: return "checkmark.circle"
        case .conversations: return "bubble.left.and.bubble.right"
        }
    }
}
```

Replace `let decisionsCount: Int` with `let badges: [MacNav: Int]` and `let missionsSupported: Bool` (defaulted `true`), and add the two static helpers the test pins:

```swift
    /// The count to draw on an entry, or `nil` when there is nothing to
    /// show. Zero hides, as `UnreadBadge`/`NeedsYouBadge` do.
    static func badgeCount(_ badges: [MacNav: Int], for entry: MacNav) -> Int? {
        guard let n = badges[entry], n > 0 else { return nil }
        return n
    }

    /// The entries to draw. An old journal with no `/missions` routes hides
    /// the Missions entry entirely, matching the iOS tab.
    static func entries(missionsSupported: Bool) -> [MacNav] {
        missionsSupported ? MacNav.allCases : MacNav.allCases.filter { $0 != .missions }
    }
```

and drive the `ForEach` from `Self.entries(missionsSupported: missionsSupported)`, the overlay from `Self.badgeCount(badges, for: entry)`, and the accessibility label from the same count — one phrasing for every entry, appended to the entry title: `", \(n) need you"`.

- [ ] **Step 4: Build the Mac hosts**

Create `MatronMac/Features/Missions/MacMissionsColumn.swift`:

```swift
import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// The Missions list in the Mac sidebar column. A thin mapper, like
/// `MacChatListView.decisionsColumn` — the view model lives for the session
/// on the host so the nav badge stays live while another entry shows.
struct MacMissionsColumn: View {
    let viewModel: MissionsListViewModel
    let onSelect: (String) -> Void

    var body: some View {
        MissionsListView(
            model: .init(open: viewModel.open, closed: viewModel.closed,
                         isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
            onSelect: onSelect,
            onRefresh: { await viewModel.refresh() })
        .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}
```

Create `MatronMac/Features/Missions/MacMissionPage.swift`:

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One mission page in the Mac detail column. `backConvoID` is set when the
/// page was reached from a conversation's title, so the reader has a way
/// back to where they were (spec: "the detail column switches to it with a
/// back affordance").
struct MacMissionPage: View {
    let missionID: String
    let session: UserSession
    let backConvoID: String?
    let onBack: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if let backConvoID {
                HStack {
                    Button { onBack(backConvoID) } label: { Label("Back to the conversation", systemImage: "chevron.backward") }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
            if let viewModel {
                MissionDetailView(
                    // Same `Model` init the iOS host calls (Task 7) — the
                    // mapping exists once, so the pages cannot drift.
                    model: .init(mission: viewModel.mission, milestones: viewModel.milestones,
                                 sessionTags: viewModel.sessionTags,
                                 openItems: viewModel.openItems, conversations: viewModel.conversations,
                                 showOnlyUserInput: viewModel.showOnlyUserInput,
                                 closeSummary: viewModel.closeSummaryDraft, isBusy: viewModel.isBusy),
                    onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
                    onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                    onOpenItem: onOpenItem,
                    onOpenConversation: onOpenConversation,
                    onEditCloseSummary: { viewModel.closeSummaryDraft = $0 },
                    onClose: { Task { await viewModel.close() } })
                .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                        set: { if !$0 { viewModel.error = nil } })) {
                    Button("OK") { viewModel.error = nil }
                } message: {
                    Text(viewModel.error ?? "")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: missionID) {
            guard let deps else { return }
            viewModel?.stop()
            let vm = deps.makeMissionDetailViewModel(for: session, missionID: missionID)
            viewModel = vm
            vm.start()
        }
        .onDisappear { viewModel?.stop() }
    }
}
```

- [ ] **Step 5: Wire the host, through the hoisted helpers only**

In `MatronMac/Features/ChatList/MacChatListView.swift`:

Add state beside the decisions state:

```swift
    @State private var missionsVM: MissionsListViewModel?
    @State private var selectedMissionID: String?
    /// Set when a mission page was opened from a conversation title, so the
    /// page can offer a way back to it.
    @State private var missionBackConvoID: String?
```

`sidebarStack`: pass the badge map and support flag to `MacNavColumn`, and add the case:

```swift
            MacNavColumn(selection: $nav,
                         badges: [.decisions: decisionsVM?.awaitingYouCount ?? 0,
                                  .missions: missionsVM?.needsYouTotal ?? 0],
                         missionsSupported: missionsVM?.isSupported ?? true)
            ...
            case .missions:
                missionsColumn
```

`detailContent`: add `case .missions: missionDetail`.

`sidebarWidths(for:)` needs no change — only `.coordinator` is special-cased, so `.missions` already gets the list widths.

`navChanged(from:to:)`: clear the back affordance on the way out, so a later visit from the nav column does not offer a stale "back to the conversation":

```swift
        if old == .missions, new != .missions { missionBackConvoID = nil }
```

Add the two column bodies and the two navigation helpers (all outside `body`):

```swift
    @ViewBuilder
    private var missionsColumn: some View {
        if let missionsVM {
            MacMissionsColumn(viewModel: missionsVM, onSelect: { selectedMissionID = $0 })
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var missionDetail: some View {
        if let id = selectedMissionID, let session {
            MacMissionPage(missionID: id, session: session, backConvoID: missionBackConvoID,
                           onBack: showConversation,
                           onOpenMilestone: openMilestone,
                           onOpenItem: { id in
                               // Missions has no stack of its own on the
                               // Mac; an item opens where every item opens.
                               nav = .decisions
                               decisionsPaneState.cancelRecordingIfNavigating(to: id)
                               selectedDecisionID = id
                           },
                           onOpenConversation: showConversation)
        } else {
            ContentUnavailableView("Select a mission", systemImage: "flag.checkered",
                                   description: Text("Pick a piece of work from the list."))
        }
    }

    /// The mission page for `missionID`, remembering the conversation it was
    /// opened from so the page can offer a way back.
    private func showMission(_ missionID: String, from convoID: String?) {
        missionBackConvoID = convoID
        selectedMissionID = missionID
        nav = .missions
    }

    /// A milestone tap: show its conversation, then park the jump on that
    /// room's cached view model — `focusOrPark` fires it once the stream is
    /// live, and a seq that no longer exists lands on the nearest earlier row.
    private func openMilestone(convoID: String, seq: Int64) {
        showConversation(convoID)
        guard let deps, let session else { return }
        let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
        Task { await chat.jumpToMilestone(seq: seq) }
    }
```

In `withLifecycle`, start and stop the list view model exactly as the decisions one is started and stopped:

```swift
            .task(id: session?.userID) {
                guard let deps, let session else { return }
                missionsVM?.stop()
                let vm = deps.makeMissionsListViewModel(for: session)
                missionsVM = vm
                vm.start()
            }
```

and add `missionsVM?.stop()` to the existing `.onDisappear` teardown.

In `chatDetail(for:)`, pass the two new callbacks to `MacChatView`: `onOpenMission: { showMission($0, from: id) }` (the transcript cards) and the title tap, which needs the conversation's mission — read it with a `.task(id:)` on `MacChatView` over `deps.journalStore(for: session).missionIDStream(convoID:)` into a `@State private var missionID: String?`, exactly as iOS does.

- [ ] **Step 6: Title tap on the Mac toolbar; delete the summaries panel**

In `MatronMac/Features/Chat/MacChatToolbar.swift`, replace `let showSummaries: Binding<Bool>` and `let popoverContent: () -> AnyView` — the summaries panel was the only thing that popover ever showed — with the mission the title now opens (drop both init parameters too; add these two, defaulted so the file's other tests keep compiling unchanged):

```swift
    /// The mission this conversation belongs to, or `nil` when it has none
    /// (or the host hasn't resolved one yet). The title is a button only
    /// when there is something to open — spec: "With no mission the title
    /// is not a button" — which is `Self.titleOpensMission(missionID:)`.
    let missionID: String?
    /// Opens `missionID`'s page. Inert by default so a toolbar built in a
    /// test or a preview has nowhere to navigate and doesn't need a host.
    let onOpenMission: (String) -> Void
```

Add the rule as a pure static, so it is testable without rendering a `ToolbarContent` (which has no init cheap enough to construct in a test — it needs a `SessionStatus`, a `SubChatStripViewModel` and three closures):

```swift
    /// Whether the title renders as a button. Only a real mission id counts:
    /// an empty string is treated as absent rather than producing a button
    /// that navigates nowhere.
    static func titleOpensMission(missionID: String?) -> Bool {
        guard let missionID else { return false }
        return !missionID.trimmingCharacters(in: .whitespaces).isEmpty
    }
```

Replace the `Button { showSummaries.wrappedValue = true } label: { titleCluster }` + `.popover(isPresented: showSummaries, …) { MacSummariesPanel… }` pair with:

```swift
                if Self.titleOpensMission(missionID: missionID), let missionID {
                    Button { onOpenMission(missionID) } label: { titleCluster }
                        .buttonStyle(.plain)
                        .help("Open this conversation's mission")
                        .accessibilityLabel(accessibilityTitle ?? title)
                        .accessibilityHint("Opens this conversation's mission")
                } else {
                    titleCluster
                        .accessibilityLabel(accessibilityTitle ?? title)
                }
```

In `MacChatView`, drop `@State private var showSummaries` and the `showSummaries:` / `popoverContent:` arguments, and pass `missionID: missionID` (the `@State` filled by the `missionIDStream` task added in step 5) and `onOpenMission: { onOpenMission?($0) }`.

Then delete the retired files:

```bash
git rm MatronMac/Features/Chat/MacSummariesPanel.swift MatronMacTests/MacSummariesPanelSnapshotTests.swift
git rm -r MatronMacTests/__Snapshots__/MacSummariesPanelSnapshotTests
```

Update `MatronMacTests/MacChatToolbarTests.swift`: replace `testToolbarCarriesSummariesBinding` (which pinned the summaries binding that no longer exists) with a test of the rule the body now branches on:

```swift
    /// The title renders as a button only when the conversation has a
    /// mission to open — the rule the principal toolbar item branches on.
    func testTitleOpensTheMissionOnlyWhenThereIsOne() {
        XCTAssertTrue(MacChatToolbar.titleOpensMission(missionID: "ms_1"))
        XCTAssertFalse(MacChatToolbar.titleOpensMission(missionID: nil),
                       "no mission, no button")
        XCTAssertFalse(MacChatToolbar.titleOpensMission(missionID: ""),
                       "an empty id would make a button that navigates nowhere")
    }
```

Update `MatronMacTests/MacNavColumnSnapshotTests.swift` for the new initializer — its two `MacNavColumn(...)` constructions (lines 11 and 18 today) become

```swift
        let view = MacNavColumn(selection: .constant(.decisions), badges: [.decisions: 4])
```

```swift
        let view = MacNavColumn(selection: .constant(.conversations), badges: [:])
```

(`missionsSupported` defaults to `true`, so both baselines show the new entry) — and its `testEntriesInBarOrder` expectation, which today reads `XCTAssertEqual(MacNav.allCases, [.coordinator, .conversations, .decisions])`, becomes the four-case bar order:

```swift
        XCTAssertEqual(MacNav.allCases, [.coordinator, .missions, .decisions, .conversations])
```

`MatronMacTests/MacSidebarWidthTests.swift` needs no change: it reads `MacNavColumn.width` and `MacChatListView.sidebarWidths(for:)` and never constructs the view.

- [ ] **Step 7: Re-record the Mac nav snapshots, then run the suite**

The nav column gains a fourth entry, so its two baselines no longer match and must be re-recorded. Delete them first — `assertVariants` only writes a baseline that is missing:

```bash
ls MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/    # 6 PNGs today (2 tests x light/dark/axxxl)
rm -f MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/*.png
```

Then record. Note both `MATRON_APP_SUPPORT_OVERRIDE` variables are set (Global Constraints) and the skip variable is deliberately NOT set — this is one of the two steps that record baselines:

```bash
xcodegen generate
MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests/MacNavColumnSnapshotTests \
  CODE_SIGNING_ALLOWED=NO > /tmp/missions-mac-navcolumn-record.log 2>&1; echo "exit=$?"
grep -E "Executed [0-9]+ tests" /tmp/missions-mac-navcolumn-record.log
ls MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/
```

Expected: `exit=65`, `Executed 3 tests, with 2 failures` (recording counts as a failure by design), and the 6 PNGs back on disk with the Missions entry in them.

Now verify, same command with a fresh log:

```bash
MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests/MacNavColumnSnapshotTests \
  CODE_SIGNING_ALLOWED=NO > /tmp/missions-mac-navcolumn-verify.log 2>&1; echo "exit=$?"
grep -E "Executed [0-9]+ tests" /tmp/missions-mac-navcolumn-verify.log
```

Expected: `exit=0` and `Executed 3 tests, with 0 failures`. Open one of the new PNGs and check the Missions flag actually rendered before moving on.

Then the whole Mac suite with snapshots skipped:

```bash
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 \
MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests \
  CODE_SIGNING_ALLOWED=NO > /tmp/missions-mac-suite.log 2>&1; echo "exit=$?"
grep -E "Executed [0-9]+ tests" /tmp/missions-mac-suite.log
```

Expected: `exit=0` and `Executed N tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add MatronMac/Features/Missions MatronMac/Features/Nav/MacNavColumn.swift \
        MatronMac/Features/ChatList/MacChatListView.swift MatronMac/Features/Chat/MacChatToolbar.swift \
        MatronMac/Features/Chat/MacChatView.swift MatronMac/Features/Chat/MacSummariesPanel.swift \
        MatronMacTests/MacMissionsNavTests.swift MatronMacTests/MacNavColumnSnapshotTests.swift \
        MatronMacTests/MacChatToolbarTests.swift \
        MatronMacTests/MacSummariesPanelSnapshotTests.swift MatronMacTests/__Snapshots__
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: Mac nav entry, missions column, mission page and title tap" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Decisions — the mission `#num` chip on item rows

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/Items/ItemRow.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/DecisionsListSnapshotTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift`

**Interfaces:**
- Consumes: `TrackerItem.missionNum` (Task 1).
- Produces: `ItemRow.missionChipText(for:) -> String?` — the one place the chip's copy lives.

Nothing else changes on the Decisions tab: the rows already come from `ItemsPanelViewModel.awaitingYou`, and `mission_num` rides the item row the journal already returns. `item_move` is agent-only, so there is no affordance to add.

- [ ] **Step 1: Write the failing test**

Append to `MatronShared/Tests/DesignSystemSnapshotTests/DecisionsListSnapshotTests.swift`:

```swift
    /// Numbers are one namespace across items, missions and milestones, so
    /// the chip is a bare `#N` with the mission glyph — never "Mission 61".
    func testMissionChipTextOnlyAppearsForAnAssignedItem() {
        let assigned = TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                   title: "Which order?", originConvoID: "c1", missionID: "ms_1", missionNum: 61)
        XCTAssertEqual(ItemRow.missionChipText(for: assigned), "#61")
        let unassigned = TrackerItem(id: "it_2", num: 65, kind: .task, title: "Unfiled", originConvoID: "c1")
        XCTAssertNil(ItemRow.missionChipText(for: unassigned))
    }

    func testDecisionsListWithAMissionChip() {
        let model = DecisionsListView.Model(rows: [
            .init(item: TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Which order for the tabs?", originConvoID: "c1",
                                    missionID: "ms_1", missionNum: 61),
                  originTitle: "dev-2 · Session"),
            .init(item: TrackerItem(id: "it_2", num: 65, kind: .decision, awaiting: .user,
                                    title: "Unfiled decision", originConvoID: "c2"),
                  originTitle: "dev-3 · Other"),
        ], isSupported: true, isRefreshing: false)
        assertVariants(of: DecisionsListView(model: model, onSelect: { _ in }, onOpenConversation: { _ in },
                                             onRefresh: {}).frame(width: 380, height: 260),
                       named: "decisions-mission-chip")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter DecisionsListSnapshotTests`
Expected: FAIL — `type 'ItemRow' has no member 'missionChipText'`.

- [ ] **Step 3: Add the chip**

In `MatronShared/Sources/DesignSystem/Items/ItemRow.swift`, add the static helper and render it in the metadata `HStack`, immediately after the origin label:

```swift
    /// `#61` when the item belongs to a mission, else `nil`. Static so the
    /// copy is testable without rendering — and deliberately bare: `#61` may
    /// name an item, a mission or a milestone, and prefixing it with a type
    /// word would be the only place in the app that pretends otherwise.
    ///
    /// An item can carry a `missionNum` for a mission this device cannot
    /// read (protocol, "Accepted exception — numbers, never words"), so the
    /// chip must never try to resolve a title.
    public static func missionChipText(for item: TrackerItem) -> String? {
        item.missionNum.map { "#\($0)" }
    }
```

```swift
                HStack(spacing: 8) {
                    if let origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if let chip = Self.missionChipText(for: item) {
                        Label(chip, systemImage: "flag.checkered")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Mission \(chip)")
                    }
                    if item.needsUser {
```

- [ ] **Step 4: Re-record the two affected baselines, then verify**

Run: `swift test --package-path MatronShared --filter "DecisionsListSnapshotTests|ItemsListSnapshotTests"`
Expected: FAIL on the first pass with rewritten/new `__Snapshots__` PNGs (the chip changes existing row baselines).

Run it again unchanged.
Expected: PASS — `Executed N tests, with 0 failures`.

Then: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — the whole package green.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Items/ItemRow.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/DecisionsListSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "missions: mission number chip on tracker item rows" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: End-to-end verification against a live journal and bridge

No code. Run this before opening the PR — the spec's *Testing* section calls for one real box before any fleet deploy.

- [ ] **Step 1: Full local suite**

```bash
MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared
xcodegen generate
xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 \
  MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO
```

Expected: three `Executed N tests, with 0 failures` lines.

- [ ] **Step 2: Live pass on one box**

With the journal and one bridge already deployed, in a real session:

1. `mission_start` → the Missions tab shows `#N` with its title; the mission page header shows the goal body.
2. `milestone_post` with `kind: "user_input"` and again with `kind: "progress"` → both render as inline cards in the transcript; the card's subtitle names the mission.
3. Tap a milestone card → the mission page opens.
4. From the Missions tab, tap that milestone row → the conversation opens **and lands on the marker**, including from cold (kill the app first, so the jump has to park until the first snapshot).
5. Tap the conversation title → the mission page opens. Open a conversation with no mission → the title is not a button.
6. File an item from that conversation → it appears under "Open items" on the mission page and its Decisions row shows the `#N` chip.
7. `mission_close` from the agent while that item is open → the bridge reports the block in the transcript; nothing on the mission page changes.
8. Close from the app with the item still open → the confirmation names the count, the mission flips to Closed, and its header shows "Closed over 1 open item".
9. Sign in on a second device against the same journal → the missions list matches.

- [ ] **Step 3: Old-journal check**

Point one app at a journal without the `/missions` routes (or stop the routes): the Missions tab is absent on iOS, the Missions entry is absent from the Mac nav column, and nothing else regresses.

- [ ] **Step 4: Install and hand over**

Build and install Release builds per the `technique_mac_install_verification` recipe (hash-verify the installed binary; `touch` the bundle after `ditto`). Then open the PR.

---

## Self-review

### 1. Spec coverage

| Spec requirement | Task |
|---|---|
| Store migration v10: `mission` + `milestone` tables, `mission_id` on `item` | 3 |
| `MissionRecord` / `MilestoneRecord`, `missions(state:)`, `mission(id:)`, `milestones(missionID:)`, `milestones(convoID:)`, `missionID(convoID:)`, `ValueObservation` streams | 3 |
| `MissionsSync` cloned from `ItemsSync` — full list on connect/reconnect, detail on demand and on a marker, marker as invalidation only | 5 |
| `ItemsSync` already refetches on an `item` marker and the refetched row carries `mission_id` | 1 (decode) + 3 (store column) — no `ItemsSync` change needed |
| `MissionsAPI` feature-detected like items (404 ⇒ unsupported ⇒ tab hidden) | 4, 5, 9, 10 |
| `MissionsListViewModel` (sections, sort, badge counts, `isSupported`) | 6 |
| `MissionDetailViewModel` (milestones newest first, `showOnlyUserInput`, awaiting-first items, conversations, `close(summary:)` with the "N items still open" confirmation) | 6 (+ store ordering in 3) |
| Navigation: a milestone tap from any tab opens the conversation and lands on the marker after the first snapshot | 8 (`jumpToMilestone`), 9 (iOS), 10 (Mac) |
| `AppTab.missions`, bar order Coordinator · Missions · Decisions · Conversations, own `missionsPath` | 9 |
| `MacNav.missions`; switch sites only in `sidebarStack` / `sidebarWidths(for:)` / `detailContent` / `navChanged(from:to:)` | 10 |
| List row: `#num`, title, last milestone + relative age, needs-you badge, closed section | 7 |
| Page: header, milestones with kind glyph + `SessionTag`, "My inputs only", open items, conversations, user close | 7 |
| Empty states; unsupported hides the tab | 7, 9, 10 |
| `TimelineItem` milestone card + `mission` one-line notice; tap → mission page | 8 |
| Title tap opens the mission; no mission ⇒ not a button; summaries UI deleted; `summary_entry` untouched | 9 (iOS), 10 (Mac) |
| Decisions rows gain the mission `#num` chip | 11 |
| Error handling: sync failure keeps the cache; a tap into an uncached conversation opens at the tail; a stale `focusSeq` lands on the nearest earlier row | 5 (test), 8 (`focus` fallback), 9/10 (navigation always succeeds) |
| Testing: v10 up from v9 with items; `MissionsSync` connect/marker/unsupported; list sort/sections/badges; detail filter and order; parked focus fires; snapshots skipped locally; Mac override env | 3, 5, 6, 7, 8, plus Global Constraints |
| push/unread untouched | Global Constraints + the `messageTypes` test in Task 2 |
| `item_move` display-only | Global Constraints; Task 11 adds no affordance |
| Rollout step 3 (a) migration+sync+API, (b) tab/list/page/navigation, (c) transcript card + title tap + retire summaries, (d) Decisions chip | Tasks 1–5, 6–7 + 9–10, 8 + 9/10, 11 |

**Number resolution (`#N` in bodies resolving against item, then mission, then milestone).** The spec lists this under *Shared core*. It is **deliberately out of scope for this plan** and is not a task: the shipped `matron://item/<n>` link scheme (item #115) is item-only end to end — `MatronItemLink.itemNumber(from:)`, `TrackerItemLinkResolver`, `TrackerItemLinkOutcome`, `\.openTrackerItem` and four host installs. Generalising it is its own change with its own review surface (a new URL host, a three-way resolver, and a per-host router), and it is not needed for anything else here: milestones are reached from the transcript and the mission page, missions from the tab and the title. File it as a follow-up item rather than bolting a second navigation scheme onto the end of this plan.

### 2. Placeholder scan

Checked for "TBD", "TODO", "implement later", "add appropriate error handling", "write tests for the above", "similar to Task N", and steps that describe without showing. None remain. Three places deliberately describe an edit rather than reprinting a large existing file — threading `onOpenMission` through `TimelineListContent` (Task 8), the `MacChatToolbar` principal item's title branch (Task 10), and the `MacNavColumn` `ForEach` body (Task 10). Each names the exact file, the exact symbol to copy from (`onOpenItem`, `showSummaries`, `decisionsCount`), and the exact replacement, so the engineer has a mechanical edit rather than a decision. Nothing in the plan asks a test to construct a `MacChatToolbar`: the two rules a test cares about are pure statics (`MacChatToolbar.titleOpensMission(missionID:)`, `MacNavColumn.badgeCount(_:for:)` / `entries(missionsSupported:)`).

### 3. Type consistency

Cross-checked every name used across task boundaries:

- `Mission`, `Milestone`, `MissionConversation`, `MissionLastMilestone`, `MissionState`, `MilestoneKind` — defined Task 1, used identically in 3, 4, 5, 6, 7.
- `Mission.conversationCount` / `milestoneCount` (not `conversations` / `milestones`, which are the *wire* keys) — consistent in Task 1's decoder, Task 3's `MissionRecord`, and Task 7's row.
- `MilestoneMarkerEvent.missionLabel` / `MissionMarkerEvent.missionLabel` — defined Task 2, used in Tasks 7 (`MilestoneCard.subtitle`, `MissionNotice.text`) and 8's tests.
- `MissionMarker` (the union) — Task 2, consumed by `JournalSyncEngine.missionMarkers()` and `MissionsSync`'s `markers` closure, both Task 5.
- `MissionsProviding` methods `listMissions(_:)`, `mission(id:)`, `milestones(convoID:)`, `closeMission(id:summary:)` — Task 4, faked with the same signatures in Task 5's `FakeMissions`.
- `MissionsSync` surface `refresh()`, `refreshMission(id:)`, `refreshMilestones(convoID:)`, `closeMission(id:summary:)`, `supportedStream()` — Task 5, restated exactly by `MissionsSyncing` in Task 6 (minus `refreshMilestones`, which no view model calls).
- `MissionsStoreReading`'s five stream methods — Task 6 — match the `JournalStore` methods added in Task 3 by name and signature (`missionsStream(state:)`, `missionStream(id:)`, `milestonesStream(missionID:)`, `itemsStream(missionID:)`, `missionConversationsStream(missionID:)`). Note `itemsStream(missionID:)` is an *overload* of the existing `itemsStream(scope:)`; both live in `JournalStore+Items.swift`.
- The protocol's sixth member, `sessionTag(convoID:) -> SessionTagInputs?` (Task 6), is the one requirement `JournalStore` does NOT already satisfy: its witness is written in the same `extension JournalStore: MissionsStoreReading` in `MissionsListViewModel.swift`, out of `conversation(id:)`, `agentNames()` and `agentTagChars()` — three shipped public reads. Faked in the tests by a `[String: SessionTagInputs]` dictionary.
- `SessionTagInputs` (`boxLetter`, `boxName`, `sessionShort`) — created in Task 6 in `MatronModels`, published by `MissionDetailViewModel.sessionTags` (Task 6), carried on `MissionDetailView.Model.MilestoneRow` (Task 7), and consumed by `SessionTagText.run(boxLetter:boxName:sessionShort:colorScheme:)` — the SHIPPED signature, an enum of `Text` factories, not a view and not a type with an initializer.
- `MissionsListView.Model` (`open`, `closed`, `isSupported`, `isRefreshing`) and `MissionDetailView.Model` (`mission`, `milestones: [MilestoneRow]`, `openItems`, `conversations`, `showOnlyUserInput`, `closeSummary`, `isBusy`) — Task 7 — match the property names the hosts read in Tasks 9 and 10 one for one. Both hosts build the detail model through the single mapping init `Model.init(mission:milestones:sessionTags:openItems:conversations:showOnlyUserInput:closeSummary:isBusy:)`, whose `milestones:` is the view model's plain `[Milestone]` and whose `sessionTags:` is its `[String: SessionTagInputs]`; the `[MilestoneRow]` memberwise init is used only by the Task 7 snapshot fixtures.
- `MissionDetailView`'s callback order (`onToggleUserInputOnly`, `onOpenMilestone`, `onOpenItem`, `onOpenConversation`, `onEditCloseSummary`, `onClose`) is identical in the Task 7 test, the Task 9 host and the Task 10 host.
- `ChatViewModel.jumpToMilestone(seq:)` — Task 8 — called in Tasks 9 and 10 with the same label.
- `TimelineItem.Kind.milestoneMarker` / `.missionMarker` — Task 8 — same spelling in the mapper, both renderers and both shell tests.
- `onOpenMission: ((String) -> Void)?` — one name on `TimelineItemView`, `MacTimelineItemView` and `MacChatView`. On `MacChatToolbar` the pair is `missionID: String?` + `onOpenMission: (String) -> Void` (non-optional, inert by default): the toolbar decides button-vs-text from `titleOpensMission(missionID:)` rather than from a nil closure, so the rule is a pure function a test can call. Called out at both definitions.
- `MissionRoute.pathPrefix = "mission/"` vs `ItemRoute.pathPrefix = "item/"` — both from the shared `PathPrefixedRoute` (Task 9), which owns `pathValue` and `init?(pathValue:)` once. Disjoint prefixes, so the Task 9 `navigationDestination` decoder is unambiguous and each route rejects the other's value (pinned in both directions by `testPathPrefixedRoutesRoundTripAndRejectEachOther`). `ItemRoute`'s public surface is unchanged, so `[ItemRoute]` decisions stacks and every existing call site compile untouched.
- `MacNavColumn.badgeCount(_:for:)` / `entries(missionsSupported:)` — Task 10 — used by the same file's `ForEach` and pinned by `MacMissionsNavTests`.

## Conflicts resolved (spec vs the journal's shipped contract)

The protocol wins wherever the two differ. Each difference, and what this plan does:

1. **Marker titles are optional.** The spec's marker examples show `title` on `mission` and `mission_title` on `milestone` unconditionally. The shipped protocol drops both at write time when the marker crosses the privacy boundary. → `MissionMarkerEvent.title` and `MilestoneMarkerEvent.missionTitle` are `String?`; every render site uses `missionLabel`, which falls back to `#N`; the store learns titles only from `GET /missions` / `GET /missions/:id`. Pinned by tests in Tasks 2, 7 and 8.

2. **`items.mission_id` can name a mission this caller cannot read.** The protocol's "Accepted exception — numbers, never words" allows `mission_id`/`mission_num` on a visible item whose mission is hidden. → `ItemRow.missionChipText` renders the bare number and never resolves a title; nothing in the app treats a local `mission` row as guaranteed to exist for an item's `missionID` (Task 11, documented at the helper).

3. **`conversations.mission_id` is not on the wire.** The spec's data model adds the column server-side, but `GET /snapshot` does not return it, so the apps have no column to mirror. → `JournalStore.missionID(convoID:)` derives it locally: origin conversation first, then any milestone posted in that conversation (which covers `join` and inheritance). Documented on the method and pinned in Task 3.

4. **`GET /missions` sorts by the *sieved* last milestone.** The spec says `last_milestone_at DESC NULLS LAST`; the protocol adds `created_at DESC` as the tiebreak and notes the timestamp is sieved per caller. → `MissionsListViewModel.sections(from:)` and the store's SQL both implement `last_milestone_at DESC NULLS LAST, created_at DESC` over whatever the server returned, so a cache assembled from several fetches keeps the server's order rather than inventing one.

5. **`focusOrPark` cannot become `focus(seq:parkIfNeeded:)`.** The spec asks for that rename, but `ChatViewModel` already has a public `focus(seq:)` with different semantics (run now, no parking) and a private `focusOrPark(seq:owner:)` whose `FocusOwner` decides what `endChatSearch()` may cancel. Renaming would either collide or lose the ownership rule. → a new public `jumpToMilestone(seq:)` plus a `FocusOwner.milestone` case, so a milestone jump survives a search-bar dismissal. Pinned in Task 8.

6. **No `focusSeq` on the shell routes.** The spec threads an optional `focusSeq:` through `AppShellNavigation.openChat(_:)` / `openConversation(fromDecisions:)`. That would add an optional to two call paths used by notification taps, search hits and the sub-chat switcher, and it duplicates a mechanism that already exists: `focusOrPark` parks a target until the room's first snapshot. → the hosts navigate as normal and then park the jump on the room's cached `ChatViewModel` (`vmCache.viewModels(for:deps:session:)`). Same observable behaviour, no new optional on shared routes. Tasks 9 and 10.

7. **The app never creates, joins or renames a mission.** The spec's app section only ever asks for a user *close*, and every other write is a bridge tool. → `MissionsProviding` carries reads plus `closeMission` only (Task 4), which also means there is no offline outbox to build: the one write is an interactive foreground action that reports its own failure.

8. **Tab order.** The spec's bar order (Coordinator · Missions · Decisions · Conversations) moves Conversations from second to last in `AppTab.allCases`, which is also the root swipe order. The spec is binding, so this plan adopts it and updates `AppShellNavigationTests`' swipe expectations in the same task (9) rather than silently keeping the old order.

9. **`#N` resolution across the three types is deferred.** See "Spec coverage" above: it is the one *Shared core* bullet with no task here, because generalising the `matron://item/<n>` scheme is a self-contained change with its own review surface and nothing in this plan depends on it.
