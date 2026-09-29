# Missions dashboard — Apple apps (iOS + Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static Missions list on iOS (Missions tab root) and Mac (Missions nav entry) with a live dashboard: one card per open mission carrying its written status, latest step, what needs the user and its sessions with a "what's happening now" line; a "Not on a mission" group of loose running sessions; a collapsed Closed section; and an "Ask the Coordinator to update" button.

**Architecture:** Phase A (shared layer, PR 1) adds the status fields to `Mission` and the GRDB cache (migration v13), `JournalAPI.roster()`, four aggregate store streams, `ChatSummary.sessionState`, an `ItemsSync` → `MissionsSync` hook so item changes refetch their mission, the pure `MissionsDashboardAssembly` + the session-long `MissionsDashboardViewModel`, and the DesignSystem leaf views with snapshots — nothing on screen changes yet. Phase B (hosts, PR 2) swaps both apps onto the dashboard (iOS tab root; Mac full-width detail with the sidebar collapsed to the nav column like the Coordinator page), adds navigation tests, and deletes `MissionsListViewModel` / `MissionsListView` / `MacMissionsColumn`.

**Tech Stack:** Swift 5.10 language mode, SwiftUI (iOS 17+/macOS 14+), GRDB 6 (`JournalStore`), XCTest, swift-snapshot-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-28-missions-dashboard-design.md` (apps = §3, plus the `Mission` status fields of §1). Journal (§1) and bridge (§2) are planned separately; an app against an old journal simply shows no status lines.

## Global Constraints

- Mission status wire fields (spec §1, verbatim): `status` (markdown, ≤600 chars), `status_by` (`'user'` | `'agent'`), `status_convo_id`, `status_updated_at` (ms epoch); all null when unset. Decoded leniently: absent, null or malformed → `nil`, never a dropped row.
- The Coordinator refresh message is EXACTLY: `Refresh the status of every open mission from its latest milestones, sessions and open items.` — sent to the Coordinator conversation through the normal send path (`JournalSyncEngine.sendMessage`, the offline outbox).
- Session summary text (spec §3.5): roster `summary` if non-empty → newest `SummaryEntryRecord.toc` → chat snippet → nothing.
- Card copy (spec §3.2): `#num` · title (2 lines) · red pill `Needs you · n`; status up to 4 lines then `Updated 12m ago by an agent` / `by you`; latest step or `No milestones yet`; up to 3 needs-you rows then `+n more`; up to 4 sessions then `+n more sessions`. No placeholder when the status is unset.
- Ordering (spec §3.6): cards grouped needs-you > 0, then any session running, then the rest; within a group newest activity first (max of last milestone, status time, sessions' last activity). Loose cards: running first, then last activity.
- Loose sessions (spec §3.3): top-level (no `parentConvoID`), not on any open mission, not the Coordinator, and `running`, or `waiting` with last activity in the last 24 h.
- Roster poll: on page appear, every 60 s while shown, and on refresh; cancelled on page disappear; a failed fetch keeps the last good map and shows no error.
- Detail refresh on page appear: every open mission, at most 4 requests in flight.
- Grid: adaptive columns, minimum 340 pt wide (one column on iPhone).
- Run `xcodegen generate` after adding, renaming or deleting any file or folder (snapshot PNGs are project members too), then `git checkout Matron/App/Info.plist` — xcodegen adds an unwanted audio entry to it.
- Shared tests: `cd MatronShared && swift test --filter <Target>.<Class>` (full suite: `swift test`). `swift test` can hang at 0% CPU — kill it and rerun. Snapshot PNGs are recorded by deleting the PNGs (none exist for new tests), regenerating with `xcodegen generate`, and running the test twice (the first run records and fails, the second passes); then `xcodegen generate` again so new PNGs are members. `MATRON_SKIP_SNAPSHOT_TESTS=1` skips snapshot assertions when a step only needs the logic tests.
- Mac tests ONLY via `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-support xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -only-testing:MatronMacTests test` (append `/<Class>` to `-only-testing:MatronMacTests` to narrow). The override must be a real environment variable before `xcodebuild`, never a trailing `KEY=value` argument — anything else can wipe the live journal store. Four Mac snapshot tests already fail locally on main and are NOT regressions: `MacNavColumn testBadge`, `MacNavColumn testNoBadge`, `MacItemsPane testPaneListPopulated`, `NewChatSheetCapacity testAgentPickerRowStates`.
- iOS tests on an iPhone 17 simulator: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/<Class> CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`. Assert the `Executed N tests, with 0 failures` line; never trust a grep/tail for "success" alone.
- Commits: `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "<subject>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Never `git config` anything (worktrees share `.git/config`).
- CI's Xcode 16.4 type-checker budget is tighter than local: keep SwiftUI bodies split into small computed views / `@ViewBuilder` helpers; never grow a long inline modifier chain on `MacChatListView` or `AppShellView`.
- iOS List/ScrollView `Button` labels inherit the accent tint — reset with `.foregroundStyle(Color.primary)`.
- Nothing under the Mac chat header accessory may add toolbar items; the sidebar toolbar must never be empty (use `MacCoordinatorToolbarPlaceholder` where the sidebar is the 72 pt nav column alone).

## Review Focus

- **A status written as `[blocked]: waiting on Dan`** — CommonMark reads `[label]: text` as a link reference definition and renders nothing; the card must still show the words. Pinned in Task 8 (`testStatusTextKeepsALabelColonLine`).
- **A mission session this device never synced** (a conversation on another user device's box, not in the chat list) — its row must still render from the mission detail's own title/box/state rather than vanish or show a bare id with a `[bc] ` prefix. Pinned in Task 6 (`testAnUncachedMissionSessionRendersFromTheDetailRow`).
- **`onAppear` firing twice** (SwiftUI does this on tab re-selection and on iOS pop-back) — must not start a second roster poll loop that doubles the request rate. Pinned in Task 7 (`testAppearingTwiceRunsOneRosterLoop`).
- **The server's `needs_you` count ahead of the local item cache** (items not yet refetched) — the pill must show the larger count and `+n more` must count the items not listed, not go negative or hide. Pinned in Task 6 (`testNeedsYouUsesTheLargerCountAndCapsRowsAtThree`).
- **No Coordinator set, or a whitespace-only cached id** — the Ask button must be hidden and `askCoordinator()` must send nothing. Pinned in Task 7 (`testAskIsHiddenAndInertWithoutACoordinator`).

---

## File map

| File | Phase | Responsibility |
|---|---|---|
| `MatronShared/Sources/Models/Mission.swift` | A | `status`, `statusBy`, `statusUpdatedAt`, lenient decode |
| `MatronShared/Sources/Journal/JournalStore.swift` | A | Migration v13 (three nullable `mission` columns) |
| `MatronShared/Sources/Journal/JournalStore+Missions.swift` | A | `MissionRecord` status columns; four dashboard reads + streams |
| `MatronShared/Sources/Journal/JournalAPI+Roster.swift` (new) | A | `roster() -> [convoID: summary]` |
| `MatronShared/Sources/Chat/ChatSummary.swift`, `Chat/JournalChatService.swift` | A | `ChatSummary.sessionState` |
| `MatronShared/Sources/Journal/ItemsSync.swift` | A | `setMissionRefetcher(_:)` — item refetch → mission refetch |
| `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift` | A, B | A: wire the refetcher. B: `makeMissionsDashboardViewModel` |
| `MatronShared/Sources/Models/MissionsDashboard.swift` (new) | A | Dashboard value types + `MissionsDashboardAction` |
| `MatronShared/Sources/ViewModels/MissionsDashboardAssembly.swift` (new) | A | Pure grouping / ordering / membership / summary chain |
| `MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift` (new) | A | Streams, roster poll, detail fan-out, Ask |
| `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardFormat.swift` (new) | A | Bylines, relative ages, status markdown |
| `MatronShared/Sources/DesignSystem/Missions/NeedsYouPill.swift` (new) | A | Red `Needs you · n` pill |
| `MatronShared/Sources/DesignSystem/Missions/DashboardSessionRow.swift` (new) | A | Session row + state dot |
| `MatronShared/Sources/DesignSystem/Missions/MissionCardView.swift` (new) | A | Mission card + card chrome |
| `MatronShared/Sources/DesignSystem/Missions/LooseSessionCardView.swift` (new) | A | Loose session card |
| `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardView.swift` (new) | A | The page: grid, loose, closed, empty/unsupported, Mac header, Ask button |
| `Matron/Features/Missions/MissionsTabRoot.swift` | B | iOS host |
| `Matron/App/AppShellView.swift`, `Matron/App/AppShellNavigation.swift` | B | iOS VM swap + `handleDashboard(_:)` |
| `MatronMac/Features/Missions/MacMissionsDashboard.swift` (new) | B | Mac host (replaces `MacMissionsColumn.swift`) |
| `MatronMac/Features/Missions/MacMissionPage.swift` | B | "All missions" way back |
| `MatronMac/Features/ChatList/MacChatListView.swift` | B | Collapsed sidebar, header chrome, detail swap |
| `MatronShared/Sources/ViewModels/MissionsStoreReading.swift` (new) | B | Protocols moved out of the deleted list VM |
| Deleted in B: `MissionsListViewModel.swift`, `MissionsListView.swift`, `MacMissionsColumn.swift` + their tests/PNGs | B | |

---

# Phase A — shared layer (PR 1)

Branch: `git switch -c feat/missions-dashboard-shared origin/main` in a fresh worktree (never branch-switch a tree someone else is using).

### Task 1: `Mission` status fields and migration v13

**Files:**
- Modify: `MatronShared/Sources/Models/Mission.swift` (struct `Mission`, both inits)
- Modify: `MatronShared/Sources/Journal/JournalStore+Missions.swift` (`MissionRecord`)
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (after the `v12` migration, ~line 604)
- Test: `MatronShared/Tests/JournalTests/MissionModelTests.swift`, `MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift`

**Interfaces:**
- Produces: `Mission.status: String?`, `Mission.statusBy: ItemAuthor?`, `Mission.statusUpdatedAt: Date?`; memberwise init gains trailing `status: String? = nil, statusBy: ItemAuthor? = nil, statusUpdatedAt: Date? = nil` (after `lastMilestone:`). `MissionRecord` gains `status: String?`, `statusBy: String?`, `statusUpdatedAt: Int64?` (columns `status`, `status_by`, `status_updated_at`).

- [ ] **Step 1: Write the failing model tests**

Append to `MissionModelTests`:

```swift
    /// Spec 2026-09-28 §1: every mission object carries the status fields.
    func testMissionDecodesStatusFields() throws {
        var json = Self.missionJSON
        json["status"] = "Journal half merged; bridge next."
        json["status_by"] = "agent"
        json["status_convo_id"] = "c2"
        json["status_updated_at"] = 1_700_000_006_000
        let m = try XCTUnwrap(Mission(json: json))
        XCTAssertEqual(m.status, "Journal half merged; bridge next.")
        XCTAssertEqual(m.statusBy, .agent)
        XCTAssertEqual(m.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_006))
    }

    /// An old journal sends none of them; a sieved one sends nulls; a
    /// future one might send a `status_by` this build doesn't know. None of
    /// those may drop the row.
    func testMissionToleratesAbsentOrMalformedStatus() throws {
        let bare = try XCTUnwrap(Mission(json: Self.missionJSON))
        XCTAssertNil(bare.status); XCTAssertNil(bare.statusBy); XCTAssertNil(bare.statusUpdatedAt)

        var odd = Self.missionJSON
        odd["status"] = NSNull(); odd["status_by"] = "robot"; odd["status_updated_at"] = "yesterday"
        let m = try XCTUnwrap(Mission(json: odd), "a malformed status must not drop the row")
        XCTAssertNil(m.status); XCTAssertNil(m.statusBy); XCTAssertNil(m.statusUpdatedAt)

        var empty = Self.missionJSON
        empty["status"] = ""
        XCTAssertNil(try XCTUnwrap(Mission(json: empty)).status, "an empty status reads as unset")
    }
```

- [ ] **Step 2: Write the failing store tests**

Append to `JournalStoreMissionsTests`:

```swift
    /// v13 is additive: a cache already at v12 keeps its rows and gains
    /// three NULL columns. No watermark to clear — the list refresh is a
    /// full `GET /missions` on every connect.
    func testV13AddsStatusColumnsToAnExistingMissionCache() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "v12")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
                VALUES('ms_1', 61, 'open', 'Existing', 'c1', 'agent', 1, 2)
                """)
        }
        try JournalStore.migrator().migrate(queue)
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT title, status, status_by, status_updated_at FROM mission WHERE id='ms_1'")
        }
        XCTAssertEqual(row?["title"], "Existing")
        XCTAssertNil(row?["status"] as String?)
        XCTAssertNil(row?["status_by"] as String?)
        XCTAssertNil(row?["status_updated_at"] as Int64?)
    }

    func testMissionStatusRoundTripsThroughTheCache() throws {
        let store = try makeStore()
        try store.upsertMissions([
            Mission(id: "ms_1", num: 61, title: "M61", originConvoID: "c1",
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                    status: "Blocked on **Dan**", statusBy: .agent, statusUpdatedAt: Date(timeIntervalSince1970: 5)),
            mission("ms_2", num: 62, convo: "c2"),
        ])
        let withStatus = try XCTUnwrap(store.mission(id: "ms_1"))
        XCTAssertEqual(withStatus.status, "Blocked on **Dan**")
        XCTAssertEqual(withStatus.statusBy, .agent)
        XCTAssertEqual(withStatus.statusUpdatedAt, Date(timeIntervalSince1970: 5))
        let without = try XCTUnwrap(store.mission(id: "ms_2"))
        XCTAssertNil(without.status); XCTAssertNil(without.statusBy); XCTAssertNil(without.statusUpdatedAt)
    }
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.(MissionModelTests|JournalStoreMissionsTests)'`
Expected: build FAILS — `extra arguments 'status', 'statusBy', 'statusUpdatedAt'` / `value of type 'Mission' has no member 'status'`.

- [ ] **Step 4: Implement the model fields**

In `Mission.swift`, add after `public let lastMilestone: MissionLastMilestone?`:

```swift
    /// The mission's written status (spec 2026-09-28 missions dashboard
    /// §1): one short markdown paragraph an agent keeps current, the
    /// headline on the mission's dashboard card. `nil` when unset, withheld
    /// by the privacy sieve, or the journal predates the field.
    public let status: String?
    /// Who wrote `status` — the writing device's kind. `nil` when unset or
    /// a value this build doesn't know.
    public let statusBy: ItemAuthor?
    public let statusUpdatedAt: Date?
```

Replace the memberwise init's signature tail and body tail:

```swift
                milestoneCount: Int = 0, lastMilestone: MissionLastMilestone? = nil,
                status: String? = nil, statusBy: ItemAuthor? = nil, statusUpdatedAt: Date? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body
        self.closeSummary = closeSummary; self.closedBy = closedBy; self.closedOverOpenItems = closedOverOpenItems
        self.originConvoID = originConvoID; self.originDeviceID = originDeviceID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastMilestoneAt = lastMilestoneAt
        self.closedAt = closedAt; self.openItems = openItems; self.needsYou = needsYou
        self.conversationCount = conversationCount; self.milestoneCount = milestoneCount
        self.lastMilestone = lastMilestone
        self.status = status; self.statusBy = statusBy; self.statusUpdatedAt = statusUpdatedAt
    }
```

In `init?(json:)`, replace the last argument line of the `self.init(...)` call:

```swift
            lastMilestone: (json["last_milestone"] as? [String: Any]).flatMap(MissionLastMilestone.init(json:)),
            // Lenient on purpose: a sieved (null), absent or unknown value
            // reads as "no status", never as a malformed row.
            status: (json["status"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            statusBy: (json["status_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
            statusUpdatedAt: msDate(json["status_updated_at"]))
```

(`msDate` already returns `nil` for anything that is not an `NSNumber`, so `"yesterday"` reads as `nil`.)

- [ ] **Step 5: Implement the record and the migration**

In `MissionRecord` (`JournalStore+Missions.swift`), extend the stored properties, `CodingKeys`, `init(_:)` and `mission`:

```swift
    public var milestoneCount: Int; public var lastMilestoneJson: String?
    public var status: String?; public var statusBy: String?; public var statusUpdatedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, num, state, title, body, status
        case closeSummary = "close_summary", closedBy = "closed_by", closedOverOpenItems = "closed_over_open_items"
        case originConvoId = "origin_convo_id", originDeviceId = "origin_device_id", createdBy = "created_by"
        case createdAt = "created_at", updatedAt = "updated_at", lastMilestoneAt = "last_milestone_at"
        case closedAt = "closed_at", openItems = "open_items", needsYou = "needs_you"
        case conversationCount = "conversation_count", milestoneCount = "milestone_count"
        case lastMilestoneJson = "last_milestone_json"
        case statusBy = "status_by", statusUpdatedAt = "status_updated_at"
    }
```

At the end of `init(_ m: Mission)` add:

```swift
        status = m.status; statusBy = m.statusBy?.rawValue; statusUpdatedAt = ms(m.statusUpdatedAt)
```

In `var mission: Mission`, replace the final `milestoneCount: milestoneCount, lastMilestone: last)` with:

```swift
                       milestoneCount: milestoneCount, lastMilestone: last,
                       status: status, statusBy: statusBy.flatMap(ItemAuthor.init(rawValue:)),
                       statusUpdatedAt: date(statusUpdatedAt))
```

In `JournalStore.swift`, directly after the `v12` registration and before `return migrator`:

```swift
        // v13: mission status (spec 2026-09-28 missions dashboard §1). Three
        // nullable columns, no backfill and no watermark to clear: the
        // mission list refresh is a full `GET /missions` on every connect
        // (`MissionsSync.refreshOnce`), so the first one after the upgrade
        // fills them.
        migrator.registerMigration("v13") { db in
            try Self.addColumnIfMissing(db, table: "mission", column: "status", .text)
            try Self.addColumnIfMissing(db, table: "mission", column: "status_by", .text)
            try Self.addColumnIfMissing(db, table: "mission", column: "status_updated_at", .integer)
        }
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(MissionModelTests|JournalStoreMissionsTests|JournalStoreMigrationIdempotenceTests|MissionsSyncTests)'`
Expected: PASS, every test in the four classes.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Models/Mission.swift MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Sources/Journal/JournalStore+Missions.swift \
        MatronShared/Tests/JournalTests/MissionModelTests.swift MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions: Mission carries its status; v13 caches it" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `JournalAPI.roster()`

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Roster.swift`
- Test: `MatronShared/Tests/JournalTests/RosterAPITests.swift` (new)

**Interfaces:**
- Produces: `public func roster() async throws -> [String: String]` on `JournalAPI` (conversation id → trimmed, non-empty `summary`); `static func decodeRosterSummaries(_ obj: [String: Any]) throws -> [String: String]` (internal, tested).

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/RosterAPITests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class RosterAPITests: XCTestCase {
    /// Same stub wiring as `MissionsAPITests.makeStubbedAPI` —
    /// `ItemsStubURLProtocol` lives in `ItemsAPITests.swift`, same target.
    private func makeStubbedAPI(status: Int, body: [String: Any]) -> (JournalAPI, ItemsStubURLProtocol.Type) {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        return (api, ItemsStubURLProtocol.self)
    }

    /// Only `id` and `summary` are read; a null, empty or whitespace
    /// summary is "no summary", and a row without an id is skipped.
    func testDecodeKeepsOnlyNonEmptySummaries() throws {
        let obj: [String: Any] = ["agents": [], "conversations": [
            ["id": "c1", "title": "Parser", "session_state": "running", "summary": "  Reviewing the parser\n"],
            ["id": "c2", "summary": NSNull()],
            ["id": "c3", "summary": "   "],
            ["summary": "orphan"],
            ["id": "c4"],
        ]]
        XCTAssertEqual(try JournalAPI.decodeRosterSummaries(obj), ["c1": "Reviewing the parser"])
    }

    /// A response with no `conversations` array is malformed, not "nobody
    /// has a summary" — it throws so the dashboard keeps its last map.
    func testDecodeWithoutAConversationsArrayThrows() {
        XCTAssertThrowsError(try JournalAPI.decodeRosterSummaries(["agents": []]))
    }

    func testRosterGetsSlashRoster() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "agents": [], "conversations": [["id": "c1", "summary": "Shipping"]],
        ])
        let summaries = try await api.roster()
        XCTAssertEqual(summaries, ["c1": "Shipping"])
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/roster")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && swift test --filter JournalTests.RosterAPITests`
Expected: build FAILS — `type 'JournalAPI' has no member 'decodeRosterSummaries'`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Journal/JournalAPI+Roster.swift`:

```swift
import Foundation

extension JournalAPI {
    /// Internal so `RosterAPITests` pins the decoding without an HTTP stub
    /// per shape. Reads only `conversations[].id` and `.summary` — the
    /// Missions dashboard's "what's happening now" line (spec 2026-09-28
    /// §3.5). The roster's other fields (agents, capacity, titles) are
    /// deliberately not decoded here.
    static func decodeRosterSummaries(_ obj: [String: Any]) throws -> [String: String] {
        guard let rows = obj["conversations"] as? [[String: Any]] else {
            throw JournalAPIError.transport("malformed roster response")
        }
        var summaries: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String,
                  let summary = (row["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else { continue }
            summaries[id] = summary
        }
        return summaries
    }

    /// `GET /roster` reduced to conversation id → the bridge-written
    /// summary. Top-level conversations only (the journal omits children).
    public func roster() async throws -> [String: String] {
        try Self.decodeRosterSummaries(try await request(path: "/roster"))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd MatronShared && swift test --filter JournalTests.RosterAPITests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI+Roster.swift MatronShared/Tests/JournalTests/RosterAPITests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "journal api: roster() returns each conversation's summary" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Dashboard store reads

One observation per kind of data for EVERY mission, instead of the spec's per-mission `missionConversationsStream` + items stream: the dashboard shows every open mission at once, and N observations re-run N fetches per write.

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore+Missions.swift` (new `// MARK: Dashboard reads` section before `// MARK: Wipe`)
- Test: `MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift`

**Interfaces:**
- Produces on `JournalStore` (each has a one-shot `throws` read and a stream):
  - `allMissionConversations() throws -> [String: [MissionConversation]]` / `allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]>` — keyed by mission id, each list ordered by `convo_id`.
  - `latestMilestones() throws -> [String: Milestone]` / `latestMilestonesStream()` — newest milestone per mission (`created_at`, then `num`).
  - `needsYouItemsByMission() throws -> [String: [TrackerItem]]` / `needsYouItemsByMissionStream()` — open items awaiting the user, per mission, `updated_at DESC, num DESC`.
  - `latestSummaryTOCs() throws -> [String: String]` / `latestSummaryTOCsStream()` — newest `summary_entry.toc` per conversation.

- [ ] **Step 1: Write the failing tests**

Append to `JournalStoreMissionsTests`:

```swift
    // MARK: Dashboard reads (spec 2026-09-28 §3.7)

    func testAllMissionConversationsAreGroupedByMission() throws {
        let store = try makeStore()
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c2", title: "B", box: "dev-2", state: "running"),
            MissionConversation(id: "c1", title: "A", box: nil, state: "done"),
        ])
        try store.replaceMissionConversations(missionID: "ms_2", [MissionConversation(id: "c9", title: "Z", box: nil, state: "waiting")])
        let all = try store.allMissionConversations()
        XCTAssertEqual(all["ms_1"]?.map(\.id), ["c1", "c2"])
        XCTAssertEqual(all["ms_2"]?.map(\.id), ["c9"])
        XCTAssertNil(all["ms_3"])
    }

    func testLatestMilestonesPickTheNewestPerMission() throws {
        let store = try makeStore()
        try store.replaceMilestones(missionID: "ms_1", [
            milestone("ml_1", mission: "ms_1", num: 62, seq: 10, created: 10),
            milestone("ml_2", mission: "ms_1", num: 63, seq: 20, created: 30),
            // Same instant: the higher number wins, deterministically.
            milestone("ml_3", mission: "ms_1", num: 64, seq: 21, created: 30),
        ])
        try store.replaceMilestones(missionID: "ms_2", [milestone("ml_9", mission: "ms_2", num: 70, seq: 5, created: 5)])
        let latest = try store.latestMilestones()
        XCTAssertEqual(latest["ms_1"]?.id, "ml_3")
        XCTAssertEqual(latest["ms_2"]?.id, "ml_9")
        XCTAssertEqual(latest.count, 2)
    }

    func testNeedsYouItemsAreOpenAwaitingUserAndGroupedByMission() throws {
        let store = try makeStore()
        try store.upsertItems([
            TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "older ask",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 1), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_2", num: 2, kind: .question, awaiting: .user, title: "newer ask",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 9), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_3", num: 3, kind: .task, awaiting: .agent, title: "agent's turn",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 5), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_4", num: 4, kind: .question, state: .closed, awaiting: .user, title: "answered",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 6), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_5", num: 5, kind: .question, awaiting: .user, title: "no mission",
                        originConvoID: "c2", updatedAt: Date(timeIntervalSince1970: 7)),
        ])
        let grouped = try store.needsYouItemsByMission()
        XCTAssertEqual(grouped["ms_1"]?.map(\.id), ["it_2", "it_1"])
        XCTAssertEqual(grouped.count, 1, "an item on no mission is not grouped anywhere")
    }

    func testLatestSummaryTOCsPickTheNewestEntryPerConversation() throws {
        let store = try makeStore()
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_entry(convo_id, seq, toc, detail, created_at) VALUES
                ('c1', 5, 'Old heading', '', 1), ('c1', 9, 'Newest heading', '', 2), ('c2', 3, 'Only one', '', 1)
                """)
        }
        XCTAssertEqual(try store.latestSummaryTOCs(), ["c1": "Newest heading", "c2": "Only one"])
    }

    func testNeedsYouStreamEmitsOnAnItemWrite() async throws {
        let store = try makeStore()
        var iterator = store.needsYouItemsByMissionStream().makeAsyncIterator()
        _ = await iterator.next()   // initial (empty) value
        try store.upsertItems([TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q",
                                           originConvoID: "c1", missionID: "ms_1", missionNum: 61)])
        let next = await iterator.next()
        XCTAssertEqual(next?["ms_1"]?.map(\.id), ["it_1"])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter JournalTests.JournalStoreMissionsTests`
Expected: build FAILS — `value of type 'JournalStore' has no member 'allMissionConversations'` (and the other three).

- [ ] **Step 3: Implement**

In `JournalStore+Missions.swift`, insert before `// MARK: Wipe`:

```swift
    // MARK: Dashboard reads (spec 2026-09-28 missions dashboard §3.7)
    //
    // One observation per kind of data across EVERY mission: the dashboard
    // shows all open missions at once, and a per-mission stream each would
    // re-run N fetches on every write to the table.

    private static func allMissionConversationsQuery(_ db: Database) throws -> [String: [MissionConversation]] {
        let rows = try MissionConversationRecord.order(Column("mission_id"), Column("convo_id")).fetchAll(db)
        return Dictionary(grouping: rows, by: \.missionId).mapValues { $0.map(\.conversation) }
    }

    public func allMissionConversations() throws -> [String: [MissionConversation]] {
        try dbQueue.read(Self.allMissionConversationsQuery)
    }

    public func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]> {
        Self.stream(ValueObservation.tracking(Self.allMissionConversationsQuery), in: dbQueue)
    }

    /// Newest milestone per mission — the card's "latest step" with its
    /// body, which `Mission.lastMilestone` (list rows) does not carry. Ties
    /// on `created_at` go to the higher number, so the pick is stable.
    private static func latestMilestonesQuery(_ db: Database) throws -> [String: Milestone] {
        let rows = try MilestoneRecord.fetchAll(db, sql: """
            SELECT * FROM milestone m
            WHERE NOT EXISTS (
                SELECT 1 FROM milestone n
                WHERE n.mission_id = m.mission_id
                  AND (n.created_at > m.created_at OR (n.created_at = m.created_at AND n.num > m.num))
            )
            """)
        return Dictionary(rows.map { ($0.missionId, $0.milestone) }, uniquingKeysWith: { first, _ in first })
    }

    public func latestMilestones() throws -> [String: Milestone] { try dbQueue.read(Self.latestMilestonesQuery) }

    public func latestMilestonesStream() -> AsyncStream<[String: Milestone]> {
        Self.stream(ValueObservation.tracking(Self.latestMilestonesQuery), in: dbQueue)
    }

    /// Open items awaiting the user (questions and consent asks alike), per
    /// mission, newest activity first — the card's needs-you rows.
    private static func needsYouItemsByMissionQuery(_ db: Database) throws -> [String: [TrackerItem]] {
        let rows = try ItemRecord.fetchAll(db, sql: """
            SELECT * FROM item
            WHERE mission_id IS NOT NULL AND state = 'open' AND awaiting = 'user'
            ORDER BY updated_at DESC, num DESC
            """)
        var grouped: [String: [TrackerItem]] = [:]
        for row in rows {
            guard let missionID = row.missionId else { continue }
            grouped[missionID, default: []].append(row.item)
        }
        return grouped
    }

    public func needsYouItemsByMission() throws -> [String: [TrackerItem]] {
        try dbQueue.read(Self.needsYouItemsByMissionQuery)
    }

    public func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]> {
        Self.stream(ValueObservation.tracking(Self.needsYouItemsByMissionQuery), in: dbQueue)
    }

    /// Newest TOC heading per conversation — the session summary's second
    /// source (spec §3.5), after the roster's `summary`.
    private static func latestSummaryTOCsQuery(_ db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.convo_id AS c, s.toc AS toc FROM summary_entry s
            WHERE s.seq = (SELECT MAX(seq) FROM summary_entry WHERE convo_id = s.convo_id)
            """)
        return Dictionary(rows.map { ($0["c"] as String, $0["toc"] as String) }, uniquingKeysWith: { first, _ in first })
    }

    public func latestSummaryTOCs() throws -> [String: String] { try dbQueue.read(Self.latestSummaryTOCsQuery) }

    public func latestSummaryTOCsStream() -> AsyncStream<[String: String]> {
        Self.stream(ValueObservation.tracking(Self.latestSummaryTOCsQuery), in: dbQueue)
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter JournalTests.JournalStoreMissionsTests`
Expected: PASS, all tests in the class.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore+Missions.swift MatronShared/Tests/JournalTests/JournalStoreMissionsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "journal store: dashboard reads across every mission" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `ChatSummary.sessionState`

The dashboard's state dots need every session's `session_state`; `ChatSummary` never carried it (only `SubChatSummary.isRunning` did).

**Files:**
- Modify: `MatronShared/Sources/Chat/ChatSummary.swift`
- Modify: `MatronShared/Sources/Chat/JournalChatService.swift` (`summary(from:boxNames:boxLetters:needsUser:)`)
- Test: `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift`

**Interfaces:**
- Produces: `ChatSummary.sessionState: String`; init gains trailing `sessionState: String = "waiting"` (after `needsUserCount:`).

- [ ] **Step 1: Write the failing test**

Append to `JournalChatServiceTests`:

```swift
    /// The Missions dashboard's state dot reads the store's `session_state`
    /// straight off the summary (spec 2026-09-28 §3.2).
    func testSummaryCarriesTheSessionState() throws {
        let store = try makeStore()
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "Busy", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1),
            ConvoSummaryDTO(id: "c2", title: "Idle", sessionState: "done", lastSeq: 1, snippet: "", createdAt: 1),
        ], headSeq: 1)
        let busy = try XCTUnwrap(store.conversation(id: "c1"))
        let idle = try XCTUnwrap(store.conversation(id: "c2"))
        XCTAssertEqual(JournalChatService.summary(from: busy, boxNames: [:]).sessionState, "running")
        XCTAssertEqual(JournalChatService.summary(from: idle, boxNames: [:]).sessionState, "done")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && swift test --filter ChatTests.JournalChatServiceTests/testSummaryCarriesTheSessionState`
Expected: build FAILS — `value of type 'ChatSummary' has no member 'sessionState'`.

- [ ] **Step 3: Implement**

In `ChatSummary`, after `public let needsUserCount: Int`:

```swift
    /// The conversation's `session_state` as the store holds it —
    /// `"running"` while a turn is in flight, `"waiting"` / `"done"`
    /// otherwise. Drives the Missions dashboard's state dots.
    public let sessionState: String
```

Init signature: change `needsUserCount: Int = 0` to `needsUserCount: Int = 0,` and add `sessionState: String = "waiting"` on the next line; in the body add `self.sessionState = sessionState`.

In `JournalChatService.summary(from:...)`, change the last argument of the `ChatSummary(...)` call:

```swift
            needsUserCount: needsUser,
            sessionState: record.sessionState
        )
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd MatronShared && swift test --filter 'ChatTests.JournalChatServiceTests|ViewModelTests.ChatListViewModelTests'`
Expected: PASS (both classes — the list VM tests prove the new default leaves existing call sites intact).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Chat/ChatSummary.swift MatronShared/Sources/Chat/JournalChatService.swift \
        MatronShared/Tests/ChatTests/JournalChatServiceTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "chat: ChatSummary carries the session state" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Item changes refetch their mission

Spec §3.7 "Fix": item markers whose item has a mission must refetch that mission, or `needs_you`/`open_items` stay stale until reconnect. The journal's `item` marker payload carries NO `mission_id` (`src/items-marker.js`), so the mission is resolved where the item is actually fetched: `ItemsSync.refreshItemOnce`, which every item marker already triggers. The mission it names now, and the one the cached row named before (an item moved off a mission changes that one's counts too), are handed to a refetcher that the app wires to `MissionsSync.refreshMission(id:)`. A drained reply also runs `refreshItem`, which is right: answering an item changes `needs_you`.

**Files:**
- Modify: `MatronShared/Sources/Journal/ItemsSync.swift` (property + setter near `init`; `refreshItemOnce`)
- Modify: `Matron/App/AppDependencies.swift` (~line 243), `MatronMac/App/AppDependencies.swift` (~line 182)
- Test: `MatronShared/Tests/JournalTests/ItemsSyncTests.swift`

**Interfaces:**
- Produces: `public func setMissionRefetcher(_ refetcher: @escaping @Sendable (String) async -> Void)` on `ItemsSync`.
- Consumes: `MissionsSync.refreshMission(id:)` (existing).

- [ ] **Step 1: Write the failing tests**

In `ItemsSyncTests.swift`, add below the private `Atomic` class at the top of the file:

```swift
private final class IDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func record(_ id: String) { lock.withLock { ids.append(id) } }
    var recorded: [String] { lock.withLock { ids } }
}
```

Append to `ItemsSyncTests`:

```swift
    // MARK: Mission refetch (spec 2026-09-28 missions dashboard §3.7)

    func testAnItemMarkerRefetchesTheItemsMission() async throws {
        let api = FakeItems()
        api.detail["it_1"] = (TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q",
                                          originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 5),
                                          missionID: "ms_1", missionNum: 61), [])
        let (sync, _, markers, _) = try make(api: api)
        let asked = IDRecorder()
        await sync.setMissionRefetcher { asked.record($0) }
        await sync.start()
        markers.yield((convoID: "c1", marker: ItemMarkerEvent(itemID: "it_1", num: 1, kind: .question, title: "Q",
                                                              action: .created, by: .agent)))
        try await waitUntil { asked.recorded == ["ms_1"] }
    }

    /// Moving an item between missions changes BOTH missions' counts.
    func testAnItemMovedBetweenMissionsRefetchesBoth() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api)
        try store.upsertItems([TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q",
                                           originConvoID: "c1", missionID: "ms_old", missionNum: 60)])
        api.detail["it_1"] = (TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q",
                                          originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 5),
                                          missionID: "ms_new", missionNum: 61), [])
        let asked = IDRecorder()
        await sync.setMissionRefetcher { asked.record($0) }
        await sync.refreshItem(id: "it_1")
        try await waitUntil { Set(asked.recorded) == ["ms_old", "ms_new"] }
    }

    func testAnItemOnNoMissionRefetchesNothing() async throws {
        let api = FakeItems()
        api.detail["it_1"] = (item("it_1", num: 1, updated: 5), [])
        let (sync, _, _, _) = try make(api: api)
        let asked = IDRecorder()
        await sync.setMissionRefetcher { asked.record($0) }
        await sync.refreshItem(id: "it_1")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(asked.recorded, [])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter JournalTests.ItemsSyncTests`
Expected: build FAILS — `value of type 'ItemsSync' has no member 'setMissionRefetcher'`.

- [ ] **Step 3: Implement**

In `ItemsSync`, after `private var stopped = false`:

```swift
    /// Spec 2026-09-28 missions dashboard §3.7: an item change on a mission
    /// changes that mission's `needs_you` / `open_items`, which live on the
    /// mission row. The `item` marker carries no `mission_id`, so the
    /// mission is resolved here, from the row this actor just fetched (and
    /// the row it replaced). Set by the app to `MissionsSync.refreshMission`.
    private var missionRefetcher: (@Sendable (String) async -> Void)?

    public func setMissionRefetcher(_ refetcher: @escaping @Sendable (String) async -> Void) {
        missionRefetcher = refetcher
    }

    /// Fire-and-forget: this actor must not wait on a mission fetch, and
    /// `MissionsSync` coalesces repeats of the same id itself.
    private func refetchMissions(_ ids: Set<String>) {
        guard let refetcher = missionRefetcher else { return }
        for id in ids.sorted() { Task { await refetcher(id) } }
    }
```

Replace `refreshItemOnce(id:)` with:

```swift
    private func refreshItemOnce(id: String) async {
        // Read before the fetch: the mission the cached row names now is
        // the one an item moved OFF.
        let previousMissionID = (try? store.item(id: id))?.missionID
        do {
            let r = try await api.item(id: id)
            guard !stopped else { return }
            try store.upsertItems([r.item])
            try store.replaceComments(itemID: id, r.comments)
            setSupported(true)
            refetchMissions(Set([previousMissionID, r.item.missionID].compactMap { $0 }))
        } catch {
            Self.logger.warning("item refetch \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
```

In BOTH `Matron/App/AppDependencies.swift` and `MatronMac/App/AppDependencies.swift`, replace `core.itemsStartTask = Task { await items.start() }` with:

```swift
        core.itemsStartTask = Task {
            // Spec 2026-09-28 dashboard §3.7: an item change on a mission
            // refetches that mission, so its needs-you count stays current.
            await items.setMissionRefetcher { missionID in await missions.refreshMission(id: missionID) }
            await items.start()
        }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(ItemsSyncTests|MissionsSyncTests)'`
Expected: PASS, both classes.

Build both apps (the wiring compiles):
`xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO -quiet` → `** BUILD SUCCEEDED **`
`xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -quiet` → `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/ItemsSync.swift MatronShared/Tests/JournalTests/ItemsSyncTests.swift \
        Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "items sync: an item change refetches its mission" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Dashboard value types and the pure assembly

**Files:**
- Create: `MatronShared/Sources/Models/MissionsDashboard.swift`
- Create: `MatronShared/Sources/ViewModels/MissionsDashboardAssembly.swift`
- Test: `MatronShared/Tests/ViewModelTests/MissionsDashboardAssemblyTests.swift` (new)

**Interfaces:**
- Produces (MatronModels): `DashboardSessionState` (`running`/`waiting`/`done`, `init(sessionState:)`, `sortRank`), `DashboardSession`, `DashboardNeedsYouItem`, `DashboardLatestStep`, `DashboardMissionCard` (`moreNeedsYou`), `MissionsDashboardAction` (`openMission(String)`, `openSession(String)`, `openItem(String)`).
- Produces (MatronViewModels): `MissionsDashboardInputs`, `MissionsDashboardSnapshot`, `enum MissionsDashboardAssembly` with `assemble(_:now:) -> MissionsDashboardSnapshot`, `summaryText(convoID:roster:tocs:snippet:) -> String?`, `attribution(for:coordinatorConvoID:titles:) -> String?`, constants `maxNeedsYouRows = 3`, `maxSessionRows = 4`, `looseWaitingWindow = 86_400`.

- [ ] **Step 1: Write the value types**

Create `MatronShared/Sources/Models/MissionsDashboard.swift`:

```swift
import Foundation

// Value types for the Missions dashboard (spec 2026-09-28 missions
// dashboard §3). Built by `MissionsDashboardAssembly` (MatronViewModels),
// drawn by `MissionsDashboardView` (MatronDesignSystem) — the one module
// both can see.

/// A session's state as the dashboard's dot shows it.
public enum DashboardSessionState: String, Sendable, Equatable, Hashable, CaseIterable {
    case running, waiting, done

    /// The store's / journal's `session_state`. Anything that is not
    /// `running` or `done` reads as waiting — the store's own default.
    public init(sessionState: String) {
        switch sessionState {
        case "running": self = .running
        case "done": self = .done
        default: self = .waiting
        }
    }

    /// Running first, then waiting, then done (spec §3.2).
    public var sortRank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .done: return 2
        }
    }
}

/// One session row on a mission card, or one loose-session card.
public struct DashboardSession: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let state: DashboardSessionState
    public let lastActivity: Date?
    /// The two-line "what's happening now" text (spec §3.5), or nil.
    public let summary: String?
    /// The `A:bc` tag halves when this device has the conversation cached.
    public let tag: SessionTagInputs?
    /// A bare box name from the mission detail, for a conversation this
    /// device has never synced (no `tag` to draw) — rendered as a chip.
    public let boxName: String?
    public let needsYou: Int

    public init(id: String, title: String, state: DashboardSessionState, lastActivity: Date? = nil,
                summary: String? = nil, tag: SessionTagInputs? = nil, boxName: String? = nil, needsYou: Int = 0) {
        self.id = id; self.title = title; self.state = state; self.lastActivity = lastActivity
        self.summary = summary; self.tag = tag; self.boxName = boxName; self.needsYou = needsYou
    }
}

/// One open item awaiting the user, as a card row.
public struct DashboardNeedsYouItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let kind: ItemKind
    public let title: String
    public init(id: String, num: Int, kind: ItemKind, title: String) {
        self.id = id; self.num = num; self.kind = kind; self.title = title
    }
}

/// The card's "latest step": the newest milestone, with its body when this
/// device has cached it (`Mission.lastMilestone` carries no body).
public struct DashboardLatestStep: Equatable, Hashable, Sendable {
    public let num: Int
    public let kind: MilestoneKind
    public let title: String
    public let body: String
    public let createdAt: Date
    public init(num: Int, kind: MilestoneKind, title: String, body: String = "", createdAt: Date) {
        self.num = num; self.kind = kind; self.title = title; self.body = body; self.createdAt = createdAt
    }
}

/// One open mission's card (spec §3.2).
public struct DashboardMissionCard: Identifiable, Equatable, Hashable, Sendable {
    public let mission: Mission
    /// "from Coordinator" / "from <title>" — unassigned missions only.
    public let attribution: String?
    public let latestStep: DashboardLatestStep?
    /// The larger of the server's `needs_you` and the local rows, so a
    /// cache that hasn't caught up never under-reports.
    public let needsYouCount: Int
    /// At most `MissionsDashboardAssembly.maxNeedsYouRows`.
    public let needsYouItems: [DashboardNeedsYouItem]
    /// At most `MissionsDashboardAssembly.maxSessionRows`, sorted.
    public let sessions: [DashboardSession]
    public let moreSessions: Int
    /// Any of the mission's sessions (not only the listed ones) running.
    public let anyRunning: Bool
    /// Max of last milestone, status time and sessions' last activity.
    public let lastActivity: Date

    public var id: String { mission.id }
    public var moreNeedsYou: Int { max(0, needsYouCount - needsYouItems.count) }

    public init(mission: Mission, attribution: String? = nil, latestStep: DashboardLatestStep? = nil,
                needsYouCount: Int = 0, needsYouItems: [DashboardNeedsYouItem] = [],
                sessions: [DashboardSession] = [], moreSessions: Int = 0, anyRunning: Bool = false,
                lastActivity: Date) {
        self.mission = mission; self.attribution = attribution; self.latestStep = latestStep
        self.needsYouCount = needsYouCount; self.needsYouItems = needsYouItems; self.sessions = sessions
        self.moreSessions = moreSessions; self.anyRunning = anyRunning; self.lastActivity = lastActivity
    }
}

/// What a tap on the dashboard asks the host to do. One enum so both hosts
/// route every tap through one function each (`AppShellNavigation
/// .handleDashboard`, `MacChatListView.handleDashboardAction`).
public enum MissionsDashboardAction: Equatable, Hashable, Sendable {
    case openMission(String)
    case openSession(String)
    case openItem(String)
}
```

- [ ] **Step 2: Write the failing assembly tests**

Create `MatronShared/Tests/ViewModelTests/MissionsDashboardAssemblyTests.swift`:

```swift
import XCTest
import MatronModels
import MatronChat
@testable import MatronViewModels

final class MissionsDashboardAssemblyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func mission(_ id: String, num: Int, state: MissionState = .open, origin: String = "c-origin",
                         lastMilestoneAt: Date? = nil, needsYou: Int = 0, conversations: Int = 1,
                         closedAt: Date? = nil, statusUpdatedAt: Date? = nil) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: origin,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                lastMilestoneAt: lastMilestoneAt, closedAt: closedAt, needsYou: needsYou,
                conversationCount: conversations,
                lastMilestone: lastMilestoneAt.map { MissionLastMilestone(num: num + 100, title: "step", kind: .progress, createdAt: $0) },
                status: statusUpdatedAt == nil ? nil : "Status", statusBy: statusUpdatedAt == nil ? nil : .agent,
                statusUpdatedAt: statusUpdatedAt)
    }

    private func summary(_ id: String, state: String = "waiting", last: Date? = nil, parent: String? = nil,
                         snippet: String = "", title: String? = nil, needs: Int = 0) -> ChatSummary {
        ChatSummary(id: id, title: title ?? "Chat \(id)",
                    bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
                    lastActivity: last, unreadCount: 0, snippet: snippet, parentConvoID: parent,
                    needsUserCount: needs, sessionState: state)
    }

    private func convo(_ id: String, state: String = "waiting", title: String = "", box: String? = nil) -> MissionConversation {
        MissionConversation(id: id, title: title, box: box, state: state)
    }

    // MARK: Grouping

    func testOpenClosedAndUnassignedLandInTheirPlaces() {
        var inputs = MissionsDashboardInputs()
        inputs.coordinatorConvoID = "c-coord"
        inputs.missions = [
            mission("ms_open", num: 61),
            mission("ms_unassigned", num: 62, origin: "c-coord", conversations: 0),
            mission("ms_closed_old", num: 50, state: .closed, closedAt: ago(500)),
            mission("ms_closed_new", num: 51, state: .closed, closedAt: ago(100)),
        ]
        inputs.conversationsByMission = ["ms_open": [convo("c1")]]
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(Set(snapshot.cards.map(\.id)), ["ms_open", "ms_unassigned"])
        XCTAssertEqual(snapshot.closed.map(\.id), ["ms_closed_new", "ms_closed_old"], "newest close first")
        let unassigned = snapshot.cards.first { $0.id == "ms_unassigned" }
        XCTAssertEqual(unassigned?.attribution, "from Coordinator")
        XCTAssertEqual(unassigned?.sessions, [])
        XCTAssertNil(snapshot.cards.first { $0.id == "ms_open" }?.attribution, "only unassigned cards are attributed")
    }

    func testAttributionNamesTheCoordinatorThenTheOriginThenNothing() {
        let fromCoordinator = mission("ms_1", num: 1, origin: "c-coord", conversations: 0)
        let fromElsewhere = mission("ms_2", num: 2, origin: "c-other", conversations: 0)
        let unknown = mission("ms_3", num: 3, origin: "c-gone", conversations: 0)
        let titles = ["c-other": "Parser work"]
        XCTAssertEqual(MissionsDashboardAssembly.attribution(for: fromCoordinator, coordinatorConvoID: "c-coord", titles: titles),
                       "from Coordinator")
        XCTAssertEqual(MissionsDashboardAssembly.attribution(for: fromElsewhere, coordinatorConvoID: "c-coord", titles: titles),
                       "from Parser work")
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: unknown, coordinatorConvoID: "c-coord", titles: titles))
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: fromCoordinator, coordinatorConvoID: "", titles: [:]))
    }

    // MARK: Ordering (spec §3.6)

    func testCardsGroupNeedsYouThenRunningThenRestAndSortByActivityWithin() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [
            mission("ms_quiet_new", num: 1, lastMilestoneAt: ago(10)),
            mission("ms_running", num: 2, lastMilestoneAt: ago(9_000)),
            mission("ms_needs_old", num: 3, lastMilestoneAt: ago(8_000), needsYou: 1),
            mission("ms_needs_new", num: 4, lastMilestoneAt: ago(50), needsYou: 2),
            mission("ms_quiet_old", num: 5, lastMilestoneAt: ago(7_000)),
        ]
        inputs.conversationsByMission = ["ms_running": [convo("c-run", state: "running")]]
        let ids = MissionsDashboardAssembly.assemble(inputs, now: now).cards.map(\.id)
        XCTAssertEqual(ids, ["ms_needs_new", "ms_needs_old", "ms_running", "ms_quiet_new", "ms_quiet_old"])
    }

    func testActivityIsTheMaxOfMilestoneStatusAndSessions() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [
            mission("ms_status", num: 1, lastMilestoneAt: ago(9_000), statusUpdatedAt: ago(20)),
            mission("ms_session", num: 2, lastMilestoneAt: ago(9_000)),
            mission("ms_milestone", num: 3, lastMilestoneAt: ago(30)),
        ]
        inputs.conversationsByMission = ["ms_session": [convo("c1")]]
        inputs.summaries = [summary("c1", last: ago(10))]
        let cards = MissionsDashboardAssembly.assemble(inputs, now: now).cards
        XCTAssertEqual(cards.map(\.id), ["ms_session", "ms_status", "ms_milestone"])
        XCTAssertEqual(cards.first?.lastActivity, ago(10))
    }

    func testSessionsSortRunningWaitingDoneThenActivityAndCapAtFour() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [
            convo("done"), convo("wait_old"), convo("wait_new"), convo("run"), convo("wait_mid"), convo("never"),
        ]]
        inputs.summaries = [
            summary("done", state: "done", last: ago(1)),
            summary("wait_old", last: ago(300)),
            summary("wait_new", last: ago(10)),
            summary("run", state: "running", last: ago(5_000)),
            summary("wait_mid", last: ago(100)),
            summary("never", last: nil),
        ]
        let card = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0]
        XCTAssertEqual(card.sessions.map(\.id), ["run", "wait_new", "wait_mid", "wait_old"])
        XCTAssertEqual(card.moreSessions, 2)
        XCTAssertTrue(card.anyRunning)
    }

    // MARK: Loose sessions (spec §3.3)

    func testLooseSessionMembership() {
        var inputs = MissionsDashboardInputs()
        inputs.coordinatorConvoID = "c-coord"
        inputs.missions = [mission("ms_1", num: 1, origin: "c-origin"),
                           mission("ms_closed", num: 2, state: .closed, origin: "c-closed-origin", closedAt: ago(1))]
        inputs.conversationsByMission = ["ms_1": [convo("c-member")], "ms_closed": [convo("c-on-closed", state: "running")]]
        inputs.summaries = [
            summary("c-running-old", state: "running", last: ago(10 * 86_400)),
            summary("c-waiting-recent", last: ago(3_600)),
            summary("c-waiting-stale", last: ago(25 * 3_600)),
            summary("c-waiting-never", last: nil),
            summary("c-done", state: "done", last: ago(60)),
            summary("c-child", state: "running", last: ago(60), parent: "c-running-old"),
            summary("c-coord", state: "running", last: ago(60)),
            summary("c-member", state: "running", last: ago(60)),
            summary("c-origin", state: "running", last: ago(60)),
            summary("c-on-closed", state: "running", last: ago(60)),
        ]
        let ids = Set(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id))
        XCTAssertEqual(ids, ["c-running-old", "c-waiting-recent", "c-on-closed"],
                       "running always, waiting only inside 24 h; never a child, the Coordinator or an open mission's session")
    }

    func testLooseSessionsPutRunningFirstThenActivity() {
        var inputs = MissionsDashboardInputs()
        inputs.summaries = [
            summary("wait_new", last: ago(10)),
            summary("run_old", state: "running", last: ago(5_000)),
            summary("wait_old", last: ago(600)),
            summary("run_new", state: "running", last: ago(100)),
        ]
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id),
                       ["run_new", "run_old", "wait_new", "wait_old"])
    }

    // MARK: Summary text (spec §3.5)

    func testSummaryFallsBackFromRosterToTOCToSnippet() {
        let roster = ["c1": "Roster line", "c2": "   "]
        let tocs = ["c1": "TOC 1", "c2": "TOC 2"]
        XCTAssertEqual(MissionsDashboardAssembly.summaryText(convoID: "c1", roster: roster, tocs: tocs, snippet: "s"), "Roster line")
        XCTAssertEqual(MissionsDashboardAssembly.summaryText(convoID: "c2", roster: roster, tocs: tocs, snippet: "s"), "TOC 2",
                       "a blank roster summary falls through")
        XCTAssertEqual(MissionsDashboardAssembly.summaryText(convoID: "c3", roster: roster, tocs: tocs, snippet: "last line"), "last line")
        XCTAssertNil(MissionsDashboardAssembly.summaryText(convoID: "c3", roster: roster, tocs: tocs, snippet: ""))
        XCTAssertNil(MissionsDashboardAssembly.summaryText(convoID: "c3", roster: roster, tocs: tocs, snippet: nil))
    }

    // MARK: Review Focus

    /// Review Focus: the server's count can be ahead of the local items.
    func testNeedsYouUsesTheLargerCountAndCapsRowsAtThree() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_ahead", num: 1, needsYou: 5), mission("ms_local", num: 2, needsYou: 0)]
        let items = (1...4).map { i in
            TrackerItem(id: "it_\(i)", num: i, kind: .question, awaiting: .user, title: "Q\(i)",
                        originConvoID: "c1", missionID: "ms_local", missionNum: 2)
        }
        let onlyOneSynced = TrackerItem(id: "it_a", num: 9, kind: .question, awaiting: .user, title: "Only one synced",
                                        originConvoID: "c1", missionID: "ms_ahead", missionNum: 1)
        inputs.needsYouItems = ["ms_ahead": [onlyOneSynced], "ms_local": items]
        let cards = Dictionary(uniqueKeysWithValues: MissionsDashboardAssembly.assemble(inputs, now: now).cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["ms_ahead"]?.needsYouCount, 5)
        XCTAssertEqual(cards["ms_ahead"]?.needsYouItems.map(\.id), ["it_a"])
        XCTAssertEqual(cards["ms_ahead"]?.moreNeedsYou, 4)
        XCTAssertEqual(cards["ms_local"]?.needsYouCount, 4, "the server's stale 0 never hides local asks")
        XCTAssertEqual(cards["ms_local"]?.needsYouItems.count, 3)
        XCTAssertEqual(cards["ms_local"]?.moreNeedsYou, 1)
    }

    /// Review Focus: a session on another box this device never synced.
    func testAnUncachedMissionSessionRendersFromTheDetailRow() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-far", state: "running", title: "[xy] Far away work", box: "dev-9")]]
        inputs.tocs = ["c-far": "Heading from the TOC"]
        let session = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0].sessions[0]
        XCTAssertEqual(session.title, "Far away work", "the [bc] short is peeled off the detail title")
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.boxName, "dev-9")
        XCTAssertEqual(session.tag?.sessionShort, "xy")
        XCTAssertEqual(session.summary, "Heading from the TOC")
    }

    func testLatestStepPrefersTheCachedMilestoneWithItsBody() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1, lastMilestoneAt: ago(60)), mission("ms_2", num: 2, lastMilestoneAt: ago(60))]
        inputs.latestMilestones = ["ms_1": Milestone(id: "ml_1", missionID: "ms_1", num: 101, kind: .progress, title: "step",
                                                     body: "Wired the migration", convoID: "c1", seq: 4, createdAt: ago(60))]
        let cards = Dictionary(uniqueKeysWithValues: MissionsDashboardAssembly.assemble(inputs, now: now).cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["ms_1"]?.latestStep?.body, "Wired the migration")
        XCTAssertEqual(cards["ms_2"]?.latestStep?.title, "step", "no cached milestone: the list row's title, no body")
        XCTAssertEqual(cards["ms_2"]?.latestStep?.body, "")

        var none = MissionsDashboardInputs()
        none.missions = [mission("ms_3", num: 3)]
        XCTAssertNil(MissionsDashboardAssembly.assemble(none, now: now).cards[0].latestStep, "no milestone, no step")
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd MatronShared && swift test --filter ViewModelTests.MissionsDashboardAssemblyTests`
Expected: build FAILS — `cannot find 'MissionsDashboardInputs' in scope`.

- [ ] **Step 4: Implement the assembly**

Create `MatronShared/Sources/ViewModels/MissionsDashboardAssembly.swift`:

```swift
import Foundation
import MatronChat
import MatronModels

/// Everything the dashboard is assembled from, as the view model last
/// received it. A value, so the assembly is a pure function of it.
public struct MissionsDashboardInputs: Equatable, Sendable {
    public var missions: [Mission] = []
    public var summaries: [ChatSummary] = []
    /// Conversation id → roster `summary` (`JournalAPI.roster()`).
    public var roster: [String: String] = [:]
    /// Conversation id → newest TOC heading.
    public var tocs: [String: String] = [:]
    public var conversationsByMission: [String: [MissionConversation]] = [:]
    public var latestMilestones: [String: Milestone] = [:]
    public var needsYouItems: [String: [TrackerItem]] = [:]
    public var coordinatorConvoID: String?
    public init() {}
}

public struct MissionsDashboardSnapshot: Equatable, Sendable {
    public var cards: [DashboardMissionCard]
    public var looseSessions: [DashboardSession]
    public var closed: [Mission]
}

/// The dashboard's rules (spec 2026-09-28 §3.2–§3.6), pure so every one of
/// them is a plain unit test.
public enum MissionsDashboardAssembly {
    public static let maxNeedsYouRows = 3
    public static let maxSessionRows = 4
    /// A waiting session counts as "loose and live" for this long after its
    /// last activity (spec §3.3).
    public static let looseWaitingWindow: TimeInterval = 24 * 60 * 60

    public static func assemble(_ inputs: MissionsDashboardInputs, now: Date) -> MissionsDashboardSnapshot {
        let summariesByID = Dictionary(inputs.summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let open = inputs.missions.filter { $0.state == .open }
        let cards = open.map { card(for: $0, inputs: inputs, summariesByID: summariesByID) }.sorted(by: cardPrecedes)
        let closed = inputs.missions.filter { $0.state == .closed }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        let loose = looseSessions(inputs: inputs, openMissions: open, now: now)
        return MissionsDashboardSnapshot(cards: cards, looseSessions: loose, closed: closed)
    }

    // MARK: Cards

    static func card(for mission: Mission, inputs: MissionsDashboardInputs,
                     summariesByID: [String: ChatSummary]) -> DashboardMissionCard {
        let conversations = inputs.conversationsByMission[mission.id] ?? []
        let sessions = sortedSessions(conversations.map { convo in
            session(for: convo, summary: summariesByID[convo.id], inputs: inputs)
        })
        let items = inputs.needsYouItems[mission.id] ?? []
        let unassigned = mission.conversationCount == 0 && conversations.isEmpty
        let titles = summariesByID.mapValues(\.title)
        let sessionTimes: [Date] = sessions.compactMap(\.lastActivity)
        let activity = ([mission.lastMilestoneAt, mission.statusUpdatedAt].compactMap { $0 } + sessionTimes).max()
        return DashboardMissionCard(
            mission: mission,
            attribution: unassigned ? attribution(for: mission, coordinatorConvoID: inputs.coordinatorConvoID, titles: titles) : nil,
            latestStep: latestStep(for: mission, cached: inputs.latestMilestones[mission.id]),
            needsYouCount: max(mission.needsYou, items.count),
            needsYouItems: items.prefix(maxNeedsYouRows).map {
                DashboardNeedsYouItem(id: $0.id, num: $0.num, kind: $0.kind, title: $0.title)
            },
            sessions: Array(sessions.prefix(maxSessionRows)),
            moreSessions: max(0, sessions.count - maxSessionRows),
            anyRunning: sessions.contains { $0.state == .running },
            lastActivity: activity ?? mission.createdAt)
    }

    /// Needs you first, then any session running, then the rest; newest
    /// activity first within a group; the higher number breaks a tie.
    static func cardPrecedes(_ a: DashboardMissionCard, _ b: DashboardMissionCard) -> Bool {
        let groupA = group(a), groupB = group(b)
        if groupA != groupB { return groupA < groupB }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.mission.num > b.mission.num
    }

    private static func group(_ card: DashboardMissionCard) -> Int {
        if card.needsYouCount > 0 { return 0 }
        return card.anyRunning ? 1 : 2
    }

    /// The cached newest milestone (it has a body) when it is at least as
    /// new as the list row's `last_milestone`; otherwise the list row's
    /// title alone.
    static func latestStep(for mission: Mission, cached: Milestone?) -> DashboardLatestStep? {
        if let cached {
            let listRow = mission.lastMilestone
            let isCurrent = listRow == nil || listRow?.num == cached.num || cached.createdAt >= (listRow?.createdAt ?? .distantPast)
            if isCurrent {
                return DashboardLatestStep(num: cached.num, kind: cached.kind, title: cached.title,
                                           body: cached.body, createdAt: cached.createdAt)
            }
        }
        guard let last = mission.lastMilestone else { return nil }
        return DashboardLatestStep(num: last.num, kind: last.kind, title: last.title, createdAt: last.createdAt)
    }

    /// "from Coordinator" when the mission was born in the Coordinator's
    /// conversation, otherwise "from <origin title>" when this device knows
    /// that conversation, otherwise nil.
    public static func attribution(for mission: Mission, coordinatorConvoID: String?,
                                   titles: [String: String]) -> String? {
        if let coordinatorConvoID, !coordinatorConvoID.isEmpty, mission.originConvoID == coordinatorConvoID {
            return "from Coordinator"
        }
        guard let title = titles[mission.originConvoID], !title.isEmpty else { return nil }
        return "from \(title)"
    }

    // MARK: Sessions

    /// A mission conversation: the cached chat summary when this device has
    /// one (live state, activity, tag), else the detail row itself.
    static func session(for convo: MissionConversation, summary: ChatSummary?,
                        inputs: MissionsDashboardInputs) -> DashboardSession {
        let text = summaryText(convoID: convo.id, roster: inputs.roster, tocs: inputs.tocs, snippet: summary?.snippet)
        if let summary { return session(from: summary, text: text) }
        let split = SessionTag.splitTitle(convo.title)
        return DashboardSession(
            id: convo.id, title: split.title.isEmpty ? convo.id : split.title,
            state: DashboardSessionState(sessionState: convo.state), lastActivity: nil, summary: text,
            tag: split.sessionShort.map { SessionTagInputs(boxLetter: nil, boxName: nil, sessionShort: $0) },
            boxName: convo.box, needsYou: 0)
    }

    static func session(from summary: ChatSummary, text: String?) -> DashboardSession {
        DashboardSession(id: summary.id, title: summary.title,
                         state: DashboardSessionState(sessionState: summary.sessionState),
                         lastActivity: summary.lastActivity, summary: text, tag: tagInputs(summary),
                         boxName: nil, needsYou: summary.needsUserCount)
    }

    static func tagInputs(_ summary: ChatSummary) -> SessionTagInputs? {
        guard summary.boxShort != nil || summary.sessionShort != nil || !summary.roomBoxNames.isEmpty else { return nil }
        return SessionTagInputs(boxLetter: summary.boxShort, boxName: summary.boxName, sessionShort: summary.sessionShort,
                                roomBoxNames: summary.roomBoxNames, roomBoxShorts: summary.roomBoxShorts)
    }

    /// Running → waiting → done, then newest activity (never-active last),
    /// then id so the order is stable.
    static func sortedSessions(_ sessions: [DashboardSession]) -> [DashboardSession] {
        sessions.sorted { a, b in
            if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
            switch (a.lastActivity, b.lastActivity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }

    /// Spec §3.3. "On a mission" means an OPEN mission's conversation or
    /// origin: a session still running after its mission closed has nowhere
    /// else on this page to appear.
    static func looseSessions(inputs: MissionsDashboardInputs, openMissions: [Mission], now: Date) -> [DashboardSession] {
        var onMission = Set(openMissions.map(\.originConvoID))
        for mission in openMissions {
            for convo in inputs.conversationsByMission[mission.id] ?? [] { onMission.insert(convo.id) }
        }
        let coordinator = inputs.coordinatorConvoID.flatMap { $0.isEmpty ? nil : $0 }
        let cutoff = now.addingTimeInterval(-looseWaitingWindow)
        let loose: [DashboardSession] = inputs.summaries.compactMap { summary in
            guard summary.parentConvoID == nil, !onMission.contains(summary.id), summary.id != coordinator else { return nil }
            switch DashboardSessionState(sessionState: summary.sessionState) {
            case .running: break
            case .waiting:
                guard let last = summary.lastActivity, last >= cutoff else { return nil }
            case .done: return nil
            }
            let text = summaryText(convoID: summary.id, roster: inputs.roster, tocs: inputs.tocs, snippet: summary.snippet)
            return session(from: summary, text: text)
        }
        return sortedSessions(loose)
    }

    /// Spec §3.5: roster summary, else newest TOC heading, else the chat
    /// snippet, else nothing. Blank candidates fall through.
    public static func summaryText(convoID: String, roster: [String: String], tocs: [String: String],
                                   snippet: String?) -> String? {
        for candidate in [roster[convoID], tocs[convoID], snippet] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter ViewModelTests.MissionsDashboardAssemblyTests`
Expected: PASS (11 tests).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Models/MissionsDashboard.swift MatronShared/Sources/ViewModels/MissionsDashboardAssembly.swift \
        MatronShared/Tests/ViewModelTests/MissionsDashboardAssemblyTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions dashboard: value types and the pure assembly rules" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `MissionsDashboardViewModel`

Session-long like the list VM it will replace (the tab/nav badge and `isSupported` are read while another tab shows): `start()`/`stop()` follow the session; `pageDidAppear()`/`pageDidDisappear()` follow the page and own the roster poll and the detail fan-out.

**Files:**
- Create: `MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/MissionsDashboardViewModelTests.swift` (new)

**Interfaces:**
- Consumes: `MissionsSyncing` (existing, `MissionsListViewModel.swift`), `MissionsDashboardAssembly` (Task 6), the Task 3 streams, `ChatSummary` (Task 4).
- Produces:
  - `public protocol MissionsDashboardStoreReading: Sendable` with `missionsStream(state:)`, `allMissionConversationsStream()`, `latestMilestonesStream()`, `needsYouItemsByMissionStream()`, `latestSummaryTOCsStream()`; `extension JournalStore: MissionsDashboardStoreReading {}`.
  - `@MainActor @Observable public final class MissionsDashboardViewModel`:
    - `init(store: any MissionsDashboardStoreReading, sync: any MissionsSyncing, summaries: @escaping @Sendable () -> AsyncThrowingStream<[ChatSummary], Error>, roster: @escaping @Sendable () async throws -> [String: String], send: @escaping @Sendable (_ convoID: String, _ body: String) async throws -> Void, rosterInterval: Duration = .seconds(60), now: @escaping @Sendable () -> Date = { Date() })`
    - `static let coordinatorRefreshMessage: String`, `static let maxDetailRefreshesInFlight = 4`
    - read-only: `cards`, `looseSessions`, `closed`, `isSupported: Bool?`, `isRefreshing`, `askedAt: Date?`, `needsYouTotal: Int`, `canAskCoordinator: Bool`; settable: `error: String?`, `coordinatorConvoID: String?`
    - `start()`, `stop()`, `pageDidAppear()`, `pageDidDisappear()`, `refresh() async`, `askCoordinator() async`

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/ViewModelTests/MissionsDashboardViewModelTests.swift`:

```swift
import XCTest
import MatronModels
import MatronChat
import MatronJournal
@testable import MatronViewModels

private final class FakeDashboardStore: MissionsDashboardStoreReading, @unchecked Sendable {
    let missions: AsyncStream<[Mission]>.Continuation
    let conversations: AsyncStream<[String: [MissionConversation]]>.Continuation
    let milestones: AsyncStream<[String: Milestone]>.Continuation
    let items: AsyncStream<[String: [TrackerItem]]>.Continuation
    let tocs: AsyncStream<[String: String]>.Continuation
    private let missionsValue: AsyncStream<[Mission]>
    private let conversationsValue: AsyncStream<[String: [MissionConversation]]>
    private let milestonesValue: AsyncStream<[String: Milestone]>
    private let itemsValue: AsyncStream<[String: [TrackerItem]]>
    private let tocsValue: AsyncStream<[String: String]>

    init() {
        (missionsValue, missions) = AsyncStream.makeStream()
        (conversationsValue, conversations) = AsyncStream.makeStream()
        (milestonesValue, milestones) = AsyncStream.makeStream()
        (itemsValue, items) = AsyncStream.makeStream()
        (tocsValue, tocs) = AsyncStream.makeStream()
    }
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missionsValue }
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]> { conversationsValue }
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]> { milestonesValue }
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]> { itemsValue }
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]> { tocsValue }
}

private final class FakeDashboardSync: MissionsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshes = 0
    private var _refetches: [String] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _gate = false
    private var _waiters: [CheckedContinuation<Void, Never>] = []
    private var _refreshOutcome: MissionsRefreshOutcome = .succeeded
    var supported: [Bool] = [true]

    var refreshes: Int { lock.withLock { _refreshes } }
    var refetches: [String] { lock.withLock { _refetches } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var gateDetails: Bool { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
    var refreshOutcome: MissionsRefreshOutcome {
        get { lock.withLock { _refreshOutcome } } set { lock.withLock { _refreshOutcome = newValue } }
    }
    func releaseWaiting() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { _waiters = [] }; return _waiters }
        waiters.forEach { $0.resume() }
    }

    func refresh() async -> MissionsRefreshOutcome { lock.withLock { _refreshes += 1; return _refreshOutcome } }
    func refreshMission(id: String) async -> MissionsRefreshOutcome {
        let gated = lock.withLock { () -> Bool in
            _refetches.append(id); _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight); return _gate
        }
        if gated { await withCheckedContinuation { c in lock.withLock { _waiters.append(c) } } }
        lock.withLock { _inFlight -= 1 }
        return .succeeded
    }
    func closeMission(id: String, summary: String) async throws -> Mission { fatalError("not used") }
    func supportedStream() async -> AsyncStream<Bool> {
        let values = supported
        return AsyncStream { c in for v in values { c.yield(v) }; c.finish() }
    }
}

private final class FakeRoster: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _results: [Result<[String: String], Error>] = [.success([:])]
    var calls: Int { lock.withLock { _calls } }
    /// Each call takes the next result; the last one repeats forever.
    func script(_ results: [Result<[String: String], Error>]) { lock.withLock { _results = results } }
    func fetch() async throws -> [String: String] {
        let result = lock.withLock { () -> Result<[String: String], Error> in
            _calls += 1
            return _results.count > 1 ? _results.removeFirst() : _results[0]
        }
        return try result.get()
    }
}

private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(convoID: String, body: String)] = []
    private var _error: Error?
    var sent: [(convoID: String, body: String)] { lock.withLock { _sent } }
    var error: Error? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    func send(_ convoID: String, _ body: String) async throws {
        if let error { throw error }
        lock.withLock { _sent.append((convoID, body)) }
    }
}

@MainActor
final class MissionsDashboardViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var store: FakeDashboardStore!
    private var sync: FakeDashboardSync!
    private var roster: FakeRoster!
    private var sender: SendRecorder!
    private var summaries: AsyncThrowingStream<[ChatSummary], Error>.Continuation!
    private var vm: MissionsDashboardViewModel!

    private func makeVM(rosterInterval: Duration = .seconds(60)) {
        store = FakeDashboardStore(); sync = FakeDashboardSync(); roster = FakeRoster(); sender = SendRecorder()
        let (stream, continuation) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        summaries = continuation
        let rosterFake: FakeRoster = self.roster, senderFake: SendRecorder = self.sender, fixedNow = now
        vm = MissionsDashboardViewModel(store: store, sync: sync, summaries: { stream },
                                        roster: { try await rosterFake.fetch() },
                                        send: { try await senderFake.send($0, $1) },
                                        rosterInterval: rosterInterval, now: { fixedNow })
    }

    override func tearDown() async throws {
        sync?.gateDetails = false
        sync?.releaseWaiting()
        vm?.stop()
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func mission(_ id: String, num: Int, needsYou: Int = 0, statusUpdatedAt: Date? = nil) -> Mission {
        Mission(id: id, num: num, title: "M\(num)", originConvoID: "c-origin-\(num)",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                needsYou: needsYou, conversationCount: 1,
                status: statusUpdatedAt == nil ? nil : "Status", statusBy: statusUpdatedAt == nil ? nil : .agent,
                statusUpdatedAt: statusUpdatedAt)
    }

    private func summary(_ id: String, state: String = "running") -> ChatSummary {
        ChatSummary(id: id, title: "Chat \(id)", bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
                    lastActivity: now.addingTimeInterval(-60), unreadCount: 0, sessionState: state)
    }

    // MARK: Streams

    func testStartPublishesCardsLooseAndClosedAndTheBadge() async {
        makeVM()
        vm.start()
        store.missions.yield([
            mission("ms_1", num: 61, needsYou: 2),
            Mission(id: "ms_0", num: 50, state: .closed, title: "Old", originConvoID: "c0", closedAt: now),
        ])
        store.conversations.yield(["ms_1": [MissionConversation(id: "c1", title: "", box: nil, state: "running")]])
        summaries.yield([summary("c1"), summary("c-loose")])
        await waitUntil { vm.cards.first?.sessions.first?.title == "Chat c1" && !vm.looseSessions.isEmpty }
        XCTAssertEqual(vm.cards.map(\.id), ["ms_1"])
        XCTAssertEqual(vm.closed.map(\.id), ["ms_0"])
        XCTAssertEqual(vm.looseSessions.map(\.id), ["c-loose"])
        XCTAssertEqual(vm.needsYouTotal, 2)
        XCTAssertEqual(sync.refreshes, 1, "start runs one list refresh")
        XCTAssertEqual(roster.calls, 0, "no roster until the page shows")
    }

    func testIsSupportedStartsUnknownThenFollowsTheSync() async {
        makeVM()
        XCTAssertNil(vm.isSupported)
        sync.supported = [true, false]
        vm.start()
        await waitUntil { vm.isSupported == false }
    }

    func testRefreshReportsAFailureAndASuccessClearsIt() async {
        makeVM()
        sync.refreshOutcome = .failed(MissionsRefreshFailure(message: "offline"))
        await vm.refresh()
        XCTAssertEqual(vm.error, "offline")
        sync.refreshOutcome = .succeeded
        await vm.refresh()
        XCTAssertNil(vm.error)
        XCTAssertEqual(roster.calls, 2, "a refresh also fetches the roster")
    }

    // MARK: Roster poll (spec §3.7)

    func testRosterPollsOnlyWhileThePageShows() async {
        makeVM(rosterInterval: .milliseconds(30))
        vm.start()
        vm.pageDidAppear()
        await waitUntil { roster.calls >= 3 }
        vm.pageDidDisappear()
        let settled = roster.calls
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(roster.calls, settled, "the poll stops with the page")
    }

    /// Review Focus: SwiftUI can deliver `onAppear` twice.
    func testAppearingTwiceRunsOneRosterLoop() async {
        makeVM(rosterInterval: .seconds(60))
        vm.start()
        vm.pageDidAppear()
        vm.pageDidAppear()
        await waitUntil { roster.calls >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(roster.calls, 1)
    }

    func testAFailedRosterFetchKeepsTheLastSummaries() async {
        makeVM(rosterInterval: .milliseconds(30))
        roster.script([.success(["c1": "Reviewing the parser"]), .failure(URLError(.notConnectedToInternet))])
        vm.start()
        store.missions.yield([mission("ms_1", num: 61)])
        store.conversations.yield(["ms_1": [MissionConversation(id: "c1", title: "", box: nil, state: "running")]])
        summaries.yield([summary("c1")])
        vm.pageDidAppear()
        await waitUntil { vm.cards.first?.sessions.first?.summary == "Reviewing the parser" }
        await waitUntil { roster.calls >= 3 }
        XCTAssertEqual(vm.cards.first?.sessions.first?.summary, "Reviewing the parser")
        XCTAssertNil(vm.error, "a failed roster fetch is not an error")
    }

    // MARK: Detail fan-out (spec §3.7)

    func testDetailRefreshOnAppearIsCappedAtFourInFlight() async {
        makeVM()
        sync.gateDetails = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.inFlight == 4 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches.count, 4, "the fifth waits for a slot")
        while sync.refetches.count < 6 {
            sync.releaseWaiting()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        sync.gateDetails = false
        sync.releaseWaiting()
        XCTAssertEqual(Set(sync.refetches), Set((1...6).map { "ms_\($0)" }))
        XCTAssertEqual(sync.maxInFlight, 4)
    }

    /// The page can show before the first missions snapshot lands (cold
    /// launch straight onto the tab): the fan-out waits for it.
    func testAppearingBeforeTheMissionsLandStillRefreshesTheirDetails() async {
        makeVM()
        vm.start()
        vm.pageDidAppear()
        store.missions.yield([mission("ms_1", num: 1), mission("ms_2", num: 2)])
        await waitUntil { Set(sync.refetches) == ["ms_1", "ms_2"] }
    }

    // MARK: Ask the Coordinator (spec §3.4)

    func testAskSendsTheExactMessageToTheCoordinatorAndShowsAsked() async {
        makeVM()
        vm.coordinatorConvoID = "c-coord"
        XCTAssertTrue(vm.canAskCoordinator)
        await vm.askCoordinator()
        XCTAssertEqual(sender.sent.map(\.convoID), ["c-coord"])
        XCTAssertEqual(sender.sent.map(\.body),
                       ["Refresh the status of every open mission from its latest milestones, sessions and open items."])
        XCTAssertEqual(vm.askedAt, now)
    }

    func testAskedClearsWhenAStatusLandsAfterIt() async {
        makeVM()
        vm.start()
        vm.coordinatorConvoID = "c-coord"
        await vm.askCoordinator()
        store.missions.yield([mission("ms_1", num: 1, statusUpdatedAt: now.addingTimeInterval(-600))])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.askedAt, now, "an older status is not the answer")
        store.missions.yield([mission("ms_1", num: 1, statusUpdatedAt: now.addingTimeInterval(5))])
        await waitUntil { vm.askedAt == nil }
    }

    func testAFailedAskSurfacesTheErrorAndIsNotMarkedAsked() async {
        makeVM()
        vm.coordinatorConvoID = "c-coord"
        sender.error = URLError(.cannotWriteToFile)
        await vm.askCoordinator()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.askedAt)
    }

    /// Review Focus: no Coordinator, or a blank cached id.
    func testAskIsHiddenAndInertWithoutACoordinator() async {
        makeVM()
        for id in [nil, "", "   "] as [String?] {
            vm.coordinatorConvoID = id
            XCTAssertFalse(vm.canAskCoordinator)
            await vm.askCoordinator()
        }
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertNil(vm.askedAt)
    }

    func testTheCoordinatorIsNeverALooseSession() async {
        makeVM()
        vm.start()
        summaries.yield([summary("c-coord"), summary("c-other")])
        await waitUntil { vm.looseSessions.count == 2 }
        vm.coordinatorConvoID = "c-coord"
        XCTAssertEqual(vm.looseSessions.map(\.id), ["c-other"])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter ViewModelTests.MissionsDashboardViewModelTests`
Expected: build FAILS — `cannot find type 'MissionsDashboardStoreReading' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift`:

```swift
import Foundation
import Observation
import MatronChat
import MatronModels
import MatronJournal

/// The store reads the dashboard needs, as a protocol so tests fake the
/// store (`JournalStore` conforms here, as with `MissionsStoreReading`).
public protocol MissionsDashboardStoreReading: Sendable {
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]>
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]>
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]>
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]>
}

extension JournalStore: MissionsDashboardStoreReading {}

/// Backs the Missions dashboard (spec 2026-09-28 §3.7). One per signed-in
/// session, like the list it replaces: `start()`/`stop()` follow the
/// session (the badge and `isSupported` are read while another tab shows),
/// `pageDidAppear()`/`pageDidDisappear()` follow the page and own the
/// roster poll and the per-mission detail refresh.
@MainActor @Observable
public final class MissionsDashboardViewModel {
    /// Spec §3.4, verbatim.
    public static let coordinatorRefreshMessage =
        "Refresh the status of every open mission from its latest milestones, sessions and open items."
    public static let maxDetailRefreshesInFlight = 4

    public private(set) var cards: [DashboardMissionCard] = []
    public private(set) var looseSessions: [DashboardSession] = []
    public private(set) var closed: [Mission] = []
    /// Tri-state exactly as `MissionsListViewModel.isSupported`: `nil`
    /// until known, and every consumer treats `nil` as supported.
    public private(set) var isSupported: Bool?
    public private(set) var isRefreshing = false
    public var error: String?
    /// When the Ask was sent (this session); cleared once a mission status
    /// newer than it lands.
    public private(set) var askedAt: Date?
    /// Mirrored from the host's cached Coordinator setting.
    public var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            inputs.coordinatorConvoID = coordinatorConvoID
            rebuild()
        }
    }

    public var canAskCoordinator: Bool { Self.trimmed(coordinatorConvoID) != nil }
    /// The tab / nav badge.
    public var needsYouTotal: Int { cards.reduce(0) { $0 + $1.needsYouCount } }

    @ObservationIgnored private var inputs = MissionsDashboardInputs()
    @ObservationIgnored private let store: any MissionsDashboardStoreReading
    @ObservationIgnored private let sync: any MissionsSyncing
    @ObservationIgnored private let summariesSource: @Sendable () -> AsyncThrowingStream<[ChatSummary], Error>
    @ObservationIgnored private let rosterSource: @Sendable () async throws -> [String: String]
    @ObservationIgnored private let send: @Sendable (String, String) async throws -> Void
    @ObservationIgnored private let rosterInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var rosterTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedMissions = false
    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var detailFanOutPending = false

    public init(store: any MissionsDashboardStoreReading, sync: any MissionsSyncing,
                summaries: @escaping @Sendable () -> AsyncThrowingStream<[ChatSummary], Error>,
                roster: @escaping @Sendable () async throws -> [String: String],
                send: @escaping @Sendable (_ convoID: String, _ body: String) async throws -> Void,
                rosterInterval: Duration = .seconds(60),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.sync = sync; self.summariesSource = summaries
        self.rosterSource = roster; self.send = send; self.rosterInterval = rosterInterval; self.now = now
    }

    // MARK: Session lifetime

    public func start() {
        stop()
        tasks.append(observe(store.missionsStream(state: nil)) { vm, missions in
            vm.inputs.missions = missions
            vm.clearAskedIfAnswered(missions)
            if !vm.hasLoadedMissions {
                vm.hasLoadedMissions = true
                if vm.detailFanOutPending { vm.startDetailFanOut() }
            }
        })
        tasks.append(observe(store.allMissionConversationsStream()) { $0.inputs.conversationsByMission = $1 })
        tasks.append(observe(store.latestMilestonesStream()) { $0.inputs.latestMilestones = $1 })
        tasks.append(observe(store.needsYouItemsByMissionStream()) { $0.inputs.needsYouItems = $1 })
        tasks.append(observe(store.latestSummaryTOCsStream()) { $0.inputs.tocs = $1 })
        let summaries = summariesSource()
        tasks.append(Task { [weak self] in
            do {
                for try await list in summaries {
                    guard let self, !Task.isCancelled else { return }
                    self.inputs.summaries = list
                    self.rebuild()
                }
            } catch {
                // The chat list surfaces its own stream errors; the
                // dashboard keeps the last list it had.
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let stream = await self.sync.supportedStream()
            for await supported in stream {
                guard !Task.isCancelled else { return }
                self.isSupported = supported
            }
        })
        listRefreshTask = Task { [weak self] in await self?.refreshList() }
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        listRefreshTask?.cancel(); listRefreshTask = nil
        pageDidDisappear()
        hasLoadedMissions = false
    }

    private func observe<Value: Sendable>(
        _ stream: AsyncStream<Value>,
        _ apply: @escaping @MainActor (MissionsDashboardViewModel, Value) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                apply(self, value)
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now())
        if cards != snapshot.cards { cards = snapshot.cards }
        if looseSessions != snapshot.looseSessions { looseSessions = snapshot.looseSessions }
        if closed != snapshot.closed { closed = snapshot.closed }
    }

    // MARK: Page lifetime

    /// Idempotent: a second `onAppear` never starts a second poll loop.
    public func pageDidAppear() {
        pageVisible = true
        guard rosterTask == nil else { return }
        let interval = rosterInterval
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let vm = self else { return }
                await vm.fetchRoster()
                try? await Task.sleep(for: interval)
            }
        }
        if hasLoadedMissions { startDetailFanOut() } else { detailFanOutPending = true }
    }

    public func pageDidDisappear() {
        pageVisible = false
        detailFanOutPending = false
        rosterTask?.cancel(); rosterTask = nil
        detailTask?.cancel(); detailTask = nil
    }

    private func startDetailFanOut() {
        detailFanOutPending = false
        guard pageVisible else { return }
        detailTask?.cancel()
        detailTask = Task { [weak self] in await self?.refreshOpenMissionDetails() }
    }

    // MARK: Fetches

    /// Pull-to-refresh / the Mac refresh button: list, roster, details.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshList()
        await fetchRoster()
        await refreshOpenMissionDetails()
    }

    private func refreshList() async {
        switch await sync.refresh() {
        case .succeeded: error = nil
        case .failed(let failure): error = failure.message
        case .unsupported, .stopped: break
        }
    }

    /// Spec §3.7: a failed fetch keeps the last good map and is not shown.
    private func fetchRoster() async {
        do {
            let map = try await rosterSource()
            guard !Task.isCancelled else { return }
            inputs.roster = map
            rebuild()
        } catch {
            // Deliberately silent (spec §3.7).
        }
    }

    private func refreshOpenMissionDetails() async {
        let ids = inputs.missions.filter { $0.state == .open }.map(\.id)
        let sync = self.sync
        await Self.forEach(ids, maxConcurrent: Self.maxDetailRefreshesInFlight) { id in
            _ = await sync.refreshMission(id: id)
        }
    }

    /// Runs `body` for every id with at most `maxConcurrent` in flight;
    /// stops handing out ids once cancelled.
    nonisolated static func forEach(_ ids: [String], maxConcurrent: Int,
                                    _ body: @escaping @Sendable (String) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let id = pending.next() else { break }
                group.addTask { await body(id) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let id = pending.next() { group.addTask { await body(id) } }
            }
        }
    }

    // MARK: Ask the Coordinator (spec §3.4)

    public func askCoordinator() async {
        guard let convoID = Self.trimmed(coordinatorConvoID) else { return }
        do {
            try await send(convoID, Self.coordinatorRefreshMessage)
            askedAt = now()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clearAskedIfAnswered(_ missions: [Mission]) {
        guard let askedAt else { return }
        let answered = missions.contains { $0.state == .open && ($0.statusUpdatedAt.map { $0 >= askedAt } ?? false) }
        if answered { self.askedAt = nil }
    }

    private static func trimmed(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.(MissionsDashboardViewModelTests|MissionsDashboardAssemblyTests|MissionsViewModelTests)'`
Expected: PASS, all three classes. If `swift test` sits at 0% CPU for over a minute, kill it and rerun.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift \
        MatronShared/Tests/ViewModelTests/MissionsDashboardViewModelTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions dashboard: view model — streams, roster poll, detail fan-out, Ask" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Card components (format helpers, pill, session row, mission card, loose card)

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardFormat.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/NeedsYouPill.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/DashboardSessionRow.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionCardView.swift`
- Create: `MatronShared/Sources/DesignSystem/Missions/LooseSessionCardView.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MissionsDashboardSnapshotTests.swift` (new) + recorded PNGs under `__Snapshots__/MissionsDashboardSnapshotTests/`

**Interfaces:**
- Consumes: Task 6 value types; `RelativeMinuteTimeView.format(_:now:)` (internal static, same module); `SessionTagText.run/room`; `BoxChip`; `MissionGlyph`; `ItemGlyph`; `NeedsYouBadge`.
- Produces: `MissionsDashboardFormat.relative(_:now:)`, `.statusByline(updatedAt:by:now:) -> String?`, `.askedLabel(askedAt:now:)`, `.statusText(_:) -> AttributedString`, `.moreSessions(_:) -> String`; `NeedsYouPill(count:)`; `DashboardStateDot(state:)`; `DashboardSessionRow(session:showsNeedsYou:)`; `MissionCardView(card:now:onAction:)`; `LooseSessionCardView(session:onOpen:)`; internal `DashboardCardChrome` modifier.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/MissionsDashboardSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class MissionsDashboardSnapshotTests: XCTestCase {
    /// Fixed so the relative ages in the snapshots never drift.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    static let fullMission = Mission(
        id: "ms_1", num: 61, title: "Missions dashboard", originConvoID: "c1",
        createdAt: ago(86_400), updatedAt: ago(600), lastMilestoneAt: ago(1_800),
        needsYou: 4, conversationCount: 5,
        status: "Journal PR merged and **deployed**; bridge tool in review. Waiting on Dan for the card copy.",
        statusBy: .agent, statusUpdatedAt: ago(720))

    static let fullCard = DashboardMissionCard(
        mission: fullMission,
        latestStep: DashboardLatestStep(num: 88, kind: .progress, title: "Bridge mission_status tool wired",
                                        body: "Tests green; PR #301 open.", createdAt: ago(1_800)),
        needsYouCount: 4,
        needsYouItems: [
            DashboardNeedsYouItem(id: "it_1", num: 90, kind: .question, title: "Red or orange for the pill?"),
            DashboardNeedsYouItem(id: "it_2", num: 91, kind: .decision, title: "Ship behind a flag?"),
            DashboardNeedsYouItem(id: "it_3", num: 92, kind: .question, title: "Grid minimum 340 pt OK?"),
        ],
        sessions: [
            DashboardSession(id: "c1", title: "Journal status column", state: .running, lastActivity: ago(60),
                             summary: "Running the route tests for the 600-char limit",
                             tag: SessionTagInputs(boxLetter: "D", boxName: "dev-2", sessionShort: "bc")),
            DashboardSession(id: "c2", title: "Bridge tool", state: .waiting, lastActivity: ago(900),
                             summary: "Waiting for review on PR #301"),
            DashboardSession(id: "c3", title: "Far box session", state: .done, summary: nil, boxName: "ci-3"),
        ],
        moreSessions: 2, anyRunning: true, lastActivity: ago(60))

    static let bareCard = DashboardMissionCard(
        mission: Mission(id: "ms_2", num: 62, title: "Rotate the relay keys", originConvoID: "c9",
                         createdAt: ago(3_600), updatedAt: ago(3_600), conversationCount: 1),
        sessions: [DashboardSession(id: "c9", title: "Key rotation", state: .waiting, lastActivity: ago(3_000))],
        lastActivity: ago(3_000))

    static let unassignedCard = DashboardMissionCard(
        mission: Mission(id: "ms_3", num: 63, title: "Audit the push relay", originConvoID: "c-coord",
                         createdAt: ago(7_200), updatedAt: ago(7_200)),
        attribution: "from Coordinator", lastActivity: ago(7_200))

    static let looseSession = DashboardSession(
        id: "c-loose", title: "Fix the flaky timeline test", state: .running, lastActivity: ago(120),
        summary: "Bisecting the gap test; two of five runs fail on CI only",
        tag: SessionTagInputs(boxLetter: "M", boxName: "mac", sessionShort: "qz"), needsYou: 1)

    // MARK: Pure

    func testRelativeAges() {
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(20), now: Self.now), "just now")
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(720), now: Self.now), "12m ago")
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(3 * 3_600), now: Self.now), "3h ago")
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(2 * 86_400), now: Self.now), "2d ago")
        XCTAssertTrue(MissionsDashboardFormat.relative(Self.ago(30 * 86_400), now: Self.now).hasPrefix("on "))
    }

    func testStatusBylineNamesTheWriter() {
        XCTAssertEqual(MissionsDashboardFormat.statusByline(updatedAt: Self.ago(720), by: .agent, now: Self.now),
                       "Updated 12m ago by an agent")
        XCTAssertEqual(MissionsDashboardFormat.statusByline(updatedAt: Self.ago(10), by: .user, now: Self.now),
                       "Updated just now by you")
        XCTAssertEqual(MissionsDashboardFormat.statusByline(updatedAt: Self.ago(720), by: nil, now: Self.now),
                       "Updated 12m ago")
        XCTAssertNil(MissionsDashboardFormat.statusByline(updatedAt: nil, by: .agent, now: Self.now))
    }

    func testAskedLabelAndMoreSessions() {
        XCTAssertEqual(MissionsDashboardFormat.askedLabel(askedAt: Self.ago(5), now: Self.now), "Asked just now")
        XCTAssertEqual(MissionsDashboardFormat.askedLabel(askedAt: Self.ago(300), now: Self.now), "Asked 5m ago")
        XCTAssertEqual(MissionsDashboardFormat.moreSessions(1), "+1 more session")
        XCTAssertEqual(MissionsDashboardFormat.moreSessions(3), "+3 more sessions")
    }

    /// Review Focus: `[label]: text` is a CommonMark link reference
    /// definition — block-level markdown renders it as nothing at all.
    func testStatusTextKeepsALabelColonLine() {
        let text = String(MissionsDashboardFormat.statusText("[blocked]: waiting on Dan").characters)
        XCTAssertTrue(text.contains("waiting on Dan"), "got \(text)")
        let bold = String(MissionsDashboardFormat.statusText("Bridge **deployed**").characters)
        XCTAssertEqual(bold, "Bridge deployed", "inline markdown is interpreted, not shown raw")
    }

    func testStateDotLabels() {
        XCTAssertEqual(DashboardStateDot.label(.running), "Running")
        XCTAssertEqual(DashboardStateDot.label(.waiting), "Waiting")
        XCTAssertEqual(DashboardStateDot.label(.done), "Done")
    }

    // MARK: Snapshots

    func testMissionCardFull() {
        assertVariants(of: MissionCardView(card: Self.fullCard, now: Self.now, onAction: { _ in })
            .frame(width: 380).padding(), named: "dashboard-card-full")
    }

    func testMissionCardWithoutStatusOrMilestones() {
        assertVariants(of: MissionCardView(card: Self.bareCard, now: Self.now, onAction: { _ in })
            .frame(width: 380).padding(), named: "dashboard-card-bare")
    }

    func testMissionCardUnassigned() {
        assertVariants(of: MissionCardView(card: Self.unassignedCard, now: Self.now, onAction: { _ in })
            .frame(width: 380).padding(), named: "dashboard-card-unassigned")
    }

    func testLooseSessionCard() {
        assertVariants(of: LooseSessionCardView(session: Self.looseSession, onOpen: {})
            .frame(width: 380).padding(), named: "dashboard-loose-card")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests`
Expected: build FAILS — `cannot find 'MissionsDashboardFormat' in scope`.

- [ ] **Step 3: Implement the format helpers and the pill**

Create `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardFormat.swift`:

```swift
import Foundation
import MatronModels

/// The dashboard's words (spec 2026-09-28 §3.2 / §3.4), pure so each is a
/// plain test and the cards never disagree.
public enum MissionsDashboardFormat {
    /// "just now", "12m ago", "3h ago", "2d ago", then "on <date>" —
    /// `RelativeMinuteTimeView`'s buckets, worded for a sentence.
    public static func relative(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let short = RelativeMinuteTimeView.format(date, now: now)
        return interval < 86_400 * 7 ? "\(short) ago" : "on \(short)"
    }

    /// "Updated 12m ago by an agent" / "… by you"; nil when unset.
    public static func statusByline(updatedAt: Date?, by author: ItemAuthor?, now: Date) -> String? {
        guard let updatedAt else { return nil }
        let who: String
        switch author {
        case .user: who = " by you"
        case .agent: who = " by an agent"
        case nil: who = ""
        }
        return "Updated \(relative(updatedAt, now: now))\(who)"
    }

    public static func askedLabel(askedAt: Date, now: Date) -> String {
        "Asked \(relative(askedAt, now: now))"
    }

    public static func moreSessions(_ count: Int) -> String {
        "+\(count) more session\(count == 1 ? "" : "s")"
    }

    /// Inline-only markdown: bold, code and links render, but nothing is
    /// read as a block — so `[blocked]: waiting on Dan` (a CommonMark link
    /// reference definition, which renders as nothing) stays visible.
    public static func statusText(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
```

Create `MatronShared/Sources/DesignSystem/Missions/NeedsYouPill.swift`:

```swift
import SwiftUI

/// The mission card's red "Needs you · n" pill (spec §3.2). Deliberately
/// not `NeedsYouBadge` (orange, a bare count on chat rows): on a card it is
/// the loudest thing, and says what it means. Draws nothing at zero.
public struct NeedsYouPill: View {
    private let count: Int
    public init(count: Int) { self.count = count }

    public var body: some View {
        if count > 0 {
            Text("Needs you · \(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red, in: Capsule())
                .fixedSize()
                .accessibilityLabel(count == 1 ? "1 item needs you" : "\(count) items need you")
        }
    }
}
```

- [ ] **Step 4: Implement the session row and the cards**

Create `MatronShared/Sources/DesignSystem/Missions/DashboardSessionRow.swift`:

```swift
import SwiftUI
import MatronModels

/// Running green / waiting amber / done grey (spec §3.2).
public struct DashboardStateDot: View {
    let state: DashboardSessionState
    public init(state: DashboardSessionState) { self.state = state }

    public var body: some View {
        Circle().fill(Self.color(state)).frame(width: 8, height: 8)
            .accessibilityLabel(Self.label(state))
    }

    public static func color(_ state: DashboardSessionState) -> Color {
        switch state {
        case .running: return .green
        case .waiting: return .orange
        case .done: return .gray
        }
    }

    public static func label(_ state: DashboardSessionState) -> String {
        switch state {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .done: return "Done"
        }
    }
}

/// One session: tag, title, state dot, then two lines of summary.
public struct DashboardSessionRow: View {
    let session: DashboardSession
    /// Loose-session cards show the chat's needs-you count; mission cards
    /// list the items themselves, so they don't.
    let showsNeedsYou: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(session: DashboardSession, showsNeedsYou: Bool = false) {
        self.session = session; self.showsNeedsYou = showsNeedsYou
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if let summary = session.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 6) {
            tag
            Text(session.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            if showsNeedsYou { NeedsYouBadge(count: session.needsYou) }
            DashboardStateDot(state: session.state)
        }
    }

    /// Room tag, then the single-box tag, then a bare box chip for a
    /// conversation this device never synced — the chat rows' fallback
    /// order. Never restyled (that would flatten the per-box colour).
    @ViewBuilder private var tag: some View {
        if let tagText { tagText.font(.caption) } else if let box = session.boxName { BoxChip(box) }
    }

    private var tagText: Text? {
        guard let tag = session.tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
    }
}
```

Create `MatronShared/Sources/DesignSystem/Missions/MissionCardView.swift`:

```swift
import SwiftUI
import MatronModels

/// Rounded card chrome shared by mission and loose-session cards.
struct DashboardCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }
}

/// One open mission (spec §3.2): header, status, latest step, needs-you
/// rows, sessions. Tapping the card's background opens the mission page;
/// the item and session rows are their own buttons. Split into small
/// computed views for CI's type-checker budget.
public struct MissionCardView: View {
    let card: DashboardMissionCard
    let now: Date
    let onAction: (MissionsDashboardAction) -> Void

    public init(card: DashboardMissionCard, now: Date, onAction: @escaping (MissionsDashboardAction) -> Void) {
        self.card = card; self.now = now; self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusBlock
            latestStepBlock
            needsYouBlock
            sessionsBlock
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DashboardCardChrome())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onAction(.openMission(card.id)) }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("missions.card.\(card.mission.num)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("#\(card.mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.mission.title).font(.headline).lineLimit(2)
                if let attribution = card.attribution {
                    Text(attribution).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            NeedsYouPill(count: card.needsYouCount)
        }
    }

    /// Nothing at all when unset — no placeholder (spec §3.2).
    @ViewBuilder private var statusBlock: some View {
        if let status = card.mission.status {
            VStack(alignment: .leading, spacing: 3) {
                Text(MissionsDashboardFormat.statusText(status)).font(.subheadline).lineLimit(4)
                if let byline = MissionsDashboardFormat.statusByline(updatedAt: card.mission.statusUpdatedAt,
                                                                     by: card.mission.statusBy, now: now) {
                    Text(byline).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var latestStepBlock: some View {
        if let step = card.latestStep {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: MissionGlyph.symbol(step.kind))
                        .font(.caption2).foregroundStyle(MissionGlyph.tint(step.kind))
                    Text(step.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(MissionsDashboardFormat.relative(step.createdAt, now: now))
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                }
                if !step.body.isEmpty {
                    Text(step.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            Text("No milestones yet").font(.subheadline).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var needsYouBlock: some View {
        if !card.needsYouItems.isEmpty || card.moreNeedsYou > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.needsYouItems) { item in
                    Button { onAction(.openItem(item.id)) } label: { needsYouRow(item) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
                if card.moreNeedsYou > 0 {
                    Button("+\(card.moreNeedsYou) more") { onAction(.openMission(card.id)) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func needsYouRow(_ item: DashboardNeedsYouItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ItemGlyph.symbol(item.kind)).font(.caption).foregroundStyle(ItemGlyph.tint(item.kind))
            Text("#\(item.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(item.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var sessionsBlock: some View {
        if !card.sessions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.sessions) { session in
                    Button { onAction(.openSession(session.id)) } label: { DashboardSessionRow(session: session) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
                if card.moreSessions > 0 {
                    Button(MissionsDashboardFormat.moreSessions(card.moreSessions)) { onAction(.openMission(card.id)) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

Create `MatronShared/Sources/DesignSystem/Missions/LooseSessionCardView.swift`:

```swift
import SwiftUI
import MatronModels

/// A compact card for a running session on no mission (spec §3.3).
public struct LooseSessionCardView: View {
    let session: DashboardSession
    let onOpen: () -> Void

    public init(session: DashboardSession, onOpen: @escaping () -> Void) {
        self.session = session; self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            DashboardSessionRow(session: session, showsNeedsYou: true)
                .padding(12)
                .modifier(DashboardCardChrome())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("missions.loose.\(session.id)")
    }
}
```

- [ ] **Step 5: Run the logic tests**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests`
Expected: PASS (all 9; the snapshot ones return early).

- [ ] **Step 6: Record and verify the snapshots**

```bash
cd /path/to/worktree && xcodegen generate && git checkout Matron/App/Info.plist
cd MatronShared && swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests   # first run records, FAILS
swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests                      # second run PASSES
cd .. && xcodegen generate && git checkout Matron/App/Info.plist
```

Expected on the second run: `Executed 9 tests, with 0 failures`. Open each new PNG in `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsDashboardSnapshotTests/` (light and dark) and check: red pill top-right on the full card; status wraps to at most 4 lines with "Updated 12m ago by an agent"; three needs-you rows then "+1 more"; three session rows with green/amber/grey dots and "+2 more sessions"; the bare card shows "No milestones yet" and no status line; the unassigned card shows "from Coordinator" and no sessions.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Missions/MissionsDashboardFormat.swift \
        MatronShared/Sources/DesignSystem/Missions/NeedsYouPill.swift \
        MatronShared/Sources/DesignSystem/Missions/DashboardSessionRow.swift \
        MatronShared/Sources/DesignSystem/Missions/MissionCardView.swift \
        MatronShared/Sources/DesignSystem/Missions/LooseSessionCardView.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/MissionsDashboardSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsDashboardSnapshotTests \
        Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions dashboard: mission and loose-session cards" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `MissionsDashboardView` (the page)

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardView.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MissionsDashboardSnapshotTests.swift` (append) + PNGs

**Interfaces:**
- Consumes: Task 8 views.
- Produces:
  - `MissionsDashboardView(model: Model, now: Date? = nil, onAction: (MissionsDashboardAction) -> Void, onRefresh: () async -> Void, onAsk: (() -> Void)? = nil)` — `now == nil` ticks live every minute; `onAsk` draws the Ask button in the Mac header (iOS hosts put it in the toolbar).
  - `MissionsDashboardView.Model(cards:looseSessions:closed:isSupported:isRefreshing:askedAt:)` with `isEmpty`.
  - `MissionsDashboardAskButton(action:)`, `static let title = "Ask the Coordinator to update"`.
  - `static let columns: [GridItem]` (adaptive, minimum 340).

- [ ] **Step 1: Write the failing tests**

Append to `MissionsDashboardSnapshotTests`:

```swift
    // MARK: The page

    private static func pageModel(askedAt: Date? = nil) -> MissionsDashboardView.Model {
        MissionsDashboardView.Model(
            cards: [fullCard, bareCard, unassignedCard],
            looseSessions: [looseSession],
            closed: [Mission(id: "ms_0", num: 55, state: .closed, title: "Items tracker", closeSummary: "Shipped.",
                             closedBy: .agent, originConvoID: "c0", closedAt: ago(9 * 86_400))],
            isSupported: true, isRefreshing: false, askedAt: askedAt)
    }

    private func page(_ model: MissionsDashboardView.Model) -> MissionsDashboardView {
        MissionsDashboardView(model: model, now: Self.now, onAction: { _ in }, onRefresh: {}, onAsk: {})
    }

    func testModelEmptyState() {
        let empty = MissionsDashboardView.Model(cards: [], looseSessions: [], closed: [], isSupported: true, isRefreshing: false)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(MissionsDashboardView.Model(cards: [], looseSessions: [Self.looseSession], closed: [],
                                                   isSupported: true, isRefreshing: false).isEmpty)
        XCTAssertEqual(MissionsDashboardAskButton.title, "Ask the Coordinator to update")
    }

    func testDashboardEmpty() {
        let empty = MissionsDashboardView.Model(cards: [], looseSessions: [], closed: [], isSupported: true, isRefreshing: false)
        assertVariants(of: page(empty).frame(width: 390, height: 360), named: "dashboard-empty")
    }

    func testDashboardPhoneWidth() {
        assertVariants(of: page(Self.pageModel(askedAt: Self.ago(120))).frame(width: 390, height: 1_400),
                       named: "dashboard-phone")
    }

    func testDashboardIPadWidth() {
        assertVariants(of: page(Self.pageModel()).frame(width: 820, height: 1_000), named: "dashboard-ipad")
    }

    func testDashboardMacWidth() {
        assertVariants(of: page(Self.pageModel()).frame(width: 1_140, height: 820), named: "dashboard-wide")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests`
Expected: build FAILS — `cannot find 'MissionsDashboardView' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardView.swift`:

```swift
import SwiftUI
import MatronModels

/// The Ask button (spec §3.4). A labelled icon: the Mac header shows the
/// title, the iOS toolbar the icon (iOS 26 truncates leading toolbar text).
public struct MissionsDashboardAskButton: View {
    public static let title = "Ask the Coordinator to update"
    let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) { Label(Self.title, systemImage: "arrow.triangle.2.circlepath") }
            .help(Self.title)
            .accessibilityIdentifier("missions.askCoordinator")
    }
}

/// The Missions dashboard (spec 2026-09-28 §3). A pure leaf view: hosts map
/// `MissionsDashboardViewModel` into `Model`, so this snapshots without a
/// view model — the same contract `MissionsListView` had.
public struct MissionsDashboardView: View {
    public struct Model: Equatable {
        public var cards: [DashboardMissionCard]
        public var looseSessions: [DashboardSession]
        public var closed: [Mission]
        /// `false` shows the unsupported message; hosts hide the entry too.
        public var isSupported: Bool
        public var isRefreshing: Bool
        /// When the Coordinator was last asked this session, if pending.
        public var askedAt: Date?
        public init(cards: [DashboardMissionCard], looseSessions: [DashboardSession], closed: [Mission],
                    isSupported: Bool, isRefreshing: Bool, askedAt: Date? = nil) {
            self.cards = cards; self.looseSessions = looseSessions; self.closed = closed
            self.isSupported = isSupported; self.isRefreshing = isRefreshing; self.askedAt = askedAt
        }
        public var isEmpty: Bool { cards.isEmpty && looseSessions.isEmpty && closed.isEmpty }
    }

    /// One column on an iPhone; two or three on iPad and Mac (spec §3.2).
    public static let columns = [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)]

    let model: Model
    let now: Date?
    let onAction: (MissionsDashboardAction) -> Void
    let onRefresh: () async -> Void
    let onAsk: (() -> Void)?
    @State private var showClosed = false

    public init(model: Model, now: Date? = nil, onAction: @escaping (MissionsDashboardAction) -> Void,
                onRefresh: @escaping () async -> Void, onAsk: (() -> Void)? = nil) {
        self.model = model; self.now = now; self.onAction = onAction; self.onRefresh = onRefresh; self.onAsk = onAsk
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macHeader
            Divider()
            #endif
            content
        }
        #if os(iOS)
        .background(MatronTimelineBackground())
        #endif
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            Text("Missions").font(.headline)
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
            if let onAsk { MissionsDashboardAskButton(action: onAsk).labelStyle(.titleAndIcon) }
            Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
    #endif

    @ViewBuilder private var content: some View {
        if !model.isSupported {
            placeholder(ContentUnavailableView("Missions not available", systemImage: "exclamationmark.triangle",
                                               description: Text("Update the journal server to use missions.")))
        } else if model.isEmpty {
            // Only an agent can start one (`mission_start`, spec #74).
            placeholder(ContentUnavailableView("No missions yet", systemImage: "flag.checkered",
                                               description: Text("An agent starts one with mission_start, then posts milestones as the work goes.")))
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            ticking { now in page(now: now) }
        }
        #if os(iOS)
        .refreshable { await onRefresh() }
        #endif
    }

    /// A fixed clock for snapshots, a minute-aligned tick otherwise, so
    /// "12m ago" keeps moving without the host re-rendering.
    @ViewBuilder private func ticking<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let now {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in content(context.date) }
        }
    }

    private func page(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let askedAt = model.askedAt { askedCaption(askedAt, now: now) }
            if !model.cards.isEmpty { cardGrid(now: now) }
            if !model.looseSessions.isEmpty { looseSection }
            if !model.closed.isEmpty { closedSection }
        }
        .padding(16)
    }

    private func askedCaption(_ askedAt: Date, now: Date) -> some View {
        Label(MissionsDashboardFormat.askedLabel(askedAt: askedAt, now: now), systemImage: "arrow.triangle.2.circlepath")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("missions.asked")
    }

    private func cardGrid(now: Date) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
            ForEach(model.cards) { card in MissionCardView(card: card, now: now, onAction: onAction) }
        }
    }

    private var looseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not on a mission").font(.headline)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(model.looseSessions) { session in
                    LooseSessionCardView(session: session) { onAction(.openSession(session.id)) }
                }
            }
        }
    }

    /// Collapsed by default, today's compact rows inside (spec §3.1).
    private var closedSection: some View {
        DisclosureGroup(isExpanded: $showClosed) {
            VStack(spacing: 0) {
                ForEach(model.closed) { mission in
                    Button { onAction(.openMission(mission.id)) } label: { MissionRowView(mission: mission) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                    Divider()
                }
            }
        } label: {
            Text("Closed (\(model.closed.count))").font(.headline)
        }
        .accessibilityIdentifier("missions.closedToggle")
    }

    /// Same shape as `MissionsListView.placeholder`: on iOS the empty states
    /// still answer pull-to-refresh.
    @ViewBuilder private func placeholder<Content: View>(_ content: Content) -> some View {
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

- [ ] **Step 4: Run the logic tests, then record the snapshots**

```bash
cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests
cd .. && xcodegen generate && git checkout Matron/App/Info.plist
cd MatronShared && swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests   # records the 4 new, FAILS
swift test --filter DesignSystemSnapshotTests.MissionsDashboardSnapshotTests                      # PASSES
cd .. && xcodegen generate && git checkout Matron/App/Info.plist
```

Expected on the last test run: `Executed 14 tests, with 0 failures`. Eyeball the PNGs: `dashboard-phone` one column with "Asked 2m ago" at the top; `dashboard-ipad` two columns; `dashboard-wide` three columns; "Not on a mission" below the cards; "Closed (1)" collapsed at the bottom; `dashboard-empty` shows "No missions yet" under a header with the Ask button titled "Ask the Coordinator to update".

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Missions/MissionsDashboardView.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/MissionsDashboardSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsDashboardSnapshotTests \
        Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions dashboard: the page — grid, loose sessions, closed, Ask" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Phase A verification and PR

**Files:** none new.

- [ ] **Step 1: Full shared suite**

Run: `cd MatronShared && swift test 2>&1 | tee /tmp/shared-test.log | grep -E "Executed [0-9]+ test|error:"`
Expected: the final `Executed N tests, with 0 failures` line (kill and rerun if it hangs at 0% CPU).

- [ ] **Step 2: Both apps build and their existing suites still pass**

```bash
set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-support xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -only-testing:MatronMacTests test 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"
```

Expected: iOS `Executed N tests, with 0 failures`. Mac: the only failures are the four known pre-existing snapshot tests (Global Constraints) — confirm by `grep -E "error: -\[" /tmp/mac-test.log`.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/missions-dashboard-shared
gh pr create --title "Missions dashboard: shared layer (status, roster, view model, cards)" --body "$(cat <<'EOF'
Phase A of docs/superpowers/plans/2026-09-28-missions-dashboard-apps.md (spec docs/superpowers/specs/2026-09-28-missions-dashboard-design.md §1 fields + §3).

- `Mission` status fields + GRDB v13
- `JournalAPI.roster()`
- Aggregate dashboard store reads
- `ChatSummary.sessionState`
- Item refetch → mission refetch (item markers carry no mission_id)
- `MissionsDashboardAssembly` + `MissionsDashboardViewModel`
- DesignSystem cards and page, light/dark snapshots

Nothing on screen changes until the hosts PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

# Phase B — iOS and Mac hosts (PR 2)

Branch from Phase A's merge commit: `git switch -c feat/missions-dashboard-hosts origin/main` once PR 1 is merged (or stack on `feat/missions-dashboard-shared` and retarget to `main` after it merges — `--delete-branch` on the parent closes stacked children).

### Task 11: iOS host

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (replace `makeMissionsListViewModel`, ~line 456)
- Modify: `Matron/App/AppShellNavigation.swift` (imports; new `handleDashboard(_:)` beside `pushMissionItem`)
- Modify: `Matron/App/AppShellView.swift` (`missionsVM` type/init, `.onChange(of: coordinatorConvoID)`, `originConvoIDs`, `missionsTab`)
- Rewrite: `Matron/Features/Missions/MissionsTabRoot.swift`
- Test: `MatronTests/MissionsDashboardNavigationTests.swift` (new)

**Interfaces:**
- Consumes: `MissionsDashboardViewModel` (Task 7), `MissionsDashboardView`, `MissionsDashboardAskButton` (Task 9), `MissionsDashboardAction` (Task 6), existing `pushMission(_:)`, `openConversation(fromMissions:)`, `pushMissionItem(_:)`.
- Produces: `AppDependencies.makeMissionsDashboardViewModel(for:) -> MissionsDashboardViewModel`; `AppShellNavigation.handleDashboard(_ action: MissionsDashboardAction)`.

- [ ] **Step 1: Write the failing navigation tests**

Create `MatronTests/MissionsDashboardNavigationTests.swift`:

```swift
import XCTest
import MatronModels
@testable import Matron

/// Spec 2026-09-28 §3.1 / §3.8: every dashboard tap routes through
/// `AppShellNavigation.handleDashboard`.
@MainActor
final class MissionsDashboardNavigationTests: XCTestCase {
    func testACardPushesTheMissionPageOnTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleDashboard(.openMission("ms_1"))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1"])
        nav.handleDashboard(.openMission("ms_1"))
        XCTAssertEqual(nav.missionsPath, ["mission/ms_1"], "a double tap never stacks two pages")
    }

    func testASessionOpensItsChatInConversations() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleDashboard(.openSession("c1"))
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    /// The Coordinator can be on a mission; its chat belongs to its tab.
    func testTheCoordinatorsSessionSelectsTheCoordinatorTab() {
        let nav = AppShellNavigation()
        nav.coordinatorConvoID = "c-coord"
        nav.tab = .missions
        nav.handleDashboard(.openSession("c-coord"))
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, [])
    }

    func testANeedsYouRowPushesTheItemOnTheMissionsStack() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleDashboard(.openItem("it_1"))
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["item/it_1"])
    }
}
```

- [ ] **Step 2: Regenerate and run to verify it fails**

Run: `xcodegen generate && git checkout Matron/App/Info.plist && set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/MissionsDashboardNavigationTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: `error: value of type 'AppShellNavigation' has no member 'handleDashboard'`, `** TEST FAILED **`.

- [ ] **Step 3: Implement the navigation and the factory**

In `AppShellNavigation.swift`, add `import MatronModels` below `import Observation`, and after `pushMissionItem(_:)`:

```swift
    /// Every Missions dashboard tap (spec 2026-09-28 §3.1): a card pushes
    /// its page, a session opens its chat the way a mission page's
    /// conversation row does, a needs-you row pushes the item — all on the
    /// Missions stack except the chat, which hands off to Conversations.
    func handleDashboard(_ action: MissionsDashboardAction) {
        switch action {
        case .openMission(let id): pushMission(id)
        case .openSession(let id): openConversation(fromMissions: id)
        case .openItem(let id): pushMissionItem(id)
        }
    }
```

Also update the `missionsSupported` doc comment: `MissionsListViewModel.isSupported` → `MissionsDashboardViewModel.isSupported`.

In `Matron/App/AppDependencies.swift`, replace `makeMissionsListViewModel(for:)` with:

```swift
    /// The Missions dashboard's view model — one per signed-in session,
    /// created and started by the shell (its badge shows on every tab),
    /// stopped when the shell leaves. The Ask button sends through the
    /// engine's offline outbox, like any composed message.
    @MainActor func makeMissionsDashboardViewModel(for session: UserSession) -> MissionsDashboardViewModel {
        let c = core(for: session)
        let api = c.api, engine = c.engine
        let chat = chatService(for: session)
        return MissionsDashboardViewModel(
            store: c.store, sync: c.missions,
            summaries: { chat.chatSummaries() },
            roster: { try await api.roster() },
            send: { convoID, body in
                try await engine.sendMessage(convoID: convoID, body: body, localID: UUID().uuidString)
            })
    }
```

- [ ] **Step 4: Rewrite the tab root**

Replace `Matron/Features/Missions/MissionsTabRoot.swift` with:

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Missions tab's root: the dashboard (spec 2026-09-28 §3.1). The view
/// model is owned by `AppShellView` (its badge is read while another tab
/// shows), so this view only maps it and reports taps. The roster poll and
/// the detail refresh run while this root is on screen.
struct MissionsTabRoot: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (MissionsDashboardAction) -> Void
    /// The Memories entry (decision #3948): a toolbar button on this root.
    var onOpenMemories: (() -> Void)? = nil

    var body: some View {
        MissionsDashboardView(model: model, onAction: onAction, onRefresh: { await viewModel.refresh() })
            .navigationTitle("Missions")
            .toolbar { toolbarContent }
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .alert("Missions", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var model: MissionsDashboardView.Model {
        MissionsDashboardView.Model(
            cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
            // Not proven false yet ⇒ supported (CodeRabbit #209, H2).
            isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
            askedAt: viewModel.askedAt)
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if viewModel.canAskCoordinator {
            ToolbarItem(placement: .primaryAction) {
                MissionsDashboardAskButton { Task { await viewModel.askCoordinator() } }
            }
        }
        if let onOpenMemories {
            ToolbarItem(placement: .primaryAction) {
                Button { onOpenMemories() } label: { Label("Memories", systemImage: "brain") }
                    .accessibilityIdentifier("missions.memories")
            }
        }
    }
}
```

- [ ] **Step 5: Swap the shell onto the dashboard**

In `AppShellView.swift`:

1. `@State private var missionsVM: MissionsListViewModel` → `@State private var missionsVM: MissionsDashboardViewModel`.
2. In `init`: `_missionsVM = State(initialValue: deps.makeMissionsDashboardViewModel(for: session))`.
3. In the `.onChange(of: coordinatorConvoID, initial: true)` closure add a third line: `missionsVM.coordinatorConvoID = id`.
4. `originConvoIDs` becomes (the dashboard derives its own attributions):

```swift
    /// Origins whose labels the Decisions rows draw — a typed property,
    /// not an inline expression, for CI's Xcode 16.4 type-checker.
    private var originConvoIDs: [String] {
        decisionsVM.awaitingYou.map(\.originConvoID)
    }
```

5. In `missionsTab`, replace the `MissionsTabRoot(...)` construction with:

```swift
            MissionsTabRoot(viewModel: missionsVM, onAction: { nav.handleDashboard($0) },
                            onOpenMemories: { nav.openMemories() })
```

`.badge(missionsVM.needsYouTotal)`, `missionsVM.isSupported`, `.task { missionsVM.start() }` and `.onDisappear { missionsVM.stop() }` keep compiling unchanged.

- [ ] **Step 6: Run to verify it passes**

Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: `Executed N tests, with 0 failures` (N includes the 4 new) and `** TEST SUCCEEDED **`.

Manual: run in the iPhone 17 simulator signed in to a journal with missions — the Missions tab shows cards; pull-to-refresh works; tapping a card pushes the mission page; a session opens its chat under Conversations; a needs-you row opens the item; the Ask icon appears only with a Coordinator set, and after a tap "Asked just now" shows above the cards.

- [ ] **Step 7: Commit**

```bash
git add Matron/App/AppDependencies.swift Matron/App/AppShellNavigation.swift Matron/App/AppShellView.swift \
        Matron/Features/Missions/MissionsTabRoot.swift MatronTests/MissionsDashboardNavigationTests.swift Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: the Missions tab is the dashboard" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Mac host

On Missions the sidebar collapses to the 72 pt nav column (as on the Coordinator page) and the dashboard fills the detail. The window's Back/Forward then have no sidebar toolbar room, so — exactly as on the Coordinator page — the sidebar toolbar gets `MacCoordinatorToolbarPlaceholder` and the chat header draws `MacCoordinatorPageHeaderCluster` (it already does whenever `props == nil` and `coordinatorPage` is set). The dashboard is `MacPlace(detail: .mission(id: nil))`, a mission page is `.mission(id:)`, so Back from a page returns to the dashboard with no `MacPlace` change. The page also gets an "All missions" link (the sidebar no longer lists missions). Picking the Missions nav entry keeps whatever it last showed (dashboard or a page), as today.

**Files:**
- Modify: `MatronMac/App/AppDependencies.swift` (replace `makeMissionsListViewModel`, ~line 392)
- Create: `MatronMac/Features/Missions/MacMissionsDashboard.swift`
- Delete: `MatronMac/Features/Missions/MacMissionsColumn.swift`
- Modify: `MatronMac/Features/Missions/MacMissionPage.swift`
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift`
- Modify: `MatronMacTests/MacCoordinatorPageTests.swift` (`test_sidebarWidths_collapseToTheNavColumnOnTheCoordinatorPage`)
- Test: `MatronMacTests/MacMissionsDashboardNavTests.swift` (new)

**Interfaces:**
- Consumes: `MissionsDashboardViewModel`, `MissionsDashboardView`, `MissionsDashboardAction`.
- Produces: `AppDependencies.makeMissionsDashboardViewModel(for:)` (Mac); `static func MacChatListView.showsNavColumnOnly(_ nav: MacNav) -> Bool`; `MacMissionPage.onShowDashboard: (() -> Void)?`.

- [ ] **Step 1: Write the failing tests**

Create `MatronMacTests/MacMissionsDashboardNavTests.swift`:

```swift
import XCTest
@testable import MatronMac

/// Spec 2026-09-28 §3.1: the Missions entry shows the dashboard full width.
@MainActor
final class MacMissionsDashboardNavTests: XCTestCase {
    func testMissionsCollapsesTheSidebarToTheNavColumnLikeTheCoordinator() {
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions))
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.coordinator))
        for nav in [MacNav.decisions, .conversations, .memories] {
            XCTAssertFalse(MacChatListView.showsNavColumnOnly(nav), "\(nav) keeps its list column")
        }
        let widths = MacChatListView.sidebarWidths(for: .missions)
        XCTAssertEqual(widths.min, MacNavColumn.width)
        XCTAssertEqual(widths.ideal, MacNavColumn.width)
        XCTAssertEqual(widths.max, MacNavColumn.width)
    }

    func testTheDashboardIsTheMissionsPlaceWithNoMission() {
        let place = MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: nil,
                                          selectedDecisionID: "it_1", paneRoute: .items(path: []),
                                          coordinatorConvoID: "c-coord")
        XCTAssertEqual(place, MacPlace(detail: .mission(id: nil)))
        XCTAssertTrue(MacChatListView.isRecordable(place, historyIsEmpty: true), "the dashboard is a place to go back to")
        XCTAssertNil(MacChatListView.detailChatID(nav: .missions, selectedSummaryID: "c1",
                                                  coordinatorConvoID: nil, isStaleRestore: false),
                     "the dashboard mounts no chat")
    }

    func testBackFromAMissionPageReturnsToTheDashboard() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .mission(id: nil)))
        history.visit(MacPlace(detail: .mission(id: "ms_1")))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .mission(id: nil)))
        XCTAssertEqual(history.goForward(), MacPlace(detail: .mission(id: "ms_1")))
    }

    /// A dashboard session tap goes through `showConversation`: the
    /// Coordinator's chat lands on its page, anything else under
    /// Conversations.
    func testASessionTapRoutesTheCoordinatorToItsPage() {
        XCTAssertEqual(MacChatListView.navForShowingConversation("c-coord", coordinatorConvoID: "c-coord"), .coordinator)
        XCTAssertEqual(MacChatListView.navForShowingConversation("c1", coordinatorConvoID: "c-coord"), .conversations)
    }
}
```

In `MatronMacTests/MacCoordinatorPageTests.swift`, `test_sidebarWidths_collapseToTheNavColumnOnTheCoordinatorPage`: change the loop to `for nav in [MacNav.decisions, .conversations] {` (Missions now collapses too; pinned in the new file).

- [ ] **Step 2: Regenerate and run to verify it fails**

Run: `xcodegen generate && git checkout Matron/App/Info.plist && env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-support xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -only-testing:MatronMacTests/MacMissionsDashboardNavTests test 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: `error: type 'MacChatListView' has no member 'showsNavColumnOnly'`, `** TEST FAILED **`.

- [ ] **Step 3: Factory, host view and the page's way back**

In `MatronMac/App/AppDependencies.swift`, replace `makeMissionsListViewModel(for:)` with the same body as iOS (Task 11 Step 3), doc comment included:

```swift
    /// The Missions dashboard's view model — one per signed-in session,
    /// created and started by the shell (its badge shows on every entry),
    /// stopped when the shell leaves. The Ask button sends through the
    /// engine's offline outbox, like any composed message.
    @MainActor func makeMissionsDashboardViewModel(for session: UserSession) -> MissionsDashboardViewModel {
        let c = core(for: session)
        let api = c.api, engine = c.engine
        let chat = chatService(for: session)
        return MissionsDashboardViewModel(
            store: c.store, sync: c.missions,
            summaries: { chat.chatSummaries() },
            roster: { try await api.roster() },
            send: { convoID, body in
                try await engine.sendMessage(convoID: convoID, body: body, localID: UUID().uuidString)
            })
    }
```

Create `MatronMac/Features/Missions/MacMissionsDashboard.swift`:

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Missions dashboard in the Mac detail, full width (spec 2026-09-28
/// §3.1). A thin mapper: the view model lives for the session on the shell
/// so the nav badge stays live while another entry shows; the roster poll
/// and detail refresh run while this is on screen.
struct MacMissionsDashboard: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (MissionsDashboardAction) -> Void

    var body: some View {
        MissionsDashboardView(model: model, onAction: onAction, onRefresh: { await viewModel.refresh() },
                              onAsk: askAction)
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .alert("Missions", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var model: MissionsDashboardView.Model {
        MissionsDashboardView.Model(
            cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
            isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
            askedAt: viewModel.askedAt)
    }

    /// Hidden with no Coordinator (spec §3.4).
    private var askAction: (() -> Void)? {
        guard viewModel.canAskCoordinator else { return nil }
        return { Task { await viewModel.askCoordinator() } }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })
    }
}
```

Delete the column: `git rm MatronMac/Features/Missions/MacMissionsColumn.swift`.

In `MacMissionPage.swift`, add a last stored property and the header branch:

```swift
    /// "All missions": back to the dashboard. The Mac sidebar no longer
    /// lists missions, so a page reached from the dashboard needs a visible
    /// way back beside the window's Back (spec 2026-09-28 §3.1).
    var onShowDashboard: (() -> Void)? = nil
```

and in `body`, extend the `if let backConvoID { … }` block with:

```swift
            } else if let onShowDashboard {
                HStack {
                    Button { onShowDashboard() } label: { Label("All missions", systemImage: "chevron.backward") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("missions.allMissions")
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
```

(The existing `if let backConvoID { … }` closes with `}` before `if let viewModel` — attach `else if` to it.)

- [ ] **Step 4: Wire `MacChatListView`**

All edits in `MatronMac/Features/ChatList/MacChatListView.swift`:

1. `@State private var missionsVM: MissionsListViewModel?` → `@State private var missionsVM: MissionsDashboardViewModel?` (update its doc comment: "The per-session Missions dashboard view model…").

2. Add beside `sidebarWidths(for:)`, and make `sidebarWidths` use it:

```swift
    /// Entries whose detail takes the full width: the sidebar is the 72 pt
    /// nav column alone. The Coordinator page (decision #2911) and the
    /// Missions dashboard (spec 2026-09-28 §3.1).
    static func showsNavColumnOnly(_ nav: MacNav) -> Bool {
        nav == .coordinator || nav == .missions
    }

    static func sidebarWidths(for nav: MacNav) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let column = MacNavColumn.width
        if showsNavColumnOnly(nav) { return (column, column, column) }
        return (260 + column, 400 + column, 600 + column)
    }
```

3. In `sidebarStack`'s `switch nav`, replace `case .missions: missionsColumn` with a fall-through to the Coordinator's collapse:

```swift
            case .coordinator, .missions:
                // Full-width detail: the list column collapses to the nav
                // column alone (the width modifier below shrinks it).
                Spacer(minLength: 0)
```

and delete the separate `case .coordinator:` arm and the `missionsColumn` property.

4. In `sidebarToolbar`, `if nav == .coordinator {` → `if Self.showsNavColumnOnly(nav) {` (doc comment: "…the Coordinator page's and the Missions dashboard's sidebar is the 72 pt nav column alone…").

5. `coordinatorPageChrome` — the header carries Back/Forward and New Chat on both full-width entries; Your requests stays Coordinator-only:

```swift
    private var coordinatorPageChrome: MacCoordinatorPageChrome? {
        guard Self.showsNavColumnOnly(nav) else { return nil }
        return MacCoordinatorPageChrome(navigation: navigationActions,
                                        newChat: { showingNewChat = true },
                                        requestsChatVM: nav == .coordinator ? coordinatorPageRequestsVM() : nil)
    }
```

6. `missionDetail` becomes:

```swift
    @ViewBuilder
    private var missionDetail: some View {
        if let id = selectedMissionID, let session {
            MacMissionPage(missionID: id, session: session, backConvoID: missionBackConvoID,
                           onBack: showConversation,
                           onOpenMilestone: openMilestone,
                           onOpenItem: { id in
                               // Missions has no stack of its own on the
                               // Mac; an item opens where every item opens.
                               showDecisionsItem(id, switchingNav: true)
                           },
                           onOpenConversation: showConversation,
                           onShowDashboard: showMissionsDashboard)
        } else if let missionsVM {
            MacMissionsDashboard(viewModel: missionsVM, onAction: handleDashboardAction)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Every dashboard tap (spec 2026-09-28 §3.1). A card is a sidebar-style
    /// pick (no "back to the conversation"); a session goes through
    /// `showConversation` like every "show me that chat"; an item opens
    /// where every item opens.
    private func handleDashboardAction(_ action: MissionsDashboardAction) {
        switch action {
        case .openMission(let id): pickMission(id)
        case .openSession(let id): showConversation(id)
        case .openItem(let id): showDecisionsItem(id, switchingNav: true)
        }
    }

    /// The page's "All missions": the dashboard is the Missions place with
    /// no mission, so this records a history entry like any move.
    private func showMissionsDashboard() {
        missionBackConvoID = nil
        selectedMissionID = nil
    }
```

Add `import MatronModels` at the top of the file if it is not already imported.

7. In the lifecycle `.task(id: session?.userID)` that builds the Missions VM, replace the factory call and seed the Coordinator:

```swift
                missionsVM?.stop()
                let vm = deps.makeMissionsDashboardViewModel(for: session)
                vm.coordinatorConvoID = coordinatorConvoID
                missionsVM = vm
                vm.start()
```

8. In `coordinatorChanged(to:)`, add as its first line: `missionsVM?.coordinatorConvoID = id`.

9. `originConvoIDs` drops the unassigned half:

```swift
    /// Origins whose labels the Decisions rows draw — a typed property,
    /// not an inline expression, for CI's Xcode 16.4 type-checker.
    private var originConvoIDs: [String] {
        decisionsVM?.awaitingYou.map(\.originConvoID) ?? []
    }
```

`navBadges(... missions: missionsVM?.needsYouTotal ?? 0 ...)`, `.onChange(of: missionsVM?.isSupported)` and `missionsVM?.stop()` compile unchanged.

- [ ] **Step 5: Run to verify it passes**

Run: `xcodegen generate && git checkout Matron/App/Info.plist && env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-support xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -only-testing:MatronMacTests test 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: the new class passes; the only failures are the four known pre-existing snapshot tests (check with `grep -E "error: -\[" /tmp/mac-test.log`).

Manual (Release build per the Mac install memo, or a Debug run with a COPY of the store): Missions shows the dashboard full width with the sidebar at the nav column; the title bar shows Back/Forward/New Chat and is 52 pt tall (not 32 pt); a card opens the page with "All missions"; Back returns to the dashboard; Refresh and Ask sit in the dashboard header; switching to Decisions restores the list column width.

- [ ] **Step 6: Commit**

```bash
git add MatronMac/App/AppDependencies.swift MatronMac/Features/Missions MatronMac/Features/ChatList/MacChatListView.swift \
        MatronMacTests/MacMissionsDashboardNavTests.swift MatronMacTests/MacCoordinatorPageTests.swift Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "mac: the Missions entry is the full-width dashboard" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Remove the old list view model and view

Nothing references `MissionsListViewModel`, `MissionsListView` or `makeMissionsListViewModel` after Tasks 11–12. The two protocols the mission page still needs live in the list VM's file, so they move first.

**Files:**
- Create: `MatronShared/Sources/ViewModels/MissionsStoreReading.swift`
- Delete: `MatronShared/Sources/ViewModels/MissionsListViewModel.swift`, `MatronShared/Sources/DesignSystem/Missions/MissionsListView.swift`
- Modify: `MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift`
- Delete PNGs: `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests/testMissionsList.*`, `testListWithUnassignedSection.*` (the `testMissionsList.*` glob also covers `testMissionsListUnsupported.*`)
- Modify comments: `MatronShared/Sources/Journal/JournalStore+Missions.swift:138`, `MatronShared/Sources/ViewModels/MissionDetailViewModel.swift:100`, `MatronShared/Sources/DesignSystem/Memories/MemoriesListView.swift:147`

**Interfaces:**
- Produces (moved verbatim, unchanged): `MissionsStoreReading`, `extension JournalStore: MissionsStoreReading` (with `sessionTag(s)` and the private `roomTags`), `MissionsSyncing`, `extension MissionsSync: MissionsSyncing {}`.

- [ ] **Step 1: Move the protocols**

Create `MatronShared/Sources/ViewModels/MissionsStoreReading.swift` with the imports `Foundation`, `MatronChat`, `MatronModels`, `MatronJournal`, then cut lines 7–100 of `MissionsListViewModel.swift` (from `/// The store reads the missions surfaces need…` through `extension MissionsSync: MissionsSyncing {}`) and paste them unchanged below the imports. Then delete the rest: `git rm MatronShared/Sources/ViewModels/MissionsListViewModel.swift MatronShared/Sources/DesignSystem/Missions/MissionsListView.swift`.

- [ ] **Step 2: Prune the tests that exercised only the list**

In `MissionsViewModelTests.swift` delete these functions (their behaviour is now pinned by `MissionsDashboardAssemblyTests` / `MissionsDashboardViewModelTests`): `testSectionsSortOpenByActivityAndClosedByCloseTime`, `testListPublishesSectionsBadgeAndSupport`, `testUnsupportedJournalFlipsTheFlagThatHidesTheTab`, `testIsSupportedStartsUnknown`, `testListRefreshClearsStaleErrorOnSuccess`, `testOpenMissionsWithoutAConversationAreUnassigned`, `testListPublishesUnassignedFirstAndCountsItsBadge`, `testAttributionNamesTheCoordinatorThenTheOrigin`. Keep the fakes and every `testDetail…`, `testClose…`, `testFailedDetailRefreshSetsError`, `testSessionTags…` test.

In `MissionsSnapshotTests.swift` delete `testListModelEmptyState`, `testMissionsList`, `testListModelCountsUnassignedAsContent`, `testListWithUnassignedSection`, `testMissionsListUnsupported`, and their PNGs:

```bash
git rm MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests/testMissionsList.* \
       MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests/testListWithUnassignedSection.*
```

- [ ] **Step 3: Update the stale comments**

- `JournalStore+Missions.swift` (~138): "The sole caller (`MissionsListViewModel.start()`) re-sorts everything through `sections(from:)`" → "The sole caller (`MissionsDashboardViewModel.start()`) re-sorts everything through `MissionsDashboardAssembly.assemble`".
- `MissionDetailViewModel.swift` (~100): "As in `MissionsListViewModel.refresh()`" → "As in `MissionsDashboardViewModel.refresh()`".
- `MemoriesListView.swift` (~147): "Same shape as `MissionsListView.placeholder`" → "Same shape as `MissionsDashboardView.placeholder`"; in `MissionsDashboardView.swift` change its own "Same shape as `MissionsListView.placeholder`" to "Same shape as `DecisionsListView.placeholder`".

Then prove nothing else names the old types:

Run: `grep -rn "MissionsListViewModel\|MissionsListView\b\|makeMissionsListViewModel\|MacMissionsColumn" --include=*.swift . | grep -v '/build/'`
Expected: no output.

- [ ] **Step 4: Regenerate and run everything**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
cd MatronShared && swift test 2>&1 | tee /tmp/shared-test.log | grep -E "Executed [0-9]+ test|error:"; cd ..
set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-support xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -only-testing:MatronMacTests test 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"
```

Expected: shared `Executed N tests, with 0 failures`; iOS `Executed N tests, with 0 failures` + `** TEST SUCCEEDED **`; Mac failures limited to the four known snapshot tests.

- [ ] **Step 5: Commit**

```bash
git add -A MatronShared/Sources/ViewModels MatronShared/Sources/DesignSystem MatronShared/Sources/Journal/JournalStore+Missions.swift \
        MatronShared/Tests/ViewModelTests/MissionsViewModelTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions: remove the list view model and view the dashboard replaced" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Phase B PR

- [ ] **Step 1: Confirm `Info.plist` is untouched and the tree is clean**

Run: `git status --short && git diff origin/main -- Matron/App/Info.plist`
Expected: nothing to commit; no Info.plist diff.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/missions-dashboard-hosts
gh pr create --title "Missions dashboard: iOS tab and Mac full-width page" --body "$(cat <<'EOF'
Phase B of docs/superpowers/plans/2026-09-28-missions-dashboard-apps.md (spec §3.1).

- iOS: the Missions tab root is the dashboard; taps route through `AppShellNavigation.handleDashboard`
- Mac: the Missions entry collapses the sidebar to the nav column and shows the dashboard full width; Back/Forward in the header as on the Coordinator page; "All missions" on the page
- Ask the Coordinator to update (iOS toolbar, Mac header), sent through the outbox
- Removes MissionsListViewModel / MissionsListView / MacMissionsColumn

Manual checks owed: iPhone tab (pull-to-refresh, taps, Ask), Mac title bar height (52 pt) and Back to the dashboard.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
