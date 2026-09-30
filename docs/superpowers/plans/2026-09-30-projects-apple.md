# Projects and multi-mission conversations — Apple apps (iOS + Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Missions tab into **Projects**: slim project cards over slim unfiled-mission rows with Quiet and Closed folds; add a project page (Mac two-column, iOS List); give the mission page a project chip, breadcrumb, "On it now / Earlier" conversations with sub-chats folded and a paged milestone list (plus the status card and needs-you section on iOS); and replace the conversation header's hidden title button with a chip naming the current mission plus "+n", opening a Current / Also on / Earlier list.

**Architecture:** Four stacked PRs. **PR 1 (shared data, Tasks 1–9)** adds the wire models, GRDB migration v14, the store reads, `JournalAPI+Projects`, the `ProjectsSync` actor (cloned from `MissionsSync`) and wires it into both apps' `JournalCore` — nothing on screen changes. **PR 2 (shared view models and views, Tasks 10–18)** adds the pure `ProjectsHomeAssembly`, projects inputs on `MissionsDashboardViewModel`, `ProjectDetailViewModel`, the `MissionDetailViewModel` additions, and every DesignSystem view with snapshots. **PR 3 (iOS, Tasks 19–22)** and **PR 4 (Mac, Tasks 23–27)** swap the hosts. An old journal (`GET /projects` → 404) keeps today's missions dashboard; `GET /conversations/:id/missions` → 404 keeps today's single-mission derivation.

**Tech Stack:** Swift 5.10 language mode, SwiftUI (iOS 17+/macOS 14+), GRDB 6 (`JournalStore`), XCTest, swift-snapshot-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-30-projects-and-mission-links-design.md` — apps are §2 and §6; the routes consumed are §3 (links) and §4 (projects); rollout §7. Mockups: `docs/superpowers/specs/2026-09-30-projects-assets/mockups/01…04-*.png`. The journal plan is written in parallel; this plan uses the route and field names exactly as the spec gives them.

## Global Constraints

- Wire fields, verbatim from the spec. Project rows: `id` (`pj_…`), `num`, `state` (`open`|`closed`), `title`, `body`, `status`, `status_by`, `status_updated_at`, `close_summary`, `closed_at`, `merged_into`, `origin_convo_id`, `created_by`, `created_at`, `updated_at`; `GET /projects` rows add `missions:{running, waiting, idle, quiet, closed}`, `needs_you`, `open_items`, `last_activity_at`. `GET /projects/:id` → `{project, missions:[list rows], needs_you:[items with mission_num], recent_milestones:[5], sessions_by_box:{box: n}}`. Mission rows gain `project_id`, `project_num`, `activity` (`running`|`waiting`|`quiet`|`idle`). `GET /missions/:id` conversation rows gain `current`, `joined_at`, `ended_at`, `how` (`origin`|`joined`|`spawned`|`inherited`|`backfill`), `parent_convo_id`, `subchat_count`; `?subchats=1` lists sub-chats. `GET /conversations/:id/missions` → `{missions:[{mission row…, current, active, joined_at, ended_at, how}]}`. Snapshot conversation rows gain `mission_id` (current) and `mission_count`. The `mission` marker gains actions `left` and `current_changed`; a project move is an `updated` marker with `project_changed: true`. All times are ms epoch. Decode leniently: an absent, null or unknown value reads as `nil`/default, never a dropped row.
- Writes the apps make: `POST /projects {title, body?}` with an `Idempotency-Key` header → 201 `{project}`; `POST /projects/:id/merge {into}`; `PATCH /missions/:id {project: id|null}` → `{mission}`. Nothing else (no project status/close from the apps).
- `GET /projects` is called **without** `state` (both states, like `GET /missions`); a 404 means "old journal" and the Projects entry falls back to today's missions dashboard.
- Activity (spec §2): the server's `activity` wins. With none (journal mid-rollout), a mission with needs-you > 0 is `waiting`; one whose newest of last milestone / status / update is over **7 days** old is `quiet`; otherwise `idle`. A mission with needs-you > 0 is never shown as quiet.
- Copy: nav/tab title **Projects** (⌘2, same position, badge = needs-you total). Home sections: `Projects` + `n open`; `Missions not in a project` + `n active`; folds `Quiet for over a week (n)` and `Closed (n)`. Card counts line e.g. `5 missions · 2 running · 2 waiting · 1 quiet · updated 11m ago`, or `6 missions · all quiet · last activity 12d ago`. No written status: `No written status yet — latest: “<title>” (<age>)`. Mission row second line: status, else `No status · last milestone <age>: “<title>”`, else `No status yet`. Mission page sections `On it now` / `Earlier`; header chip `#N <title>` + `+n`; menu/sheet sections `Current` / `Also on` / `Earlier`.
- The iOS mission page and the Mac mission page show the **latest 5** milestones first; `Show more (n)` adds 20.
- Run `xcodegen generate` after adding, renaming or deleting any file or folder (snapshot PNGs are project members), then `git checkout Matron/App/Info.plist` (xcodegen adds an unwanted audio entry).
- Shared tests: `cd MatronShared && swift test --filter <Target>.<Class>`; full suite `swift test --package-path MatronShared`. `swift test` can hang at 0% CPU — kill it and rerun. Snapshots record on first run (delete the PNG, run twice: first records and fails, second passes), then `xcodegen generate`. `MATRON_SKIP_SNAPSHOT_TESTS=1` skips snapshot assertions when a step only needs logic tests.
- **Mac tests ONLY with the store override as a real environment variable:** `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests` (append `/<Class>` to narrow). NEVER a trailing `KEY=value` argument (silently dropped) and never without the override — the test host can wipe the live journal store. Four Mac snapshot tests already fail locally on main and are not regressions: `MacNavColumn testBadge`, `MacNavColumn testNoBadge`, `MacItemsPane testPaneListPopulated`, `NewChatSheetCapacity testAgentPickerRowStates`.
- iOS tests on an **iPhone 17** simulator (there is no iPhone 16 here): `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/<Class> CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`. **Assert the `Executed N tests, with 0 failures` line with the expected N**; a grep|tail that shows no error is not a pass.
- Commits: `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "<subject>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Never `git config` anything (worktrees share `.git/config`).
- CI's type-checker budget is far smaller than local: keep SwiftUI bodies in small computed views / `@ViewBuilder` helpers; every new `switch` or branch in `MacChatListView` or `AppShellView` goes in a hoisted helper, never inline in `body`.
- iOS List/ScrollView `Button` labels inherit the accent tint — reset with `.foregroundStyle(Color.primary)`.
- Nothing under the Mac chat header accessory may add toolbar items.
- Internal identifiers stay: `MacNav.missions`, `MatronCommand.showMissions`, `AppTab.missions`, `AppShellNavigation.missionsPath`, `MissionsDashboardViewModel`. Only what the user sees is renamed (decision in this plan: renaming the enum cases would touch ~30 tests for no user-visible gain).

## Review Focus

- **A journal that predates projects or links** — `GET /projects` 404 must show today's missions dashboard under the Projects entry (not an empty page or an error), and `GET /conversations/:id/missions` 404 must leave the header chip on today's local derivation (origin → mission_conversation → milestone). Pinned in Task 8 (`testListNotFoundIsUnsupported`) and Task 5 (`testLegacyDerivationStandsInWhenNoLinksAreKnown`).
- **Opening a project that was merged away** (Back/Forward history, a stale `#N` link, the page open while the Coordinator merges) — the page must land on the target project, not "not on this device". Pinned in Task 12 (`testAMergedProjectRedirectsToItsTarget`, `testTheServerRedirectSwitchesTheStreams`).
- **Snapshot `mission_id: null` vs the key absent** — null means the conversation left its last mission (clear the pointer); absent means an old journal (leave it). Pinned in Task 4 (`testSnapshotMissionPointerNullClearsAbsentKeeps`).
- **A sub-chat whose parent is not on the mission** (the parent never joined; only the child inherited) — it must show as its own row, not vanish into a fold that is never drawn. Pinned in Task 10 (`testAnOrphanSubChatIsItsOwnRow`).
- **A mission filed in a project this device has not cached, or one that closed** — it must stay visible on the home screen as unfiled rather than disappear from every list. Pinned in Task 10 (`testAMissionInAnUnknownProjectStaysOnTheHomeScreen`).

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `MatronShared/Sources/Models/Project.swift` (new) | 1 | `MissionActivity`, `ProjectMissionCounts`, `Project` |
| `MatronShared/Sources/Models/Mission.swift` | 1 | `Mission.projectID/projectNum/activity`; `MissionConversation` link fields; `msDate` made internal |
| `MatronShared/Sources/Models/ConversationMissions.swift` (new) | 1 | `ConversationMissionLink`, `ConversationMissionSections`, `ConversationMissions` |
| `MatronShared/Sources/Events/MissionMarkerEvent.swift`, `DesignSystem/Missions/MilestoneCard.swift` | 2 | `left`, `current_changed`, `project_changed`; notice text |
| `MatronShared/Sources/Journal/JournalStore.swift` | 3, 4 | Migration v14; `ConversationRecord.missionID/missionCount`; `ConvoSummaryDTO` fields; `upsertSummary` |
| `MatronShared/Sources/Journal/JournalStore+Projects.swift` (new) | 3, 6 | `ProjectRecord`; project reads/writes |
| `MatronShared/Sources/Journal/JournalStore+Missions.swift` | 3, 5, 6 | Record columns; conversation links; `missionsStream(convoID:)` replaces `missionIDStream`; `upsertMilestones` |
| `MatronShared/Sources/Journal/JournalAPI.swift` | 4 | Snapshot decode of `mission_id` / `mission_count` |
| `MatronShared/Sources/Journal/JournalAPI+Projects.swift` (new) | 7 | `ProjectsProviding`, decoders, the six calls |
| `MatronShared/Sources/Journal/JournalAPI+Missions.swift` | 7 | `?subchats=1` on the detail GET |
| `MatronShared/Sources/Journal/ProjectsSync.swift` (new) | 8 | Refresh on connect / marker; project detail; watched-conversation links; writes |
| `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift` | 9, 19, 23 | `JournalCore.projects`; VM factories |
| `MatronShared/Sources/Models/ProjectsHome.swift` (new) | 10 | `ProjectCard`, `MissionRowModel`, `ProjectsHomeSnapshot`, `ProjectsHomeAction`, `ProjectPageModel` |
| `MatronShared/Sources/Models/MissionConversationGroups.swift` (new) | 10 | On it now / Earlier grouping with sub-chats folded |
| `MatronShared/Sources/ViewModels/ProjectsHomeAssembly.swift` (new) | 10 | Pure home/page rules |
| `MatronShared/Sources/ViewModels/ProjectsStoreReading.swift` (new) | 11 | `ProjectsStoreReading`, `ProjectsSyncing` |
| `MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift`, `MissionsDashboardAssembly.swift` | 11 | Projects inputs, `home`, `projectsSupported`, create/move, visibility hooks |
| `MatronShared/Sources/ViewModels/ProjectDetailViewModel.swift` (new) | 12 | The project page's state, redirect, merge, add mission |
| `MatronShared/Sources/ViewModels/MissionDetailViewModel.swift` | 13 | `project`, `moveTargets`, `conversationGroups`, `moveToProject` |
| `MatronShared/Sources/DesignSystem/Projects/*` (new folder) | 14–18 | Format, glyphs, card, home, new-project sheet, project page, session chips, header chip, missions list, loose section |
| `MatronShared/Sources/DesignSystem/Missions/MissionRowView.swift` | 14 | Rewritten slim row |
| `MatronShared/Sources/DesignSystem/Missions/MissionDetailView.swift` | 17 | Status, needs-you, conversations, 5 milestones, project chip, move |
| `Matron/App/ProjectRoute.swift` (new), `PathPrefixedRoute.swift`, `AppShellNavigation.swift`, `AppShellView.swift` | 19, 20, 22 | Tab rename, project routes, host swap |
| `Matron/Features/Projects/*` (new folder) | 20 | `ProjectsTabRoot` (replaces `MissionsTabRoot`), `ProjectDetailHost` |
| `Matron/Features/Missions/MissionDetailHost.swift` | 20 | Project chip, move |
| `Matron/Features/Chat/ChatView.swift` | 5, 21 | Header chip + sheet; title inert |
| `Matron/Features/ChatList/ChatListView.swift` | 22 | "Not on a mission" section |
| `MatronMac/Features/Nav/*` | 23 | Title/symbol; `MacPlace.Detail.project` |
| `MatronMac/Features/ChatList/MacChatListView.swift` | 23–27 | `selectedProjectID`, hoisted detail helpers, `showProject`, loose section |
| `MatronMac/Features/Projects/*` (new folder) | 24 | `MacProjectsHome`, `MacProjectPage` |
| `MatronMac/Features/Missions/*` | 25 | Breadcrumb, chip, move, conversations card, 5 milestones, no latest-step or sessions card |
| `MatronMac/Features/Chat/MacChatToolbar.swift`, `MacChatView.swift`, `MacChatHeaderAccessory.swift` | 5, 26 | Header mission chip + menu |

## PR split

| PR | Branch | Tasks | Stacks on |
|---|---|---|---|
| 1 — shared data layer | `feat/projects-data` | 1–9 | `main` |
| 2 — view models + shared views | `feat/projects-shared-ui` | 10–18 | PR 1 |
| 3 — iOS | `feat/projects-ios` | 19–22 | PR 2 |
| 4 — Mac | `feat/projects-mac` | 23–27 | PR 2 (independent of PR 3) |

Work in a fresh worktree per PR (`git worktree add ../matron-apple-projects-<n> -b <branch> <base>`); never branch-switch a tree someone else is using. When a parent PR merges with `--delete-branch`, retarget its children to `main` first.

---

# PR 1 — shared data layer

### Task 1: Wire models — `Project`, mission project/activity, conversation link fields

**Files:**
- Create: `MatronShared/Sources/Models/Project.swift`
- Create: `MatronShared/Sources/Models/ConversationMissions.swift`
- Modify: `MatronShared/Sources/Models/Mission.swift` (`msDate`, `Mission`, `MissionConversation`)
- Test: `MatronShared/Tests/JournalTests/ProjectModelTests.swift` (new), `MatronShared/Tests/JournalTests/MissionModelTests.swift`

**Interfaces:**
- Produces (MatronModels):
  - `enum MissionActivity: String { running, waiting, idle, quiet }` with `sortRank: Int` (0…3) and `label: String`.
  - `struct ProjectMissionCounts { running, waiting, idle, quiet, closed: Int; open: Int; init(json: [String: Any]?) }`.
  - `struct Project: Identifiable` — `id, num, state: MissionState, title, body, status: String?, statusBy: ItemAuthor?, statusUpdatedAt: Date?, closeSummary: String?, closedAt: Date?, mergedInto: String?, originConvoID: String?, createdBy: ItemAuthor, createdAt, updatedAt, missions: ProjectMissionCounts, needsYou: Int, openItems: Int, lastActivityAt: Date?`; `init?(json:)`; `label`.
  - `Mission.projectID: String?`, `Mission.projectNum: Int?`, `Mission.activity: MissionActivity?` — memberwise init gains trailing `projectID: String? = nil, projectNum: Int? = nil, activity: MissionActivity? = nil`.
  - `MissionConversation` gains `isCurrent: Bool`, `joinedAt: Date?`, `endedAt: Date?`, `how: String?`, `parentConvoID: String?`, `subchatCount: Int`, computed `isActive` — init gains those as trailing defaulted params.
  - `struct ConversationMissionLink: Identifiable { mission, isCurrent, isActive, joinedAt, endedAt, how; isEarlier; init?(json:) }`.
  - `struct ConversationMissionSections { current, alsoOn, earlier; headline; othersCount(snapshotCount:) }`.
  - `struct ConversationMissions: Equatable { links: [ConversationMissionLink]; snapshotCount: Int?; sections }`.
  - `func msDate(_:) -> Date?` becomes module-internal (was `private`).

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/ProjectModelTests.swift`:

```swift
import XCTest
import MatronModels
@testable import MatronJournal

final class ProjectModelTests: XCTestCase {
    static let projectJSON: [String: Any] = [
        "id": "pj_1", "num": 4000, "state": "open", "title": "Promo launch",
        "body": "New promo site, blog and leavers' page.",
        "status": "Launch Wed 7 Oct, 07:00.", "status_by": "agent", "status_updated_at": 1_700_000_006_000,
        "close_summary": NSNull(), "closed_at": NSNull(), "merged_into": NSNull(),
        "origin_convo_id": "c-coord", "created_by": "agent",
        "created_at": 1_700_000_000_000, "updated_at": 1_700_000_006_000,
        "missions": ["running": 2, "waiting": 2, "idle": 0, "quiet": 1, "closed": 3],
        "needs_you": 6, "open_items": 37, "last_activity_at": 1_700_000_005_000,
    ]

    func testProjectDecodesAListRow() throws {
        let p = try XCTUnwrap(Project(json: Self.projectJSON))
        XCTAssertEqual(p.id, "pj_1"); XCTAssertEqual(p.num, 4000); XCTAssertEqual(p.state, .open)
        XCTAssertEqual(p.title, "Promo launch")
        XCTAssertEqual(p.status, "Launch Wed 7 Oct, 07:00.")
        XCTAssertEqual(p.statusBy, .agent)
        XCTAssertEqual(p.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_006))
        XCTAssertEqual(p.missions, ProjectMissionCounts(running: 2, waiting: 2, idle: 0, quiet: 1, closed: 3))
        XCTAssertEqual(p.missions.open, 5)
        XCTAssertEqual(p.needsYou, 6); XCTAssertEqual(p.openItems, 37)
        XCTAssertEqual(p.lastActivityAt, Date(timeIntervalSince1970: 1_700_000_005))
        XCTAssertEqual(p.label, "#4000 Promo launch")
    }

    /// A `POST /projects` / `GET /projects/:id` project carries no counts;
    /// a sieved status is null; a merged one names its target.
    func testProjectToleratesMissingCountsAndReadsMergedInto() throws {
        var json = Self.projectJSON
        json.removeValue(forKey: "missions"); json.removeValue(forKey: "needs_you")
        json["status"] = NSNull(); json["state"] = "closed"; json["merged_into"] = "pj_2"
        let p = try XCTUnwrap(Project(json: json))
        XCTAssertEqual(p.missions, ProjectMissionCounts())
        XCTAssertEqual(p.needsYou, 0)
        XCTAssertNil(p.status)
        XCTAssertEqual(p.state, .closed)
        XCTAssertEqual(p.mergedInto, "pj_2")
    }

    func testProjectWithoutItsIdentityIsDropped() {
        XCTAssertNil(Project(json: ["id": "pj_x", "title": "No number"]))
    }

    func testConversationMissionLinkDecodesAFlatRow() throws {
        var row = MissionModelTests.missionJSON
        row["current"] = true; row["active"] = true; row["joined_at"] = 1_700_000_001_000; row["how"] = "origin"
        let link = try XCTUnwrap(ConversationMissionLink(json: row))
        XCTAssertEqual(link.mission.id, "ms_a1")
        XCTAssertTrue(link.isCurrent); XCTAssertTrue(link.isActive); XCTAssertFalse(link.isEarlier)
        XCTAssertEqual(link.joinedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(link.how, "origin")
    }

    /// No `active` key: an `ended_at` decides it. A closed mission's link is
    /// history even while it is still active (spec §3, "Closing a mission").
    func testLinkActivityFallsBackToEndedAtAndClosedMissionsAreEarlier() throws {
        var ended = MissionModelTests.missionJSON
        ended["ended_at"] = 1_700_000_009_000
        XCTAssertFalse(try XCTUnwrap(ConversationMissionLink(json: ended)).isActive)
        var closed = MissionModelTests.missionJSON
        closed["state"] = "closed"
        let link = try XCTUnwrap(ConversationMissionLink(json: closed))
        XCTAssertTrue(link.isActive)
        XCTAssertTrue(link.isEarlier)
    }

    private func link(_ id: String, num: Int, current: Bool = false, joined: TimeInterval? = nil,
                      ended: TimeInterval? = nil, closed: Bool = false) -> ConversationMissionLink {
        ConversationMissionLink(
            mission: Mission(id: id, num: num, state: closed ? .closed : .open, title: "M\(num)", originConvoID: "c1"),
            isCurrent: current, isActive: ended == nil,
            joinedAt: joined.map { Date(timeIntervalSince1970: $0) },
            endedAt: ended.map { Date(timeIntervalSince1970: $0) })
    }

    func testSectionsSplitCurrentAlsoOnAndEarlier() {
        let sections = ConversationMissionSections([
            link("ms_old", num: 1, joined: 1, ended: 5),
            link("ms_also", num: 2, joined: 10),
            link("ms_cur", num: 3, current: true, joined: 20),
            link("ms_newer_also", num: 4, joined: 30),
            link("ms_done", num: 5, joined: 2, closed: true),
        ])
        XCTAssertEqual(sections.current?.id, "ms_cur")
        XCTAssertEqual(sections.alsoOn.map(\.id), ["ms_newer_also", "ms_also"], "newest joined first")
        XCTAssertEqual(Set(sections.earlier.map(\.id)), ["ms_old", "ms_done"])
        XCTAssertEqual(sections.headline?.id, "ms_cur")
        XCTAssertEqual(sections.othersCount(snapshotCount: nil), 4)
    }

    /// Before `GET /conversations/:id/missions` lands, only the snapshot's
    /// `mission_count` knows the others exist.
    func testOthersCountTrustsALargerSnapshotCount() {
        let sections = ConversationMissionSections([link("ms_cur", num: 3, current: true, joined: 20)])
        XCTAssertEqual(sections.othersCount(snapshotCount: 3), 2)
        XCTAssertEqual(sections.othersCount(snapshotCount: nil), 0)
        XCTAssertEqual(ConversationMissionSections([]).othersCount(snapshotCount: 2), 0,
                       "no headline, no chip, no count")
    }

    /// No current link (the conversation left its last mission): the chip
    /// names the newest active one, else the newest earlier one.
    func testHeadlineFallsBackWhenNothingIsCurrent() {
        let sections = ConversationMissionSections([link("ms_old", num: 1, joined: 1, ended: 5)])
        XCTAssertNil(sections.current)
        XCTAssertEqual(sections.headline?.id, "ms_old")
    }
}
```

Append to `MissionModelTests`:

```swift
    func testMissionDecodesProjectAndActivity() throws {
        var json = Self.missionJSON
        json["project_id"] = "pj_1"; json["project_num"] = 4000; json["activity"] = "waiting"
        let m = try XCTUnwrap(Mission(json: json))
        XCTAssertEqual(m.projectID, "pj_1"); XCTAssertEqual(m.projectNum, 4000); XCTAssertEqual(m.activity, .waiting)

        var odd = Self.missionJSON
        odd["project_id"] = NSNull(); odd["activity"] = "asleep"
        let o = try XCTUnwrap(Mission(json: odd), "an unknown activity must not drop the row")
        XCTAssertNil(o.projectID); XCTAssertNil(o.projectNum); XCTAssertNil(o.activity)
    }

    func testMissionConversationDecodesLinkFields() throws {
        let c = try XCTUnwrap(MissionConversation(json: [
            "id": "c1:sub:a", "title": "child", "box": "greg", "state": "done",
            "current": false, "joined_at": 1_700_000_001_000, "ended_at": 1_700_000_002_000,
            "how": "inherited", "parent_convo_id": "c1", "subchat_count": 0,
        ]))
        XCTAssertFalse(c.isCurrent); XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.joinedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(c.endedAt, Date(timeIntervalSince1970: 1_700_000_002))
        XCTAssertEqual(c.how, "inherited"); XCTAssertEqual(c.parentConvoID, "c1")

        let old = try XCTUnwrap(MissionConversation(json: ["id": "c2", "title": "T", "state": "running"]))
        XCTAssertTrue(old.isActive, "an old journal's row has no ended_at: active")
        XCTAssertFalse(old.isCurrent); XCTAssertEqual(old.subchatCount, 0)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.(ProjectModelTests|MissionModelTests)'`
Expected: build FAILS — `cannot find 'Project' in scope`, `value of type 'Mission' has no member 'projectID'`.

- [ ] **Step 3: Implement `Project.swift`**

In `Mission.swift`, change `private func msDate(_ v: Any?) -> Date?` to `func msDate(_ v: Any?) -> Date?` (module-internal, so `Project.swift` and `ConversationMissions.swift` share it). Then create `MatronShared/Sources/Models/Project.swift`:

```swift
import Foundation

/// A mission's live state, computed by the journal (spec 2026-09-30 §2):
/// running — a linked conversation is running; waiting — one is waiting or
/// items await the user; quiet — nothing for 7 days; idle — none of those.
public enum MissionActivity: String, Codable, Sendable, CaseIterable {
    case running, waiting, idle, quiet

    /// Running first, quiet last — the row and card ordering.
    public var sortRank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .idle: return 2
        case .quiet: return 3
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        case .quiet: return "Quiet"
        }
    }
}

/// `GET /projects` rows' `missions` object. Zero everywhere else (a created
/// or detail project carries none).
public struct ProjectMissionCounts: Equatable, Hashable, Sendable {
    public var running: Int, waiting: Int, idle: Int, quiet: Int, closed: Int
    public init(running: Int = 0, waiting: Int = 0, idle: Int = 0, quiet: Int = 0, closed: Int = 0) {
        self.running = running; self.waiting = waiting; self.idle = idle; self.quiet = quiet; self.closed = closed
    }
    public init(json: [String: Any]?) {
        func n(_ key: String) -> Int { (json?[key] as? NSNumber)?.intValue ?? 0 }
        self.init(running: n("running"), waiting: n("waiting"), idle: n("idle"), quiet: n("quiet"), closed: n("closed"))
    }
    /// Every mission that is not closed.
    public var open: Int { running + waiting + idle + quiet }
}

/// A project groups missions (spec 2026-09-30 §4). Numbered from the same
/// per-user counter as items, missions and milestones, so `#N` names it.
/// A mission belongs to at most one project.
public struct Project: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    /// `open` | `closed` — the same two values as a mission's.
    public let state: MissionState
    public let title: String
    public let body: String
    /// The Coordinator's paragraph. `nil` when unset or sieved.
    public let status: String?
    public let statusBy: ItemAuthor?
    public let statusUpdatedAt: Date?
    public let closeSummary: String?
    public let closedAt: Date?
    /// Set when a merge closed this project: the project its missions moved to.
    public let mergedInto: String?
    public let originConvoID: String?
    public let createdBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date
    // List-row aggregates; zero / nil elsewhere.
    public let missions: ProjectMissionCounts
    public let needsYou: Int
    public let openItems: Int
    public let lastActivityAt: Date?

    public init(id: String, num: Int, state: MissionState = .open, title: String, body: String = "",
                status: String? = nil, statusBy: ItemAuthor? = nil, statusUpdatedAt: Date? = nil,
                closeSummary: String? = nil, closedAt: Date? = nil, mergedInto: String? = nil,
                originConvoID: String? = nil, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                missions: ProjectMissionCounts = ProjectMissionCounts(), needsYou: Int = 0, openItems: Int = 0,
                lastActivityAt: Date? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body
        self.status = status; self.statusBy = statusBy; self.statusUpdatedAt = statusUpdatedAt
        self.closeSummary = closeSummary; self.closedAt = closedAt; self.mergedInto = mergedInto
        self.originConvoID = originConvoID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.missions = missions; self.needsYou = needsYou; self.openItems = openItems
        self.lastActivityAt = lastActivityAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let state = (json["state"] as? String).flatMap(MissionState.init(rawValue:)),
              let title = json["title"] as? String,
              let createdAt = msDate(json["created_at"]), let updatedAt = msDate(json["updated_at"])
        else { return nil }
        self.init(
            id: id, num: num, state: state, title: title, body: json["body"] as? String ?? "",
            status: (json["status"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            statusBy: (json["status_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
            statusUpdatedAt: msDate(json["status_updated_at"]),
            closeSummary: json["close_summary"] as? String, closedAt: msDate(json["closed_at"]),
            mergedInto: json["merged_into"] as? String, originConvoID: json["origin_convo_id"] as? String,
            createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
            createdAt: createdAt, updatedAt: updatedAt,
            missions: ProjectMissionCounts(json: json["missions"] as? [String: Any]),
            needsYou: (json["needs_you"] as? NSNumber)?.intValue ?? 0,
            openItems: (json["open_items"] as? NSNumber)?.intValue ?? 0,
            lastActivityAt: msDate(json["last_activity_at"]))
    }

    public var label: String { "#\(num) \(title)" }
}
```

- [ ] **Step 4: Extend `Mission` and `MissionConversation`**

In `Mission`, add after `public let statusUpdatedAt: Date?`:

```swift
    /// The project this mission is filed in (spec 2026-09-30 §4), or nil.
    public let projectID: String?
    /// That project's `#N`, for a chip when the project isn't cached.
    public let projectNum: Int?
    /// The journal's activity state (§2). `nil` from a journal that
    /// predates it — `ProjectsHomeAssembly.activity` derives one then.
    public let activity: MissionActivity?
```

Extend the memberwise init's tail and body:

```swift
                status: String? = nil, statusBy: ItemAuthor? = nil, statusUpdatedAt: Date? = nil,
                projectID: String? = nil, projectNum: Int? = nil, activity: MissionActivity? = nil) {
        // …existing assignments unchanged…
        self.status = status; self.statusBy = statusBy; self.statusUpdatedAt = statusUpdatedAt
        self.projectID = projectID; self.projectNum = projectNum; self.activity = activity
    }
```

In `init?(json:)`, replace the final `statusUpdatedAt: msDate(json["status_updated_at"]))` with:

```swift
            statusUpdatedAt: msDate(json["status_updated_at"]),
            projectID: (json["project_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            projectNum: (json["project_num"] as? NSNumber)?.intValue,
            activity: (json["activity"] as? String).flatMap(MissionActivity.init(rawValue:)))
```

Replace `MissionConversation` entirely:

```swift
/// A conversation linked to a mission, as `GET /missions/:id` returns it.
/// Not a `ChatSummary`: it carries only what the mission page shows, and its
/// rows can name conversations this device has never synced. The link
/// fields (spec 2026-09-30 §3) are absent from an older journal: such a row
/// reads as an active, non-current link with no dates.
public struct MissionConversation: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let box: String?
    public let state: String
    public let isCurrent: Bool
    public let joinedAt: Date?
    /// `nil` while the link is active.
    public let endedAt: Date?
    /// `origin` | `joined` | `spawned` | `inherited` | `backfill`.
    public let how: String?
    public let parentConvoID: String?
    /// Sub-chats folded into this row by the journal.
    public let subchatCount: Int

    public var isActive: Bool { endedAt == nil }

    public init(id: String, title: String, box: String?, state: String, isCurrent: Bool = false,
                joinedAt: Date? = nil, endedAt: Date? = nil, how: String? = nil,
                parentConvoID: String? = nil, subchatCount: Int = 0) {
        self.id = id; self.title = title; self.box = box; self.state = state; self.isCurrent = isCurrent
        self.joinedAt = joinedAt; self.endedAt = endedAt; self.how = how
        self.parentConvoID = parentConvoID; self.subchatCount = subchatCount
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", box: json["box"] as? String,
                  state: json["state"] as? String ?? "", isCurrent: json["current"] as? Bool ?? false,
                  joinedAt: msDate(json["joined_at"]), endedAt: msDate(json["ended_at"]),
                  how: json["how"] as? String, parentConvoID: json["parent_convo_id"] as? String,
                  subchatCount: (json["subchat_count"] as? NSNumber)?.intValue ?? 0)
    }
}
```

- [ ] **Step 5: Implement `ConversationMissions.swift`**

```swift
import Foundation

/// One mission a conversation has touched (spec 2026-09-30 §3), as
/// `GET /conversations/:id/missions` returns it — the mission row itself
/// plus the link's own fields.
public struct ConversationMissionLink: Identifiable, Equatable, Hashable, Sendable {
    public let mission: Mission
    /// Where `milestone_post` goes by default. At most one link is current.
    public let isCurrent: Bool
    public let isActive: Bool
    public let joinedAt: Date?
    public let endedAt: Date?
    public let how: String?

    public var id: String { mission.id }
    /// History: an ended link, or any link to a closed mission.
    public var isEarlier: Bool { !isActive || mission.state == .closed }

    public init(mission: Mission, isCurrent: Bool = false, isActive: Bool = true,
                joinedAt: Date? = nil, endedAt: Date? = nil, how: String? = nil) {
        self.mission = mission; self.isCurrent = isCurrent; self.isActive = isActive
        self.joinedAt = joinedAt; self.endedAt = endedAt; self.how = how
    }

    /// The spec spreads the mission row flat into each element; a nested
    /// `mission` object is accepted too, so either journal shape decodes.
    public init?(json: [String: Any]) {
        let row = (json["mission"] as? [String: Any]) ?? json
        guard let mission = Mission(json: row) else { return nil }
        let ended = msDate(json["ended_at"])
        self.init(mission: mission, isCurrent: json["current"] as? Bool ?? false,
                  isActive: json["active"] as? Bool ?? (ended == nil),
                  joinedAt: msDate(json["joined_at"]), endedAt: ended, how: json["how"] as? String)
    }
}

/// The header's Current / Also on / Earlier split.
public struct ConversationMissionSections: Equatable, Sendable {
    public let current: ConversationMissionLink?
    /// Active links to open missions other than the current one, newest joined first.
    public let alsoOn: [ConversationMissionLink]
    /// Ended links and links to closed missions, most recently ended first.
    public let earlier: [ConversationMissionLink]

    public init(_ links: [ConversationMissionLink]) {
        let live = links.filter { !$0.isEarlier }
        let current = live.first(where: \.isCurrent)
        self.current = current
        alsoOn = live.filter { $0.id != current?.id }
            .sorted { ($0.joinedAt ?? .distantPast) > ($1.joinedAt ?? .distantPast) }
        earlier = links.filter(\.isEarlier).sorted {
            ($0.endedAt ?? $0.mission.closedAt ?? .distantPast) > ($1.endedAt ?? $1.mission.closedAt ?? .distantPast)
        }
    }

    public var isEmpty: Bool { current == nil && alsoOn.isEmpty && earlier.isEmpty }

    /// What the chip names: the current mission, else the newest active,
    /// else the most recent earlier one.
    public var headline: ConversationMissionLink? { current ?? alsoOn.first ?? earlier.first }

    /// The chip's "+n": every other mission this conversation touched.
    /// `snapshotCount` (the snapshot's `mission_count`) wins when larger —
    /// the links may not have been fetched yet.
    public func othersCount(snapshotCount: Int?) -> Int {
        guard headline != nil else { return 0 }
        let known = (current == nil ? 0 : 1) + alsoOn.count + earlier.count
        return max(0, max(known, snapshotCount ?? 0) - 1)
    }
}

/// What `JournalStore.missionsStream(convoID:)` yields.
public struct ConversationMissions: Equatable, Sendable {
    public var links: [ConversationMissionLink]
    public var snapshotCount: Int?
    public init(links: [ConversationMissionLink] = [], snapshotCount: Int? = nil) {
        self.links = links; self.snapshotCount = snapshotCount
    }
    public var sections: ConversationMissionSections { ConversationMissionSections(links) }
    public var othersCount: Int { sections.othersCount(snapshotCount: snapshotCount) }
}
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(ProjectModelTests|MissionModelTests|MissionsAPITests|JournalStoreMissionsTests)'`
Expected: PASS, every test in the four classes.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Models/Project.swift MatronShared/Sources/Models/ConversationMissions.swift \
        MatronShared/Sources/Models/Mission.swift \
        MatronShared/Tests/JournalTests/ProjectModelTests.swift MatronShared/Tests/JournalTests/MissionModelTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: wire models for projects, mission activity and conversation links" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `mission` marker actions `left` / `current_changed` and `project_changed`

**Files:**
- Modify: `MatronShared/Sources/Events/MissionMarkerEvent.swift`
- Modify: `MatronShared/Sources/DesignSystem/Missions/MilestoneCard.swift` (`MissionNotice.text`)
- Test: `MatronShared/Tests/EventsTests/MissionMarkerEventTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift`

**Interfaces:**
- Produces: `MissionMarkerEvent.Action.left`, `.currentChanged` (raw `current_changed`); `MissionMarkerEvent.projectChanged: Bool` (init gains trailing `projectChanged: Bool = false`).

Without this, `MissionMarkerEvent.parse` returns `nil` for the two new actions, so `MissionsSync`/`ProjectsSync` never hear them and the transcript drops the notice.

- [ ] **Step 1: Write the failing tests**

Append to `MissionMarkerEventTests`:

```swift
    func testParsesLeftCurrentChangedAndProjectChanged() throws {
        let left = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 61, "action": "left", "by": "agent"]))
        XCTAssertEqual(left.action, .left)
        let current = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 61, "action": "current_changed", "by": "agent"]))
        XCTAssertEqual(current.action, .currentChanged)
        let moved = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 61, "action": "updated", "by": "user", "project_changed": true]))
        XCTAssertTrue(moved.projectChanged)
        let renamed = try XCTUnwrap(MissionMarkerEvent.parse(payload: [
            "mission_id": "ms_1", "num": 61, "action": "updated", "by": "agent"]))
        XCTAssertFalse(renamed.projectChanged)
    }
```

Append to `MissionsSnapshotTests.testMissionNoticeText()` (inside the function, after the last assertion):

```swift
        let left = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Promo", action: .left, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: left), "🏁 Left mission #61 · Promo")
        let now = MissionMarkerEvent(missionID: "ms_1", num: 61, title: nil, action: .currentChanged, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: now), "🏁 Now on mission #61")
        let moved = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Promo", action: .updated, by: .user,
                                       projectChanged: true)
        XCTAssertEqual(MissionNotice.text(for: moved), "🏁 Mission #61 · Promo changed project")
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'EventsTests.MissionMarkerEventTests'`
Expected: build FAILS — `type 'MissionMarkerEvent.Action' has no member 'left'`.

- [ ] **Step 3: Implement**

In `MissionMarkerEvent`:

```swift
    public enum Action: String, Sendable {
        case created, joined, updated, closed, left
        case currentChanged = "current_changed"
    }
    // …existing stored properties…
    /// On an `updated` marker: the mission moved into, out of or between
    /// projects (spec 2026-09-30 §4.2), rather than being renamed.
    public let projectChanged: Bool

    public init(missionID: String, num: Int, title: String? = nil, action: Action,
                by: ItemAuthor = .agent, openItemNums: [Int] = [], projectChanged: Bool = false) {
        self.missionID = missionID; self.num = num; self.title = title
        self.action = action; self.by = by; self.openItemNums = openItemNums
        self.projectChanged = projectChanged
    }
```

In `parse(payload:)`, pass `projectChanged: payload["project_changed"] as? Bool ?? false` as the final argument.

In `MissionNotice.text(for:)`, replace the `switch`:

```swift
        switch marker.action {
        case .created: return "🏁 Mission #\(marker.num) started\(named)"
        case .joined:  return "🏁 Joined mission #\(marker.num)\(named)"
        case .left:    return "🏁 Left mission #\(marker.num)\(named)"
        case .currentChanged: return "🏁 Now on mission #\(marker.num)\(named)"
        case .updated:
            return marker.projectChanged
                ? "🏁 Mission #\(marker.num)\(named) changed project"
                : "🏁 Mission #\(marker.num) renamed\(named)"
        case .closed:
            guard !marker.openItemNums.isEmpty else { return "🏁 Mission #\(marker.num) closed\(named)" }
            return "🏁 Mission #\(marker.num)\(named) closed over " + marker.openItemNums.map { "#\($0)" }.joined(separator: ", ")
        }
```

Run `grep -rn "switch .*\.action" MatronShared/Sources Matron MatronMac --include=*.swift` and add the two cases to any other exhaustive `switch` over `MissionMarkerEvent.Action` it finds (none are expected besides `MissionNotice`).

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'EventsTests.MissionMarkerEventTests' && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'DesignSystemSnapshotTests.MissionsSnapshotTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Events/MissionMarkerEvent.swift MatronShared/Sources/DesignSystem/Missions/MilestoneCard.swift \
        MatronShared/Tests/EventsTests/MissionMarkerEventTests.swift MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions: parse left / current_changed / project_changed markers" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Migration v14 and the records

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (after `v13`, ~line 640; `ConversationRecord`; `wipe()` is untouched — it calls `wipeMissionTables`)
- Modify: `MatronShared/Sources/Journal/JournalStore+Missions.swift` (`MissionRecord`, `MissionConversationRecord`, `wipeMissionTables`)
- Create: `MatronShared/Sources/Journal/JournalStore+Projects.swift` (`ProjectRecord` only; reads come in Task 6)
- Test: `MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift` (new)

**Interfaces:**
- Consumes: Task 1's `Project`, `Mission.projectID/projectNum/activity`, `MissionConversation` link fields.
- Produces:
  - Table `project` (columns below); `mission.project_id`, `mission.project_num`, `mission.activity`; `mission_conversation.joined_at`, `ended_at`, `how`, `is_current`, `parent_convo_id`, `subchat_count`; `conversation.mission_id`, `conversation.mission_count`.
  - `ProjectRecord: Codable, FetchableRecord, PersistableRecord` with `init(_ p: Project)`, `var project: Project`, `var sessionsByBoxJson: String?`.
  - `ConversationRecord.missionID: String?`, `ConversationRecord.missionCount: Int?` (declared last, defaulted `nil`).

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift`:

```swift
import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreProjectsTests: XCTestCase {
    func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    static func project(_ id: String, num: Int, state: MissionState = .open, title: String? = nil,
                        needsYou: Int = 0, lastActivity: TimeInterval? = 10, mergedInto: String? = nil) -> Project {
        Project(id: id, num: num, state: state, title: title ?? "P\(num)", body: "goal",
                status: "Going well.", statusBy: .agent, statusUpdatedAt: Date(timeIntervalSince1970: 9),
                mergedInto: mergedInto, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                missions: ProjectMissionCounts(running: 1, waiting: 2, idle: 0, quiet: 1, closed: 4),
                needsYou: needsYou, openItems: 7, lastActivityAt: lastActivity.map { Date(timeIntervalSince1970: $0) })
    }

    /// v14 is additive: a cache at v13 keeps every row and gains NULL
    /// columns plus the empty `project` table.
    func testV14MigratesUpFromV13() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "v13")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
                VALUES('ms_1', 61, 'open', 'Existing', 'c1', 'agent', 1, 2);
                INSERT INTO mission_conversation(mission_id, convo_id, title, box, state)
                VALUES('ms_1', 'c1', 'Session', 'dev-2', 'running');
                """)
        }
        try JournalStore.migrator().migrate(queue)
        try queue.read { db in
            let mission = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT title, project_id, project_num, activity FROM mission"))
            XCTAssertEqual(mission["title"], "Existing")
            XCTAssertNil(mission["project_id"] as String?)
            XCTAssertNil(mission["activity"] as String?)
            let link = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT title, joined_at, ended_at, how, is_current, parent_convo_id, subchat_count FROM mission_conversation
                """))
            XCTAssertEqual(link["title"], "Session")
            XCTAssertNil(link["ended_at"] as Int64?)
            XCTAssertNil(link["is_current"] as Bool?)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project"), 0)
            let convoCols = try db.columns(in: "conversation").map(\.name)
            XCTAssertTrue(convoCols.contains("mission_id"))
            XCTAssertTrue(convoCols.contains("mission_count"))
        }
    }

    func testProjectRecordRoundTrips() throws {
        let store = try makeStore()
        let p = Self.project("pj_1", num: 4000, needsYou: 6, mergedInto: "pj_2")
        try store.dbQueue.write { db in try ProjectRecord(p).insert(db) }
        let back = try store.dbQueue.read { db in try ProjectRecord.fetchOne(db, key: "pj_1")?.project }
        XCTAssertEqual(back, p)
    }

    func testMissionAndLinkColumnsRoundTrip() throws {
        let store = try makeStore()
        let mission = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1",
                              createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                              projectID: "pj_1", projectNum: 4000, activity: .quiet)
        try store.upsertMissions([mission])
        XCTAssertEqual(try store.mission(id: "ms_1"), mission)
        let link = MissionConversation(id: "c1", title: "S", box: "greg", state: "running", isCurrent: true,
                                       joinedAt: Date(timeIntervalSince1970: 3), endedAt: nil, how: "origin",
                                       parentConvoID: nil, subchatCount: 6)
        try store.replaceMissionConversations(missionID: "ms_1", [link])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1"), [link])
    }

    func testWipeMissionsClearsProjects() throws {
        let store = try makeStore()
        try store.dbQueue.write { db in try ProjectRecord(Self.project("pj_1", num: 1)).insert(db) }
        try store.wipeMissions()
        XCTAssertEqual(try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") }, 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.JournalStoreProjectsTests'`
Expected: build FAILS — `cannot find 'ProjectRecord' in scope`.

- [ ] **Step 3: Add migration v14**

In `JournalStore.migrator()`, directly after the `v13` registration and before `return migrator`:

```swift
        // v14: projects and conversation↔mission links (spec 2026-09-30
        // §3, §4, §6). Additive. No backfill and no watermark to clear:
        // `GET /missions` and `GET /projects` are full refreshes on every
        // connect, a mission page's detail GET refills its link columns,
        // and the next snapshot fills `conversation.mission_id`.
        migrator.registerMigration("v14") { db in
            try db.create(table: "project", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("num", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("status", .text)
                t.column("status_by", .text)
                t.column("status_updated_at", .integer)
                t.column("close_summary", .text)
                t.column("closed_at", .integer)
                t.column("merged_into", .text)
                t.column("origin_convo_id", .text)
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("missions_running", .integer).notNull().defaults(to: 0)
                t.column("missions_waiting", .integer).notNull().defaults(to: 0)
                t.column("missions_idle", .integer).notNull().defaults(to: 0)
                t.column("missions_quiet", .integer).notNull().defaults(to: 0)
                t.column("missions_closed", .integer).notNull().defaults(to: 0)
                t.column("needs_you", .integer).notNull().defaults(to: 0)
                t.column("open_items", .integer).notNull().defaults(to: 0)
                t.column("last_activity_at", .integer)
                t.column("sessions_by_box_json", .text)
            }
            try Self.addColumnIfMissing(db, table: "mission", column: "project_id", .text)
            try Self.addColumnIfMissing(db, table: "mission", column: "project_num", .integer)
            try Self.addColumnIfMissing(db, table: "mission", column: "activity", .text)
            try db.create(index: "mission_project", on: "mission", columns: ["project_id", "state"], options: .ifNotExists)
            try Self.addColumnIfMissing(db, table: "mission_conversation", column: "joined_at", .integer)
            try Self.addColumnIfMissing(db, table: "mission_conversation", column: "ended_at", .integer)
            try Self.addColumnIfMissing(db, table: "mission_conversation", column: "how", .text)
            try Self.addColumnIfMissing(db, table: "mission_conversation", column: "is_current", .boolean)
            try Self.addColumnIfMissing(db, table: "mission_conversation", column: "parent_convo_id", .text)
            try Self.addColumnIfMissing(db, table: "mission_conversation", column: "subchat_count", .integer)
            try db.create(index: "mission_conversation_convo", on: "mission_conversation",
                          columns: ["convo_id", "ended_at"], options: .ifNotExists)
            try Self.addColumnIfMissing(db, table: "conversation", column: "mission_id", .text)
            try Self.addColumnIfMissing(db, table: "conversation", column: "mission_count", .integer)
        }
```

- [ ] **Step 4: Extend the records**

`ConversationRecord` (in `JournalStore.swift`): add as the LAST two stored properties (so every memberwise call site keeps compiling):

```swift
    /// The conversation's current mission from the snapshot (spec
    /// 2026-09-30 §3, "Snapshot conversation rows"), or nil. Written only
    /// when the snapshot carries the key — see `ConvoSummaryDTO.missionIDKnown`.
    public var missionID: String? = nil
    /// How many missions the conversation has touched, per the snapshot.
    public var missionCount: Int? = nil
```

and add to its `CodingKeys`: `case missionID = "mission_id"` and `case missionCount = "mission_count"`.

`MissionRecord` (in `JournalStore+Missions.swift`): add stored properties `public var projectId: String?; public var projectNum: Int?; public var activity: String?`, `CodingKeys` `case projectId = "project_id", projectNum = "project_num"` and add `activity` to the plain-name case list; in `init(_ m: Mission)` add `projectId = m.projectID; projectNum = m.projectNum; activity = m.activity?.rawValue`; in `var mission` append `projectID: projectId, projectNum: projectNum, activity: activity.flatMap(MissionActivity.init(rawValue:))` after `statusUpdatedAt:`.

Replace `MissionConversationRecord`:

```swift
public struct MissionConversationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "mission_conversation"
    public var missionId: String; public var convoId: String
    public var title: String; public var box: String?; public var state: String
    public var joinedAt: Int64?; public var endedAt: Int64?; public var how: String?
    /// Nullable: rows cached before v14 have no value (read as false).
    public var isCurrent: Bool?
    public var parentConvoId: String?; public var subchatCount: Int?
    enum CodingKeys: String, CodingKey {
        case title, box, state, how
        case missionId = "mission_id", convoId = "convo_id"
        case joinedAt = "joined_at", endedAt = "ended_at", isCurrent = "is_current"
        case parentConvoId = "parent_convo_id", subchatCount = "subchat_count"
    }
    public init(missionID: String, _ c: MissionConversation) {
        missionId = missionID; convoId = c.id; title = c.title; box = c.box; state = c.state
        joinedAt = ms(c.joinedAt); endedAt = ms(c.endedAt); how = c.how; isCurrent = c.isCurrent
        parentConvoId = c.parentConvoID; subchatCount = c.subchatCount
    }
    public var conversation: MissionConversation {
        MissionConversation(id: convoId, title: title, box: box, state: state, isCurrent: isCurrent ?? false,
                            joinedAt: date(joinedAt), endedAt: date(endedAt), how: how,
                            parentConvoID: parentConvoId, subchatCount: subchatCount ?? 0)
    }
}
```

In `wipeMissionTables`, change the SQL to:

```swift
        try db.execute(sql: "DELETE FROM mission; DELETE FROM milestone; DELETE FROM mission_conversation; DELETE FROM project;")
```

- [ ] **Step 5: Create `JournalStore+Projects.swift` with `ProjectRecord`**

```swift
import Foundation
import GRDB
import MatronModels

// Project cache (spec 2026-09-30 §4, §6). Records and queries for the
// `project` table created by migration v14. Filled from GET /projects and
// GET /projects/:id by `ProjectsSync` — never from the event log.

private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
private func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }
private func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
private func date(_ v: Int64?) -> Date? { v.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

public struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "project"
    public var id: String; public var num: Int; public var state: String
    public var title: String; public var body: String
    public var status: String?; public var statusBy: String?; public var statusUpdatedAt: Int64?
    public var closeSummary: String?; public var closedAt: Int64?; public var mergedInto: String?
    public var originConvoId: String?; public var createdBy: String
    public var createdAt: Int64; public var updatedAt: Int64
    public var missionsRunning: Int; public var missionsWaiting: Int; public var missionsIdle: Int
    public var missionsQuiet: Int; public var missionsClosed: Int
    public var needsYou: Int; public var openItems: Int; public var lastActivityAt: Int64?
    /// `GET /projects/:id`'s `sessions_by_box`, JSON. Kept across list
    /// refreshes (`JournalStore.upsertProjects` never writes it).
    public var sessionsByBoxJson: String?

    enum CodingKeys: String, CodingKey {
        case id, num, state, title, body, status
        case statusBy = "status_by", statusUpdatedAt = "status_updated_at"
        case closeSummary = "close_summary", closedAt = "closed_at", mergedInto = "merged_into"
        case originConvoId = "origin_convo_id", createdBy = "created_by"
        case createdAt = "created_at", updatedAt = "updated_at"
        case missionsRunning = "missions_running", missionsWaiting = "missions_waiting"
        case missionsIdle = "missions_idle", missionsQuiet = "missions_quiet", missionsClosed = "missions_closed"
        case needsYou = "needs_you", openItems = "open_items", lastActivityAt = "last_activity_at"
        case sessionsByBoxJson = "sessions_by_box_json"
    }

    public init(_ p: Project, sessionsByBoxJson: String? = nil) {
        id = p.id; num = p.num; state = p.state.rawValue; title = p.title; body = p.body
        status = p.status; statusBy = p.statusBy?.rawValue; statusUpdatedAt = ms(p.statusUpdatedAt)
        closeSummary = p.closeSummary; closedAt = ms(p.closedAt); mergedInto = p.mergedInto
        originConvoId = p.originConvoID; createdBy = p.createdBy.rawValue
        createdAt = ms(p.createdAt); updatedAt = ms(p.updatedAt)
        missionsRunning = p.missions.running; missionsWaiting = p.missions.waiting; missionsIdle = p.missions.idle
        missionsQuiet = p.missions.quiet; missionsClosed = p.missions.closed
        needsYou = p.needsYou; openItems = p.openItems; lastActivityAt = ms(p.lastActivityAt)
        self.sessionsByBoxJson = sessionsByBoxJson
    }

    public var project: Project {
        Project(id: id, num: num, state: MissionState(rawValue: state) ?? .open, title: title, body: body,
                status: status, statusBy: statusBy.flatMap(ItemAuthor.init(rawValue:)),
                statusUpdatedAt: date(statusUpdatedAt), closeSummary: closeSummary, closedAt: date(closedAt),
                mergedInto: mergedInto, originConvoID: originConvoId,
                createdBy: ItemAuthor(rawValue: createdBy) ?? .agent,
                createdAt: date(createdAt), updatedAt: date(updatedAt),
                missions: ProjectMissionCounts(running: missionsRunning, waiting: missionsWaiting, idle: missionsIdle,
                                               quiet: missionsQuiet, closed: missionsClosed),
                needsYou: needsYou, openItems: openItems, lastActivityAt: date(lastActivityAt))
    }
}
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalStoreProjectsTests|JournalStoreMissionsTests|JournalStoreTests|MissionsSyncTests)'`
Expected: PASS (existing `JournalStoreTests` prove the `ConversationRecord` change broke no snapshot/list path).

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Sources/Journal/JournalStore+Missions.swift \
        MatronShared/Sources/Journal/JournalStore+Projects.swift MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: migration v14 — project table, mission project/activity, link columns" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The snapshot's `mission_id` / `mission_count`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (`ConvoSummaryDTO`, `upsertSummary`)
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift` (`snapshot()`)
- Test: `MatronShared/Tests/JournalTests/JournalAPITests.swift`, `MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift`

**Interfaces:**
- Produces: `ConvoSummaryDTO.missionID: String?`, `.missionIDKnown: Bool`, `.missionCount: Int?` (init gains trailing `missionID: String? = nil, missionIDKnown: Bool = false, missionCount: Int? = nil`).

`mission_id: null` is information (the conversation has no current mission any more); an absent key is an old journal. Same key-presence rule as `AgentDTO.tagCharKnown`.

- [ ] **Step 1: Write the failing tests**

Append to `JournalAPITests`:

```swift
    func testSnapshotParsesMissionPointerAndCount() async throws {
        StubURLProtocol.responses = ["/snapshot": (200, """
            {"conversations":[\
            {"id":"c1","title":"A","session_state":"running","last_seq":1,"snippet":"","created_at":1,"mission_id":"ms_1","mission_count":3},\
            {"id":"c2","title":"B","session_state":"running","last_seq":1,"snippet":"","created_at":1,"mission_id":null,"mission_count":1},\
            {"id":"c3","title":"C","session_state":"running","last_seq":1,"snippet":"","created_at":1}\
            ],"seq":1}
            """)]
        let api = makeAPI()
        await api.setToken("t")
        let byID = Dictionary(uniqueKeysWithValues: try await api.snapshot().conversations.map { ($0.id, $0) })
        XCTAssertEqual(byID["c1"]?.missionID, "ms_1"); XCTAssertEqual(byID["c1"]?.missionIDKnown, true)
        XCTAssertEqual(byID["c1"]?.missionCount, 3)
        XCTAssertNil(byID["c2"]?.missionID); XCTAssertEqual(byID["c2"]?.missionIDKnown, true)
        XCTAssertEqual(byID["c3"]?.missionIDKnown, false); XCTAssertNil(byID["c3"]?.missionCount)
    }
```

Append to `JournalStoreProjectsTests`:

```swift
    private func dto(_ id: String, missionID: String?, known: Bool, count: Int?) -> ConvoSummaryDTO {
        ConvoSummaryDTO(id: id, title: "T", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1,
                        missionID: missionID, missionIDKnown: known, missionCount: count)
    }

    /// Review Focus: null clears the pointer, absent leaves it.
    func testSnapshotMissionPointerNullClearsAbsentKeeps() throws {
        let store = try makeStore()
        try store.refreshSummaries([dto("c1", missionID: "ms_1", known: true, count: 2),
                                    dto("c2", missionID: "ms_2", known: true, count: 1)])
        XCTAssertEqual(try store.conversation(id: "c1")?.missionID, "ms_1")
        XCTAssertEqual(try store.conversation(id: "c1")?.missionCount, 2)

        try store.refreshSummaries([dto("c1", missionID: nil, known: true, count: 2),
                                    dto("c2", missionID: nil, known: false, count: nil)])
        XCTAssertNil(try store.conversation(id: "c1")?.missionID, "null: the conversation left its last mission")
        XCTAssertEqual(try store.conversation(id: "c2")?.missionID, "ms_2", "absent: an old journal says nothing")
        XCTAssertEqual(try store.conversation(id: "c2")?.missionCount, 1)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalAPITests|JournalStoreProjectsTests)'`
Expected: build FAILS — `extra arguments 'missionID', 'missionIDKnown', 'missionCount'`.

- [ ] **Step 3: Implement**

`ConvoSummaryDTO`: add

```swift
    /// The conversation's current mission (spec 2026-09-30 §3). Only
    /// meaningful when `missionIDKnown` — the key was on the wire; a JSON
    /// null there means "no current mission" and clears the stored one.
    public let missionID: String?
    public let missionIDKnown: Bool
    /// How many missions the conversation has touched; nil when absent.
    public let missionCount: Int?
```

and extend its init: `…, participants: [Int64]? = nil, missionID: String? = nil, missionIDKnown: Bool = false, missionCount: Int? = nil)` with the three assignments.

`JournalAPI.snapshot()`: add to the `ConvoSummaryDTO(...)` call after `participants:`:

```swift
                // Current mission pointer and link count (spec 2026-09-30
                // §3). Key presence matters: null clears, absent keeps.
                missionID: c["mission_id"] as? String,
                missionIDKnown: c["mission_id"] != nil,
                missionCount: (c["mission_count"] as? NSNumber)?.intValue
```

`upsertSummary`: in the `if var existing` branch, before `if c.lastSeq > existing.lastSeq`:

```swift
            if c.missionIDKnown { existing.missionID = c.missionID }
            if let count = c.missionCount { existing.missionCount = count }
```

and in the insert branch pass `missionID: c.missionID, missionCount: c.missionCount` as the last two arguments of `ConversationRecord(...)`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalAPITests|JournalStoreProjectsTests|JournalStoreTests)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Sources/Journal/JournalAPI.swift \
        MatronShared/Tests/JournalTests/JournalAPITests.swift MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: cache the snapshot's current-mission pointer and mission count" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Conversation links in the store — `missionsStream(convoID:)`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore+Missions.swift` ("A conversation's mission" section)
- Modify: `Matron/Features/Chat/ChatView.swift` (~line 593, the `.task(id: viewModel.roomID)` over `missionIDStream`)
- Modify: `MatronMac/Features/Chat/MacChatView.swift` (~line 1256, same task)
- Test: `MatronShared/Tests/JournalTests/JournalStoreConversationMissionsTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 `ConversationMissionLink`, `ConversationMissions`; Task 3 link columns; Task 4 `conversation.mission_id/mission_count`.
- Produces:
  - `JournalStore.replaceConversationMissionLinks(convoID: String, _ links: [ConversationMissionLink]) throws` — authoritative for that conversation's links; caches any mission row it did not have (never overwrites a cached one).
  - `JournalStore.conversationMissions(convoID: String) throws -> ConversationMissions`
  - `JournalStore.missionsStream(convoID: String) -> AsyncStream<ConversationMissions>`
  - `JournalStore.missionIDStream(convoID:)` is **removed** (spec §6: it "becomes `missionsStream(convoID:)`"). `missionID(convoID:)` stays as the legacy derivation.

Resolution rule, in order: link rows (a row with `joined_at` came from a journal that knows links); if no link is current, the snapshot's `conversation.mission_id` marks one; if the snapshot never said anything (`mission_count` NULL) and no row carries link data, today's derivation (origin → `mission_conversation` → newest milestone) marks one. So an old journal behaves exactly as today.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/JournalStoreConversationMissionsTests.swift`:

```swift
import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreConversationMissionsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    private func mission(_ id: String, num: Int, origin: String = "c-other", state: MissionState = .open) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: origin,
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    }

    private func link(_ m: Mission, current: Bool = false, joined: TimeInterval = 10, ended: TimeInterval? = nil,
                      how: String = "joined") -> ConversationMissionLink {
        ConversationMissionLink(mission: m, isCurrent: current, isActive: ended == nil,
                                joinedAt: Date(timeIntervalSince1970: joined),
                                endedAt: ended.map { Date(timeIntervalSince1970: $0) }, how: how)
    }

    private func conversation(_ store: JournalStore, _ id: String, missionID: String? = nil, known: Bool = false,
                              count: Int? = nil) throws {
        try store.refreshSummaries([ConvoSummaryDTO(id: id, title: "Chat \(id)", sessionState: "running", lastSeq: 1,
                                                    snippet: "", createdAt: 1, missionID: missionID,
                                                    missionIDKnown: known, missionCount: count)])
    }

    func testReplacedLinksComeBackAsSections() throws {
        let store = try makeStore()
        try conversation(store, "c1", missionID: "ms_2", known: true, count: 3)
        try store.replaceConversationMissionLinks(convoID: "c1", [
            link(mission("ms_1", num: 61), joined: 5, ended: 8, how: "origin"),
            link(mission("ms_2", num: 62), current: true, joined: 20),
            link(mission("ms_3", num: 63), joined: 30),
        ])
        let sections = try store.conversationMissions(convoID: "c1").sections
        XCTAssertEqual(sections.current?.id, "ms_2")
        XCTAssertEqual(sections.alsoOn.map(\.id), ["ms_3"])
        XCTAssertEqual(sections.earlier.map(\.id), ["ms_1"])
        XCTAssertEqual(try store.mission(id: "ms_3")?.title, "M63", "an uncached mission is cached from the link row")
    }

    func testReplaceDropsLinksTheServerNoLongerReturnsAndKeepsDetailTitles() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61), mission("ms_2", num: 62)])
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c1", title: "Detail title", box: "greg", state: "running")])
        try store.replaceMissionConversations(missionID: "ms_2", [
            MissionConversation(id: "c1", title: "Detail title", box: "greg", state: "running")])
        try store.replaceConversationMissionLinks(convoID: "c1", [link(mission("ms_1", num: 61), current: true)])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_2"), [], "the server no longer links ms_2")
        let kept = try XCTUnwrap(store.missionConversations(missionID: "ms_1").first)
        XCTAssertEqual(kept.title, "Detail title"); XCTAssertEqual(kept.box, "greg")
        XCTAssertTrue(kept.isCurrent)
    }

    /// The header can draw its chip from the snapshot before any fetch.
    func testSnapshotPointerMarksCurrentBeforeLinksAreFetched() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try conversation(store, "c1", missionID: "ms_1", known: true, count: 3)
        let missions = try store.conversationMissions(convoID: "c1")
        XCTAssertEqual(missions.sections.current?.id, "ms_1")
        XCTAssertEqual(missions.othersCount, 2, "the snapshot's count knows about the other two")
    }

    /// Review Focus: an old journal (no link data, no snapshot fields) keeps
    /// today's derivation — origin first.
    func testLegacyDerivationStandsInWhenNoLinksAreKnown() throws {
        let store = try makeStore()
        try conversation(store, "c1")
        try store.upsertMissions([mission("ms_1", num: 61, origin: "c1")])
        XCTAssertEqual(try store.conversationMissions(convoID: "c1").sections.current?.id, "ms_1")
        try conversation(store, "c9")
        XCTAssertTrue(try store.conversationMissions(convoID: "c9").sections.isEmpty)
    }

    /// A new journal that says "no current mission" (`mission_id: null`,
    /// count present) must NOT fall back to the origin guess.
    func testANewJournalsNullPointerIsNotSecondGuessed() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61, origin: "c1")])
        try conversation(store, "c1", missionID: nil, known: true, count: 1)
        try store.replaceConversationMissionLinks(convoID: "c1", [link(mission("ms_1", num: 61, origin: "c1"), ended: 50)])
        let sections = try store.conversationMissions(convoID: "c1").sections
        XCTAssertNil(sections.current)
        XCTAssertEqual(sections.earlier.map(\.id), ["ms_1"])
    }

    func testStreamEmitsOnALinkChange() async throws {
        let store = try makeStore()
        try conversation(store, "c1", missionID: nil, known: true, count: 0)
        var iterator = store.missionsStream(convoID: "c1").makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.links, [])
        try store.replaceConversationMissionLinks(convoID: "c1", [link(mission("ms_1", num: 61), current: true)])
        let second = await iterator.next()
        XCTAssertEqual(second?.sections.current?.id, "ms_1")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.JournalStoreConversationMissionsTests'`
Expected: build FAILS — `value of type 'JournalStore' has no member 'replaceConversationMissionLinks'`.

- [ ] **Step 3: Implement the store functions**

In `JournalStore+Missions.swift`, replace the `missionIDStream(convoID:)` function (keep `missionIDQuery` and `missionID(convoID:)`) and add:

```swift
    // MARK: A conversation's missions (spec 2026-09-30 §3, §6)

    /// Authoritative for ONE conversation's links: rows for missions not in
    /// `links` go, the rest gain the link fields. A mission row this device
    /// has never cached is inserted from the link row; a cached one is left
    /// alone (the list/detail refresh owns it, with its counts).
    public func replaceConversationMissionLinks(convoID: String, _ links: [ConversationMissionLink]) throws {
        try dbQueue.write { db in
            for link in links { try MissionRecord(link.mission).insert(db, onConflict: .ignore) }
            let keep = Array(Set(links.map(\.id)))
            try MissionConversationRecord
                .filter(Column("convo_id") == convoID && !keep.contains(Column("mission_id")))
                .deleteAll(db)
            let title = try String.fetchOne(db, sql: "SELECT title FROM conversation WHERE id = ?", arguments: [convoID]) ?? ""
            for link in links {
                if var row = try MissionConversationRecord.fetchOne(db, key: ["mission_id": link.id, "convo_id": convoID]) {
                    row.joinedAt = ms(link.joinedAt); row.endedAt = ms(link.endedAt)
                    row.how = link.how; row.isCurrent = link.isCurrent
                    try row.update(db)
                } else {
                    try MissionConversationRecord(missionID: link.id, MissionConversation(
                        id: convoID, title: title, box: nil, state: "", isCurrent: link.isCurrent,
                        joinedAt: link.joinedAt, endedAt: link.endedAt, how: link.how)).insert(db)
                }
            }
        }
    }

    private static func conversationMissionsQuery(_ db: Database, _ convoID: String) throws -> ConversationMissions {
        let convo = try Row.fetchOne(db, sql: "SELECT mission_id, mission_count FROM conversation WHERE id = ?",
                                     arguments: [convoID])
        let pointer: String? = convo?["mission_id"]
        let snapshotCount: Int? = convo?["mission_count"]
        let rows = try MissionConversationRecord.filter(Column("convo_id") == convoID).fetchAll(db)
        let missions = try MissionRecord.filter(keys: rows.map(\.missionId)).fetchAll(db)
        let byID = Dictionary(missions.map { ($0.id, $0.mission) }, uniquingKeysWith: { first, _ in first })
        var links: [ConversationMissionLink] = rows.compactMap { row in
            guard let mission = byID[row.missionId] else { return nil }
            return ConversationMissionLink(mission: mission, isCurrent: row.isCurrent ?? false,
                                           isActive: row.endedAt == nil, joinedAt: date(row.joinedAt),
                                           endedAt: date(row.endedAt), how: row.how)
        }
        guard !links.contains(where: \.isCurrent) else { return ConversationMissions(links: links, snapshotCount: snapshotCount) }
        // A journal that knows links always sends `joined_at`; one that
        // knows the snapshot fields always sends `mission_count`. With
        // neither, this is an old journal: today's derivation.
        let linksKnown = rows.contains { $0.joinedAt != nil }
        let legacy = snapshotCount == nil && !linksKnown
        let currentID = pointer ?? (legacy ? try missionIDQuery(db, convoID) : nil)
        if let currentID {
            if let index = links.firstIndex(where: { $0.id == currentID }) {
                let l = links[index]
                links[index] = ConversationMissionLink(mission: l.mission, isCurrent: true, isActive: l.isActive,
                                                       joinedAt: l.joinedAt, endedAt: l.endedAt, how: l.how)
            } else if let mission = try MissionRecord.fetchOne(db, key: currentID)?.mission {
                links.append(ConversationMissionLink(mission: mission, isCurrent: true))
            }
        }
        return ConversationMissions(links: links, snapshotCount: snapshotCount)
    }

    public func conversationMissions(convoID: String) throws -> ConversationMissions {
        try dbQueue.read { db in try Self.conversationMissionsQuery(db, convoID) }
    }

    /// Every mission the conversation touched, for the header chip.
    /// Replaces `missionIDStream(convoID:)` (spec §6).
    public func missionsStream(convoID: String) -> AsyncStream<ConversationMissions> {
        Self.stream(ValueObservation.tracking { db in try Self.conversationMissionsQuery(db, convoID) }
            .removeDuplicates(), in: dbQueue)
    }
```

- [ ] **Step 4: Keep the two chat views compiling on today's behaviour**

In `Matron/Features/Chat/ChatView.swift` and `MatronMac/Features/Chat/MacChatView.swift`, inside the existing `.task(id: viewModel.roomID)`, replace the loop header and body:

```swift
            for await missions in deps.journalStore(for: session).missionsStream(convoID: viewModel.roomID) {
                // See the comment above (CodeRabbit #209).
                guard !Task.isCancelled else { return }
                missionID = missions.sections.headline?.mission.id
            }
```

(Tasks 21 and 26 replace this with the chip.)

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalStoreConversationMissionsTests|JournalStoreMissionsTests)'`
Expected: PASS.
Run: `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet && xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -quiet`
Expected: both `** BUILD SUCCEEDED **` (no remaining `missionIDStream` caller).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore+Missions.swift Matron/Features/Chat/ChatView.swift \
        MatronMac/Features/Chat/MacChatView.swift MatronShared/Tests/JournalTests/JournalStoreConversationMissionsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions: missionsStream(convoID:) — every mission a conversation touched" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Project reads and writes in the store

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore+Projects.swift`
- Modify: `MatronShared/Sources/Journal/JournalStore+Missions.swift` (add `upsertMilestones`)
- Test: `MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift`

**Interfaces:**
- Produces on `JournalStore`:
  - `replaceProjects(_ projects: [Project], keeping protectedIDs: Set<String> = []) throws` (authoritative, like `replaceMissions`)
  - `upsertProjects(_ projects: [Project]) throws`, `setProjectSessionsByBox(id: String, _ map: [String: Int]) throws`
  - `project(id: String) throws -> Project?`, `projects() throws -> [Project]`
  - `projectsStream() -> AsyncStream<[Project]>` (open first, then newest activity)
  - `projectStream(id: String) -> AsyncStream<Project?>`
  - `projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]>`
  - `missionsStream(projectID: String) -> AsyncStream<[Mission]>`
  - `unfiledOpenMissionsStream() -> AsyncStream<[Mission]>`
  - `needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]>`
  - `recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]>`
  - `upsertMilestones(_ milestones: [Milestone]) throws`

- [ ] **Step 1: Write the failing tests**

Append to `JournalStoreProjectsTests`:

```swift
    private func mission(_ id: String, num: Int, project: String?, state: MissionState = .open,
                         lastMilestoneAt: TimeInterval = 10) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: "c1",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: Date(timeIntervalSince1970: lastMilestoneAt), projectID: project)
    }

    func testReplaceProjectsIsAuthoritativeButKeepsProtectedAndSessions() throws {
        let store = try makeStore()
        try store.replaceProjects([Self.project("pj_1", num: 1), Self.project("pj_2", num: 2)])
        try store.setProjectSessionsByBox(id: "pj_1", ["greg": 2, "pat": 1])
        try store.upsertProjects([Self.project("pj_3", num: 3)])
        try store.replaceProjects([Self.project("pj_1", num: 1, title: "Renamed")], keeping: ["pj_3"])
        XCTAssertEqual(try store.projects().map(\.id).sorted(), ["pj_1", "pj_3"])
        XCTAssertEqual(try store.project(id: "pj_1")?.title, "Renamed")
        let sessions = try await firstValue(store.projectSessionsByBoxStream(id: "pj_1"))
        XCTAssertEqual(sessions, ["greg": 2, "pat": 1], "a list refresh must not wipe the detail's sessions")
    }

    func testProjectsStreamPutsOpenFirstThenNewestActivity() async throws {
        let store = try makeStore()
        try store.replaceProjects([Self.project("pj_old", num: 1, lastActivity: 5),
                                   Self.project("pj_new", num: 2, lastActivity: 50),
                                   Self.project("pj_closed", num: 3, state: .closed, lastActivity: 99)])
        let projects = try await firstValue(store.projectsStream())
        XCTAssertEqual(projects.map(\.id), ["pj_new", "pj_old", "pj_closed"])
    }

    func testProjectScopedReads() async throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61, project: "pj_1", lastMilestoneAt: 20),
                                  mission("ms_2", num: 62, project: "pj_1", lastMilestoneAt: 30),
                                  mission("ms_3", num: 63, project: nil),
                                  mission("ms_4", num: 64, project: nil, state: .closed)])
        try store.upsertItems([
            TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q1", originConvoID: "c1",
                        updatedAt: Date(timeIntervalSince1970: 5), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_2", num: 91, kind: .question, awaiting: .user, title: "Q2", originConvoID: "c1",
                        missionID: "ms_3", missionNum: 63),
            TrackerItem(id: "it_3", num: 92, kind: .task, awaiting: .agent, title: "T", originConvoID: "c1",
                        missionID: "ms_2", missionNum: 62),
        ])
        try store.upsertMilestones([
            Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "a", convoID: "c1", seq: 1,
                      createdAt: Date(timeIntervalSince1970: 20)),
            Milestone(id: "ml_2", missionID: "ms_2", num: 71, kind: .userInput, title: "b", convoID: "c1", seq: 2,
                      createdAt: Date(timeIntervalSince1970: 30)),
            Milestone(id: "ml_3", missionID: "ms_3", num: 72, kind: .progress, title: "c", convoID: "c1", seq: 3,
                      createdAt: Date(timeIntervalSince1970: 40)),
        ])
        XCTAssertEqual(try await firstValue(store.missionsStream(projectID: "pj_1")).map(\.id), ["ms_2", "ms_1"])
        XCTAssertEqual(try await firstValue(store.unfiledOpenMissionsStream()).map(\.id), ["ms_3"])
        XCTAssertEqual(try await firstValue(store.needsYouItemsStream(projectID: "pj_1")).map(\.id), ["it_1"])
        XCTAssertEqual(try await firstValue(store.recentMilestonesStream(projectID: "pj_1", limit: 5)).map(\.id),
                       ["ml_2", "ml_1"])
        XCTAssertEqual(try await firstValue(store.recentMilestonesStream(projectID: "pj_1", limit: 1)).map(\.id), ["ml_2"])
    }

    private func firstValue<T: Sendable>(_ stream: AsyncStream<T>) async throws -> T {
        var iterator = stream.makeAsyncIterator()
        return try XCTUnwrap(await iterator.next())
    }
```

(`testReplaceProjectsIsAuthoritativeButKeepsProtectedAndSessions` awaits, so declare it `async throws`.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.JournalStoreProjectsTests'`
Expected: build FAILS — `value of type 'JournalStore' has no member 'replaceProjects'`.

- [ ] **Step 3: Implement**

Append to `JournalStore+Projects.swift`:

```swift
extension JournalStore {
    private static let projectsOrder = """
        ORDER BY state DESC, last_activity_at IS NULL, last_activity_at DESC, num DESC
        """

    /// `sessions_by_box_json` belongs to the detail fetch; a list row has
    /// none, so every save carries the stored value over.
    private static func save(_ project: Project, _ db: Database) throws {
        let kept = try String.fetchOne(db, sql: "SELECT sessions_by_box_json FROM project WHERE id = ?",
                                       arguments: [project.id])
        try ProjectRecord(project, sessionsByBoxJson: kept).save(db)
    }

    public func upsertProjects(_ projects: [Project]) throws {
        guard !projects.isEmpty else { return }
        try dbQueue.write { db in for p in projects { try Self.save(p, db) } }
    }

    /// `GET /projects` returns the complete set, so this write is
    /// authoritative (same reasoning as `replaceMissions`). `protectedIDs`:
    /// ids a detail fetch or a create wrote since the list GET started —
    /// kept, and not overwritten by the (older) list row.
    public func replaceProjects(_ projects: [Project], keeping protectedIDs: Set<String> = []) throws {
        try dbQueue.write { db in
            for p in projects where !protectedIDs.contains(p.id) { try Self.save(p, db) }
            let ids = Array(Set(projects.map(\.id)).union(protectedIDs))
            try ProjectRecord.filter(!ids.contains(Column("id"))).deleteAll(db)
        }
    }

    public func setProjectSessionsByBox(id: String, _ map: [String: Int]) throws {
        let data = try JSONEncoder().encode(map)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET sessions_by_box_json = ? WHERE id = ?",
                           arguments: [String(decoding: data, as: UTF8.self), id])
        }
    }

    public func project(id: String) throws -> Project? {
        try dbQueue.read { db in try ProjectRecord.fetchOne(db, key: id)?.project }
    }

    public func projects() throws -> [Project] {
        try dbQueue.read { db in try ProjectRecord.fetchAll(db, sql: "SELECT * FROM project \(Self.projectsOrder)").map(\.project) }
    }

    public func projectsStream() -> AsyncStream<[Project]> {
        Self.stream(ValueObservation.tracking { db in
            try ProjectRecord.fetchAll(db, sql: "SELECT * FROM project \(Self.projectsOrder)").map(\.project)
        }.removeDuplicates(), in: dbQueue)
    }

    public func projectStream(id: String) -> AsyncStream<Project?> {
        Self.stream(ValueObservation.tracking { db in try ProjectRecord.fetchOne(db, key: id)?.project }
            .removeDuplicates(), in: dbQueue)
    }

    public func projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]> {
        Self.stream(ValueObservation.tracking { db -> [String: Int] in
            guard let json = try String.fetchOne(db, sql: "SELECT sessions_by_box_json FROM project WHERE id = ?",
                                                 arguments: [id]) else { return [:] }
            return (try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8))) ?? [:]
        }.removeDuplicates(), in: dbQueue)
    }

    public func missionsStream(projectID: String) -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in
            try MissionRecord.fetchAll(db, sql: """
                SELECT * FROM mission WHERE project_id = ?
                ORDER BY state DESC, last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """, arguments: [projectID]).map(\.mission)
        }.removeDuplicates(), in: dbQueue)
    }

    /// The project page's "Add a mission" choices.
    public func unfiledOpenMissionsStream() -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in
            try MissionRecord.fetchAll(db, sql: """
                SELECT * FROM mission WHERE project_id IS NULL AND state = 'open'
                ORDER BY last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """).map(\.mission)
        }.removeDuplicates(), in: dbQueue)
    }

    /// Open items awaiting the user across every mission in the project.
    public func needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]> {
        Self.stream(ValueObservation.tracking { db in
            try ItemRecord.fetchAll(db, sql: """
                SELECT i.* FROM item i JOIN mission m ON m.id = i.mission_id
                WHERE m.project_id = ? AND i.state = 'open' AND i.awaiting = 'user'
                ORDER BY i.updated_at DESC, i.num DESC
                """, arguments: [projectID]).map(\.item)
        }.removeDuplicates(), in: dbQueue)
    }

    public func recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]> {
        Self.stream(ValueObservation.tracking { db in
            try MilestoneRecord.fetchAll(db, sql: """
                SELECT ml.* FROM milestone ml JOIN mission m ON m.id = ml.mission_id
                WHERE m.project_id = ? ORDER BY ml.created_at DESC, ml.num DESC LIMIT ?
                """, arguments: [projectID, limit]).map(\.milestone)
        }.removeDuplicates(), in: dbQueue)
    }
}
```

In `JournalStore+Missions.swift`, after `replaceMilestones`:

```swift
    /// Additive — the project detail's `recent_milestones` span several
    /// missions, so it cannot replace any one mission's list.
    public func upsertMilestones(_ milestones: [Milestone]) throws {
        guard !milestones.isEmpty else { return }
        try dbQueue.write { db in for m in milestones { try MilestoneRecord(m).save(db) } }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.JournalStoreProjectsTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore+Projects.swift MatronShared/Sources/Journal/JournalStore+Missions.swift \
        MatronShared/Tests/JournalTests/JournalStoreProjectsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: store reads and writes for projects and project-scoped rows" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `JournalAPI+Projects` and the sub-chat detail query

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Projects.swift`
- Modify: `MatronShared/Sources/Journal/JournalAPI+Missions.swift` (`mission(id:)`)
- Test: `MatronShared/Tests/JournalTests/ProjectsAPITests.swift` (new), `MatronShared/Tests/JournalTests/MissionsAPITests.swift` (`testMissionDetailFetchesByEncodedID`)

**Interfaces:**
- Consumes: Task 1 `Project`, `ConversationMissionLink`; existing `JournalAPI.request`, `pathSegment`, `decodeMission`.
- Produces (MatronJournal):
  - `struct ProjectsListDecode { projects: [Project]; droppedIDs: [String] }`
  - `struct ProjectDetail { project: Project; missions: [Mission]; needsYou: [TrackerItem]; recentMilestones: [Milestone]; sessionsByBox: [String: Int] }`
  - `protocol ProjectsProviding: Sendable` with `listProjects() async throws -> ProjectsListDecode`, `project(id:) async throws -> ProjectDetail`, `createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project`, `mergeProject(id: String, into: String) async throws`, `setMissionProject(missionID: String, project: String?) async throws -> Mission`, `conversationMissions(convoID: String) async throws -> [ConversationMissionLink]`; `JournalAPI` conforms.
  - `JournalAPI.mission(id:)` now sends `?subchats=1` so the mission page can fold sub-chats itself.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/ProjectsAPITests.swift`:

```swift
import XCTest
import MatronModels
@testable import MatronJournal

final class ProjectsAPITests: XCTestCase {
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

    private func sentBody(_ recorder: ItemsStubURLProtocol.Type) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.lastBody)) as? [String: Any])
    }

    func testListProjectsGetsWithoutAStateAndKeepsDroppedIDs() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["projects": [
            ProjectModelTests.projectJSON, ["id": "pj_broken"],
        ]])
        let decoded = try await api.listProjects()
        XCTAssertEqual(decoded.projects.map(\.id), ["pj_1"])
        XCTAssertEqual(decoded.droppedIDs, ["pj_broken"])
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/projects")
        XCTAssertNil(url.query, "both states: no ?state=")
    }

    func testAMalformedListIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeProjects(["foo": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    func testListProjects404IsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.listProjects(); XCTFail("expected a throw") }
        catch { XCTAssertEqual(error as? JournalAPIError, .notFound) }
    }

    func testProjectDetailDecodesEveryPart() async throws {
        var item = ItemsAPITests.itemJSON
        item["mission_id"] = "ms_a1"; item["mission_num"] = 61
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "project": ProjectModelTests.projectJSON,
            "missions": [MissionModelTests.missionJSON],
            "needs_you": [item],
            "recent_milestones": [MissionModelTests.milestoneJSON],
            "sessions_by_box": ["greg": 2, "pat": 1],
        ])
        let detail = try await api.project(id: "#4000")
        XCTAssertEqual(detail.project.id, "pj_1")
        XCTAssertEqual(detail.missions.map(\.id), ["ms_a1"])
        XCTAssertEqual(detail.needsYou.first?.missionNum, 61)
        XCTAssertEqual(detail.recentMilestones.map(\.id), ["ml_b2"])
        XCTAssertEqual(detail.sessionsByBox, ["greg": 2, "pat": 1])
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/projects/%234000") == true)
    }

    func testCreateProjectPostsTitleBodyAndIdempotencyKey() async throws {
        let (api, recorder) = makeStubbedAPI(status: 201, body: ["project": ProjectModelTests.projectJSON])
        let project = try await api.createProject(title: "Promo launch", body: "Site and blog", idempotencyKey: "k-1")
        XCTAssertEqual(project.id, "pj_1")
        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/projects")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Idempotency-Key"), "k-1")
        let sent = try sentBody(recorder)
        XCTAssertEqual(sent["title"] as? String, "Promo launch")
        XCTAssertEqual(sent["body"] as? String, "Site and blog")
    }

    func testCreateProjectOmitsAnEmptyBody() async throws {
        let (api, recorder) = makeStubbedAPI(status: 201, body: ["project": ProjectModelTests.projectJSON])
        _ = try await api.createProject(title: "T", body: "  ", idempotencyKey: "k")
        XCTAssertNil(try sentBody(recorder)["body"])
    }

    func testMergePostsInto() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["project": ProjectModelTests.projectJSON])
        try await api.mergeProject(id: "pj_1", into: "pj_2")
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/projects/pj_1/merge") == true)
        XCTAssertEqual(try sentBody(recorder)["into"] as? String, "pj_2")
    }

    func testSetMissionProjectPatchesAnIdOrNull() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["mission": MissionModelTests.missionJSON])
        _ = try await api.setMissionProject(missionID: "ms_a1", project: "pj_1")
        XCTAssertEqual(recorder.lastRequest?.httpMethod, "PATCH")
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/missions/ms_a1") == true)
        XCTAssertEqual(try sentBody(recorder)["project"] as? String, "pj_1")
        _ = try await api.setMissionProject(missionID: "ms_a1", project: nil)
        XCTAssertTrue(try sentBody(recorder)["project"] is NSNull, "null takes the mission out of its project")
    }

    func testConversationMissionsDecodesLinks() async throws {
        var row = MissionModelTests.missionJSON
        row["current"] = true; row["joined_at"] = 1_700_000_001_000; row["how"] = "joined"
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["missions": [row, ["current": true]]])
        let links = try await api.conversationMissions(convoID: "c1:sub:a")
        XCTAssertEqual(links.map(\.id), ["ms_a1"], "a row with no mission is dropped")
        XCTAssertTrue(links[0].isCurrent)
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/conversations/c1%3Asub%3Aa/missions") == true)
    }
}
```

In `MissionsAPITests.testMissionDetailFetchesByEncodedID`, replace the final assertion with:

```swift
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertTrue(url.absoluteString.contains("/missions/%2361?"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "subchats", value: "1")),
                      "the mission page folds sub-chats itself, so it asks for them")
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.(ProjectsAPITests|MissionsAPITests)'`
Expected: build FAILS — `value of type 'JournalAPI' has no member 'listProjects'`.

- [ ] **Step 3: Implement**

In `JournalAPI+Missions.swift`, `mission(id:)` becomes:

```swift
    public func mission(id: String) async throws -> MissionDetail {
        // `subchats=1` (spec 2026-09-30 §3): the journal folds sub-chats
        // into their parent by default; the apps fold them locally so the
        // mission page can open one. An older journal ignores the query.
        try Self.decodeMissionDetail(try await request(path: "/missions/\(Self.pathSegment(id))",
                                                       query: [.init(name: "subchats", value: "1")]))
    }
```

Create `JournalAPI+Projects.swift`:

```swift
import Foundation
import os
import MatronModels

private let projectsAPILogger = Logger(subsystem: "chat.matron", category: "projects-api")

/// `decodeProjects`' result: the rows that decoded plus the ids of any that
/// did not, so an authoritative replace never reads a local decode failure
/// as "the server removed it" (same contract as `MissionsListDecode`).
public struct ProjectsListDecode: Equatable, Sendable {
    public let projects: [Project]
    public let droppedIDs: [String]
    public init(projects: [Project], droppedIDs: [String]) { self.projects = projects; self.droppedIDs = droppedIDs }
}

/// `GET /projects/:id` (spec 2026-09-30 §4.2). For a merged project the
/// journal answers with the TARGET — `project.id` differs from the id asked.
public struct ProjectDetail: Equatable, Sendable {
    public let project: Project
    public let missions: [Mission]
    public let needsYou: [TrackerItem]
    public let recentMilestones: [Milestone]
    public let sessionsByBox: [String: Int]
    public init(project: Project, missions: [Mission], needsYou: [TrackerItem], recentMilestones: [Milestone],
                sessionsByBox: [String: Int]) {
        self.project = project; self.missions = missions; self.needsYou = needsYou
        self.recentMilestones = recentMilestones; self.sessionsByBox = sessionsByBox
    }
}

/// The projects routes the apps use, plus the link read for the header.
/// Only the three writes spec §6 gives the apps: create, merge, file.
public protocol ProjectsProviding: Sendable {
    func listProjects() async throws -> ProjectsListDecode
    func project(id: String) async throws -> ProjectDetail
    func createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project
    func mergeProject(id: String, into: String) async throws
    func setMissionProject(missionID: String, project: String?) async throws -> Mission
    func conversationMissions(convoID: String) async throws -> [ConversationMissionLink]
}

extension JournalAPI: ProjectsProviding {
    static func decodeProjects(_ obj: [String: Any]) throws -> ProjectsListDecode {
        guard let rows = obj["projects"] as? [Any] else { throw JournalAPIError.transport("malformed projects response") }
        var projects: [Project] = []
        var dropped: [String] = []
        for element in rows {
            let row = element as? [String: Any]
            if let row, let project = Project(json: row) { projects.append(project); continue }
            let id = row?["id"] as? String
            projectsAPILogger.error("dropped malformed project row id=\(id ?? "?", privacy: .public)")
            if let id { dropped.append(id) }
        }
        return ProjectsListDecode(projects: projects, droppedIDs: dropped)
    }

    static func decodeProject(_ obj: [String: Any]) throws -> Project {
        guard let project = (obj["project"] as? [String: Any]).flatMap(Project.init(json:)) else {
            throw JournalAPIError.transport("malformed project response")
        }
        return project
    }

    static func decodeProjectDetail(_ obj: [String: Any]) throws -> ProjectDetail {
        let boxes = (obj["sessions_by_box"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.intValue }
        return ProjectDetail(
            project: try decodeProject(obj),
            missions: (obj["missions"] as? [[String: Any]] ?? []).compactMap(Mission.init(json:)),
            needsYou: (obj["needs_you"] as? [[String: Any]] ?? []).compactMap(TrackerItem.init(json:)),
            recentMilestones: (obj["recent_milestones"] as? [[String: Any]] ?? []).compactMap(Milestone.init(json:)),
            sessionsByBox: boxes)
    }

    static func decodeConversationMissions(_ obj: [String: Any]) throws -> [ConversationMissionLink] {
        guard let rows = obj["missions"] as? [[String: Any]] else {
            throw JournalAPIError.transport("malformed conversation missions response")
        }
        return rows.compactMap(ConversationMissionLink.init(json:))
    }

    public func listProjects() async throws -> ProjectsListDecode {
        try Self.decodeProjects(try await request(path: "/projects"))
    }

    public func project(id: String) async throws -> ProjectDetail {
        try Self.decodeProjectDetail(try await request(path: "/projects/\(Self.pathSegment(id))"))
    }

    public func createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project {
        var payload: [String: Any] = ["title": title]
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["body"] = body }
        return try Self.decodeProject(try await request(path: "/projects", method: "POST", body: payload,
                                                        accept: [200, 201], headers: ["Idempotency-Key": idempotencyKey]))
    }

    public func mergeProject(id: String, into: String) async throws {
        _ = try await request(path: "/projects/\(Self.pathSegment(id))/merge", method: "POST", body: ["into": into])
    }

    public func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        let value: Any = project ?? NSNull()
        return try Self.decodeMission(try await request(path: "/missions/\(Self.pathSegment(missionID))",
                                                        method: "PATCH", body: ["project": value]))
    }

    public func conversationMissions(convoID: String) async throws -> [ConversationMissionLink] {
        try Self.decodeConversationMissions(
            try await request(path: "/conversations/\(Self.pathSegment(convoID))/missions"))
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(ProjectsAPITests|MissionsAPITests|ItemsAPITests)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI+Projects.swift MatronShared/Sources/Journal/JournalAPI+Missions.swift \
        MatronShared/Tests/JournalTests/ProjectsAPITests.swift MatronShared/Tests/JournalTests/MissionsAPITests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: JournalAPI routes for projects, filing and conversation links" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `ProjectsSync`

**Files:**
- Create: `MatronShared/Sources/Journal/ProjectsSync.swift`
- Test: `MatronShared/Tests/JournalTests/ProjectsSyncTests.swift` (new)

**Interfaces:**
- Consumes: Task 7 `ProjectsProviding`, `ProjectDetail`; Task 5 `replaceConversationMissionLinks`; Task 6 project store writes; existing `MissionsRefreshFailure`, `MissionMarker`, `SyncConnectionState`.
- Produces (MatronJournal):
  - `enum ProjectsRefreshOutcome { succeeded, unsupported, stopped, failed(MissionsRefreshFailure) }`
  - `enum ProjectRefreshOutcome { loaded(projectID: String), notFound, stopped, failed(MissionsRefreshFailure) }`
  - `actor ProjectsSync` — `init(api:store:markers:connectionStates:)`, `start()`, `stop() async`, `supportedStream() -> AsyncStream<Bool>`, `isSupported`, `refresh() async -> ProjectsRefreshOutcome`, `refreshProject(id:) async -> ProjectRefreshOutcome`, `beginWatching(convoID:)`, `endWatching(convoID:)`, `refreshConversationMissions(convoID:) async`, `createProject(title:body:) async throws -> Project`, `mergeProject(id:into:) async throws`, `setMissionProject(missionID:project:) async throws -> Mission`.

Triggers (spec §4.2 "Apps refresh `GET /projects` on any mission marker, and while the Projects tab is open"): a reconnect → full list; ANY mission/milestone marker → list refresh, coalesced so a catch-up replay of a hundred markers costs at most two GETs; a marker in a **watched** conversation (one whose chat is on screen) → that conversation's links. Unwatched conversations' links are never fetched from markers.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/ProjectsSyncTests.swift`:

```swift
import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeProjects: ProjectsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [Project] = []
    private var _listError: Error?
    private var _listCalls = 0
    private var _details: [String: ProjectDetail] = [:]
    private var _links: [String: [ConversationMissionLink]] = [:]
    private var _linkCalls: [String] = []
    private var _created: [(String, String?, String)] = []
    private var _merged: [(String, String)] = []
    private var _filed: [(String, String?)] = []
    private var _listGate: CheckedContinuation<Void, Never>?
    private var _blockNextList = false

    var list: [Project] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var details: [String: ProjectDetail] { get { lock.withLock { _details } } set { lock.withLock { _details = newValue } } }
    var links: [String: [ConversationMissionLink]] { get { lock.withLock { _links } } set { lock.withLock { _links = newValue } } }
    var linkCalls: [String] { lock.withLock { _linkCalls } }
    var created: [(String, String?, String)] { lock.withLock { _created } }
    var merged: [(String, String)] { lock.withLock { _merged } }
    var filed: [(String, String?)] { lock.withLock { _filed } }
    var blockNextList: Bool { get { lock.withLock { _blockNextList } } set { lock.withLock { _blockNextList = newValue } } }
    var isListGated: Bool { lock.withLock { _listGate != nil } }
    func releaseListGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _listGate = nil }; return _listGate }
        c?.resume()
    }

    func listProjects() async throws -> ProjectsListDecode {
        lock.withLock { _listCalls += 1 }
        if blockNextList {
            blockNextList = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _listGate = c } }
        }
        if let e = listError { throw e }
        return ProjectsListDecode(projects: list, droppedIDs: [])
    }
    func project(id: String) async throws -> ProjectDetail {
        guard let d = details[id] else { throw JournalAPIError.notFound }
        return d
    }
    func createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project {
        lock.withLock { _created.append((title, body, idempotencyKey)) }
        return Project(id: "pj_new", num: 9000, title: title, createdAt: Date(timeIntervalSince1970: 1),
                       updatedAt: Date(timeIntervalSince1970: 1))
    }
    func mergeProject(id: String, into: String) async throws { lock.withLock { _merged.append((id, into)) } }
    func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        lock.withLock { _filed.append((missionID, project)) }
        return Mission(id: missionID, num: 61, title: "M61", originConvoID: "c1",
                       createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 3),
                       projectID: project)
    }
    func conversationMissions(convoID: String) async throws -> [ConversationMissionLink] {
        lock.withLock { _linkCalls.append(convoID) }
        guard let l = links[convoID] else { throw JournalAPIError.notFound }
        return l
    }
}

final class ProjectsSyncTests: XCTestCase {
    private func project(_ id: String, num: Int) -> Project {
        Project(id: id, num: num, title: "P\(num)", createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2))
    }

    private func make(api: FakeProjects) throws -> (ProjectsSync, JournalStore,
                                                     AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation,
                                                     AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: MissionMarker)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ProjectsSync(api: api, store: store, markers: { markers }, connectionStates: { states })
        return (sync, store, mc, sc)
    }

    private func marker(_ missionID: String = "ms_1") -> MissionMarker {
        .mission(MissionMarkerEvent(missionID: missionID, num: 61, action: .joined))
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReconnectFetchesTheListIntoTheStore() async throws {
        let api = FakeProjects()
        api.list = [project("pj_1", num: 1), project("pj_2", num: 2)]
        let (sync, store, _, states) = try make(api: api)
        await sync.start()
        states.yield(.running)
        try await waitUntil { try store.projects().count == 2 }
        await sync.stop()
    }

    /// Review Focus: an old journal answers 404 — unsupported, not an error.
    func testListNotFoundIsUnsupported() async throws {
        let api = FakeProjects()
        api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        var supported = await sync.supportedStream().makeAsyncIterator()
        XCTAssertEqual(await supported.next(), true, "optimistic until proven")
        let outcome = await sync.refresh()
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertEqual(await supported.next(), false)
    }

    func testRefreshProjectWritesEveryPart() async throws {
        let api = FakeProjects()
        let mission = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", projectID: "pj_1")
        api.details["pj_1"] = ProjectDetail(
            project: project("pj_1", num: 1), missions: [mission],
            needsYou: [TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q",
                                   originConvoID: "c1", missionID: "ms_1", missionNum: 61)],
            recentMilestones: [Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "s",
                                         convoID: "c1", seq: 1)],
            sessionsByBox: ["greg": 2])
        let (sync, store, _, _) = try make(api: api)
        let outcome = await sync.refreshProject(id: "pj_1")
        XCTAssertEqual(outcome, .loaded(projectID: "pj_1"))
        XCTAssertNotNil(try store.project(id: "pj_1"))
        XCTAssertEqual(try store.mission(id: "ms_1")?.projectID, "pj_1")
        XCTAssertEqual(try store.item(id: "it_1")?.missionNum, 61)
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_1"])
    }

    /// A merged project's detail answers with the target (spec §4.2).
    func testRefreshingAMergedProjectReportsTheTarget() async throws {
        let api = FakeProjects()
        api.details["pj_old"] = ProjectDetail(project: project("pj_new", num: 2), missions: [], needsYou: [],
                                              recentMilestones: [], sessionsByBox: [:])
        let (sync, _, _, _) = try make(api: api)
        let outcome = await sync.refreshProject(id: "pj_old")
        XCTAssertEqual(outcome, .loaded(projectID: "pj_new"))
        let missing = await sync.refreshProject(id: "pj_gone")
        XCTAssertEqual(missing, .notFound)
    }

    /// A catch-up replay floods markers: the list refresh coalesces, and an
    /// unwatched conversation's links are never fetched.
    func testAMarkerFloodCostsAtMostTwoListFetchesAndNoLinkFetches() async throws {
        let api = FakeProjects()
        api.blockNextList = true
        let (sync, _, markers, _) = try make(api: api)
        await sync.start()
        markers.yield((convoID: "c-unwatched", marker: marker()))
        try await waitUntil { api.isListGated }
        for _ in 0..<50 { markers.yield((convoID: "c-unwatched", marker: marker())) }
        try await Task.sleep(for: .milliseconds(100))
        api.releaseListGate()
        try await waitUntil { api.listCalls == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.listCalls, 2)
        XCTAssertEqual(api.linkCalls, [])
        await sync.stop()
    }

    func testAWatchedConversationRefetchesItsLinksOnOpenAndOnAMarker() async throws {
        let api = FakeProjects()
        let m = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1")
        api.links["c1"] = [ConversationMissionLink(mission: m, isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1))]
        let (sync, store, markers, _) = try make(api: api)
        await sync.start()
        await sync.beginWatching(convoID: "c1")
        try await waitUntil { try store.conversationMissions(convoID: "c1").sections.current?.id == "ms_1" }
        markers.yield((convoID: "c1", marker: marker()))
        try await waitUntil { api.linkCalls.count == 2 }
        await sync.endWatching(convoID: "c1")
        markers.yield((convoID: "c1", marker: marker()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.linkCalls.count, 2, "no longer watched")
        await sync.stop()
    }

    func testWritesLandInTheStore() async throws {
        let api = FakeProjects()
        let (sync, store, _, _) = try make(api: api)
        let created = try await sync.createProject(title: "Promo", body: nil)
        XCTAssertEqual(created.id, "pj_new")
        XCTAssertEqual(try store.project(id: "pj_new")?.title, "Promo")
        XCTAssertFalse(api.created[0].2.isEmpty, "an idempotency key is always sent")
        let filed = try await sync.setMissionProject(missionID: "ms_1", project: "pj_new")
        XCTAssertEqual(filed.projectID, "pj_new")
        XCTAssertEqual(try store.mission(id: "ms_1")?.projectID, "pj_new")
        try await sync.mergeProject(id: "pj_a", into: "pj_b")
        XCTAssertEqual(api.merged.map(\.1), ["pj_b"])
    }

    /// A created project must survive a list GET that left before it existed.
    func testACreateDuringAListFetchSurvivesTheReplace() async throws {
        let api = FakeProjects()
        api.list = []
        api.blockNextList = true
        let (sync, store, _, _) = try make(api: api)
        let list = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        _ = try await sync.createProject(title: "Fresh", body: nil)
        api.releaseListGate()
        _ = await list.value
        XCTAssertNotNil(try store.project(id: "pj_new"))
    }

    func testStopPreventsLaterWrites() async throws {
        let api = FakeProjects()
        api.list = [project("pj_1", num: 1)]
        api.blockNextList = true
        let (sync, store, _, _) = try make(api: api)
        let run = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let stopping = Task { await sync.stop() }
        try await Task.sleep(for: .milliseconds(50))
        api.releaseListGate()
        _ = await run.value
        await stopping.value
        XCTAssertEqual(try store.projects(), [])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.ProjectsSyncTests'`
Expected: build FAILS — `cannot find 'ProjectsSync' in scope`.

- [ ] **Step 3: Implement `ProjectsSync.swift`**

```swift
import Foundation
import os
import MatronModels
import MatronEvents

public enum ProjectsRefreshOutcome: Equatable, Sendable {
    case succeeded
    /// `GET /projects` 404: a journal that predates projects.
    case unsupported
    case stopped
    case failed(MissionsRefreshFailure)
}

public enum ProjectRefreshOutcome: Equatable, Sendable {
    /// The id the journal answered with — a merged project's TARGET.
    case loaded(projectID: String)
    case notFound
    case stopped
    case failed(MissionsRefreshFailure)
}

/// Keeps the local project cache and conversation links fresh (spec
/// 2026-09-30 §4.2, §6). Cloned from `MissionsSync`: markers are
/// invalidation signals only, nothing they carry is written.
public actor ProjectsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "projects-sync")

    private let api: any ProjectsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var inFlightRefresh: Task<ProjectsRefreshOutcome, Never>?
    /// Set when a refresh is requested while one runs: the running pass
    /// repeats ONCE, however many requests arrived (the marker flood rule).
    private var refreshAgain = false
    /// Ids a detail fetch or a create wrote since the current list GET
    /// started — kept by `replaceProjects` (same race as `MissionsSync` H1).
    private var protectedSinceListStart: Set<String> = []
    /// Conversation id → number of on-screen chat views showing it.
    private var watched: [String: Int] = [:]
    private var inFlightLinks: [String: Task<Void, Never>] = [:]
    private var linksAgain: Set<String> = []
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var stopped = false

    public init(api: any ProjectsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
    }

    // MARK: Support

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

    // MARK: Lifetime

    public func start() {
        stopped = false
        guard markerTask == nil else { return }
        let markers = markers()
        markerTask = Task { [weak self] in
            for await (convoID, _) in markers {
                guard let self else { return }
                await self.markerLanded(convoID: convoID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                if case .running = state { await self.refresh() }
            }
        }
    }

    public func stop() async {
        stopped = true
        watched = [:]
        let mt = markerTask, st = stateTask
        markerTask = nil; stateTask = nil
        mt?.cancel(); st?.cancel()
        let refresh = inFlightRefresh
        let links = Array(inFlightLinks.values)
        await mt?.value; await st?.value
        _ = await refresh?.value
        for t in links { await t.value }
    }

    /// Never awaits the fetches it starts: the marker loop must keep
    /// draining so a flood collapses into one repeat (`refreshAgain`).
    private func markerLanded(convoID: String) {
        if watched[convoID, default: 0] > 0 {
            Task { await self.refreshConversationMissions(convoID: convoID) }
        }
        if inFlightRefresh != nil { refreshAgain = true } else { Task { await self.refresh() } }
    }

    // MARK: List

    @discardableResult
    public func refresh() async -> ProjectsRefreshOutcome {
        guard !stopped else { return .stopped }
        if let running = inFlightRefresh {
            refreshAgain = true
            return await running.value
        }
        var run: Task<ProjectsRefreshOutcome, Never>!
        run = Task { [self] in
            var outcome = await refreshOnce()
            while refreshAgain, !stopped {
                refreshAgain = false
                outcome = await refreshOnce()
            }
            if inFlightRefresh == run { inFlightRefresh = nil }
            return outcome
        }
        inFlightRefresh = run
        return await run.value
    }

    private func refreshOnce() async -> ProjectsRefreshOutcome {
        protectedSinceListStart.removeAll()
        do {
            let decoded = try await api.listProjects()
            guard !stopped, !Task.isCancelled else { return .stopped }
            try store.replaceProjects(decoded.projects,
                                      keeping: protectedSinceListStart.union(decoded.droppedIDs))
            setSupported(true)
            return .succeeded
        } catch JournalAPIError.notFound {
            setSupported(false)
            return .unsupported
        } catch {
            Self.logger.warning("projects refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    // MARK: One project

    @discardableResult
    public func refreshProject(id: String) async -> ProjectRefreshOutcome {
        guard !stopped else { return .stopped }
        do {
            let detail = try await api.project(id: id)
            guard !stopped else { return .stopped }
            try store.upsertProjects([detail.project])
            try store.setProjectSessionsByBox(id: detail.project.id, detail.sessionsByBox)
            try store.upsertMissions(detail.missions)
            try store.upsertItems(detail.needsYou)
            try store.upsertMilestones(detail.recentMilestones)
            protectedSinceListStart.insert(detail.project.id)
            return .loaded(projectID: detail.project.id)
        } catch JournalAPIError.notFound {
            return .notFound
        } catch {
            Self.logger.warning("project \(id, privacy: .public) refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    // MARK: Conversation links (the header chip)

    /// A chat view came on screen. Counted, so two windows on one
    /// conversation keep it watched until both leave. Returns at once; the
    /// first fetch runs in the background.
    public func beginWatching(convoID: String) {
        guard !stopped else { return }
        watched[convoID, default: 0] += 1
        Task { await self.refreshConversationMissions(convoID: convoID) }
    }

    public func endWatching(convoID: String) {
        guard let n = watched[convoID] else { return }
        watched[convoID] = n <= 1 ? nil : n - 1
    }

    public func refreshConversationMissions(convoID: String) async {
        guard !stopped else { return }
        if let running = inFlightLinks[convoID] {
            linksAgain.insert(convoID)
            await running.value
            return
        }
        let run = Task { [self] in
            await refreshLinksOnce(convoID)
            while linksAgain.remove(convoID) != nil { await refreshLinksOnce(convoID) }
            inFlightLinks[convoID] = nil
        }
        inFlightLinks[convoID] = run
        await run.value
    }

    private func refreshLinksOnce(_ convoID: String) async {
        guard !stopped else { return }
        do {
            let links = try await api.conversationMissions(convoID: convoID)
            guard !stopped else { return }
            try store.replaceConversationMissionLinks(convoID: convoID, links)
        } catch JournalAPIError.notFound {
            // An old journal, or a conversation it doesn't know: the local
            // derivation in `missionsStream(convoID:)` stands.
        } catch {
            Self.logger.warning("links \(convoID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Writes (interactive; each throws its real message)

    public func createProject(title: String, body: String?) async throws -> Project {
        let project = try await api.createProject(title: title, body: body, idempotencyKey: UUID().uuidString)
        guard !stopped else { return project }
        try store.upsertProjects([project])
        protectedSinceListStart.insert(project.id)
        return project
    }

    public func mergeProject(id: String, into: String) async throws {
        try await api.mergeProject(id: id, into: into)
        guard !stopped else { return }
        _ = await refresh()
        _ = await refreshProject(id: into)
    }

    @discardableResult
    public func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        let mission = try await api.setMissionProject(missionID: missionID, project: project)
        guard !stopped else { return mission }
        try store.upsertMissions([mission])
        Task { await self.refresh() }
        return mission
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.ProjectsSyncTests'`
Expected: PASS (all nine). Rerun twice more to shake out timing flakes; all three runs must pass.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/ProjectsSync.swift MatronShared/Tests/JournalTests/ProjectsSyncTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: ProjectsSync — list, detail, watched-conversation links, writes" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Wire `ProjectsSync` into both apps; PR 1

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (`JournalCore`, core construction ~line 322, sign-out teardown, `missionsSync(for:)` neighbour)
- Modify: `MatronMac/App/AppDependencies.swift` (same places: `JournalCore` ~line 60–95, construction ~line 175, teardown ~line 593)
- Test: `MatronMacTests/MacAppDependenciesTests.swift` (build only), full suites

**Interfaces:**
- Produces: `JournalCore.projects: ProjectsSync`, `JournalCore.projectsStartTask`; `AppDependencies.projectsSync(for: UserSession) -> ProjectsSync` on both platforms.

- [ ] **Step 1: Add the core field and construction (both files)**

In each `JournalCore`, after `var missionsStartTask: Task<Void, Never>?`:

```swift
        /// Keeps the project cache and on-screen conversations' mission
        /// links fresh (spec 2026-09-30 §6). Started with the session,
        /// stopped with the rest of the teardown on sign-out.
        let projects: ProjectsSync
        var projectsStartTask: Task<Void, Never>?
```

Add `projects: ProjectsSync` to `JournalCore.init` right after `missions: MissionsSync` and assign it. Where the core is built, after `let missions = MissionsSync(...)`:

```swift
        let projects = ProjectsSync(api: api, store: store, markers: { engine.missionMarkers() },
                                    connectionStates: { engine.stateStream() })
```

pass `projects: projects` to `JournalCore(...)`, and after `core.missionsStartTask = Task { await missions.start() }`:

```swift
        core.projectsStartTask = Task { await projects.start() }
```

In the sign-out teardown, directly after `await core.missions.stop()`:

```swift
                await core.projectsStartTask?.value
                await core.projects.stop()
```

Beside `missionsSync(for:)`:

```swift
    func projectsSync(for session: UserSession) -> ProjectsSync {
        core(for: session).projects
    }
```

- [ ] **Step 2: Build and run every suite**

Run: `swift test --package-path MatronShared`
Expected: `Executed N tests, with 0 failures` (N = main's count plus this PR's new tests).
Run: `xcodegen generate && git checkout Matron/App/Info.plist`
Run the iOS suite: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` and an `Executed N tests, with 0 failures` line.
Run the Mac suite: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: failures limited to the four pre-existing ones named in Global Constraints.

- [ ] **Step 3: Commit, push, open PR 1**

```bash
git add Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: start ProjectsSync with the session on iOS and Mac" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/projects-data
gh pr create --base main --title "Projects (1/4): shared data layer" --body "$(cat <<'BODY'
Shared layer for spec 2026-09-30 (projects + multi-mission conversations): wire models, migration v14, project and conversation-link store reads, JournalAPI routes, ProjectsSync. No UI change; an old journal's 404s are handled as unsupported / legacy derivation.

Plan: docs/superpowers/plans/2026-09-30-projects-apple.md (Tasks 1–9)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

# PR 2 — view models and shared views

Branch: `feat/projects-shared-ui`, from `feat/projects-data`.

### Task 10: Home and page value types, conversation grouping, `ProjectsHomeAssembly`

**Files:**
- Create: `MatronShared/Sources/Models/ProjectsHome.swift`
- Create: `MatronShared/Sources/Models/MissionConversationGroups.swift`
- Create: `MatronShared/Sources/ViewModels/ProjectsHomeAssembly.swift`
- Test: `MatronShared/Tests/ViewModelTests/ProjectsHomeAssemblyTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 models; existing `DashboardSession`, `DashboardSessionState(sessionState:)`, `TrackerItem`.
- Produces (MatronModels):
  - `ProjectCard { project; needsYouCount; latestMilestone: MissionLastMilestone? }`
  - `MissionRowModel { mission; activity: MissionActivity; needsYouCount; lastActivity: Date; init(closed:) }`
  - `ProjectsHomeSnapshot { cards; unfiled; quiet; closed: [Mission]; statusRefreshedAt: Date?; isEmpty; openProjects }`
  - `enum ProjectsHomeAction { openProject(String), openMission(String), newProject, moveMission(missionID: String, projectID: String?) }`
  - `ProjectPageModel { project; missions: [MissionRowModel]; closedMissions; needsYou: [TrackerItem]; recentMilestones; missionNums: [String: Int]; sessionsByBox: [String: Int]; sessionsByMission: [String: [DashboardSession]]; mergeTargets: [Project]; unfiledMissions: [Mission]; needsYouCount }`
  - `MissionConversationRow { conversation; state: DashboardSessionState; subchats; subchatCount }`, `MissionConversationGroups { onItNow; earlier; subchatTotal; init(conversations:missionState:liveStates:) }`
- Produces (MatronViewModels): `enum ProjectsHomeAssembly` — `quietAfter`, `lastActivity(of:)`, `activity(of:needsYou:now:)`, `row(for:needsYouItems:now:)`, `missionRows(_:needsYouItems:now:)`, `card(for:missions:needsYouItems:)`, `assemble(projects:missions:needsYouItems:now:)`.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/ViewModelTests/ProjectsHomeAssemblyTests.swift`:

```swift
import XCTest
import MatronModels
@testable import MatronViewModels

final class ProjectsHomeAssemblyTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    static let day: TimeInterval = 86_400

    static func mission(_ id: String, num: Int, project: String? = nil, activity: MissionActivity? = nil,
                        needsYou: Int = 0, lastMilestone: TimeInterval? = 3_600, state: MissionState = .open,
                        closedAt: TimeInterval? = nil, milestoneTitle: String = "step") -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: "c1",
                createdAt: ago(30 * day), updatedAt: ago(30 * day),
                lastMilestoneAt: lastMilestone.map(ago), closedAt: closedAt.map(ago), needsYou: needsYou,
                lastMilestone: lastMilestone.map { MissionLastMilestone(num: num + 1000, title: milestoneTitle,
                                                                        kind: .progress, createdAt: ago($0)) },
                projectID: project, activity: activity)
    }

    static func project(_ id: String, num: Int, running: Int = 0, needsYou: Int = 0,
                        lastActivity: TimeInterval = 3_600, state: MissionState = .open) -> Project {
        Project(id: id, num: num, state: state, title: "P\(num)", createdAt: ago(30 * day), updatedAt: ago(day),
                missions: ProjectMissionCounts(running: running, waiting: 1), needsYou: needsYou,
                lastActivityAt: ago(lastActivity))
    }

    // MARK: Activity

    func testActivityPrefersTheServerValue() {
        let m = Self.mission("ms_1", num: 1, activity: .running, lastMilestone: 30 * Self.day)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: m, needsYou: 0, now: Self.now), .running)
    }

    func testActivityDerivesQuietAfterSevenDaysAndNeverWithNeedsYou() {
        let old = Self.mission("ms_1", num: 1, lastMilestone: 8 * Self.day)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: old, needsYou: 0, now: Self.now), .quiet)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: old, needsYou: 1, now: Self.now), .waiting)
        let fresh = Self.mission("ms_2", num: 2, lastMilestone: 6 * Self.day)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: fresh, needsYou: 0, now: Self.now), .idle)
        let serverQuietButAsking = Self.mission("ms_3", num: 3, activity: .quiet)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: serverQuietButAsking, needsYou: 2, now: Self.now), .waiting)
    }

    // MARK: Home

    func testCardsSortNeedsYouThenRunningThenActivity() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_quiet", num: 1, lastActivity: 60),
                       Self.project("pj_running", num: 2, running: 1, lastActivity: 7_200),
                       Self.project("pj_asks", num: 3, needsYou: 2, lastActivity: 9_000),
                       Self.project("pj_closed", num: 4, state: .closed)],
            missions: [], needsYouItems: [:], now: Self.now)
        XCTAssertEqual(snapshot.cards.map(\.id), ["pj_asks", "pj_running", "pj_quiet"])
    }

    func testCardNeedsYouUsesTheLargerCountAndCarriesTheLatestMilestone() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_1", num: 1, needsYou: 1)],
            missions: [Self.mission("ms_1", num: 10, project: "pj_1", needsYou: 2, lastMilestone: 9_000, milestoneTitle: "older"),
                       Self.mission("ms_2", num: 11, project: "pj_1", lastMilestone: 60, milestoneTitle: "newest")],
            needsYouItems: ["ms_2": [TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q",
                                                 originConvoID: "c1", missionID: "ms_2")]],
            now: Self.now)
        XCTAssertEqual(snapshot.cards.first?.needsYouCount, 3)
        XCTAssertEqual(snapshot.cards.first?.latestMilestone?.title, "newest")
    }

    func testUnfiledRowsSplitQuietAndSortNeedsYouThenActivityRank() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_1", num: 1)],
            missions: [Self.mission("ms_filed", num: 1, project: "pj_1"),
                       Self.mission("ms_idle", num: 2, activity: .idle, lastMilestone: 60),
                       Self.mission("ms_running", num: 3, activity: .running, lastMilestone: 7_200),
                       Self.mission("ms_asks", num: 4, activity: .waiting, needsYou: 1, lastMilestone: 90_000),
                       Self.mission("ms_quiet_old", num: 5, activity: .quiet, lastMilestone: 20 * Self.day),
                       Self.mission("ms_quiet_new", num: 6, activity: .quiet, lastMilestone: 9 * Self.day),
                       Self.mission("ms_closed", num: 7, state: .closed, closedAt: 60)],
            needsYouItems: [:], now: Self.now)
        XCTAssertEqual(snapshot.unfiled.map(\.id), ["ms_asks", "ms_running", "ms_idle"])
        XCTAssertEqual(snapshot.quiet.map(\.id), ["ms_quiet_new", "ms_quiet_old"])
        XCTAssertEqual(snapshot.closed.map(\.id), ["ms_closed"])
    }

    /// Review Focus: a project this device hasn't cached (or one that
    /// closed) must not swallow its missions.
    func testAMissionInAnUnknownProjectStaysOnTheHomeScreen() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_closed", num: 9, state: .closed)],
            missions: [Self.mission("ms_1", num: 1, project: "pj_unknown", activity: .running),
                       Self.mission("ms_2", num: 2, project: "pj_closed", activity: .idle)],
            needsYouItems: [:], now: Self.now)
        XCTAssertEqual(Set(snapshot.unfiled.map(\.id)), ["ms_1", "ms_2"])
    }

    func testStatusRefreshedIsTheNewestProjectStatus() {
        let a = Project(id: "pj_a", num: 1, title: "A", statusUpdatedAt: Self.ago(600))
        let b = Project(id: "pj_b", num: 2, title: "B", statusUpdatedAt: Self.ago(60))
        let snapshot = ProjectsHomeAssembly.assemble(projects: [a, b], missions: [], needsYouItems: [:], now: Self.now)
        XCTAssertEqual(snapshot.statusRefreshedAt, Self.ago(60))
    }

    // MARK: Conversation groups

    private func convo(_ id: String, state: String = "running", joined: TimeInterval? = 100, ended: TimeInterval? = nil,
                       parent: String? = nil, subchats: Int = 0) -> MissionConversation {
        MissionConversation(id: id, title: id, box: "greg", state: state,
                            joinedAt: joined.map(Self.ago), endedAt: ended.map(Self.ago), how: "joined",
                            parentConvoID: parent, subchatCount: subchats)
    }

    func testGroupsSplitOnItNowAndEarlier() {
        let groups = MissionConversationGroups(conversations: [
            convo("c-wait", state: "waiting", joined: 50),
            convo("c-run", state: "running", joined: 500),
            convo("c-gone-old", ended: 900),
            convo("c-gone-new", ended: 100),
        ], missionState: .open)
        XCTAssertEqual(groups.onItNow.map(\.id), ["c-run", "c-wait"], "running first")
        XCTAssertEqual(groups.earlier.map(\.id), ["c-gone-new", "c-gone-old"], "most recently ended first")
    }

    func testSubChatsFoldUnderTheirParent() {
        let groups = MissionConversationGroups(conversations: [
            convo("c1"), convo("c1:sub:a", parent: "c1"), convo("c1:sub:b", parent: "c1"),
        ], missionState: .open)
        XCTAssertEqual(groups.onItNow.map(\.id), ["c1"])
        XCTAssertEqual(groups.onItNow.first?.subchats.map(\.id), ["c1:sub:a", "c1:sub:b"])
        XCTAssertEqual(groups.subchatTotal, 2)
    }

    /// Review Focus: the parent never joined — the child is its own row.
    func testAnOrphanSubChatIsItsOwnRow() {
        let groups = MissionConversationGroups(conversations: [convo("c9:sub:x", parent: "c9")], missionState: .open)
        XCTAssertEqual(groups.onItNow.map(\.id), ["c9:sub:x"])
    }

    func testTheJournalsFoldedCountIsKeptWhenSubChatsAreNotListed() {
        let groups = MissionConversationGroups(conversations: [convo("c1", subchats: 6)], missionState: .open)
        XCTAssertEqual(groups.onItNow.first?.subchatCount, 6)
    }

    func testAClosedMissionHasOnlyEarlierAndLiveStateWins() {
        let closed = MissionConversationGroups(conversations: [convo("c1")], missionState: .closed)
        XCTAssertEqual(closed.onItNow, []); XCTAssertEqual(closed.earlier.map(\.id), ["c1"])
        let live = MissionConversationGroups(conversations: [convo("c1", state: "running")], missionState: .open,
                                             liveStates: ["c1": "done"])
        XCTAssertEqual(live.onItNow.first?.state, .done)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.ProjectsHomeAssemblyTests'`
Expected: build FAILS — `cannot find 'ProjectsHomeAssembly' in scope`.

- [ ] **Step 3: Implement the value types**

`MatronShared/Sources/Models/ProjectsHome.swift`:

```swift
import Foundation

// Value types for the Projects home and project page (spec 2026-09-30 §2,
// §6). Built by `ProjectsHomeAssembly` / `ProjectDetailViewModel`
// (MatronViewModels), drawn by the Projects views (MatronDesignSystem).

/// One project card: title, needs-you, one status paragraph, the state
/// bar and counts. No sessions, milestones or item rows (spec §2).
public struct ProjectCard: Identifiable, Equatable, Hashable, Sendable {
    public let project: Project
    /// The larger of the server's `needs_you` and the local mission counts.
    public let needsYouCount: Int
    /// Newest milestone across the project's missions — the "No written
    /// status yet — latest: …" line.
    public let latestMilestone: MissionLastMilestone?
    public var id: String { project.id }
    public init(project: Project, needsYouCount: Int = 0, latestMilestone: MissionLastMilestone? = nil) {
        self.project = project; self.needsYouCount = needsYouCount; self.latestMilestone = latestMilestone
    }
}

/// One slim mission row: dot · #num · title · one-line status · needs-you · age.
public struct MissionRowModel: Identifiable, Equatable, Hashable, Sendable {
    public let mission: Mission
    public let activity: MissionActivity
    public let needsYouCount: Int
    public let lastActivity: Date
    public var id: String { mission.id }
    public init(mission: Mission, activity: MissionActivity, needsYouCount: Int = 0, lastActivity: Date) {
        self.mission = mission; self.activity = activity; self.needsYouCount = needsYouCount
        self.lastActivity = lastActivity
    }
    /// A closed mission's row (the Closed fold): grey dot, closing time.
    public init(closed mission: Mission) {
        self.init(mission: mission, activity: .idle, lastActivity: mission.closedAt ?? mission.updatedAt)
    }
}

public struct ProjectsHomeSnapshot: Equatable, Sendable {
    public var cards: [ProjectCard]
    /// Open missions in no (known, open) project, not quiet.
    public var unfiled: [MissionRowModel]
    /// Open unfiled missions quiet for over a week.
    public var quiet: [MissionRowModel]
    public var closed: [Mission]
    /// Newest project status time — "Status refreshed 20m ago".
    public var statusRefreshedAt: Date?
    public init(cards: [ProjectCard] = [], unfiled: [MissionRowModel] = [], quiet: [MissionRowModel] = [],
                closed: [Mission] = [], statusRefreshedAt: Date? = nil) {
        self.cards = cards; self.unfiled = unfiled; self.quiet = quiet; self.closed = closed
        self.statusRefreshedAt = statusRefreshedAt
    }
    public var isEmpty: Bool { cards.isEmpty && unfiled.isEmpty && quiet.isEmpty && closed.isEmpty }
    /// The "Move to project…" choices.
    public var openProjects: [Project] { cards.map(\.project) }
}

/// Every tap on the Projects home, routed through one function per host.
public enum ProjectsHomeAction: Equatable, Hashable, Sendable {
    case openProject(String)
    case openMission(String)
    case newProject
    /// `projectID == nil` takes the mission out of its project.
    case moveMission(missionID: String, projectID: String?)
}

/// Everything the project page draws (spec §2 "Project page").
public struct ProjectPageModel: Equatable, Sendable {
    public var project: Project
    /// Open missions, needs-you first, then activity.
    public var missions: [MissionRowModel]
    public var closedMissions: [Mission]
    public var needsYou: [TrackerItem]
    /// The latest 5 milestones across the project's missions.
    public var recentMilestones: [Milestone]
    /// Mission id → `#num`, for the milestone rows' chips.
    public var missionNums: [String: Int]
    public var sessionsByBox: [String: Int]
    /// Filled by the host from `MissionsDashboardViewModel.sessionsByMission`.
    public var sessionsByMission: [String: [DashboardSession]]
    public var mergeTargets: [Project]
    /// "Add a mission" choices.
    public var unfiledMissions: [Mission]

    public init(project: Project, missions: [MissionRowModel] = [], closedMissions: [Mission] = [],
                needsYou: [TrackerItem] = [], recentMilestones: [Milestone] = [], missionNums: [String: Int] = [:],
                sessionsByBox: [String: Int] = [:], sessionsByMission: [String: [DashboardSession]] = [:],
                mergeTargets: [Project] = [], unfiledMissions: [Mission] = []) {
        self.project = project; self.missions = missions; self.closedMissions = closedMissions
        self.needsYou = needsYou; self.recentMilestones = recentMilestones; self.missionNums = missionNums
        self.sessionsByBox = sessionsByBox; self.sessionsByMission = sessionsByMission
        self.mergeTargets = mergeTargets; self.unfiledMissions = unfiledMissions
    }

    public var needsYouCount: Int { max(project.needsYou, needsYou.count) }
}
```

`MatronShared/Sources/Models/MissionConversationGroups.swift`:

```swift
import Foundation

/// One top-level conversation on a mission page, its sub-chats folded in.
public struct MissionConversationRow: Identifiable, Equatable, Hashable, Sendable {
    public let conversation: MissionConversation
    public let state: DashboardSessionState
    public let subchats: [MissionConversation]
    public var id: String { conversation.id }
    /// The journal's folded count when it didn't list them, else the listed ones.
    public var subchatCount: Int { max(conversation.subchatCount, subchats.count) }
    public init(conversation: MissionConversation, state: DashboardSessionState, subchats: [MissionConversation] = []) {
        self.conversation = conversation; self.state = state; self.subchats = subchats
    }
}

/// The mission page's "On it now" / "Earlier" split (spec §2). On it now:
/// an active link on an open mission. Earlier: an ended link, or every
/// link once the mission is closed. A sub-chat folds under its parent when
/// the parent is listed; otherwise it is a row of its own.
public struct MissionConversationGroups: Equatable, Sendable {
    public let onItNow: [MissionConversationRow]
    public let earlier: [MissionConversationRow]

    public var subchatTotal: Int { (onItNow + earlier).reduce(0) { $0 + $1.subchatCount } }

    /// `liveStates`: conversation id → the store's `session_state`, which
    /// wins over the detail row's (possibly stale) `state`.
    public init(conversations: [MissionConversation], missionState: MissionState, liveStates: [String: String] = [:]) {
        let ids = Set(conversations.map(\.id))
        var children: [String: [MissionConversation]] = [:]
        var top: [MissionConversation] = []
        for c in conversations {
            if let parent = c.parentConvoID, ids.contains(parent) {
                children[parent, default: []].append(c)
            } else {
                top.append(c)
            }
        }
        let rows = top.map { c in
            MissionConversationRow(conversation: c,
                                   state: DashboardSessionState(sessionState: liveStates[c.id] ?? c.state),
                                   subchats: (children[c.id] ?? []).sorted { $0.id < $1.id })
        }
        let open = missionState == .open
        onItNow = rows.filter { open && $0.conversation.isActive }.sorted(by: Self.onItNowPrecedes)
        earlier = rows.filter { !(open && $0.conversation.isActive) }.sorted(by: Self.earlierPrecedes)
    }

    private static func onItNowPrecedes(_ a: MissionConversationRow, _ b: MissionConversationRow) -> Bool {
        if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
        let (ja, jb) = (a.conversation.joinedAt ?? .distantPast, b.conversation.joinedAt ?? .distantPast)
        if ja != jb { return ja > jb }
        return a.id < b.id
    }

    private static func earlierPrecedes(_ a: MissionConversationRow, _ b: MissionConversationRow) -> Bool {
        let (ea, eb) = (a.conversation.endedAt ?? .distantPast, b.conversation.endedAt ?? .distantPast)
        if ea != eb { return ea > eb }
        return a.id < b.id
    }
}
```

- [ ] **Step 4: Implement `ProjectsHomeAssembly`**

`MatronShared/Sources/ViewModels/ProjectsHomeAssembly.swift`:

```swift
import Foundation
import MatronModels

/// The Projects home and page rules (spec 2026-09-30 §2), pure so every
/// one is a plain unit test.
public enum ProjectsHomeAssembly {
    /// "Quiet for over a week" (spec §2, decision 5).
    public static let quietAfter: TimeInterval = 7 * 86_400

    /// The row's age: newest of last milestone, status and update.
    public static func lastActivity(of mission: Mission) -> Date {
        ([mission.lastMilestoneAt, mission.statusUpdatedAt].compactMap { $0 } + [mission.updatedAt]).max()
            ?? mission.createdAt
    }

    /// The server's value when it sent one; otherwise derived. Anything
    /// asking the user is waiting, never quiet — a quiet fold must not
    /// hide a question.
    public static func activity(of mission: Mission, needsYou: Int, now: Date) -> MissionActivity {
        if let server = mission.activity { return server == .quiet && needsYou > 0 ? .waiting : server }
        if needsYou > 0 { return .waiting }
        return now.timeIntervalSince(lastActivity(of: mission)) > quietAfter ? .quiet : .idle
    }

    public static func row(for mission: Mission, needsYouItems: [String: [TrackerItem]], now: Date) -> MissionRowModel {
        let needsYou = max(mission.needsYou, needsYouItems[mission.id]?.count ?? 0)
        return MissionRowModel(mission: mission, activity: activity(of: mission, needsYou: needsYou, now: now),
                               needsYouCount: needsYou, lastActivity: lastActivity(of: mission))
    }

    /// Open missions as rows, needs-you first, then running → waiting →
    /// idle → quiet, then newest activity, then the higher number.
    public static func missionRows(_ missions: [Mission], needsYouItems: [String: [TrackerItem]], now: Date) -> [MissionRowModel] {
        missions.filter { $0.state == .open }.map { row(for: $0, needsYouItems: needsYouItems, now: now) }
            .sorted(by: rowPrecedes)
    }

    static func rowPrecedes(_ a: MissionRowModel, _ b: MissionRowModel) -> Bool {
        let (na, nb) = (a.needsYouCount > 0, b.needsYouCount > 0)
        if na != nb { return na }
        if a.activity.sortRank != b.activity.sortRank { return a.activity.sortRank < b.activity.sortRank }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.mission.num > b.mission.num
    }

    public static func card(for project: Project, missions: [Mission], needsYouItems: [String: [TrackerItem]]) -> ProjectCard {
        let mine = missions.filter { $0.projectID == project.id && $0.state == .open }
        let local = mine.reduce(0) { $0 + max($1.needsYou, needsYouItems[$1.id]?.count ?? 0) }
        let latest = mine.compactMap(\.lastMilestone).max { $0.createdAt < $1.createdAt }
        return ProjectCard(project: project, needsYouCount: max(project.needsYou, local), latestMilestone: latest)
    }

    /// Needs you first, then anything running, then newest activity.
    static func cardPrecedes(_ a: ProjectCard, _ b: ProjectCard) -> Bool {
        let (na, nb) = (a.needsYouCount > 0, b.needsYouCount > 0)
        if na != nb { return na }
        let (ra, rb) = (a.project.missions.running > 0, b.project.missions.running > 0)
        if ra != rb { return ra }
        let (la, lb) = (a.project.lastActivityAt ?? .distantPast, b.project.lastActivityAt ?? .distantPast)
        if la != lb { return la > lb }
        return a.project.num > b.project.num
    }

    public static func assemble(projects: [Project], missions: [Mission], needsYouItems: [String: [TrackerItem]],
                                now: Date) -> ProjectsHomeSnapshot {
        let openProjects = projects.filter { $0.state == .open }
        let openIDs = Set(openProjects.map(\.id))
        // Unfiled includes a mission whose project this device doesn't know
        // or that closed — it must stay visible somewhere.
        let unfiledRows = missionRows(missions.filter { m in m.projectID.map { !openIDs.contains($0) } ?? true },
                                      needsYouItems: needsYouItems, now: now)
        let closed = missions.filter { $0.state == .closed }.sorted { a, b in
            let (ca, cb) = (a.closedAt ?? .distantPast, b.closedAt ?? .distantPast)
            return ca != cb ? ca > cb : a.num > b.num
        }
        return ProjectsHomeSnapshot(
            cards: openProjects.map { card(for: $0, missions: missions, needsYouItems: needsYouItems) }.sorted(by: cardPrecedes),
            unfiled: unfiledRows.filter { $0.activity != .quiet },
            quiet: unfiledRows.filter { $0.activity == .quiet }.sorted { $0.lastActivity > $1.lastActivity },
            closed: closed,
            statusRefreshedAt: projects.compactMap(\.statusUpdatedAt).max())
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.ProjectsHomeAssemblyTests'`
Expected: PASS (all twelve).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Models/ProjectsHome.swift MatronShared/Sources/Models/MissionConversationGroups.swift \
        MatronShared/Sources/ViewModels/ProjectsHomeAssembly.swift MatronShared/Tests/ViewModelTests/ProjectsHomeAssemblyTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: home/page value types, conversation grouping and the pure assembly" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: `ProjectsStoreReading`/`ProjectsSyncing`; projects on `MissionsDashboardViewModel`

**Files:**
- Create: `MatronShared/Sources/ViewModels/ProjectsStoreReading.swift`
- Modify: `MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift`
- Modify: `MatronShared/Sources/ViewModels/MissionsDashboardAssembly.swift` (`MissionsDashboardInputs.projects`; `missionSessions` drops rows with a `parentConvoID`)
- Create: `MatronShared/Tests/ViewModelTests/ProjectsFakes.swift` (shared test fakes, internal)
- Test: `MatronShared/Tests/ViewModelTests/MissionsDashboardProjectsTests.swift` (new)

**Interfaces:**
- Consumes: Task 6 store streams; Task 8 `ProjectsSync`; Task 10 `ProjectsHomeAssembly`, `ProjectsHomeSnapshot`.
- Produces (MatronViewModels):
  - `protocol ProjectsStoreReading: Sendable` — `projectsStream()`, `projectStream(id:)`, `missionsStream(projectID:)`, `unfiledOpenMissionsStream()`, `needsYouItemsStream(projectID:)`, `recentMilestonesStream(projectID:limit:)`, `projectSessionsByBoxStream(id:)`; `JournalStore` conforms.
  - `protocol ProjectsSyncing: Sendable` — `refresh()`, `refreshProject(id:)`, `beginWatching(convoID:)`, `endWatching(convoID:)`, `createProject(title:body:)`, `mergeProject(id:into:)`, `setMissionProject(missionID:project:)`, `supportedStream()`; `ProjectsSync` conforms.
  - `MissionsDashboardViewModel`: init gains trailing `projectsStore: (any ProjectsStoreReading)? = nil, projects: (any ProjectsSyncing)? = nil`; new `home: ProjectsHomeSnapshot`, `projectsSupported: Bool?`, `canCreateProject: Bool`, public observable `sessionsByMission: [String: [DashboardSession]]`, `createProject(title:body:) async -> Project?`, `moveMission(_:to:) async`, `projectPageDidAppear()/Disappear()`, `looseSectionDidAppear()/Disappear()`.

The home is a new snapshot on the same session-long view model: it already owns the missions stream, the needs-you stream, the tab badge and the page lifetimes, so the fallback (projects unsupported → today's dashboard) is a host `if` over one model.

- [ ] **Step 1: Write the shared fakes**

Create `MatronShared/Tests/ViewModelTests/ProjectsFakes.swift`:

```swift
import Foundation
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// A stream that hands its continuation to the test.
final class Feed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Value>.Continuation] = []
    private var last: Value?
    func stream() -> AsyncStream<Value> {
        let (s, c) = AsyncStream<Value>.makeStream()
        lock.withLock {
            continuations.append(c)
            if let last { c.yield(last) }
        }
        return s
    }
    func send(_ value: Value) {
        let cs = lock.withLock { () -> [AsyncStream<Value>.Continuation] in last = value; return continuations }
        for c in cs { c.yield(value) }
    }
    var subscribers: Int { lock.withLock { continuations.count } }
}

final class FakeProjectsStore: ProjectsStoreReading, @unchecked Sendable {
    let projects = Feed<[Project]>()
    let unfiled = Feed<[Mission]>()
    private let lock = NSLock()
    private var projectFeeds: [String: Feed<Project?>] = [:]
    private var missionFeeds: [String: Feed<[Mission]>] = [:]
    private var needsYouFeeds: [String: Feed<[TrackerItem]>] = [:]
    private var milestoneFeeds: [String: Feed<[Milestone]>] = [:]
    private var sessionFeeds: [String: Feed<[String: Int]>] = [:]

    private func feed<V>(_ table: ReferenceWritableKeyPath<FakeProjectsStore, [String: Feed<V>]>, _ id: String) -> Feed<V> {
        lock.withLock {
            if let f = self[keyPath: table][id] { return f }
            let f = Feed<V>(); self[keyPath: table][id] = f; return f
        }
    }
    func project(_ id: String) -> Feed<Project?> { feed(\.projectFeeds, id) }
    func missions(_ id: String) -> Feed<[Mission]> { feed(\.missionFeeds, id) }
    func needsYou(_ id: String) -> Feed<[TrackerItem]> { feed(\.needsYouFeeds, id) }
    func milestones(_ id: String) -> Feed<[Milestone]> { feed(\.milestoneFeeds, id) }
    func sessions(_ id: String) -> Feed<[String: Int]> { feed(\.sessionFeeds, id) }

    func projectsStream() -> AsyncStream<[Project]> { projects.stream() }
    func projectStream(id: String) -> AsyncStream<Project?> { project(id).stream() }
    func missionsStream(projectID: String) -> AsyncStream<[Mission]> { missions(projectID).stream() }
    func unfiledOpenMissionsStream() -> AsyncStream<[Mission]> { unfiled.stream() }
    func needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]> { needsYou(projectID).stream() }
    func recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]> { milestones(projectID).stream() }
    func projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]> { sessions(id).stream() }
}

final class FakeProjectsSync: ProjectsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    let supported = Feed<Bool>()
    var refreshCalls: Int { lock.withLock { _refreshCalls } }
    var projectOutcomes: [String: ProjectRefreshOutcome] {
        get { lock.withLock { _projectOutcomes } } set { lock.withLock { _projectOutcomes = newValue } }
    }
    var refreshedProjects: [String] { lock.withLock { _refreshedProjects } }
    var created: [(String, String?)] { lock.withLock { _created } }
    var merged: [(String, String)] { lock.withLock { _merged } }
    var filed: [(String, String?)] { lock.withLock { _filed } }
    var failWrites: Error? { get { lock.withLock { _failWrites } } set { lock.withLock { _failWrites = newValue } } }
    private var _refreshCalls = 0
    private var _projectOutcomes: [String: ProjectRefreshOutcome] = [:]
    private var _refreshedProjects: [String] = []
    private var _created: [(String, String?)] = []
    private var _merged: [(String, String)] = []
    private var _filed: [(String, String?)] = []
    private var _failWrites: Error?

    init() { supported.send(true) }
    func refresh() async -> ProjectsRefreshOutcome { lock.withLock { _refreshCalls += 1 }; return .succeeded }
    func refreshProject(id: String) async -> ProjectRefreshOutcome {
        lock.withLock { _refreshedProjects.append(id) }
        return projectOutcomes[id] ?? .loaded(projectID: id)
    }
    func beginWatching(convoID: String) async {}
    func endWatching(convoID: String) async {}
    func createProject(title: String, body: String?) async throws -> Project {
        if let e = failWrites { throw e }
        lock.withLock { _created.append((title, body)) }
        return Project(id: "pj_new", num: 9000, title: title)
    }
    func mergeProject(id: String, into: String) async throws {
        if let e = failWrites { throw e }
        lock.withLock { _merged.append((id, into)) }
    }
    func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        if let e = failWrites { throw e }
        lock.withLock { _filed.append((missionID, project)) }
        return Mission(id: missionID, num: 1, title: "M", originConvoID: "c1", projectID: project)
    }
    func supportedStream() async -> AsyncStream<Bool> { supported.stream() }
}

final class FakeMissionsSyncForProjects: MissionsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshedMissions: [String] = []
    var refreshedMissions: [String] { lock.withLock { _refreshedMissions } }
    func refresh() async -> MissionsRefreshOutcome { .succeeded }
    func refreshMission(id: String) async -> MissionsRefreshOutcome {
        lock.withLock { _refreshedMissions.append(id) }; return .succeeded
    }
    func closeMission(id: String, summary: String) async throws -> Mission {
        Mission(id: id, num: 1, state: .closed, title: "M", originConvoID: "c1")
    }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
}

final class FakeDashboardStoreForProjects: MissionsDashboardStoreReading, @unchecked Sendable {
    let missions = Feed<[Mission]>()
    let needsYou = Feed<[String: [TrackerItem]]>()
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missions.stream() }
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]> { AsyncStream { $0.yield([:]) } }
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]> { AsyncStream { $0.yield([:]) } }
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]> { needsYou.stream() }
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]> { AsyncStream { $0.yield([:]) } }
    func sessionStatesStream() -> AsyncStream<[String: String]> { AsyncStream { $0.yield([:]) } }
}

@MainActor
func waitForProjects(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
```

(Add `import XCTest` at the top of the file for `XCTFail`. The helper is named `waitForProjects` because several ViewModelTests files already declare a file-private `waitUntil`, and a same-named internal global would make their calls ambiguous.)

- [ ] **Step 2: Write the failing tests**

Create `MatronShared/Tests/ViewModelTests/MissionsDashboardProjectsTests.swift`:

```swift
import XCTest
import MatronChat
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class MissionsDashboardProjectsTests: XCTestCase {
    private func make() -> (MissionsDashboardViewModel, FakeDashboardStoreForProjects, FakeProjectsStore, FakeProjectsSync) {
        let store = FakeDashboardStoreForProjects()
        let projectsStore = FakeProjectsStore()
        let projects = FakeProjectsSync()
        let vm = MissionsDashboardViewModel(
            store: store, sync: FakeMissionsSyncForProjects(),
            summaries: { AsyncThrowingStream { $0.yield([]) } },
            roster: { [:] }, send: { _, _ in },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            projectsStore: projectsStore, projects: projects)
        return (vm, store, projectsStore, projects)
    }

    func testHomeAssemblesFromProjectsAndMissions() async {
        let (vm, store, projectsStore, _) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo")])
        store.missions.send([Mission(id: "ms_1", num: 10, title: "Filed", originConvoID: "c1", projectID: "pj_1"),
                             Mission(id: "ms_2", num: 11, title: "Loose", originConvoID: "c1", activity: .running)])
        store.needsYou.send([:])
        await waitForProjects { vm.home.cards.count == 1 && vm.home.unfiled.count == 1 }
        XCTAssertEqual(vm.home.cards.first?.id, "pj_1")
        XCTAssertEqual(vm.home.unfiled.first?.id, "ms_2")
        vm.stop()
    }

    func testProjectsSupportFollowsTheSync() async {
        let (vm, _, _, projects) = make()
        vm.start()
        await waitForProjects { vm.projectsSupported == true }
        projects.supported.send(false)
        await waitForProjects { vm.projectsSupported == false }
        XCTAssertFalse(vm.canCreateProject)
        vm.stop()
    }

    func testRefreshAlsoRefreshesProjects() async {
        let (vm, _, _, projects) = make()
        await vm.refresh()
        XCTAssertGreaterThanOrEqual(projects.refreshCalls, 1)
    }

    func testCreateProjectTrimsAndRejectsAnEmptyTitle() async {
        let (vm, _, _, projects) = make()
        let none = await vm.createProject(title: "   ", body: nil)
        XCTAssertNil(none)
        XCTAssertEqual(vm.error, "Give the project a title.")
        vm.error = nil
        let made = await vm.createProject(title: "  Promo launch ", body: "site")
        XCTAssertEqual(made?.title, "Promo launch")
        XCTAssertEqual(projects.created.first?.0, "Promo launch")
    }

    func testMoveMissionFilesThroughTheSyncAndReportsFailure() async {
        let (vm, _, _, projects) = make()
        await vm.moveMission("ms_1", to: "pj_1")
        XCTAssertEqual(projects.filed.first?.0, "ms_1"); XCTAssertEqual(projects.filed.first?.1, "pj_1")
        projects.failWrites = JournalAPIError.http(status: 403, message: "not yours")
        await vm.moveMission("ms_1", to: nil)
        XCTAssertNotNil(vm.error)
    }

    /// The Chats tab's section needs summaries, not the 60 s roster poll.
    func testTheLooseSectionRunsTheSummariesFeedButNotTheRoster() async {
        let (vm, _, _, _) = make()
        vm.start()
        vm.looseSectionDidAppear()
        XCTAssertTrue(vm.isSummariesFeedLive)
        XCTAssertFalse(vm.isRosterLoopLive)
        vm.projectPageDidAppear()
        XCTAssertTrue(vm.isRosterLoopLive)
        vm.projectPageDidDisappear()
        XCTAssertFalse(vm.isRosterLoopLive)
        XCTAssertTrue(vm.isSummariesFeedLive, "the Chats section still watches")
        vm.looseSectionDidDisappear()
        XCTAssertFalse(vm.isSummariesFeedLive)
        vm.stop()
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.MissionsDashboardProjectsTests'`
Expected: build FAILS — `cannot find type 'ProjectsStoreReading' in scope`.

- [ ] **Step 4: Implement the protocols**

`MatronShared/Sources/ViewModels/ProjectsStoreReading.swift`:

```swift
import Foundation
import MatronModels
import MatronJournal

/// The store reads the projects surfaces need, as a protocol so tests fake
/// the store. Conformance declared here because MatronJournal cannot import
/// this module.
public protocol ProjectsStoreReading: Sendable {
    func projectsStream() -> AsyncStream<[Project]>
    func projectStream(id: String) -> AsyncStream<Project?>
    func missionsStream(projectID: String) -> AsyncStream<[Mission]>
    func unfiledOpenMissionsStream() -> AsyncStream<[Mission]>
    func needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]>
    func recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]>
    func projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]>
}

extension JournalStore: ProjectsStoreReading {}

/// The refresh/write surface, mirroring `MissionsSyncing`.
public protocol ProjectsSyncing: Sendable {
    @discardableResult func refresh() async -> ProjectsRefreshOutcome
    @discardableResult func refreshProject(id: String) async -> ProjectRefreshOutcome
    func beginWatching(convoID: String) async
    func endWatching(convoID: String) async
    func createProject(title: String, body: String?) async throws -> Project
    func mergeProject(id: String, into: String) async throws
    @discardableResult func setMissionProject(missionID: String, project: String?) async throws -> Mission
    func supportedStream() async -> AsyncStream<Bool>
}

extension ProjectsSync: ProjectsSyncing {}
```

- [ ] **Step 5: Extend the dashboard view model and assembly**

In `MissionsDashboardAssembly.swift`: add `public var projects: [Project] = []` to `MissionsDashboardInputs`, and in `missionSessions(for:inputs:summariesByID:)` change the filter to

```swift
        let conversations = (inputs.conversationsByMission[mission.id] ?? []).filter { convo in
            // The detail now lists sub-chats (`?subchats=1`); they are the
            // work of a listed session, as the `:sub:` rule already says.
            convo.parentConvoID == nil && !convo.id.contains(JournalEventType.childConvoInfix)
        }
```

In `MissionsDashboardViewModel.swift`:

1. Replace `@ObservationIgnored private var sessionsByMission: [String: [DashboardSession]] = [:]` with

```swift
    /// Every mission's sessions, uncapped. Observable: the project page's
    /// session chips read it (spec 2026-09-30 §2).
    public private(set) var sessionsByMission: [String: [DashboardSession]] = [:]
    /// The Projects home (spec 2026-09-30 §2, §6).
    public private(set) var home = ProjectsHomeSnapshot()
    /// `false` once `GET /projects` 404s: the host shows today's dashboard.
    public private(set) var projectsSupported: Bool?
    public var canCreateProject: Bool { projects != nil && projectsSupported != false }
    @ObservationIgnored private let projectsStore: (any ProjectsStoreReading)?
    @ObservationIgnored private let projects: (any ProjectsSyncing)?
    @ObservationIgnored private var projectPageVisible = false
    @ObservationIgnored private var looseSectionVisible = false
```

2. Init: append `projectsStore: (any ProjectsStoreReading)? = nil, projects: (any ProjectsSyncing)? = nil` after `now:` and assign `self.projectsStore = projectsStore; self.projects = projects`.

3. In `start()`, after the `sessionStatesStream` observation:

```swift
        if let projectsStore {
            tasks.append(observe(projectsStore.projectsStream()) { $0.inputs.projects = $1 })
        }
        if let projects {
            tasks.append(Task { [weak self] in
                let stream = await projects.supportedStream()
                for await supported in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.projectsSupported = supported
                }
            })
        }
```

and replace the `if pageVisible || missionPageVisible { … }` block with

```swift
        if pageVisible || missionPageVisible || projectPageVisible || looseSectionVisible { startSummariesIfNeeded() }
        if pageVisible || missionPageVisible || projectPageVisible { startRosterLoopIfNeeded() }
```

4. In `performRebuild()`, replace `sessionsByMission = snapshot.sessionsByMission` with

```swift
        if sessionsByMission != snapshot.sessionsByMission { sessionsByMission = snapshot.sessionsByMission }
        let nextHome = ProjectsHomeAssembly.assemble(projects: inputs.projects, missions: inputs.missions,
                                                     needsYouItems: inputs.needsYouItems, now: now())
        if home != nextHome { home = nextHome }
```

5. Replace `stopLiveFeedsIfUnwatched()`:

```swift
    private func stopLiveFeedsIfUnwatched() {
        if !pageVisible, !missionPageVisible, !projectPageVisible {
            rosterTask?.cancel(); rosterTask = nil
        }
        guard !pageVisible, !missionPageVisible, !projectPageVisible, !looseSectionVisible else { return }
        summariesTask?.cancel(); summariesTask = nil
    }
```

6. Add the visibility hooks beside `missionPageDidAppear`:

```swift
    /// The project page shows session chips per mission: summaries + roster.
    public func projectPageDidAppear() {
        projectPageVisible = true
        if isStarted { startSummariesIfNeeded() }
        startRosterLoopIfNeeded()
    }

    public func projectPageDidDisappear() {
        projectPageVisible = false
        stopLiveFeedsIfUnwatched()
    }

    /// The Chats tab's "Not on a mission" section (spec §6): summaries only —
    /// its rows fall back to TOC / snippet text, so no roster poll runs while
    /// the chat list is simply on screen.
    public func looseSectionDidAppear() {
        looseSectionVisible = true
        if isStarted { startSummariesIfNeeded() }
    }

    public func looseSectionDidDisappear() {
        looseSectionVisible = false
        stopLiveFeedsIfUnwatched()
    }
```

7. In `refreshList()`, after the missions `switch`:

```swift
        if let projects, case .failed(let failure) = await projects.refresh(), error == nil {
            error = failure.message
        }
```

8. Add the two writes after `askCoordinator()`:

```swift
    // MARK: Projects (spec 2026-09-30 §6 "Filing")

    /// "New project". Returns the project so the host can open it.
    public func createProject(title: String, body: String?) async -> Project? {
        guard let projects else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Give the project a title."
            return nil
        }
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await projects.createProject(title: trimmed, body: trimmedBody?.isEmpty == true ? nil : trimmedBody)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// "Move to project…" on a row. `nil` takes it out of its project.
    public func moveMission(_ missionID: String, to projectID: String?) async {
        guard let projects else { return }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.(MissionsDashboardProjectsTests|MissionsDashboardViewModelTests|MissionsDashboardAssemblyTests)'`
Expected: PASS — the existing dashboard tests prove nothing about the old page changed.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/ViewModels/ProjectsStoreReading.swift MatronShared/Sources/ViewModels/MissionsDashboardViewModel.swift \
        MatronShared/Sources/ViewModels/MissionsDashboardAssembly.swift MatronShared/Tests/ViewModelTests/ProjectsFakes.swift \
        MatronShared/Tests/ViewModelTests/MissionsDashboardProjectsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: the dashboard view model assembles the Projects home" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `ProjectDetailViewModel`

**Files:**
- Create: `MatronShared/Sources/ViewModels/ProjectDetailViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/ProjectDetailViewModelTests.swift` (new)

**Interfaces:**
- Consumes: Task 11 `ProjectsStoreReading`, `ProjectsSyncing`, fakes; Task 10 `ProjectPageModel`, `ProjectsHomeAssembly.missionRows`; existing `MissionsSyncing`, `MissionsDashboardViewModel.forEach`, `.maxDetailRefreshesInFlight`.
- Produces: `@MainActor @Observable final class ProjectDetailViewModel` — `projectID: String` (changes on a redirect), `page: ProjectPageModel?`, `isMissing`, `isBusy`, `error`; `init(projectID:store:projects:missions:now:)`, `start()`, `stop()`, `refresh() async`, `merge(into:) async -> Bool`, `addMission(_:) async`, `moveMission(_:to:) async`; `static let recentMilestoneCount = 5`.

A merged project redirects two ways (spec §4.2): the cached row is closed with `merged_into` (works offline and the instant a list refresh lands), or `GET /projects/:id` answers with the target.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/ViewModelTests/ProjectDetailViewModelTests.swift`:

```swift
import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class ProjectDetailViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(_ id: String = "pj_1") -> (ProjectDetailViewModel, FakeProjectsStore, FakeProjectsSync,
                                                 FakeMissionsSyncForProjects) {
        let store = FakeProjectsStore(), projects = FakeProjectsSync(), missions = FakeMissionsSyncForProjects()
        let now = self.now
        let vm = ProjectDetailViewModel(projectID: id, store: store, projects: projects, missions: missions, now: { now })
        return (vm, store, projects, missions)
    }

    func testPageAssemblesFromTheStreams() async {
        let (vm, store, _, _) = make()
        vm.start()
        store.projects.send([Project(id: "pj_1", num: 1, title: "Promo"), Project(id: "pj_2", num: 2, title: "Apps")])
        store.unfiled.send([Mission(id: "ms_9", num: 9, title: "Loose", originConvoID: "c1")])
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo", needsYou: 1))
        store.missions("pj_1").send([
            Mission(id: "ms_1", num: 10, title: "Open", originConvoID: "c1", projectID: "pj_1", activity: .running),
            Mission(id: "ms_2", num: 11, state: .closed, title: "Done", originConvoID: "c1", projectID: "pj_1"),
        ])
        store.needsYou("pj_1").send([TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q",
                                                 originConvoID: "c1", missionID: "ms_1", missionNum: 10)])
        store.milestones("pj_1").send([Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "s",
                                                 convoID: "c1", seq: 1)])
        store.sessions("pj_1").send(["greg": 2])
        await waitForProjects { vm.page?.sessionsByBox == ["greg": 2] && vm.page?.recentMilestones.count == 1 }
        let page = try! XCTUnwrap(vm.page)
        XCTAssertEqual(page.missions.map(\.id), ["ms_1"])
        XCTAssertEqual(page.missions.first?.needsYouCount, 1)
        XCTAssertEqual(page.closedMissions.map(\.id), ["ms_2"])
        XCTAssertEqual(page.missionNums["ms_1"], 10)
        XCTAssertEqual(page.mergeTargets.map(\.id), ["pj_2"], "never itself")
        XCTAssertEqual(page.unfiledMissions.map(\.id), ["ms_9"])
        vm.stop()
    }

    /// Review Focus: the cached row says it was merged away.
    func testAMergedProjectRedirectsToItsTarget() async {
        let (vm, store, _, _) = make("pj_old")
        vm.start()
        store.project("pj_old").send(Project(id: "pj_old", num: 1, state: .closed, title: "Old", mergedInto: "pj_new"))
        await waitForProjects { vm.projectID == "pj_new" }
        await waitForProjects { store.project("pj_new").subscribers > 0 }
        store.project("pj_new").send(Project(id: "pj_new", num: 2, title: "New"))
        await waitForProjects { vm.page?.project.id == "pj_new" }
        vm.stop()
    }

    /// Review Focus: the server answers the old id with the target.
    func testTheServerRedirectSwitchesTheStreams() async {
        let (vm, store, projects, _) = make("pj_old")
        projects.projectOutcomes["pj_old"] = .loaded(projectID: "pj_new")
        vm.start()
        await waitForProjects { vm.projectID == "pj_new" }
        store.project("pj_new").send(Project(id: "pj_new", num: 2, title: "New"))
        await waitForProjects { vm.page?.project.title == "New" }
        vm.stop()
    }

    func testNotFoundWithNothingCachedIsMissing() async {
        let (vm, _, projects, _) = make("pj_gone")
        projects.projectOutcomes["pj_gone"] = .notFound
        await vm.refresh()
        XCTAssertTrue(vm.isMissing)
    }

    func testRefreshFetchesOpenMissionDetails() async {
        let (vm, store, _, missions) = make()
        vm.start()
        store.missions("pj_1").send([
            Mission(id: "ms_1", num: 10, title: "A", originConvoID: "c1", projectID: "pj_1"),
            Mission(id: "ms_2", num: 11, state: .closed, title: "B", originConvoID: "c1", projectID: "pj_1"),
        ])
        await waitForProjects { vm.hasMissions }
        await vm.refresh()
        XCTAssertEqual(missions.refreshedMissions, ["ms_1"], "closed missions need no session chips")
        vm.stop()
    }

    func testMergeSwitchesToTheTargetAndAddMissionFiles() async {
        let (vm, _, projects, _) = make()
        let merged = await vm.merge(into: "pj_2")
        XCTAssertTrue(merged)
        XCTAssertEqual(projects.merged.first?.1, "pj_2")
        XCTAssertEqual(vm.projectID, "pj_2")
        await vm.addMission("ms_9")
        XCTAssertEqual(projects.filed.last?.0, "ms_9"); XCTAssertEqual(projects.filed.last?.1, "pj_2")
        let selfMerge = await vm.merge(into: "pj_2")
        XCTAssertFalse(selfMerge, "a project never merges into itself")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.ProjectDetailViewModelTests'`
Expected: build FAILS — `cannot find 'ProjectDetailViewModel' in scope`.

- [ ] **Step 3: Implement**

`MatronShared/Sources/ViewModels/ProjectDetailViewModel.swift`:

```swift
import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs one project page (spec 2026-09-30 §2 "Project page"). Everything
/// it shows comes from the store; `refresh()` fills the store from
/// `GET /projects/:id` and then refreshes the open missions' details so
/// their session chips have conversations to draw.
@MainActor @Observable
public final class ProjectDetailViewModel {
    public static let recentMilestoneCount = 5

    /// The project shown. Changes when the project turns out to have been
    /// merged into another (spec §4.2 redirect).
    public private(set) var projectID: String
    public private(set) var page: ProjectPageModel?
    /// The journal says there is no such project and nothing is cached.
    public private(set) var isMissing = false
    public private(set) var isBusy = false
    public var error: String?

    @ObservationIgnored private var project: Project?
    @ObservationIgnored private var missions: [Mission] = []
    @ObservationIgnored private var needsYou: [TrackerItem] = []
    @ObservationIgnored private var milestones: [Milestone] = []
    @ObservationIgnored private var sessionsByBox: [String: Int] = [:]
    @ObservationIgnored private var openProjects: [Project] = []
    @ObservationIgnored private var unfiled: [Mission] = []
    @ObservationIgnored private var projectTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sharedTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let store: any ProjectsStoreReading
    @ObservationIgnored private let projects: any ProjectsSyncing
    @ObservationIgnored private let missionsSync: any MissionsSyncing
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Test seam: whether the missions stream has delivered anything.
    var hasMissions: Bool { !missions.isEmpty }

    public init(projectID: String, store: any ProjectsStoreReading, projects: any ProjectsSyncing,
                missions: any MissionsSyncing, now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectID = projectID; self.store = store; self.projects = projects
        self.missionsSync = missions; self.now = now
    }

    public func start() {
        stop()
        sharedTasks.append(observe(store.projectsStream()) { $0.openProjects = $1.filter { $0.state == .open } })
        sharedTasks.append(observe(store.unfiledOpenMissionsStream()) { $0.unfiled = $1 })
        observeProject()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    public func stop() {
        for t in projectTasks + sharedTasks { t.cancel() }
        projectTasks = []; sharedTasks = []
        refreshTask?.cancel(); refreshTask = nil
    }

    private func observeProject() {
        for t in projectTasks { t.cancel() }
        let id = projectID
        projectTasks = [
            observe(store.projectStream(id: id)) { vm, project in
                if let project, project.state == .closed, let target = project.mergedInto, target != vm.projectID {
                    vm.switchTo(target)
                } else {
                    vm.project = project
                }
            },
            observe(store.missionsStream(projectID: id)) { $0.missions = $1 },
            observe(store.needsYouItemsStream(projectID: id)) { $0.needsYou = $1 },
            observe(store.recentMilestonesStream(projectID: id, limit: Self.recentMilestoneCount)) { $0.milestones = $1 },
            observe(store.projectSessionsByBoxStream(id: id)) { $0.sessionsByBox = $1 },
        ]
    }

    private func observe<Value: Sendable>(_ stream: AsyncStream<Value>,
                                          _ apply: @escaping @MainActor (ProjectDetailViewModel, Value) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                apply(self, value)
                self.rebuild()
            }
        }
    }

    private func switchTo(_ id: String) {
        guard id != projectID else { return }
        projectID = id
        project = nil; missions = []; needsYou = []; milestones = []; sessionsByBox = [:]
        page = nil
        observeProject()
    }

    private func rebuild() {
        guard let project else {
            if page != nil { page = nil }
            return
        }
        var byMission: [String: [TrackerItem]] = [:]
        for item in needsYou { if let id = item.missionID { byMission[id, default: []].append(item) } }
        let next = ProjectPageModel(
            project: project,
            missions: ProjectsHomeAssembly.missionRows(missions, needsYouItems: byMission, now: now()),
            closedMissions: missions.filter { $0.state == .closed },
            needsYou: needsYou, recentMilestones: milestones,
            missionNums: Dictionary(missions.map { ($0.id, $0.num) }, uniquingKeysWith: { first, _ in first }),
            sessionsByBox: sessionsByBox,
            mergeTargets: openProjects.filter { $0.id != project.id },
            unfiledMissions: unfiled)
        if page != next { page = next }
    }

    public func refresh() async {
        switch await projects.refreshProject(id: projectID) {
        case .loaded(let resolved):
            error = nil
            isMissing = false
            if resolved != projectID { switchTo(resolved) }
            await refreshOpenMissionDetails()
        case .notFound:
            isMissing = project == nil
        case .failed(let failure):
            error = failure.message
        case .stopped:
            break
        }
    }

    /// The session chips on each mission row come from the missions'
    /// conversations, which only a detail fetch fills.
    private func refreshOpenMissionDetails() async {
        let ids = missions.filter { $0.state == .open }.map(\.id)
        let sync = missionsSync
        await MissionsDashboardViewModel.forEach(ids, maxConcurrent: MissionsDashboardViewModel.maxDetailRefreshesInFlight) { id in
            _ = await sync.refreshMission(id: id)
        }
    }

    /// "Merge into…" (spec §4.2): its missions move to `target` and this
    /// project closes. The page follows its missions.
    public func merge(into target: String) async -> Bool {
        guard target != projectID else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await projects.mergeProject(id: projectID, into: target)
            switchTo(target)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func addMission(_ missionID: String) async { await moveMission(missionID, to: projectID) }

    public func moveMission(_ missionID: String, to projectID: String?) async {
        isBusy = true
        defer { isBusy = false }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.ProjectDetailViewModelTests'`
Expected: PASS (six tests).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/ProjectDetailViewModel.swift MatronShared/Tests/ViewModelTests/ProjectDetailViewModelTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: ProjectDetailViewModel with merge redirect" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: `MissionDetailViewModel` — project, move, conversation groups

**Files:**
- Modify: `MatronShared/Sources/ViewModels/MissionDetailViewModel.swift`
- Modify: `MatronShared/Tests/ViewModelTests/ProjectsFakes.swift` (add `FakeMissionPageStore`)
- Test: `MatronShared/Tests/ViewModelTests/MissionDetailProjectsTests.swift` (new)

**Interfaces:**
- Consumes: Task 10 `MissionConversationGroups`; Task 11 `ProjectsStoreReading`, `ProjectsSyncing`.
- Produces on `MissionDetailViewModel`: init gains trailing `projectsStore: (any ProjectsStoreReading)? = nil, projects: (any ProjectsSyncing)? = nil`; `project: Project?`, `moveTargets: [Project]`, `conversationGroups: MissionConversationGroups`, `canMove: Bool`, `moveToProject(_ projectID: String?) async`; `sessionTags` now covers the conversations too.

- [ ] **Step 1: Add the fake and write the failing tests**

Append to `ProjectsFakes.swift`:

```swift
final class FakeMissionPageStore: MissionsStoreReading, @unchecked Sendable {
    let mission = Feed<Mission?>()
    let milestones = Feed<[Milestone]>()
    let items = Feed<[TrackerItem]>()
    let conversations = Feed<[MissionConversation]>()
    private let lock = NSLock()
    private var _taggedIDs: Set<String> = []
    var taggedIDs: Set<String> { lock.withLock { _taggedIDs } }
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { AsyncStream { $0.yield([]) } }
    func missionStream(id: String) -> AsyncStream<Mission?> { mission.stream() }
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> { milestones.stream() }
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]> { items.stream() }
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> { conversations.stream() }
    func sessionTag(convoID: String) -> SessionTagInputs? { nil }
    func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs] {
        lock.withLock { _taggedIDs = convoIDs }
        return [:]
    }
}
```

Create `MatronShared/Tests/ViewModelTests/MissionDetailProjectsTests.swift`:

```swift
import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class MissionDetailProjectsTests: XCTestCase {
    private func make() -> (MissionDetailViewModel, FakeMissionPageStore, FakeProjectsStore, FakeProjectsSync) {
        let store = FakeMissionPageStore(), projectsStore = FakeProjectsStore(), projects = FakeProjectsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: FakeMissionsSyncForProjects(),
                                        projectsStore: projectsStore, projects: projects)
        return (vm, store, projectsStore, projects)
    }

    func testProjectAndMoveTargetsFollowTheStreams() async {
        let (vm, store, projectsStore, _) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo"),
                                     Project(id: "pj_x", num: 2, state: .closed, title: "Old")])
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", projectID: "pj_1"))
        await waitForProjects { vm.project?.id == "pj_1" }
        XCTAssertEqual(vm.moveTargets.map(\.id), ["pj_1"], "closed projects are not targets")
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", projectID: nil))
        await waitForProjects { vm.project == nil }
        vm.stop()
    }

    func testConversationGroupsFollowTheMissionState() async {
        let (vm, store, _, _) = make()
        vm.start()
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1"))
        store.conversations.send([MissionConversation(id: "c1", title: "S", box: nil, state: "running")])
        await waitForProjects { vm.conversationGroups.onItNow.count == 1 }
        store.mission.send(Mission(id: "ms_1", num: 61, state: .closed, title: "M", originConvoID: "c1"))
        await waitForProjects { vm.conversationGroups.earlier.count == 1 && vm.conversationGroups.onItNow.isEmpty }
        XCTAssertTrue(store.taggedIDs.contains("c1"), "conversation rows get their A:bc tags too")
        vm.stop()
    }

    func testMoveToProjectFilesThroughTheSync() async {
        let (vm, _, _, projects) = make()
        XCTAssertTrue(vm.canMove)
        await vm.moveToProject("pj_2")
        XCTAssertEqual(projects.filed.first?.0, "ms_1"); XCTAssertEqual(projects.filed.first?.1, "pj_2")
        projects.failWrites = JournalAPIError.forbidden
        await vm.moveToProject(nil)
        XCTAssertNotNil(vm.error)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.MissionDetailProjectsTests'`
Expected: build FAILS — `extra arguments 'projectsStore', 'projects' in call`.

- [ ] **Step 3: Implement**

In `MissionDetailViewModel`:

```swift
    /// The project this mission is filed in (spec 2026-09-30 §6 "Mission
    /// page" chip and breadcrumb), when it is cached.
    public private(set) var project: Project?
    /// "Move to project…" choices: every open project.
    public private(set) var moveTargets: [Project] = []
    /// On it now / Earlier, sub-chats folded (spec §2).
    public private(set) var conversationGroups = MissionConversationGroups(conversations: [], missionState: .open)
    public var canMove: Bool { projects != nil }

    private let projectsStore: (any ProjectsStoreReading)?
    private let projects: (any ProjectsSyncing)?
    private var allProjects: [Project] = []
```

Init: append `projectsStore: (any ProjectsStoreReading)? = nil, projects: (any ProjectsSyncing)? = nil` and assign both.

In `start()`: in the `missionStream` task body replace `self.mission = v` with `self.mission = v; self.refreshDerived()`; in the `missionConversationsStream` task replace `self.conversations = v` with `self.conversations = v; self.refreshDerived()`; and add:

```swift
        if let projectsStore {
            tasks.append(Task { [weak self] in
                let s = projectsStore.projectsStream()
                for await v in s {
                    guard let self, !Task.isCancelled else { return }
                    self.allProjects = v
                    self.refreshDerived()
                }
            })
        }
```

Replace `refreshSessionTags()` and add `refreshDerived()` and the write:

```swift
    private func refreshSessionTags() {
        sessionTags = store.sessionTags(convoIDs: Set(allMilestones.map(\.convoID)).union(conversations.map(\.id)))
    }

    private func refreshDerived() {
        project = mission?.projectID.flatMap { id in allProjects.first { $0.id == id } }
        moveTargets = allProjects.filter { $0.state == .open }
        conversationGroups = MissionConversationGroups(conversations: conversations,
                                                       missionState: mission?.state ?? .open)
        refreshSessionTags()
    }

    /// "Move to project…" (spec §6 "Filing"). `nil` takes it out.
    public func moveToProject(_ projectID: String?) async {
        guard let projects else { return }
        isBusy = true
        defer { isBusy = false }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.(MissionDetailProjectsTests|MissionsViewModelTests)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/MissionDetailViewModel.swift MatronShared/Tests/ViewModelTests/ProjectsFakes.swift \
        MatronShared/Tests/ViewModelTests/MissionDetailProjectsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions: the mission page knows its project, moves it, groups its conversations" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Project atoms — format, dot, bar, chip, card, slim mission row, move menu

**Files:**
- Create folder `MatronShared/Sources/DesignSystem/Projects/` with: `ProjectsFormat.swift`, `ProjectGlyphs.swift` (`ProjectGlyph`, `MissionActivityDot`, `ProjectActivityBar`, `ProjectChip`), `ProjectCardView.swift`, `MoveToProjectMenu.swift`
- Modify: `MatronShared/Sources/DesignSystem/Missions/MissionRowView.swift` (rewritten slim)
- Modify: `MatronShared/Sources/DesignSystem/Missions/MissionsDashboardView.swift` (Closed section's call site only)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ProjectsSnapshotTests.swift` (new), `MissionsSnapshotTests.swift` (`testMissionRow`)

**Interfaces:**
- Consumes: Task 1/10 models; existing `NeedsYouPill`, `RelativeMinuteTimeView.format(_:now:)`, `MissionsDashboardFormat.relative`, `DashboardCardChrome`.
- Produces (MatronDesignSystem):
  - `enum ProjectsFormat` — `countsLine(_:statusUpdatedAt:lastActivityAt:now:)`, `noStatusLine(latest:now:)`, `missionLine(_:now:)`, `shortDate(_:timeZone:)`, `linkSpan(joinedAt:endedAt:how:timeZone:)`, `headerLine(_:timeZone:)`, `sessionsByBox(_:)`, `conversationsSummary(_:)`.
  - `enum ProjectGlyph { symbol, chipSymbol, tint }`; `MissionActivityDot(activity:isClosed:)`; `ProjectActivityBar(counts:)`; `ProjectChip(title:action:)`.
  - `ProjectCardView(card:now:onOpen:)`.
  - `MissionRowView(row: MissionRowModel, now: Date? = nil)` — replaces `init(mission:attribution:)`.
  - `MoveToProjectMenu(currentProjectID:targets:onMove:)`.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/ProjectsSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectsSnapshotTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    static let utc = TimeZone(identifier: "UTC")!

    static let promo = Project(
        id: "pj_1", num: 4000, title: "Promo launch", status:
            "Launch Wed 7 Oct, 07:00 (fallback 13 Oct). The branch is green. Waiting on you: leavers' page, claims copy, Cloudflare.",
        statusBy: .agent, statusUpdatedAt: ago(660),
        missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 0, quiet: 1, closed: 3), needsYou: 6,
        lastActivityAt: ago(240))
    static let silent = Project(
        id: "pj_2", num: 4001, title: "Sales tax & bulk payments",
        missions: ProjectMissionCounts(quiet: 6), lastActivityAt: ago(2 * 86_400))

    static func row(_ num: Int, _ title: String, activity: MissionActivity, status: String?, needsYou: Int = 0,
                    age: TimeInterval) -> MissionRowModel {
        MissionRowModel(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                         lastMilestone: MissionLastMilestone(num: num + 1, title: "PR 8601 merged",
                                                                             kind: .progress, createdAt: ago(86_400)),
                                         status: status),
                        activity: activity, needsYouCount: needsYou, lastActivity: ago(age))
    }

    // MARK: Pure

    func testCountsLine() {
        XCTAssertEqual(ProjectsFormat.countsLine(Self.promo.missions, statusUpdatedAt: Self.ago(660),
                                                 lastActivityAt: Self.ago(240), now: Self.now),
                       "5 missions · 2 running · 2 waiting · 1 quiet · updated 11m ago")
        XCTAssertEqual(ProjectsFormat.countsLine(Self.silent.missions, statusUpdatedAt: nil,
                                                 lastActivityAt: Self.ago(2 * 86_400), now: Self.now),
                       "6 missions · all quiet · last activity 2d ago")
        XCTAssertEqual(ProjectsFormat.countsLine(ProjectMissionCounts(running: 1), statusUpdatedAt: nil,
                                                 lastActivityAt: nil, now: Self.now),
                       "1 mission · 1 running")
    }

    func testNoStatusAndMissionLines() {
        XCTAssertEqual(ProjectsFormat.noStatusLine(latest: nil, now: Self.now), "No written status yet")
        XCTAssertEqual(ProjectsFormat.noStatusLine(
            latest: MissionLastMilestone(num: 1, title: "PR 8270 final", kind: .progress, createdAt: Self.ago(3 * 3_600)),
            now: Self.now), "No written status yet — latest: “PR 8270 final” (3h ago)")
        let noStatus = Self.row(4083, "Combined promo branch", activity: .idle, status: nil, age: 86_400).mission
        XCTAssertEqual(ProjectsFormat.missionLine(noStatus, now: Self.now),
                       "No status · last milestone 1d ago: “PR 8601 merged”")
        let multi = Self.row(1, "T", activity: .idle, status: "Line one.\nLine two.", age: 60).mission
        XCTAssertEqual(ProjectsFormat.missionLine(multi, now: Self.now), "Line one. Line two.")
    }

    func testLinkWording() {
        let d29 = Date(timeIntervalSince1970: 1_759_104_000) // 29 Sep 2025 00:00 UTC
        let d30 = d29.addingTimeInterval(86_400)
        XCTAssertEqual(ProjectsFormat.shortDate(d29, timeZone: Self.utc), "29 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: nil, how: "origin", timeZone: Self.utc),
                       "since 29 Sep (started this mission)")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: nil, how: "joined", timeZone: Self.utc), "joined 29 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: d30, how: "joined", timeZone: Self.utc), "29 Sep → 30 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: nil, endedAt: nil, how: nil, timeZone: Self.utc), "")
        let mission = Mission(id: "ms_1", num: 1, title: "M", originConvoID: "c1")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, isCurrent: true, joinedAt: d29),
                                                 timeZone: Self.utc), "Current · since 29 Sep")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, joinedAt: d30),
                                                 timeZone: Self.utc), "Also on · joined 30 Sep")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, isActive: false, joinedAt: d29,
                                                                         endedAt: d30), timeZone: Self.utc), "29 Sep → 30 Sep")
    }

    func testSessionsByBoxAndConversationSummary() {
        XCTAssertEqual(ProjectsFormat.sessionsByBox(["pat": 1, "greg": 2, "bev": 1]), "greg 2 · bev 1 · pat 1")
        let groups = MissionConversationGroups(conversations: [
            MissionConversation(id: "c1", title: "a", box: nil, state: "running", subchatCount: 6),
            MissionConversation(id: "c2", title: "b", box: nil, state: "done", endedAt: Self.ago(60)),
        ], missionState: .open)
        XCTAssertEqual(ProjectsFormat.conversationsSummary(groups), "1 on it now · 1 earlier · 6 sub-chats folded")
    }

    // MARK: Snapshots

    func testProjectCardWithStatus() {
        assertVariants(of: ProjectCardView(card: ProjectCard(project: Self.promo, needsYouCount: 6), now: Self.now, onOpen: {})
            .frame(width: 380).padding(), named: "project-card-status")
    }

    func testProjectCardWithoutStatus() {
        let card = ProjectCard(project: Self.silent, needsYouCount: 1,
                               latestMilestone: MissionLastMilestone(num: 9, title: "PR 8270 final at ae015adc9c",
                                                                     kind: .progress, createdAt: Self.ago(12 * 86_400)))
        assertVariants(of: ProjectCardView(card: card, now: Self.now, onOpen: {}).frame(width: 380).padding(),
                       named: "project-card-no-status")
    }

    func testMissionRows() {
        let rows = VStack(spacing: 0) {
            MissionRowView(row: Self.row(5148, "Convert to editor v2: conversion status + email + Slack", activity: .running,
                                         status: "PR 8686 open; waiting on CI and Bugbot, then the merge train.", age: 240),
                           now: Self.now)
            Divider()
            MissionRowView(row: Self.row(3170, "Sample book proof feedback for Jack", activity: .waiting,
                                         status: "Pages 4–41 done; waiting on you to dictate the rest.", needsYou: 1, age: 300),
                           now: Self.now)
            Divider()
            MissionRowView(row: Self.row(4083, "Combined promo branch: gather and report", activity: .idle,
                                         status: nil, age: 86_400), now: Self.now)
        }
        assertVariants(of: rows.frame(width: 720).padding(), named: "mission-rows")
    }
}
```

In `MissionsSnapshotTests.testMissionRow`, replace the body with:

```swift
        assertVariants(of: MissionRowView(row: MissionRowModel(closed: Mission(
            id: "ms_1", num: 61, state: .closed, title: "Missions & milestones", closeSummary: "Shipped on both apps.",
            originConvoID: "c1", closedAt: Date(timeIntervalSince1970: 1_700_000_400))),
                                          now: Date(timeIntervalSince1970: 1_700_100_000))
            .frame(width: 380).padding(), named: "mission-row")
```

and delete its old PNGs: `rm MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests/testMissionRow.*`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ProjectsSnapshotTests'`
Expected: build FAILS — `cannot find 'ProjectsFormat' in scope`.

- [ ] **Step 3: Implement `ProjectsFormat.swift`**

```swift
import Foundation
import MatronModels

/// The Projects screens' words (spec 2026-09-30 §2), pure so each is a
/// plain test and every surface says it the same way.
public enum ProjectsFormat {
    /// "5 missions · 2 running · 2 waiting · 1 quiet · updated 11m ago";
    /// "6 missions · all quiet · last activity 2d ago".
    public static func countsLine(_ counts: ProjectMissionCounts, statusUpdatedAt: Date?, lastActivityAt: Date?,
                                  now: Date) -> String {
        let total = counts.open
        var parts = ["\(total) mission\(total == 1 ? "" : "s")"]
        if total > 0, counts.quiet == total {
            parts.append("all quiet")
            if let lastActivityAt { parts.append("last activity \(MissionsDashboardFormat.relative(lastActivityAt, now: now))") }
            return parts.joined(separator: " · ")
        }
        if counts.running > 0 { parts.append("\(counts.running) running") }
        if counts.waiting > 0 { parts.append("\(counts.waiting) waiting") }
        if counts.quiet > 0 { parts.append("\(counts.quiet) quiet") }
        if let statusUpdatedAt {
            parts.append("updated \(MissionsDashboardFormat.relative(statusUpdatedAt, now: now))")
        } else if let lastActivityAt {
            parts.append("last activity \(MissionsDashboardFormat.relative(lastActivityAt, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    public static func noStatusLine(latest: MissionLastMilestone?, now: Date) -> String {
        guard let latest else { return "No written status yet" }
        return "No written status yet — latest: “\(latest.title)” (\(MissionsDashboardFormat.relative(latest.createdAt, now: now)))"
    }

    /// A slim row's second line.
    public static func missionLine(_ mission: Mission, now: Date) -> String {
        if let status = mission.status { return oneLine(status) }
        if let last = mission.lastMilestone {
            return "No status · last milestone \(MissionsDashboardFormat.relative(last.createdAt, now: now)): “\(last.title)”"
        }
        return "No status yet"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "29 Sep".
    public static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    /// A mission page conversation row's dates: "since 29 Sep (started this
    /// mission)", "joined 29 Sep", "inherited 29 Sep", "29 Sep → 30 Sep".
    public static func linkSpan(joinedAt: Date?, endedAt: Date?, how: String?, timeZone: TimeZone = .current) -> String {
        let joined = joinedAt.map { shortDate($0, timeZone: timeZone) }
        if let endedAt {
            let ended = shortDate(endedAt, timeZone: timeZone)
            return joined.map { "\($0) → \(ended)" } ?? "until \(ended)"
        }
        guard let joined else { return "" }
        switch how {
        case "origin": return "since \(joined) (started this mission)"
        case "inherited": return "inherited \(joined)"
        case "spawned": return "spawned \(joined)"
        default: return "joined \(joined)"
        }
    }

    /// The header list's second line for one mission.
    public static func headerLine(_ link: ConversationMissionLink, timeZone: TimeZone = .current) -> String {
        let joined = link.joinedAt.map { shortDate($0, timeZone: timeZone) }
        if link.isEarlier {
            let end = link.endedAt ?? link.mission.closedAt
            switch (joined, end.map { shortDate($0, timeZone: timeZone) }) {
            case let (j?, e?): return "\(j) → \(e)"
            case let (nil, e?): return "until \(e)"
            case let (j?, nil): return "since \(j)"
            default: return "Earlier"
            }
        }
        if link.isCurrent { return joined.map { "Current · since \($0)" } ?? "Current" }
        return joined.map { "Also on · joined \($0)" } ?? "Also on"
    }

    /// "greg 2 · bev 1 · pat 1": most sessions first, then by name.
    public static func sessionsByBox(_ map: [String: Int]) -> String {
        map.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    /// "3 on it now · 4 earlier · 11 sub-chats folded".
    public static func conversationsSummary(_ groups: MissionConversationGroups) -> String {
        var parts = ["\(groups.onItNow.count) on it now"]
        if !groups.earlier.isEmpty { parts.append("\(groups.earlier.count) earlier") }
        let folded = groups.subchatTotal
        if folded > 0 { parts.append("\(folded) sub-chat\(folded == 1 ? "" : "s") folded") }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Implement the atoms, the card, the row and the menu**

`ProjectGlyphs.swift`:

```swift
import SwiftUI
import MatronModels

/// The project vocabulary's symbols, in one place (sibling of `MissionGlyph`).
public enum ProjectGlyph {
    /// The Projects tab / nav entry.
    public static let symbol = "square.stack.3d.up"
    /// The chip's mark (the mockups' ▣).
    public static let chipSymbol = "square.inset.filled"
    public static let tint = Color.purple
}

/// Running green, waiting orange, idle grey, quiet faint grey (spec §2).
public struct MissionActivityDot: View {
    let activity: MissionActivity
    let isClosed: Bool
    public init(activity: MissionActivity, isClosed: Bool = false) { self.activity = activity; self.isClosed = isClosed }

    public var body: some View {
        Circle().fill(Self.color(activity, isClosed: isClosed)).frame(width: 9, height: 9)
            .accessibilityLabel(isClosed ? "Closed" : activity.label)
    }

    public static func color(_ activity: MissionActivity, isClosed: Bool) -> Color {
        if isClosed { return Color.gray.opacity(0.5) }
        switch activity {
        case .running: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .quiet: return Color.gray.opacity(0.4)
        }
    }
}

/// The card's running / waiting / quiet bar. Decorative: the counts line
/// beside it says the same thing to VoiceOver.
public struct ProjectActivityBar: View {
    let counts: ProjectMissionCounts
    public init(counts: ProjectMissionCounts) { self.counts = counts }

    private var segments: [(Int, Color)] {
        [(counts.running, .green), (counts.waiting, .orange),
         (counts.idle, Color.gray.opacity(0.45)), (counts.quiet, Color.gray.opacity(0.25))].filter { $0.0 > 0 }
    }

    public var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if counts.open == 0 {
                    Rectangle().fill(Color.gray.opacity(0.25))
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(segment.1)
                            .frame(width: geo.size.width * CGFloat(segment.0) / CGFloat(counts.open))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// "▣ Promo launch" — a mission's project, tappable when it can open.
public struct ProjectChip: View {
    let title: String
    let action: (() -> Void)?
    public init(title: String, action: (() -> Void)? = nil) { self.title = title; self.action = action }

    public var body: some View {
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
                .accessibilityHint("Opens the project")
        } else {
            label
        }
    }

    private var label: some View {
        Label { Text(title).lineLimit(1) } icon: { Image(systemName: ProjectGlyph.chipSymbol) }
            .font(.caption.weight(.medium))
            .foregroundStyle(ProjectGlyph.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ProjectGlyph.tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Project \(title)")
    }
}
```

`ProjectCardView.swift`:

```swift
import SwiftUI
import MatronModels

/// One project on the home screen (spec §2): title and needs-you, ONE
/// status paragraph, the state bar, the counts. Nothing from two levels down.
public struct ProjectCardView: View {
    let card: ProjectCard
    let now: Date
    let onOpen: () -> Void
    public init(card: ProjectCard, now: Date, onOpen: @escaping () -> Void) {
        self.card = card; self.now = now; self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) { content }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityIdentifier("projects.card.\(card.project.num)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            status
            ProjectActivityBar(counts: card.project.missions)
            Text(ProjectsFormat.countsLine(card.project.missions, statusUpdatedAt: card.project.statusUpdatedAt,
                                           lastActivityAt: card.project.lastActivityAt, now: now))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DashboardCardChrome())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(card.project.title).font(.headline).lineLimit(2)
            Spacer(minLength: 8)
            NeedsYouPill(count: card.needsYouCount)
        }
    }

    @ViewBuilder private var status: some View {
        if let text = card.project.status {
            Text(MissionsDashboardFormat.statusText(text)).font(.subheadline).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(ProjectsFormat.noStatusLine(latest: card.latestMilestone, now: now))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}
```

Replace `MissionRowView.swift`:

```swift
import SwiftUI
import MatronModels

/// One slim mission row (spec 2026-09-30 §2): dot · #num · title ·
/// one-line status · needs-you · age. Replaces the mission card on the
/// home screen; the Closed fold uses it with `MissionRowModel(closed:)`.
public struct MissionRowView: View {
    let row: MissionRowModel
    /// Fixed for snapshots; nil ticks every minute.
    let now: Date?
    public init(row: MissionRowModel, now: Date? = nil) { self.row = row; self.now = now }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            MissionActivityDot(activity: row.activity, isClosed: row.mission.state == .closed)
            #if os(macOS)
            Text(verbatim: "#\(row.mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(row.mission.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(secondLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            NeedsYouPill(count: row.needsYouCount)
            age
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mission \(row.mission.num), \(row.mission.title), \(secondLine)"
            + (row.needsYouCount > 0 ? ", \(row.needsYouCount) \(row.needsYouCount == 1 ? "item needs" : "items need") you" : ""))
    }

    private var secondLine: String {
        if row.mission.state == .closed {
            return row.mission.closeSummary.map(ProjectsFormat.oneLine) ?? MissionGlyph.label(.closed)
        }
        return ProjectsFormat.missionLine(row.mission, now: now ?? Date())
    }

    @ViewBuilder private var age: some View {
        Group {
            if let now { Text(RelativeMinuteTimeView.format(row.lastActivity, now: now)) } else { RelativeMinuteTimeView(row.lastActivity) }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
    }
}
```

`MoveToProjectMenu.swift`:

```swift
import SwiftUI
import MatronModels

/// "Move to project…" (spec §6 "Filing"): every open project, the current
/// one ticked, and "Not in a project" when it is filed.
public struct MoveToProjectMenu: View {
    let currentProjectID: String?
    let targets: [Project]
    let onMove: (String?) -> Void
    public init(currentProjectID: String?, targets: [Project], onMove: @escaping (String?) -> Void) {
        self.currentProjectID = currentProjectID; self.targets = targets; self.onMove = onMove
    }

    public var body: some View {
        Menu {
            ForEach(targets) { project in
                Button { onMove(project.id) } label: {
                    if project.id == currentProjectID { Label(project.title, systemImage: "checkmark") } else { Text(project.title) }
                }
                .disabled(project.id == currentProjectID)
            }
            if currentProjectID != nil {
                Divider()
                Button("Not in a project") { onMove(nil) }
            }
        } label: {
            Label("Move to project…", systemImage: ProjectGlyph.symbol)
        }
        .disabled(targets.isEmpty && currentProjectID == nil)
        .accessibilityIdentifier("missions.moveToProject")
    }
}
```

In `MissionsDashboardView.closedSection`, change the row to `MissionRowView(row: MissionRowModel(closed: mission))`.

- [ ] **Step 5: Record and verify**

Run: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.(ProjectsSnapshotTests|MissionsSnapshotTests)'` twice (the first run records the new PNGs and fails; the second passes). Open each new PNG under `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ProjectsSnapshotTests/` and compare with `docs/superpowers/specs/2026-09-30-projects-assets/mockups/01-mac-projects-home.png`: card title + red pill on one line, three-line status, the bar, one counts line; rows with dot, number, bold title, grey status line, pill, age.
Expected on the second run: PASS.

- [ ] **Step 6: Commit**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronShared/Sources/DesignSystem/Projects MatronShared/Sources/DesignSystem/Missions/MissionRowView.swift \
        MatronShared/Sources/DesignSystem/Missions/MissionsDashboardView.swift \
        MatronShared/Tests/DesignSystemSnapshotTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: card, slim mission row, chip, activity bar and wording" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: `ProjectsHomeView` and `NewProjectSheet`

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Projects/ProjectsHomeView.swift`
- Create: `MatronShared/Sources/DesignSystem/Projects/NewProjectSheet.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ProjectsHomeSnapshotTests.swift` (new)

**Interfaces:**
- Consumes: Task 14 atoms; Task 10 `ProjectsHomeSnapshot`, `ProjectsHomeAction`; existing `MissionsDashboardAskButton`, `MissionsDashboardView.columns`, `MissionsDashboardFormat`.
- Produces: `ProjectsHomeView(model:now:onAction:onRefresh:onAsk:)` with `ProjectsHomeView.Model(home:isRefreshing:askedAt:isAskEnabled:canCreateProject:)`, `static let unfiledPreview = 6`; `NewProjectSheet(onCreate: (String, String?) async -> String?, onCancel: () -> Void)` — `onCreate` returns an error message or nil.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/ProjectsHomeSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectsHomeSnapshotTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    static var home: ProjectsHomeSnapshot {
        let apps = Project(id: "pj_3", num: 4002, title: "Matron apps",
                           status: "AppKit timeline waits on your manual pass. Projects redesign plan is ready for review.",
                           statusBy: .agent, statusUpdatedAt: F.ago(240),
                           missions: ProjectMissionCounts(running: 3, waiting: 4, quiet: 4), needsYou: 3,
                           lastActivityAt: F.ago(120))
        let unfiled = (0..<8).map { i in
            F.row(5100 + i, "Unfiled mission \(i + 1)", activity: i == 0 ? .running : .waiting,
                  status: "Status line for mission \(i + 1).", needsYou: i == 1 ? 1 : 0, age: TimeInterval(60 * (i + 4)))
        }
        return ProjectsHomeSnapshot(
            cards: [ProjectCard(project: F.promo, needsYouCount: 6), ProjectCard(project: apps, needsYouCount: 3),
                    ProjectCard(project: F.silent, needsYouCount: 0)],
            unfiled: unfiled,
            quiet: [F.row(2000, "Old thing", activity: .quiet, status: nil, age: 20 * 86_400)],
            closed: [Mission(id: "ms_0", num: 55, state: .closed, title: "Items tracker", closeSummary: "Shipped.",
                             originConvoID: "c0", closedAt: F.ago(9 * 86_400))],
            statusRefreshedAt: F.ago(1_200))
    }

    private func page(_ home: ProjectsHomeSnapshot) -> ProjectsHomeView {
        ProjectsHomeView(model: .init(home: home, isRefreshing: false, askedAt: nil, isAskEnabled: true, canCreateProject: true),
                         now: F.now, onAction: { _ in }, onRefresh: {}, onAsk: {})
    }

    func testModelFlags() {
        XCTAssertEqual(ProjectsHomeView.unfiledPreview, 6)
        XCTAssertTrue(ProjectsHomeSnapshot().isEmpty)
        XCTAssertEqual(Self.home.openProjects.map(\.id), ["pj_1", "pj_3", "pj_2"])
    }

    func testHomeEmpty() {
        assertVariants(of: page(ProjectsHomeSnapshot()).frame(width: 390, height: 360), named: "projects-home-empty")
    }

    func testHomePhoneWidth() {
        assertVariants(of: page(Self.home).frame(width: 390, height: 1_500), named: "projects-home-phone")
    }

    func testHomeMacWidth() {
        assertVariants(of: page(Self.home).frame(width: 1_280, height: 1_000), named: "projects-home-wide")
    }

    func testNewProjectSheet() {
        assertVariants(of: NewProjectSheet(onCreate: { _, _ in nil }, onCancel: {}).frame(width: 440),
                       named: "projects-new-sheet")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ProjectsHomeSnapshotTests'`
Expected: build FAILS — `cannot find 'ProjectsHomeView' in scope`.

- [ ] **Step 3: Implement `ProjectsHomeView.swift`**

```swift
import SwiftUI
import MatronModels

/// The Projects home (spec 2026-09-30 §2): project cards, then missions not
/// in a project as slim rows, then the Quiet and Closed folds. A pure leaf:
/// hosts map `MissionsDashboardViewModel` into `Model`.
public struct ProjectsHomeView: View {
    public struct Model: Equatable {
        public var home: ProjectsHomeSnapshot
        public var isRefreshing: Bool
        public var askedAt: Date?
        public var isAskEnabled: Bool
        public var canCreateProject: Bool
        public init(home: ProjectsHomeSnapshot, isRefreshing: Bool, askedAt: Date? = nil, isAskEnabled: Bool = true,
                    canCreateProject: Bool = true) {
            self.home = home; self.isRefreshing = isRefreshing; self.askedAt = askedAt
            self.isAskEnabled = isAskEnabled; self.canCreateProject = canCreateProject
        }
    }

    /// Rows shown before "+ n more".
    public static let unfiledPreview = 6

    let model: Model
    let now: Date?
    let onAction: (ProjectsHomeAction) -> Void
    let onRefresh: () async -> Void
    let onAsk: (() -> Void)?
    @State private var showAllUnfiled = false
    @State private var showQuiet = false
    @State private var showClosed = false

    public init(model: Model, now: Date? = nil, onAction: @escaping (ProjectsHomeAction) -> Void,
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
            Text("Projects").font(.headline)
            Spacer()
            if let at = model.home.statusRefreshedAt {
                ticking { now in
                    Text("Status refreshed \(MissionsDashboardFormat.relative(at, now: now))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
            if let onAsk { MissionsDashboardAskButton(isEnabled: model.isAskEnabled, action: onAsk).labelStyle(.titleAndIcon) }
            if model.canCreateProject { newProjectButton.labelStyle(.titleAndIcon) }
            Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
    #endif

    /// Also placed in the iOS toolbar by the host.
    public var newProjectButton: some View {
        Button { onAction(.newProject) } label: { Label("New project", systemImage: "plus") }
            .accessibilityIdentifier("projects.new")
    }

    @ViewBuilder private var content: some View {
        if model.home.isEmpty {
            placeholder
        } else {
            ScrollView { ticking { now in page(now: now) } }
            #if os(iOS)
                .refreshable { await onRefresh() }
            #endif
        }
    }

    @ViewBuilder private func ticking<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let now { content(now) } else { TimelineView(.periodic(from: .now, by: 60)) { content($0.date) } }
    }

    private func page(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let askedAt = model.askedAt {
                Label(MissionsDashboardFormat.askedLabel(askedAt: askedAt, now: now), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.home.cards.isEmpty { projectsSection(now: now) }
            if !model.home.unfiled.isEmpty { unfiledSection(now: now) }
            if !model.home.quiet.isEmpty { quietFold(now: now) }
            if !model.home.closed.isEmpty { closedFold(now: now) }
        }
        .padding(16)
    }

    private func sectionHeader(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Text(detail.uppercased()).font(.caption).tracking(0.6).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func projectsSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Projects", "\(model.home.cards.count) open")
            LazyVGrid(columns: MissionsDashboardView.columns, alignment: .leading, spacing: 16) {
                ForEach(model.home.cards) { card in
                    ProjectCardView(card: card, now: now) { onAction(.openProject(card.id)) }
                }
            }
        }
    }

    private func unfiledSection(now: Date) -> some View {
        let rows = model.home.unfiled
        let shown = showAllUnfiled ? rows : Array(rows.prefix(Self.unfiledPreview))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Missions not in a project", "\(rows.count) active")
            rowsCard(shown, now: now, more: rows.count - shown.count)
        }
    }

    private func rowsCard(_ rows: [MissionRowModel], now: Date, more: Int = 0) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                missionButton(row, now: now)
                if index < rows.count - 1 || more > 0 { Divider().padding(.leading, 12) }
            }
            if more > 0 {
                Button("+ \(more) more") { showAllUnfiled = true }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .accessibilityIdentifier("projects.unfiled.more")
            }
        }
        .modifier(DashboardCardChrome())
    }

    private func missionButton(_ row: MissionRowModel, now: Date) -> some View {
        Button { onAction(.openMission(row.id)) } label: {
            MissionRowView(row: row, now: now).padding(.horizontal, 12).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .contextMenu {
            MoveToProjectMenu(currentProjectID: row.mission.projectID, targets: model.home.openProjects) {
                onAction(.moveMission(missionID: row.id, projectID: $0))
            }
        }
    }

    private func quietFold(now: Date) -> some View {
        DisclosureGroup(isExpanded: $showQuiet) {
            rowsCard(model.home.quiet, now: now).padding(.top, 8)
        } label: {
            Text("Quiet for over a week (\(model.home.quiet.count))").font(.headline)
        }
        .accessibilityIdentifier("projects.quietToggle")
    }

    private func closedFold(now: Date) -> some View {
        DisclosureGroup(isExpanded: $showClosed) {
            rowsCard(model.home.closed.map(MissionRowModel.init(closed:)), now: now).padding(.top, 8)
        } label: {
            Text("Closed (\(model.home.closed.count))").font(.headline)
        }
        .accessibilityIdentifier("projects.closedToggle")
    }

    @ViewBuilder private var placeholder: some View {
        let content = ContentUnavailableView("No projects or missions yet", systemImage: ProjectGlyph.symbol,
                                             description: Text("An agent files each mission into a project as it starts one."))
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

`NewProjectSheet.swift`:

```swift
import SwiftUI

/// "New project" (spec §6 "Filing"): a title and an optional line on what
/// it is for. Stays open with the error when the create fails.
public struct NewProjectSheet: View {
    let onCreate: (String, String?) async -> String?
    let onCancel: () -> Void
    @State private var title = ""
    @State private var details = ""
    @State private var isCreating = false
    @State private var error: String?

    public init(onCreate: @escaping (String, String?) async -> String?, onCancel: @escaping () -> Void) {
        self.onCreate = onCreate; self.onCancel = onCancel
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("projects.new.title")
            TextField("What is it for? (optional)", text: $details, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction).disabled(isCreating)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating || trimmedTitle.isEmpty)
            }
        }
        .padding(20)
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            let failure = await onCreate(trimmedTitle, details)
            isCreating = false
            error = failure
        }
    }
}
```


- [ ] **Step 4: Record and verify**

Run the snapshot class twice: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ProjectsHomeSnapshotTests'`. Compare `projects-home-wide` against `mockups/01-mac-projects-home.png`: three-column cards, the unfiled card with six rows and "+ 2 more", then the two folds collapsed. Expected second run: PASS.

- [ ] **Step 5: Commit**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronShared/Sources/DesignSystem/Projects MatronShared/Tests/DesignSystemSnapshotTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: the Projects home and the New project sheet" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: The iOS project page — `ProjectDetailView` and `SessionChipLine`

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Projects/ProjectDetailView.swift`
- Create: `MatronShared/Sources/DesignSystem/Projects/SessionChipLine.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ProjectDetailSnapshotTests.swift` (new)

**Interfaces:**
- Consumes: Task 10 `ProjectPageModel`; Task 14 atoms; existing `ItemGlyph`, `SessionTagText`, `BoxChip`, `DashboardStateDot`, `MissionGlyph`.
- Produces: `SessionChipLine(sessions: [DashboardSession], limit: Int = 2)` (used by the Mac page too); `ProjectDetailView(page:now:onOpenMission:onOpenItem:onOpenMilestone:onMoveMission:onRefresh:)`.

Sections, top to bottom (spec §2 "Project page", mockup 04 middle): title + goal + needs-you pill; Status; Needs you · n (each item with its mission's `#N`); Missions (slim rows, two session chips each, Closed (n) fold); Latest steps (5, each with `#N`); Sessions on it now (`greg 2 · pat 1`).

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/DesignSystemSnapshotTests/ProjectDetailSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectDetailSnapshotTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    static var page: ProjectPageModel {
        let branch = F.row(4791, "Promo branch: /proto design at the base URLs", activity: .waiting,
                           status: "R2 redirect test done on 328 addresses; infra PR 605 needs the blog nginx line.",
                           needsYou: 2, age: 660)
        let launch = F.row(4907, "Launch day: Wed 7 Oct 07:00", activity: .running,
                           status: "Branch green at b6794bffa8; S7 confirmed.", age: 660)
        return ProjectPageModel(
            project: F.promo,
            missions: [branch, launch],
            closedMissions: [Mission(id: "ms_c", num: 4000, state: .closed, title: "Old promo", originConvoID: "c1")],
            needsYou: [TrackerItem(id: "it_1", num: 8666, kind: .question, awaiting: .user,
                                   title: "Leavers' page PR 8666 — ship with launch?", originConvoID: "c1",
                                   missionID: "ms_4791", missionNum: 4791),
                       TrackerItem(id: "it_2", num: 8667, kind: .question, awaiting: .user, title: "Cloudflare API token scope",
                                   originConvoID: "c1", missionID: "ms_4907", missionNum: 4907)],
            recentMilestones: [Milestone(id: "ml_1", missionID: "ms_4907", num: 9001, kind: .progress,
                                         title: "S7 confirmed: no Cloudflare rule caches HTML", convoID: "c1", seq: 1,
                                         createdAt: F.ago(660)),
                               Milestone(id: "ml_2", missionID: "ms_4907", num: 9002, kind: .userInput,
                                         title: "Dan chose Wed 7 Oct, 07:00, fallback 13 Oct", convoID: "c1", seq: 2,
                                         createdAt: F.ago(13 * 3_600))],
            missionNums: ["ms_4791": 4791, "ms_4907": 4907],
            sessionsByBox: ["greg": 2, "pat": 1, "dan-mac": 1],
            sessionsByMission: ["ms_4791": [
                DashboardSession(id: "c-p", title: "promo/integration owner", state: .waiting,
                                 tag: SessionTagInputs(boxLetter: "P", boxName: "pat", sessionShort: "ad")),
                DashboardSession(id: "c-g", title: "sales-chat", state: .running,
                                 tag: SessionTagInputs(boxLetter: "G", boxName: "greg", sessionShort: "13")),
                DashboardSession(id: "c-d", title: "done one", state: .done, boxName: "bev"),
            ]])
    }

    func testProjectPagePhone() {
        assertVariants(of: ProjectDetailView(page: Self.page, now: F.now, onOpenMission: { _ in }, onOpenItem: { _ in },
                                             onOpenMilestone: { _ in }, onMoveMission: { _, _ in }, onRefresh: {})
            .frame(width: 390, height: 1_400), named: "project-page-phone")
    }

    func testSessionChipLineCapsAtTwoAndCountsTheRest() {
        XCTAssertEqual(SessionChipLine.moreText(total: 3, limit: 2), "+1 more")
        XCTAssertNil(SessionChipLine.moreText(total: 2, limit: 2))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ProjectDetailSnapshotTests'`
Expected: build FAILS — `cannot find 'ProjectDetailView' in scope`.

- [ ] **Step 3: Implement**

`SessionChipLine.swift`:

```swift
import SwiftUI
import MatronModels

/// "P:ad pat · waiting   G:13 greg · running  +1 more" — a mission row's
/// sessions on the project page (spec §2: "2 session chips").
public struct SessionChipLine: View {
    let sessions: [DashboardSession]
    let limit: Int
    @Environment(\.colorScheme) private var colorScheme
    public init(sessions: [DashboardSession], limit: Int = 2) { self.sessions = sessions; self.limit = limit }

    public static func moreText(total: Int, limit: Int) -> String? { total > limit ? "+\(total - limit) more" : nil }

    public var body: some View {
        if !sessions.isEmpty {
            HStack(spacing: 10) {
                ForEach(sessions.prefix(limit)) { chip($0) }
                if let more = Self.moreText(total: sessions.count, limit: limit) {
                    Text(more).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    private func chip(_ session: DashboardSession) -> some View {
        HStack(spacing: 4) {
            if let tag = session.tag,
               let run = SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                            sessionShort: tag.sessionShort, colorScheme: colorScheme) {
                run.font(.caption.monospaced())
            }
            Text("\(session.tag?.boxName ?? session.boxName ?? session.title) · \(DashboardStateDot.label(session.state).lowercased())")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
```

`ProjectDetailView.swift`:

```swift
import SwiftUI
import MatronModels

/// The project page as one `List` (spec §6: "a single List on iOS"). The
/// Mac draws its own two-column page from the same `ProjectPageModel`.
public struct ProjectDetailView: View {
    let page: ProjectPageModel
    let now: Date?
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenMilestone: (Milestone) -> Void
    let onMoveMission: (String, String?) -> Void
    let onRefresh: () async -> Void
    @State private var showClosed = false

    public init(page: ProjectPageModel, now: Date? = nil, onOpenMission: @escaping (String) -> Void,
                onOpenItem: @escaping (String) -> Void, onOpenMilestone: @escaping (Milestone) -> Void,
                onMoveMission: @escaping (String, String?) -> Void, onRefresh: @escaping () async -> Void) {
        self.page = page; self.now = now; self.onOpenMission = onOpenMission; self.onOpenItem = onOpenItem
        self.onOpenMilestone = onOpenMilestone; self.onMoveMission = onMoveMission; self.onRefresh = onRefresh
    }

    public var body: some View {
        List {
            Section { header }
            if let status = page.project.status { Section { statusCard(status) } }
            if !page.needsYou.isEmpty { needsYouSection }
            missionsSection
            if !page.recentMilestones.isEmpty { milestonesSection }
            if !page.sessionsByBox.isEmpty {
                Section("Sessions on it now") {
                    Text(ProjectsFormat.sessionsByBox(page.sessionsByBox)).font(.subheadline)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MatronTimelineBackground())
        .refreshable { await onRefresh() }
        #else
        .listStyle(.inset)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.project.title).font(.title2.weight(.bold))
                Spacer(minLength: 8)
                NeedsYouPill(count: page.needsYouCount)
            }
            if !page.project.body.isEmpty {
                Text(MissionsDashboardFormat.statusText(page.project.body)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func statusCard(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(MissionsDashboardFormat.statusText(status)).font(.body)
        }
    }

    private var statusHeading: String {
        guard let at = page.project.statusUpdatedAt else { return "STATUS" }
        return "STATUS · \(RelativeMinuteTimeView.format(at, now: now ?? Date())) ago"
    }

    private var needsYouSection: some View {
        Section {
            ForEach(page.needsYou) { item in
                Button { onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).lineLimit(2)
                        Spacer(minLength: 4)
                        if let num = item.missionNum { Text(verbatim: "#\(num)").font(.caption.monospacedDigit()).foregroundStyle(.blue) }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        } header: {
            Text("Needs you · \(page.needsYouCount)").foregroundStyle(.red)
        }
    }

    private var missionsSection: some View {
        Section("Missions") {
            ForEach(page.missions) { row in
                Button { onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MissionRowView(row: row, now: now)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [])
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: row.mission.projectID,
                                      targets: page.mergeTargets + [page.project]) { onMoveMission(row.id, $0) }
                }
            }
            if !page.closedMissions.isEmpty {
                DisclosureGroup("Closed (\(page.closedMissions.count))", isExpanded: $showClosed) {
                    ForEach(page.closedMissions) { mission in
                        Button { onOpenMission(mission.id) } label: {
                            MissionRowView(row: MissionRowModel(closed: mission), now: now)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }

    private var milestonesSection: some View {
        Section("Latest steps") {
            ForEach(page.recentMilestones) { milestone in
                Button { onOpenMilestone(milestone) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: MissionGlyph.symbol(milestone.kind)).font(.caption2)
                            .foregroundStyle(MissionGlyph.tint(milestone.kind))
                        Text(milestone.title).lineLimit(2)
                        if let num = page.missionNums[milestone.missionID] {
                            Text(verbatim: "#\(num)").font(.caption.monospacedDigit()).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 4)
                        Text(RelativeMinuteTimeView.format(milestone.createdAt, now: now ?? Date()))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        }
    }
}
```

- [ ] **Step 4: Record and verify**

Run the class twice: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ProjectDetailSnapshotTests'`. Compare with the middle phone of `mockups/04-ios.png`. Expected second run: PASS.

- [ ] **Step 5: Commit**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronShared/Sources/DesignSystem/Projects MatronShared/Tests/DesignSystemSnapshotTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: the project page as one List, with session chips" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: The iOS mission page — status, needs you, On it now / Earlier, 5 milestones, project chip, move

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/Missions/MissionDetailView.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MissionsSnapshotTests.swift`

**Interfaces:**
- Consumes: Task 10 `MissionConversationGroups`; Task 14 `ProjectChip`, `MoveToProjectMenu`, `ProjectsFormat`.
- Produces: `MissionDetailView.Model` gains `project: Project?`, `moveTargets: [Project]`, `conversationTags: [String: SessionTagInputs]` (all defaulted, on both inits) and computed `groups`, `needsYouItems`, `otherItems`; `MissionDetailView.init` gains trailing `onOpenProject: ((String) -> Void)? = nil, onMove: ((String?) -> Void)? = nil`; `static let initialMilestones = 5`, `static let milestonePage = 20`.

Fixes the parity gap (spec §1, §6): the iOS page never showed the status, had no needs-you section, listed every milestone and showed a raw state string per conversation.

- [ ] **Step 1: Write the failing test**

Append to `MissionsSnapshotTests`:

```swift
    func testMissionDetailPagesMilestonesAtFive() {
        XCTAssertEqual(MissionDetailView.initialMilestones, 5)
        XCTAssertEqual(MissionDetailView.milestonePage, 20)
    }

    func testMissionDetailWithProjectStatusAndConversations() {
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        let withStatus = Mission(
            id: "ms_1", num: 4907, title: "Launch day: Wed 7 Oct 07:00", originConvoID: "c1",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000), updatedAt: now,
            needsYou: 1, status: "Branch green; S7 confirmed, robots.txt in the purge.", statusBy: .agent,
            statusUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), projectID: "pj_1")
        let milestones = (0..<8).map { i in
            Milestone(id: "ml_\(i)", missionID: "ms_1", num: 100 + i, kind: .progress, title: "Step \(i)",
                      convoID: "c1", seq: Int64(i), createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(i) * 600))
        }
        let model = MissionDetailView.Model(
            mission: withStatus, project: Project(id: "pj_1", num: 4000, title: "Promo launch"),
            milestones: milestones, sessionTags: [:],
            openItems: [TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Cloudflare: page rule for /blog", originConvoID: "c1"),
                        TrackerItem(id: "it_2", num: 65, kind: .task, awaiting: .agent, title: "Purge list", originConvoID: "c1")],
            conversations: [
                MissionConversation(id: "c1", title: "sales-chat launch coordination", box: "greg", state: "waiting",
                                    isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1_699_500_000), how: "origin",
                                    subchatCount: 6),
                MissionConversation(id: "c2", title: "legal pages site-shell updates", box: "bev", state: "done",
                                    joinedAt: Date(timeIntervalSince1970: 1_699_400_000),
                                    endedAt: Date(timeIntervalSince1970: 1_699_490_000)),
            ],
            moveTargets: [Project(id: "pj_1", num: 4000, title: "Promo launch")],
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        assertVariants(of: MissionDetailView(model: model, onToggleUserInputOnly: { _ in }, onOpenMilestone: { _ in },
                                             onOpenItem: { _ in }, onOpenConversation: { _ in }, onEditCloseSummary: { _ in },
                                             onClose: {}, onRefresh: {}, onOpenProject: { _ in }, onMove: { _ in })
            .frame(width: 390, height: 1_300), named: "mission-detail-project")
    }
```

Delete the old `testMissionDetail` PNGs (`rm MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MissionsSnapshotTests/testMissionDetail.*`) — the page's layout changes, so that baseline is re-recorded too.

- [ ] **Step 2: Run to verify it fails**

Run: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.MissionsSnapshotTests'`
Expected: build FAILS — `extra arguments 'project', 'moveTargets'`.

- [ ] **Step 3: Implement the model changes**

In `MissionDetailView.Model` add stored properties

```swift
        public var project: Project?
        public var moveTargets: [Project]
        /// `A:bc` tags for the conversation rows.
        public var conversationTags: [String: SessionTagInputs]
        public var groups: MissionConversationGroups {
            MissionConversationGroups(conversations: conversations, missionState: mission?.state ?? .open)
        }
        public var needsYouItems: [TrackerItem] { openItems.filter { $0.awaiting == .user } }
        public var otherItems: [TrackerItem] { openItems.filter { $0.awaiting != .user } }
```

Change the rows-based init to

```swift
        public init(mission: Mission?, project: Project? = nil, milestones: [MilestoneRow], openItems: [TrackerItem],
                    conversations: [MissionConversation], conversationTags: [String: SessionTagInputs] = [:],
                    moveTargets: [Project] = [], showOnlyUserInput: Bool, closeSummary: String, isBusy: Bool) {
            self.mission = mission; self.project = project; self.milestones = milestones; self.openItems = openItems
            self.conversations = conversations; self.conversationTags = conversationTags; self.moveTargets = moveTargets
            self.showOnlyUserInput = showOnlyUserInput; self.closeSummary = closeSummary; self.isBusy = isBusy
        }
```

and the milestone-based init to

```swift
        public init(mission: Mission?, project: Project? = nil, milestones: [Milestone],
                    sessionTags: [String: SessionTagInputs], openItems: [TrackerItem],
                    conversations: [MissionConversation], moveTargets: [Project] = [], showOnlyUserInput: Bool,
                    closeSummary: String, isBusy: Bool) {
            self.init(mission: mission, project: project,
                      milestones: milestones.map { MilestoneRow(milestone: $0, sessionTag: sessionTags[$0.convoID]) },
                      openItems: openItems, conversations: conversations, conversationTags: sessionTags,
                      moveTargets: moveTargets, showOnlyUserInput: showOnlyUserInput,
                      closeSummary: closeSummary, isBusy: isBusy)
        }
```

(`sessionTags` from `MissionDetailViewModel` now covers conversation ids too — Task 13 — so the one map feeds both.)

- [ ] **Step 4: Implement the view changes**

Add to `MissionDetailView`:

```swift
    public static let initialMilestones = 5
    public static let milestonePage = 20
    let onOpenProject: ((String) -> Void)?
    let onMove: ((String?) -> Void)?
    @State private var milestoneLimit = MissionDetailView.initialMilestones
```

and extend `init` with trailing `onOpenProject: ((String) -> Void)? = nil, onMove: ((String?) -> Void)? = nil`, assigning both.

Replace the `List { … }` content in `body` with:

```swift
            List {
                Section { header(mission) }
                if let status = mission.status { Section { statusCard(status, mission: mission) } }
                if !model.needsYouItems.isEmpty { needsYouSection }
                if !model.conversations.isEmpty { conversationsSection }
                milestonesSection
                if !model.otherItems.isEmpty {
                    Section("Open items") { ForEach(model.otherItems) { itemButton($0) } }
                }
                if mission.state == .open {
                    Section("Close this mission") { closeControls }
                }
            }
```

In `header(_:)`, insert after the title `HStack`:

```swift
            if model.project != nil || (onMove != nil && mission.state == .open) {
                HStack(spacing: 8) {
                    if let project = model.project {
                        ProjectChip(title: project.title, action: onOpenProject.map { open in { open(project.id) } })
                    }
                    if let onMove, mission.state == .open {
                        MoveToProjectMenu(currentProjectID: mission.projectID, targets: model.moveTargets, onMove: onMove)
                            .font(.caption)
                            #if os(iOS)
                            .menuStyle(.button)
                            #endif
                    }
                }
            }
```

Add the new sections as private helpers:

```swift
    private func statusCard(_ status: String, mission: Mission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let byline = MissionsDashboardFormat.statusByline(updatedAt: mission.statusUpdatedAt, by: mission.statusBy, now: Date()) {
                Text("STATUS · \(byline)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text("STATUS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(MissionsDashboardFormat.statusText(status)).font(.body)
        }
    }

    private var needsYouSection: some View {
        Section {
            ForEach(model.needsYouItems) { itemButton($0) }
        } header: {
            Text("Needs you · \(model.needsYouItems.count)").foregroundStyle(.red)
        }
    }

    private func itemButton(_ item: TrackerItem) -> some View {
        Button { onOpenItem(item.id) } label: { ItemRow(item: item) }
            .buttonStyle(.plain).foregroundStyle(Color.primary)
    }

    private var conversationsSection: some View {
        let groups = model.groups
        return Section {
            if !groups.onItNow.isEmpty {
                Text("ON IT NOW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(groups.onItNow) { conversationRow($0) }
            }
            if !groups.earlier.isEmpty {
                Text("EARLIER").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(groups.earlier) { conversationRow($0) }
            }
        } header: {
            HStack {
                Text("Conversations")
                Spacer()
                Text(ProjectsFormat.conversationsSummary(groups)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func conversationRow(_ row: MissionConversationRow) -> some View {
        Button { onOpenConversation(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DashboardStateDot(state: row.state)
                conversationTag(row.conversation)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.conversation.title.isEmpty ? row.id : row.conversation.title)
                        .font(.body.weight(.medium)).lineLimit(1)
                    Text(conversationMeta(row.conversation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.primary)
        if !row.subchats.isEmpty {
            DisclosureGroup("\(row.subchats.count) sub-chat\(row.subchats.count == 1 ? "" : "s")") {
                ForEach(row.subchats) { child in
                    Button { onOpenConversation(child.id) } label: {
                        Text(child.title.isEmpty ? child.id : child.title).font(.subheadline).lineLimit(1)
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
            }
            .font(.caption).padding(.leading, 24)
        } else if row.subchatCount > 0 {
            Text("\(row.subchatCount) sub-chat\(row.subchatCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
        }
    }

    @ViewBuilder private func conversationTag(_ convo: MissionConversation) -> some View {
        if let tag = model.conversationTags[convo.id],
           let run = SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                        sessionShort: tag.sessionShort, colorScheme: colorScheme) {
            run.font(.caption)
        } else if let box = convo.box {
            BoxChip(box)
        }
    }

    private func conversationMeta(_ convo: MissionConversation) -> String {
        [convo.box, ProjectsFormat.linkSpan(joinedAt: convo.joinedAt, endedAt: convo.endedAt, how: convo.how)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var milestonesSection: some View {
        Section {
            if model.milestones.isEmpty {
                Text(model.showOnlyUserInput ? "No milestones from you yet." : "No milestones yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(model.milestones.prefix(milestoneLimit)) { row in
                    Button { onOpenMilestone(row.milestone) } label: { milestoneRow(row) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
                let more = model.milestones.count - min(milestoneLimit, model.milestones.count)
                if more > 0 {
                    Button("Show more (\(more))") { milestoneLimit += Self.milestonePage }
                        .accessibilityIdentifier("missionDetail.milestones.showMore")
                }
            }
        } header: {
            HStack {
                Text("Milestones")
                Spacer()
                Toggle("My inputs only", isOn: Binding(get: { model.showOnlyUserInput },
                                                       set: { onToggleUserInputOnly($0) }))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("My inputs only")
            }
        }
    }
```

Delete the old `conversationRow(_ convo: MissionConversation)` (raw state string) and the old inline Milestones / Open items / Conversations sections.

- [ ] **Step 5: Record and verify**

Run twice: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.MissionsSnapshotTests'`. In `mission-detail-project` check: project chip + "Move to project…" under the title, the status card, "Needs you · 1", Conversations with ON IT NOW (greg row, "6 sub-chats") and EARLIER (bev row "… → …"), five milestones then "Show more (3)", then Open items with the task. Expected second run: PASS.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Missions/MissionDetailView.swift MatronShared/Tests/DesignSystemSnapshotTests
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "missions: iOS mission page gains status, needs you, On it now / Earlier and paged milestones" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Header chip, the missions list, the "Not on a mission" section; PR 2

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Projects/MissionChipLabel.swift`
- Create: `MatronShared/Sources/DesignSystem/Projects/ConversationMissionsList.swift`
- Create: `MatronShared/Sources/DesignSystem/Projects/LooseSessionsSection.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ConversationMissionsSnapshotTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 `ConversationMissions`; Task 14 `ProjectsFormat.headerLine`, `ProjectChip`; existing `DashboardSessionRow`.
- Produces:
  - `MissionChipLabel(missions: ConversationMissions)` and `static func text(_:) -> String?` (nil = no chip).
  - `ConversationMissionsList(missions:projectTitles:contextLine:onOpenMission:onOpenProject:)` — the iOS sheet's content.
  - `LooseSessionsSection(sessions:isExpanded:onOpen:)` — a `List` section for both chat lists.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/ConversationMissionsSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ConversationMissionsSnapshotTests: XCTestCase {
    static let d26 = Date(timeIntervalSince1970: 1_758_844_800) // 26 Sep 2025 UTC

    static var missions: ConversationMissions {
        let current = Mission(id: "ms_4791", num: 4791, title: "Promo branch: /proto design at the base URLs",
                              originConvoID: "c1", projectID: "pj_1")
        let also = Mission(id: "ms_4907", num: 4907, title: "Launch day: Wed 7 Oct 07:00", originConvoID: "c9",
                           projectID: "pj_1")
        let earlier = Mission(id: "ms_4083", num: 4083, title: "Combined promo branch: gather and report",
                              originConvoID: "c1")
        return ConversationMissions(links: [
            ConversationMissionLink(mission: current, isCurrent: true, joinedAt: d26),
            ConversationMissionLink(mission: also, joinedAt: d26.addingTimeInterval(4 * 86_400)),
            ConversationMissionLink(mission: earlier, isActive: false, joinedAt: d26.addingTimeInterval(2 * 86_400),
                                    endedAt: d26.addingTimeInterval(3 * 86_400)),
        ], snapshotCount: 3)
    }

    func testChipText() {
        XCTAssertEqual(MissionChipLabel.text(Self.missions), "#4791 Promo branch: /proto design at the base URLs +2")
        XCTAssertNil(MissionChipLabel.text(ConversationMissions()))
        let one = ConversationMissions(links: [Self.missions.links[0]], snapshotCount: nil)
        XCTAssertEqual(MissionChipLabel.text(one), "#4791 Promo branch: /proto design at the base URLs")
    }

    func testChip() {
        assertVariants(of: MissionChipLabel(missions: Self.missions).frame(width: 320).padding(), named: "mission-chip")
    }

    func testMissionsList() {
        let list = ConversationMissionsList(missions: Self.missions, projectTitles: ["pj_1": "Promo launch"],
                                            contextLine: "pat · ~/yearbook-app", onOpenMission: { _ in },
                                            onOpenProject: { _ in })
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        assertVariants(of: list.frame(width: 390, height: 620), named: "conversation-missions-list")
    }

    func testLooseSection() {
        let sessions = [DashboardSession(id: "c-loose", title: "Fix the flaky timeline test", state: .running,
                                         summary: "Bisecting the gap test", needsYou: 1)]
        let list = List { LooseSessionsSection(sessions: sessions, isExpanded: .constant(true), onOpen: { _ in }) }
        assertVariants(of: list.frame(width: 390, height: 240), named: "loose-sessions-section")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ConversationMissionsSnapshotTests'`
Expected: build FAILS — `cannot find 'MissionChipLabel' in scope`.

- [ ] **Step 3: Implement**

`MissionChipLabel.swift`:

```swift
import SwiftUI
import MatronModels

/// The conversation header's chip (spec §2, §6): the current mission and
/// "+n" for every other mission the conversation touched. Hosts wrap it in
/// a Menu (Mac) or a Button opening `ConversationMissionsList` (iOS).
public struct MissionChipLabel: View {
    let missions: ConversationMissions
    public init(missions: ConversationMissions) { self.missions = missions }

    public static func text(_ missions: ConversationMissions) -> String? {
        guard let headline = missions.sections.headline else { return nil }
        let others = missions.othersCount
        return "#\(headline.mission.num) \(headline.mission.title)" + (others > 0 ? " +\(others)" : "")
    }

    public var body: some View {
        if let headline = missions.sections.headline {
            let others = missions.othersCount
            HStack(spacing: 4) {
                Image(systemName: "flag.fill").font(.caption2)
                Text(verbatim: "#\(headline.mission.num) \(headline.mission.title)").lineLimit(1).truncationMode(.tail)
                if others > 0 { Text(verbatim: "+\(others)").fontWeight(.semibold) }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(headline.isCurrent ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mission \(headline.mission.num), \(headline.mission.title)"
                                + (others > 0 ? ", and \(others) more" : ""))
            .accessibilityHint("Shows every mission this conversation worked on")
        }
    }
}
```

`ConversationMissionsList.swift`:

```swift
import SwiftUI
import MatronModels

/// Every mission a conversation touched, as Current / Also on / Earlier
/// (spec §6 "Header", mockup 04 right). The iOS sheet's content.
public struct ConversationMissionsList: View {
    let missions: ConversationMissions
    /// Project id → title, for the chips; missing ids draw no chip.
    let projectTitles: [String: String]
    /// "pat · ~/yearbook-app" — moved here from the header when the chip
    /// takes the title's second line.
    let contextLine: String?
    let onOpenMission: (String) -> Void
    let onOpenProject: ((String) -> Void)?
    @Environment(\.timeZone) private var timeZone

    public init(missions: ConversationMissions, projectTitles: [String: String] = [:], contextLine: String? = nil,
                onOpenMission: @escaping (String) -> Void, onOpenProject: ((String) -> Void)? = nil) {
        self.missions = missions; self.projectTitles = projectTitles; self.contextLine = contextLine
        self.onOpenMission = onOpenMission; self.onOpenProject = onOpenProject
    }

    public var body: some View {
        let sections = missions.sections
        List {
            if let contextLine { Section { Text(contextLine).font(.footnote).foregroundStyle(.secondary) } }
            if let current = sections.current { Section("Current") { row(current) } }
            if !sections.alsoOn.isEmpty { Section("Also on") { ForEach(sections.alsoOn) { row($0) } } }
            if !sections.earlier.isEmpty { Section("Earlier") { ForEach(sections.earlier) { row($0) } } }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Missions")
    }

    private func row(_ link: ConversationMissionLink) -> some View {
        Button { onOpenMission(link.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "#\(link.mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.mission.title).font(link.isEarlier ? .body : .body.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(ProjectsFormat.headerLine(link, timeZone: timeZone)).font(.caption).foregroundStyle(.secondary)
                        if let pid = link.mission.projectID, let title = projectTitles[pid] {
                            ProjectChip(title: title, action: onOpenProject.map { open in { open(pid) } })
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.primary)
        .accessibilityIdentifier("conversationMissions.\(link.mission.num)")
    }
}
```

`LooseSessionsSection.swift`:

```swift
import SwiftUI
import MatronModels

/// "Not on a mission (n)" at the top of the Chats list (spec §6: the loose
/// sessions group moved off the Projects home). Collapsed by default; a
/// plain button header so it works in every list style.
public struct LooseSessionsSection: View {
    let sessions: [DashboardSession]
    @Binding var isExpanded: Bool
    let onOpen: (String) -> Void
    public init(sessions: [DashboardSession], isExpanded: Binding<Bool>, onOpen: @escaping (String) -> Void) {
        self.sessions = sessions; self._isExpanded = isExpanded; self.onOpen = onOpen
    }

    public var body: some View {
        if !sessions.isEmpty {
            Section {
                if isExpanded {
                    ForEach(sessions) { session in
                        Button { onOpen(session.id) } label: { DashboardSessionRow(session: session, showsNeedsYou: true) }
                            .buttonStyle(.plain).foregroundStyle(Color.primary)
                    }
                }
            } header: {
                Button { isExpanded.toggle() } label: {
                    HStack {
                        Text("Not on a mission (\(sessions.count))")
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chats.looseToggle")
            }
        }
    }
}
```

- [ ] **Step 4: Record, verify, and run the whole shared suite**

Run the class twice: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.ConversationMissionsSnapshotTests'` (second run PASS). Compare `conversation-missions-list` with the right-hand phone of `mockups/04-ios.png`.
Run: `swift test --package-path MatronShared`
Expected: `Executed N tests, with 0 failures`.
Run the iOS and Mac suites exactly as in Task 9 Step 2 (they must still build against the changed `MissionRowView`/`MissionDetailView` signatures; the hosts still use the old dashboard).
Expected: iOS `** TEST SUCCEEDED **`; Mac failures limited to the four known ones.

- [ ] **Step 5: Commit, push, open PR 2**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronShared/Sources/DesignSystem/Projects MatronShared/Tests/DesignSystemSnapshotTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "projects: header mission chip, missions list and the Chats 'Not on a mission' section" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/projects-shared-ui
gh pr create --base feat/projects-data --title "Projects (2/4): view models and shared views" --body "$(cat <<'BODY'
View models (home assembly, project page with merge redirect, mission page project/move/groups) and every shared view with snapshots for spec 2026-09-30. Hosts are unchanged until PRs 3 (iOS) and 4 (Mac).

Plan: docs/superpowers/plans/2026-09-30-projects-apple.md (Tasks 10–18)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

# PR 3 — iOS

Branch: `feat/projects-ios`, from `feat/projects-shared-ui`.

### Task 19: iOS wiring — factories, the Projects tab, `ProjectRoute`, navigation

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (`makeMissionsDashboardViewModel`, `makeMissionDetailViewModel`; new `makeProjectDetailViewModel`)
- Create: `Matron/App/ProjectRoute.swift` (`ProjectRoute`, the `openProject` environment action)
- Modify: `Matron/App/PathPrefixedRoute.swift` (`isAnyPathPrefixedRoute`)
- Modify: `Matron/App/AppShellNavigation.swift` (`openProject`, `pushProject`, `handleProjectsHome`)
- Modify: `Matron/App/AppShellView.swift` (tab label only in this task)
- Test: `MatronTests/ProjectsNavigationTests.swift` (new), `MatronTests/AppShellViewTests.swift` (tab titles)

**Interfaces:**
- Consumes: Task 9 `projectsSync(for:)`; Task 11/12/13 view model inits; Task 14 `ProjectGlyph.symbol`.
- Produces:
  - `AppDependencies.makeProjectDetailViewModel(for: UserSession, projectID: String) -> ProjectDetailViewModel`.
  - `struct ProjectRoute: PathPrefixedRoute` (`"project/"`).
  - `EnvironmentValues.openProject: ((String) -> Void)?` — how a mission page opens its project from any stack.
  - `AppShellNavigation.openProject(_:)` (switches to the Projects tab, stack = [project]), `pushProject(_:)` (pushes on the Projects stack, idempotent for the top), `handleProjectsHome(_:)` (routes `.openProject` / `.openMission`; `.newProject` and `.moveMission` belong to the tab root).

- [ ] **Step 1: Write the failing tests**

Create `MatronTests/ProjectsNavigationTests.swift`:

```swift
import XCTest
import MatronModels
@testable import Matron

@MainActor
final class ProjectsNavigationTests: XCTestCase {
    func testAProjectCardPushesTheProjectPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleProjectsHome(.openProject("pj_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"])
        nav.handleProjectsHome(.openProject("pj_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"], "a double tap never stacks two pages")
    }

    func testAMissionRowPushesTheMissionPage() {
        let nav = AppShellNavigation()
        nav.tab = .missions
        nav.handleProjectsHome(.openProject("pj_1"))
        nav.handleProjectsHome(.openMission("ms_1"))
        XCTAssertEqual(nav.missionsPath, ["project/pj_1", "mission/ms_1"])
    }

    func testTheHostHandlesNewProjectAndMove() {
        let nav = AppShellNavigation()
        nav.handleProjectsHome(.newProject)
        nav.handleProjectsHome(.moveMission(missionID: "ms_1", projectID: "pj_1"))
        XCTAssertEqual(nav.missionsPath, [])
    }

    /// A mission page on a chat stack opens its project on the Projects tab.
    func testOpenProjectFromAnotherTabSwitchesToProjects() {
        let nav = AppShellNavigation()
        nav.tab = .conversations
        nav.chatPath = ["c1", "mission/ms_1"]
        nav.openProject("pj_1")
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, ["project/pj_1"])
        XCTAssertEqual(nav.chatPath, ["c1", "mission/ms_1"], "the chat stack is left where it was")
    }

    func testOpenProjectIsInertWithoutMissions() {
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.openProject("pj_1")
        XCTAssertEqual(nav.missionsPath, [])
        XCTAssertNotEqual(nav.tab, .missions)
    }

    func testProjectRouteIsARouteNotAChat() {
        XCTAssertEqual(ProjectRoute(pathValue: "project/pj_1")?.id, "pj_1")
        XCTAssertTrue(isAnyPathPrefixedRoute("project/pj_1"))
        XCTAssertNil(ProjectRoute(pathValue: "mission/ms_1"))
    }
}
```

In `AppShellViewTests.test_shell_showsFourTabs_coordinatorFirst`, change the expected titles to `["Coordinator", "Projects", "Decisions", "Conversations"]`.

- [ ] **Step 2: Run to verify they fail**

Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/ProjectsNavigationTests -only-testing:MatronTests/AppShellViewTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `value of type 'AppShellNavigation' has no member 'handleProjectsHome'` (after `xcodegen generate` picks up the new test file).

- [ ] **Step 3: Implement**

`Matron/App/ProjectRoute.swift`:

```swift
import SwiftUI

/// A project page pushed onto the Projects tab's `[String]` stack.
struct ProjectRoute: PathPrefixedRoute {
    let id: String
    static let pathPrefix = "project/"
    init(id: String) { self.id = id }
}

extension EnvironmentValues {
    /// Opens a project page from wherever a mission page is mounted. The
    /// Projects tab pushes; every other tab hands off to the Projects tab
    /// (`AppShellView` installs both).
    @Entry var openProject: ((String) -> Void)? = nil
}
```

`PathPrefixedRoute.swift`: add `|| ProjectRoute(pathValue: value) != nil` to `isAnyPathPrefixedRoute`.

`AppShellNavigation`, beside `openMission`:

```swift
    /// A project from outside the Projects tab (a mission page on a chat
    /// stack): the Projects tab comes forward on that page.
    func openProject(_ projectID: String) {
        guard missionsSupported else { return }
        tab = .missions
        let route = ProjectRoute(id: projectID).pathValue
        if missionsPath != [route] { missionsPath = [route] }
    }

    func pushProject(_ projectID: String) {
        let route = ProjectRoute(id: projectID).pathValue
        guard missionsPath.last != route else { return }
        missionsPath.append(route)
    }

    /// Every navigation tap on the Projects home. `.newProject` and
    /// `.moveMission` are the tab root's own (a sheet, a write).
    func handleProjectsHome(_ action: ProjectsHomeAction) {
        switch action {
        case .openProject(let id): pushProject(id)
        case .openMission(let id): pushMission(id)
        case .newProject, .moveMission: break
        }
    }
```

`AppShellView`: change the tab item to `Label("Projects", systemImage: ProjectGlyph.symbol)` (import `MatronDesignSystem` if not already imported).

`Matron/App/AppDependencies.swift`: pass the new dependencies and add the factory:

```swift
        return MissionsDashboardViewModel(
            store: c.store, sync: c.missions,
            summaries: { chat.chatSummaries() },
            roster: { try await api.roster() },
            send: { convoID, body in
                try await engine.sendMessage(convoID: convoID, body: body, localID: UUID().uuidString)
            },
            projectsStore: c.store, projects: c.projects)
```

```swift
    @MainActor func makeMissionDetailViewModel(for session: UserSession, missionID: String) -> MissionDetailViewModel {
        let c = core(for: session)
        return MissionDetailViewModel(missionID: missionID, store: c.store, sync: c.missions,
                                      projectsStore: c.store, projects: c.projects)
    }

    /// One project page (spec 2026-09-30 §2).
    @MainActor func makeProjectDetailViewModel(for session: UserSession, projectID: String) -> ProjectDetailViewModel {
        let c = core(for: session)
        return ProjectDetailViewModel(projectID: projectID, store: c.store, projects: c.projects, missions: c.missions)
    }
```

(Keep the existing comment inside the `send:` closure.)

- [ ] **Step 4: Run to verify they pass**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then the Step 2 command.
Expected: `** TEST SUCCEEDED **`, `Executed N tests, with 0 failures` where N = 6 + the AppShellViewTests count.

- [ ] **Step 5: Commit**

```bash
git add Matron/App MatronTests/ProjectsNavigationTests.swift MatronTests/AppShellViewTests.swift Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: the Missions tab is Projects; project routes and navigation" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 20: iOS hosts — Projects root, project page, mission page chip and move

**Files:**
- Create: `Matron/Features/Projects/ProjectsTabRoot.swift` (replaces `Matron/Features/Missions/MissionsTabRoot.swift`, deleted)
- Create: `Matron/Features/Projects/ProjectDetailHost.swift`
- Modify: `Matron/Features/Missions/MissionDetailHost.swift`
- Modify: `Matron/App/AppShellView.swift` (`missionsTab`, hoisted `projectsDestination(_:)`, `openProject` environment on the shell and the tab)
- Test: `MatronTests/AppShellViewTests.swift`

**Interfaces:**
- Consumes: Task 19 routes/navigation/factories; Task 15 `ProjectsHomeView`, `NewProjectSheet`; Task 16 `ProjectDetailView`; Task 17 `MissionDetailView` new params.
- Produces: `ProjectsTabRoot(viewModel:onAction:onLegacyAction:onOpenMemories:)`, `ProjectDetailHost(projectID:session:missionsViewModel:onOpenMission:onOpenItem:onOpenMilestone:)`.

- [ ] **Step 1: Write the failing test**

Append to `AppShellViewTests` (it uses the file's own `coordinatorNavigation()`, `renderShellWithCoordinator(_:)`, `popTheSelectedStack()` and the tab-bar assertions):

```swift
    /// Spec §6: the project page is pushed on the Projects stack, so the
    /// tab bar hides there and comes back at the root.
    func test_projectPage_hidesTheTabBar_andTheProjectsRootShowsItAgain() throws {
        let nav = coordinatorNavigation()
        nav.tab = .missions
        renderShellWithCoordinator(nav)
        try assertTabBarShowing("at the Projects root")
        nav.pushProject("pj_1")
        try assertTabBarHidden("on a project page")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the Projects root")
        XCTAssertEqual(nav.missionsPath, [])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run the Task 19 Step 2 command narrowed to `-only-testing:MatronTests/AppShellViewTests`.
Expected: FAIL — the pushed `project/pj_1` value has no destination yet, so nothing hides the tab bar.

- [ ] **Step 3: Implement `ProjectsTabRoot`**

Delete `Matron/Features/Missions/MissionsTabRoot.swift`. Create `Matron/Features/Projects/ProjectsTabRoot.swift`:

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects tab's root (spec 2026-09-30 §6). The view model is the
/// shell's session-long `MissionsDashboardViewModel` (its badge shows while
/// another tab does). A journal without `/projects` keeps today's missions
/// dashboard here (spec §7).
struct ProjectsTabRoot: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (ProjectsHomeAction) -> Void
    let onLegacyAction: (MissionsDashboardAction) -> Void
    var onOpenMemories: (() -> Void)? = nil
    @State private var showNewProject = false

    var body: some View {
        content
            .navigationTitle("Projects")
            .toolbar { toolbarContent }
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .sheet(isPresented: $showNewProject) { newProjectSheet }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if viewModel.projectsSupported == false {
            MissionsDashboardView(model: legacyModel, onAction: onLegacyAction, onRefresh: { await viewModel.refresh() })
        } else {
            ProjectsHomeView(model: homeModel, onAction: handle, onRefresh: { await viewModel.refresh() })
        }
    }

    private var homeModel: ProjectsHomeView.Model {
        ProjectsHomeView.Model(home: viewModel.home, isRefreshing: viewModel.isRefreshing, askedAt: viewModel.askedAt,
                               isAskEnabled: viewModel.canSendAsk, canCreateProject: viewModel.canCreateProject)
    }

    private var legacyModel: MissionsDashboardView.Model {
        MissionsDashboardView.Model(cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
                                    isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
                                    askedAt: viewModel.askedAt, isAskEnabled: viewModel.canSendAsk)
    }

    private func handle(_ action: ProjectsHomeAction) {
        switch action {
        case .newProject: showNewProject = true
        case .moveMission(let missionID, let projectID): Task { await viewModel.moveMission(missionID, to: projectID) }
        case .openProject, .openMission: onAction(action)
        }
    }

    private var newProjectSheet: some View {
        NewProjectSheet(onCreate: { title, body in
            guard let project = await viewModel.createProject(title: title, body: body) else {
                let failure = viewModel.error ?? "Couldn't create the project."
                viewModel.error = nil
                return failure
            }
            showNewProject = false
            onAction(.openProject(project.id))
            return nil
        }, onCancel: { showNewProject = false })
        .presentationDetents([.medium])
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil && !showNewProject }, set: { if !$0 { viewModel.error = nil } })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if viewModel.canCreateProject {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewProject = true } label: { Label("New project", systemImage: "plus") }
                    .accessibilityIdentifier("projects.new")
            }
        }
        if viewModel.canAskCoordinator {
            ToolbarItem(placement: .primaryAction) {
                MissionsDashboardAskButton(isEnabled: viewModel.canSendAsk) { Task { await viewModel.askCoordinator() } }
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

- [ ] **Step 4: Implement `ProjectDetailHost`**

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One project page on iOS: owns its `ProjectDetailViewModel` for the life
/// of the pushed screen. Session chips come from the shell's dashboard VM.
struct ProjectDetailHost: View {
    let projectID: String
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: ProjectDetailViewModel?
    @State private var confirmMerge: Project?

    var body: some View {
        content
            .navigationTitle(viewModel?.page?.project.title ?? "Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: projectID) {
                guard let deps else { return }
                viewModel?.stop()
                let vm = deps.makeProjectDetailViewModel(for: session, projectID: projectID)
                viewModel = vm
                vm.start()
            }
            .onAppear { missionsViewModel.projectPageDidAppear() }
            .onDisappear {
                viewModel?.stop()
                missionsViewModel.projectPageDidDisappear()
            }
            .confirmationDialog(mergeTitle, isPresented: mergeShown, titleVisibility: .visible) {
                Button("Merge", role: .destructive) { merge() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its missions move there and this project closes.")
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel?.error = nil }
            } message: {
                Text(viewModel?.error ?? "")
            }
            .tabBarFollowsTheSelectedTab(otherwise: .hidden)
    }

    @ViewBuilder private var content: some View {
        if let viewModel, let page = pageModel(viewModel) {
            ProjectDetailView(page: page, onOpenMission: onOpenMission, onOpenItem: onOpenItem,
                              onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                              onMoveMission: { id, target in Task { await viewModel.moveMission(id, to: target) } },
                              onRefresh: { await viewModel.refresh() })
        } else if viewModel?.isMissing == true {
            ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                   description: Text("It may have been merged or removed."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The page with its session chips, which live on the shell's
    /// dashboard VM (it already owns every mission's sessions).
    private func pageModel(_ viewModel: ProjectDetailViewModel) -> ProjectPageModel? {
        guard var page = viewModel.page else { return nil }
        page.sessionsByMission = missionsViewModel.sessionsByMission
        return page
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let page = viewModel?.page {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu("Add a mission") {
                        ForEach(page.unfiledMissions) { mission in
                            Button(mission.label) { Task { await viewModel?.addMission(mission.id) } }
                        }
                    }
                    .disabled(page.unfiledMissions.isEmpty)
                    Menu("Merge into…") {
                        ForEach(page.mergeTargets) { target in Button(target.title) { confirmMerge = target } }
                    }
                    .disabled(page.mergeTargets.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Project actions")
            }
        }
    }

    private var mergeTitle: String {
        guard let target = confirmMerge, let page = viewModel?.page else { return "" }
        return "Merge “\(page.project.title)” into “\(target.title)”?"
    }

    private var mergeShown: Binding<Bool> {
        Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } })
    }

    private func merge() {
        guard let target = confirmMerge else { return }
        confirmMerge = nil
        Task { _ = await viewModel?.merge(into: target.id) }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel?.error != nil }, set: { if !$0 { viewModel?.error = nil } })
    }
}
```

- [ ] **Step 5: Mission page host — project chip and move**

In `MissionDetailHost`, add `@Environment(\.openProject) private var openProject`, pass the new model fields and callbacks:

```swift
                MissionDetailView(
                    model: .init(mission: viewModel.mission, project: viewModel.project, milestones: viewModel.milestones,
                                 sessionTags: viewModel.sessionTags,
                                 openItems: viewModel.openItems, conversations: viewModel.conversations,
                                 moveTargets: viewModel.moveTargets,
                                 showOnlyUserInput: viewModel.showOnlyUserInput,
                                 closeSummary: viewModel.closeSummaryDraft, isBusy: viewModel.isBusy),
                    onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
                    onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                    onOpenItem: onOpenItem,
                    onOpenConversation: onOpenConversation,
                    onEditCloseSummary: { viewModel.closeSummaryDraft = $0 },
                    onClose: { Task { await viewModel.close() } },
                    onRefresh: { await viewModel.refresh() },
                    onOpenProject: openProject,
                    onMove: viewModel.canMove ? { target in Task { await viewModel.moveToProject(target) } } : nil)
```

and change its two `.alert("Missions", …)` titles to `"Projects"`.

- [ ] **Step 6: Shell — the tab's stack and the environment**

In `AppShellView`:

1. The shell-wide action, on the `TabView` next to `.environment(\.appDependencies, deps)`:

```swift
        .environment(\.openProject) { nav.openProject($0) }
```

2. Replace `missionsTab` with a version that uses `ProjectsTabRoot` and a hoisted destination builder:

```swift
    private var missionsTab: some View {
        NavigationStack(path: missionsPath) {
            ProjectsTabRoot(viewModel: missionsVM, onAction: { nav.handleProjectsHome($0) },
                            onLegacyAction: { nav.handleDashboard($0) },
                            onOpenMemories: { nav.openMemories() })
                .simultaneousGesture(rootSwipe)
                .tabBarFollowsTheSelectedTab(otherwise: .visible)
                .navigationDestination(for: String.self) { projectsDestination($0) }
        }
        .environment(\.chatNavigationPath, missionsPath)
        // On its own stack a project opens by pushing, not by a tab switch.
        .environment(\.openProject) { nav.pushProject($0) }
    }

    /// Every value the Projects stack can carry. Hoisted out of
    /// `missionsTab` for CI's type-checker budget.
    @ViewBuilder private func projectsDestination(_ value: String) -> some View {
        if value == MemoriesRoute.list {
            MemoriesScreen(viewModel: memoriesVM, onOpen: { nav.openMemory($0) }, onNew: { nav.openNewMemory() })
                .tabBarFollowsTheSelectedTab(otherwise: .hidden)
        } else if value == MemoriesRoute.newMemory || MemoryRoute(pathValue: value) != nil {
            MemoryEditorHost(viewModel: memoriesVM, name: MemoryRoute(pathValue: value)?.id,
                             onSaved: { nav.memorySaved(name: $0, wasNew: $1) }, onDeleted: { nav.memoryDeleted() })
                .tabBarFollowsTheSelectedTab(otherwise: .hidden)
        } else if let project = ProjectRoute(pathValue: value) {
            ProjectDetailHost(projectID: project.id, session: session, missionsViewModel: missionsVM,
                              onOpenMission: { nav.pushMission($0) }, onOpenItem: { nav.pushMissionItem($0) },
                              onOpenMilestone: openMilestone)
        } else if let mission = MissionRoute(pathValue: value) {
            MissionDetailHost(missionID: mission.id, session: session, onOpenMilestone: openMilestone,
                              onOpenItem: { nav.pushMissionItem($0) },
                              onOpenConversation: { nav.openConversation(fromMissions: $0) })
        } else if let item = ItemRoute(pathValue: value) {
            ItemDetailHost(itemID: item.id, session: session, currentConvoID: nil,
                           onOpenConversation: { nav.openConversation(fromMissions: $0) },
                           onOpenItem: { nav.pushMissionItem($0) })
        }
    }
```

- [ ] **Step 7: Run to verify**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, `Executed N tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add -A Matron/Features/Projects Matron/Features/Missions Matron/App MatronTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: Projects home, project page and the mission page's project chip" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 21: iOS conversation header — the missions chip and sheet; the title stops being a button

**Files:**
- Modify: `Matron/Features/Chat/ChatView.swift` (`missionID` state ~236, the `.task(id: viewModel.roomID)` ~593, `titleStack` ~339, the principal `ToolbarItem` ~627, the sheets ~683)
- Test: `MatronTests/ChatViewBindingTests.swift`

**Interfaces:**
- Consumes: Task 5 `missionsStream(convoID:)`; Task 8 `beginWatching`/`endWatching`; Task 18 `MissionChipLabel`, `ConversationMissionsList`.
- Produces: `ChatView.headerShowsContextLine(missions:) -> Bool` (static, for the test): the context line under the title gives way to the chip.

The principal toolbar item has room for two lines: title, then the chip when the conversation has missions (mockup 04 right), else the "box · ~/workdir" line as today. The context line moves to the top of the missions sheet, one tap away (decision in this plan; see the report).

- [ ] **Step 1: Write the failing test**

Append to `ChatViewBindingTests`:

```swift
    func testTheChipTakesTheContextLinesPlaceOnlyWhenThereAreMissions() {
        XCTAssertTrue(ChatView.headerShowsContextLine(missions: ConversationMissions()))
        let link = ConversationMissionLink(mission: Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1"),
                                           isCurrent: true)
        XCTAssertFalse(ChatView.headerShowsContextLine(missions: ConversationMissions(links: [link])))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/ChatViewBindingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `type 'ChatView' has no member 'headerShowsContextLine'`.

- [ ] **Step 3: Implement**

1. Replace `@State private var missionID: String?` with:

```swift
    /// Every mission this conversation touched (spec 2026-09-30 §3, §6),
    /// for the chip under the title. Empty until the store answers.
    @State private var conversationMissions = ConversationMissions()
    @State private var showMissionsSheet = false
    /// Set by a sheet row; pushed once the sheet has gone (one sheet per
    /// presenter, as with `pendingChildOpen`).
    @State private var pendingMissionOpen: String?
    @State private var missionProjectTitles: [String: String] = [:]

    static func headerShowsContextLine(missions: ConversationMissions) -> Bool {
        MissionChipLabel.text(missions) == nil
    }
```

2. Replace the `.task(id: viewModel.roomID)` body:

```swift
        .task(id: viewModel.roomID) {
            // Clear the previous room's value first (MINOR-4).
            conversationMissions = ConversationMissions()
            guard let deps, let session else { return }
            let convoID = viewModel.roomID
            let projects = deps.projectsSync(for: session)
            // Watching makes a marker in this conversation refetch its
            // links; it ends with this task (room switch or disappear).
            await projects.beginWatching(convoID: convoID)
            defer { Task { await projects.endWatching(convoID: convoID) } }
            for await missions in deps.journalStore(for: session).missionsStream(convoID: convoID) {
                guard !Task.isCancelled else { return }
                conversationMissions = missions
            }
        }
```

3. `titleStack` becomes:

```swift
    private var titleStack: some View {
        VStack(spacing: 1) {
            titleText
                .font(.headline)
                .lineLimit(1)
            if !Self.headerShowsContextLine(missions: conversationMissions) {
                Button { openMissionsSheet() } label: { MissionChipLabel(missions: conversationMissions) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.missionsChip")
            } else if let context = chatContextLine {
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func openMissionsSheet() {
        if let deps, let session {
            let projects = (try? deps.journalStore(for: session).projects()) ?? []
            missionProjectTitles = Dictionary(projects.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        showMissionsSheet = true
    }
```

4. In the principal `ToolbarItem`, delete the `else if let missionID { Button { openMission(missionID) } … }` branch so the non-tasks case is always the inert `titleStack` with its accessibility label and value.

5. After the existing `.sheet(isPresented: $showSessionStatus, …)`, add:

```swift
        .sheet(isPresented: $showMissionsSheet, onDismiss: {
            if let id = pendingMissionOpen {
                pendingMissionOpen = nil
                openMission(id)
            }
        }) {
            NavigationStack {
                ConversationMissionsList(missions: conversationMissions, projectTitles: missionProjectTitles,
                                         contextLine: chatContextLine,
                                         onOpenMission: { id in
                                             pendingMissionOpen = id
                                             showMissionsSheet = false
                                         })
            }
            .presentationDetents([.medium, .large])
        }
```

`openMission(_:)` (the milestone-card path) is unchanged and still used by the transcript's milestone cards.

- [ ] **Step 4: Run to verify**

Run the Step 2 command, then the full `-only-testing:MatronTests` suite.
Expected: `** TEST SUCCEEDED **`, `Executed N tests, with 0 failures`.

- [ ] **Step 5: Look at it**

Install on the iPhone 17 simulator (`xcodebuild -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build` then `xcrun simctl install booted <app>` and launch), open a conversation that is on a mission, and compare the header and sheet with the right-hand phone of `mockups/04-ios.png`. Tap a sheet row: the sheet closes and the mission page pushes.

- [ ] **Step 6: Commit**

```bash
git add Matron/Features/Chat/ChatView.swift MatronTests/ChatViewBindingTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: header chip names the current mission and opens every mission the chat touched" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 22: iOS Chats — "Not on a mission"; PR 3

**Files:**
- Modify: `Matron/Features/ChatList/ChatListView.swift` (the `List` at ~347)
- Modify: `Matron/App/AppShellView.swift` (`conversationsTab` passes the dashboard VM)
- Test: `MatronTests/ChatListViewBindingTests.swift`

**Interfaces:**
- Consumes: Task 11 `looseSectionDidAppear/Disappear`, `looseSessions`, `projectsSupported`; Task 18 `LooseSessionsSection`.
- Produces: `ChatListView` gains `var missionsVM: MissionsDashboardViewModel? = nil` and `static func showsLooseSection(projectsSupported: Bool?) -> Bool`.

Only when projects are supported: on an old journal the legacy dashboard still shows its own loose group.

- [ ] **Step 1: Write the failing test**

Append to `ChatListViewBindingTests`:

```swift
    func testTheLooseSectionFollowsProjectsSupport() {
        XCTAssertTrue(ChatListView.showsLooseSection(projectsSupported: true))
        XCTAssertTrue(ChatListView.showsLooseSection(projectsSupported: nil), "unknown yet: optimistic, like the tab")
        XCTAssertFalse(ChatListView.showsLooseSection(projectsSupported: false), "the legacy dashboard shows its own")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:MatronTests/ChatListViewBindingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `type 'ChatListView' has no member 'showsLooseSection'`.

- [ ] **Step 3: Implement**

In `ChatListView`:

```swift
    /// The session-long dashboard VM, for the "Not on a mission" section
    /// (spec 2026-09-30 §6). Nil in previews and tests.
    var missionsVM: MissionsDashboardViewModel? = nil
    @State private var showLoose = false

    static func showsLooseSection(projectsSupported: Bool?) -> Bool { projectsSupported != false }

    @ViewBuilder private var looseSection: some View {
        if let missionsVM, Self.showsLooseSection(projectsSupported: missionsVM.projectsSupported) {
            LooseSessionsSection(sessions: missionsVM.looseSessions, isExpanded: $showLoose) { id in
                chatNavigationPath?.wrappedValue.append(id)
            }
        }
    }
```

Insert `looseSection` as the first child of the `List { … }` (before `ForEach(viewModel.groups)`), and on the `List` add:

```swift
            .onAppear { missionsVM?.looseSectionDidAppear() }
            .onDisappear { missionsVM?.looseSectionDidDisappear() }
```

(`chatNavigationPath` is the `@Environment(\.chatNavigationPath)` the file already declares at line ~52; appending a conversation id pushes that chat exactly as a row's `NavigationLink(value:)` does.)

In `AppShellView.conversationsTab`, pass `missionsVM: missionsVM` to `ChatListView(…)`.

- [ ] **Step 4: Run every iOS test, then look**

Run: the full `-only-testing:MatronTests` command from Task 20 Step 7.
Expected: `** TEST SUCCEEDED **`, `Executed N tests, with 0 failures`.
Build and launch on the iPhone 17 simulator: the Projects tab shows cards over slim rows with both folds; a card pushes the project page; a row pushes the mission page with status, needs you, On it now / Earlier, five milestones; the Chats tab shows "Not on a mission (n)" collapsed at the top.

- [ ] **Step 5: Commit, push, open PR 3**

```bash
git add Matron/Features/ChatList/ChatListView.swift Matron/App/AppShellView.swift MatronTests/ChatListViewBindingTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: loose sessions move to the Chats tab" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/projects-ios
gh pr create --base feat/projects-shared-ui --title "Projects (3/4): iOS" --body "$(cat <<'BODY'
iOS for spec 2026-09-30: Projects tab (home, project page, New project, Move to project, Merge into…), mission page chip and parity sections, header missions chip + sheet, loose sessions in Chats. Old journals keep the missions dashboard.

Plan: docs/superpowers/plans/2026-09-30-projects-apple.md (Tasks 19–22)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

# PR 4 — Mac

Branch: `feat/projects-mac`, from `feat/projects-shared-ui` (independent of PR 3).

### Task 23: Mac wiring — factories, the Projects entry, `MacPlace.Detail.project`, `selectedProjectID`

**Files:**
- Modify: `MatronMac/App/AppDependencies.swift` (`makeMissionsDashboardViewModel` ~407, `makeMissionDetailViewModel` ~436; new `makeProjectDetailViewModel`)
- Modify: `MatronMac/Features/Nav/MacNavColumn.swift` (`MacNav.title`, `.symbol`)
- Modify: `MatronMac/Features/Nav/MacNavigationHistory.swift` (`MacPlace.Detail.project`, its three switches)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`selectedProjectID`, `place(…)`, `NavEntryLanding`, `selectingNavEntry`, `selectNavEntry`, `restore(_:)`, `showMissionsDashboard`, new `showProject(_:)`)
- Test: `MatronMacTests/MacProjectsNavTests.swift` (new), `MatronMacTests/MacMissionsNavTests.swift` (title/symbol), `MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/*` (re-record)

**Interfaces:**
- Consumes: Task 9 core; Task 11–13 inits; Task 14 `ProjectGlyph.symbol`.
- Produces: `AppDependencies.makeProjectDetailViewModel(for:projectID:)` (Mac); `MacPlace.Detail.project(id: String)` (nav `.missions`, no pane, no displayed conversation); `MacChatListView.place(…, selectedProjectID: String? = nil)`; `NavEntryLanding.selectedProjectID` (defaulted); `selectingNavEntry(_:selectedMissionID:selectedProjectID: = nil, missionBackConvoID:)`; private `showProject(_:)`.

The Projects entry's places: home = `.mission(id: nil)` (unchanged, so existing history tests hold), a project page = `.project(id:)`, a mission page = `.mission(id:)`. A mission wins over a project when both are set.

- [ ] **Step 1: Write the failing tests**

Create `MatronMacTests/MacProjectsNavTests.swift`:

```swift
import XCTest
import SwiftUI
import MatronDesignSystem
@testable import MatronMac

@MainActor
final class MacProjectsNavTests: XCTestCase {
    func testTheEntryIsCalledProjects() {
        XCTAssertEqual(MacNav.missions.title, "Projects")
        XCTAssertEqual(MacNav.missions.symbol, ProjectGlyph.symbol)
        XCTAssertEqual(ChatCommands.navShortcuts[1].title, "Projects", "⌘2 keeps its place and takes the name")
    }

    func testAProjectPageIsItsOwnPlace() {
        let place = MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: nil,
                                          selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                                          selectedProjectID: "pj_1")
        XCTAssertEqual(place, MacPlace(detail: .project(id: "pj_1")))
        XCTAssertEqual(place.nav, .missions)
        XCTAssertNil(place.pane)
        XCTAssertNil(place.displayedConversationID)
    }

    func testAMissionWinsOverTheProjectItWasOpenedFrom() {
        let place = MacChatListView.place(nav: .missions, selectedSummaryID: nil, selectedMissionID: "ms_1",
                                          selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                                          selectedProjectID: "pj_1")
        XCTAssertEqual(place, MacPlace(detail: .mission(id: "ms_1")))
    }

    func testChoosingProjectsLandsOnTheHomeFromAProjectPage() {
        let landing = MacChatListView.selectingNavEntry(.missions, selectedMissionID: nil, selectedProjectID: "pj_1",
                                                        missionBackConvoID: nil)
        XCTAssertEqual(landing, .init(nav: .missions, selectedMissionID: nil, missionBackConvoID: nil, selectedProjectID: nil))
        let elsewhere = MacChatListView.selectingNavEntry(.decisions, selectedMissionID: nil, selectedProjectID: "pj_1",
                                                          missionBackConvoID: nil)
        XCTAssertEqual(elsewhere.selectedProjectID, "pj_1", "another entry leaves it for Back and ⌘2")
    }

    func testBackRestoresAProjectPage() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .project(id: "pj_1")))
        history.visit(MacPlace(detail: .mission(id: "ms_1")))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .project(id: "pj_1")))
    }
}
```

Delete the title/symbol assertions from `MacMissionsNavTests.testNavOrderIsCoordinatorMissionsDecisionsConversationsMemories` (keep its `allCases` order assertion) — the new file owns them.

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacProjectsNavTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `type 'MacPlace.Detail' has no member 'project'`.

- [ ] **Step 3: Implement**

`MacNavColumn.swift`: `import MatronDesignSystem`; `case .missions: return "Projects"` in `title`, `case .missions: return ProjectGlyph.symbol` in `symbol`. (The accessibility identifier becomes `nav.projects`; no UI test reads `nav.missions`.)

`MacNavigationHistory.swift`: add to `MacPlace.Detail`:

```swift
        /// A project page (spec 2026-09-30 §2), under the Projects entry.
        case project(id: String)
```

and add `.project` to the three switches: `case .mission, .project: return .missions` in `nav`; `case .mission, .project, .decision, .memory: return nil` in `pane` and in `displayedConversationID`.

`MacChatListView.swift`:

1. Beside `@State private var selectedMissionID: String?`: `@State private var selectedProjectID: String?`.
2. `place(…)`: append the parameter `selectedProjectID: String? = nil` and change the `.missions` case to

```swift
        case .missions:
            if selectedMissionID == nil, let selectedProjectID {
                return MacPlace(detail: .project(id: selectedProjectID))
            }
            return MacPlace(detail: .mission(id: selectedMissionID))
```

   and pass `selectedProjectID: selectedProjectID` from `currentPlace`.
3. `NavEntryLanding`: add `var selectedProjectID: String? = nil` as its last field. `selectingNavEntry` gains `selectedProjectID: String? = nil` between `selectedMissionID:` and `missionBackConvoID:`; the non-missions branch returns `NavEntryLanding(nav: entry, selectedMissionID: selectedMissionID, missionBackConvoID: missionBackConvoID, selectedProjectID: selectedProjectID)`; the missions branch is unchanged (its new field defaults to nil). `selectNavEntry` passes `selectedProjectID: selectedProjectID` and assigns `selectedProjectID = landing.selectedProjectID`.
4. `restore(_:)`: add

```swift
        case .project(let id):
            missionBackConvoID = nil
            selectedMissionID = nil
            selectedProjectID = id
            nav = .missions
```

   and in the `.mission(let id)` case leave `selectedProjectID` alone (a mission wins in `place`).
5. `showMissionsDashboard()` also sets `selectedProjectID = nil`. Add beside it:

```swift
    /// A project page — from a home card, a mission page's chip or
    /// breadcrumb, or the header menu's "Open project".
    private func showProject(_ projectID: String) {
        missionBackConvoID = nil
        selectedMissionID = nil
        selectedProjectID = projectID
        nav = .missions
    }
```

6. Run `grep -n "switch .*detail\|case .mission(" MatronMac -r --include=*.swift` and give every remaining exhaustive `switch` over `MacPlace.Detail` a `.project` case matching its `.mission` sibling.

`MatronMac/App/AppDependencies.swift`: the same three factory changes as Task 19 Step 3 (dashboard VM gets `projectsStore: c.store, projects: c.projects`; mission detail VM gets `projectsStore: c.store, projects: c.projects` after its existing `closedItems:`/`refreshItems:` arguments; add `makeProjectDetailViewModel`).

- [ ] **Step 4: Run to verify they pass, re-record the nav column**

Run the Step 2 command with `-only-testing:MatronMacTests/MacProjectsNavTests -only-testing:MatronMacTests/MacMissionsNavTests -only-testing:MatronMacTests/MacMissionsDashboardNavTests -only-testing:MatronMacTests/MacMemoriesNavTests -only-testing:MatronMacTests/MacCoordinatorPageTests`.
Expected: `** TEST SUCCEEDED **`.
Then delete `MatronMacTests/__Snapshots__/MacNavColumnSnapshotTests/*`, run `xcodegen generate`, and run `-only-testing:MatronMacTests/MacNavColumnSnapshotTests` twice without the skip variable (records, then compares). Check the PNG shows "Projects" with the stacked-squares symbol second.

- [ ] **Step 5: Commit**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronMac MatronMacTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "mac: the Missions entry is Projects; project pages are places" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 24: Mac Projects home and the two-column project page

**Files:**
- Create: `MatronMac/Features/Projects/MacProjectsHome.swift`
- Create: `MatronMac/Features/Projects/MacProjectPage.swift` (host, top bar, content)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`missionDetail` split into hoisted helpers)
- Test: `MatronMacTests/MacProjectPageFixtures.swift`, `MatronMacTests/MacProjectPageSnapshotTests.swift` (new)

**Interfaces:**
- Consumes: Task 23 `showProject`, `selectedProjectID`; Task 12 `ProjectDetailViewModel`; Task 15/16 shared views (`ProjectsHomeView`, `NewProjectSheet`, `MissionRowView`, `SessionChipLine`, `NeedsYouPill`, `MoveToProjectMenu`); Mac mission-page chrome (`MacMissionPageLayout`, `.macMissionCard`, `MacMissionSectionLabel`, `MacMinuteText`, `macMissionPageClock`).
- Produces: `MacProjectsHome(viewModel:onAction:)`; `MacProjectPage(projectID:session:missionsViewModel:actions:onRedirect:)`; `MacProjectPageActions`; `MacProjectPageContent(page:actions:)`; `MacProjectPageTopBar(page:actions:)`; `MacProjectPageContent.otherOpenItems(_:) -> Int`.

- [ ] **Step 1: Write the fixtures and the failing tests**

`MatronMacTests/MacProjectPageFixtures.swift`:

```swift
#if os(macOS)
import Foundation
@testable import MatronMac
import MatronModels

/// The "Promo launch" project of mockup 02, at a fixed `now`.
enum MacProjectPageFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    static func row(_ num: Int, _ title: String, _ status: String?, _ activity: MissionActivity, needsYou: Int = 0,
                    age: TimeInterval) -> MissionRowModel {
        MissionRowModel(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                         lastMilestone: MissionLastMilestone(num: num + 1, title: "PR 8601 merged…",
                                                                             kind: .progress, createdAt: ago(86_400)),
                                         status: status, projectID: "pj_1"),
                        activity: activity, needsYouCount: needsYou, lastActivity: ago(age))
    }

    static func item(_ num: Int, _ title: String, mission: Int) -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: .question, awaiting: .user, title: title, originConvoID: "c1",
                    missionID: "ms_\(mission)", missionNum: mission)
    }

    static let page = ProjectPageModel(
        project: Project(id: "pj_1", num: 4000, title: "Promo launch",
                         body: "New promo site, blog, leavers' page and sales chat, launched from promo/integration.",
                         status: "Launch Wed 7 Oct, 07:00 (fallback 13 Oct; checkpoint Sun 4 Oct 18:00). The branch meets the launch gate.",
                         statusBy: .agent, statusUpdatedAt: ago(660),
                         missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 1), needsYou: 6, openItems: 43),
        missions: [
            row(4791, "Promo branch: /proto design at the base URLs",
                "R2 redirect test done on 328 addresses; infra PR 605 needs the blog nginx line.", .waiting, needsYou: 2, age: 660),
            row(4907, "Launch day: Wed 7 Oct 07:00", "Branch green at b6794bffa8; S7 confirmed.", .running, age: 660),
            row(4083, "Combined promo branch: gather and report", nil, .idle, age: 86_400),
        ],
        needsYou: [item(8666, "Leavers' page PR 8666 — ship with launch?", mission: 4791),
                   item(8667, "Claims on the homepage copy", mission: 4791),
                   item(8668, "Cloudflare: page rule for /blog", mission: 4907)],
        recentMilestones: [
            Milestone(id: "ml_1", missionID: "ms_4907", num: 9001, kind: .progress,
                      title: "S7 confirmed: no Cloudflare rule caches HTML", convoID: "c1", seq: 1, createdAt: ago(660)),
            Milestone(id: "ml_2", missionID: "ms_4907", num: 9002, kind: .userInput,
                      title: "Dan chose Wed 7 Oct, 07:00, fallback 13 Oct", convoID: "c1", seq: 2, createdAt: ago(13 * 3_600)),
        ],
        missionNums: ["ms_4791": 4791, "ms_4907": 4907, "ms_4083": 4083],
        sessionsByBox: ["greg": 2, "pat": 1, "dan-mac": 1, "terry": 1, "bev": 1],
        sessionsByMission: ["ms_4907": [
            DashboardSession(id: "c-g", title: "sales-chat", state: .running,
                             tag: SessionTagInputs(boxLetter: "G", boxName: "greg", sessionShort: "13")),
            DashboardSession(id: "c-d", title: "Cloudflare", state: .running,
                             tag: SessionTagInputs(boxLetter: "D", boxName: "dan-mac", sessionShort: "16")),
            DashboardSession(id: "c-x", title: "old", state: .done, boxName: "bev"),
        ]],
        mergeTargets: [Project(id: "pj_2", num: 4001, title: "Matron apps")],
        unfiledMissions: [Mission(id: "ms_5148", num: 5148, title: "Convert to editor v2", originConvoID: "c1")])
}
#endif
```

`MatronMacTests/MacProjectPageSnapshotTests.swift`:

```swift
#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

@MainActor
final class MacProjectPageSnapshotTests: XCTestCase {
    private typealias F = MacProjectPageFixtures

    func testOtherOpenItemsNeverGoesNegative() {
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(F.page), 40)
        var none = F.page
        none.project = Project(id: "pj_1", num: 1, title: "P", openItems: 1)
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(none), 0)
    }

    private func page(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            MacProjectPageTopBar(page: F.page, actions: .init())
            Divider()
            MacProjectPageContent(page: F.page, actions: .init())
        }
        .frame(width: width, height: height)
        .environment(\.macMissionPageClock, F.now)
    }

    func testProjectPageWide() {
        assertVariants(of: page(width: 1_440, height: 1_000), named: "project-page-1440")
    }

    func testProjectPageNarrow() {
        assertVariants(of: page(width: 800, height: 1_500), named: "project-page-800")
    }
}
#endif
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacProjectPageSnapshotTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `cannot find 'MacProjectPageContent' in scope`.

- [ ] **Step 3: Implement `MacProjectsHome`**

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects home in the Mac detail, full width. A thin host like
/// `MacMissionsDashboard`: it owns the New project sheet and the move
/// write, and hands navigation to the shell.
struct MacProjectsHome: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (ProjectsHomeAction) -> Void
    @State private var showNewProject = false

    var body: some View {
        ProjectsHomeView(model: model, onAction: handle, onRefresh: { await viewModel.refresh() }, onAsk: askAction)
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .sheet(isPresented: $showNewProject) {
                NewProjectSheet(onCreate: { title, body in
                    guard let project = await viewModel.createProject(title: title, body: body) else {
                        let failure = viewModel.error ?? "Couldn't create the project."
                        viewModel.error = nil
                        return failure
                    }
                    showNewProject = false
                    onAction(.openProject(project.id))
                    return nil
                }, onCancel: { showNewProject = false })
                .frame(width: 440)
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var model: ProjectsHomeView.Model {
        ProjectsHomeView.Model(home: viewModel.home, isRefreshing: viewModel.isRefreshing, askedAt: viewModel.askedAt,
                               isAskEnabled: viewModel.canSendAsk, canCreateProject: viewModel.canCreateProject)
    }

    private func handle(_ action: ProjectsHomeAction) {
        switch action {
        case .newProject: showNewProject = true
        case .moveMission(let missionID, let projectID): Task { await viewModel.moveMission(missionID, to: projectID) }
        case .openProject, .openMission: onAction(action)
        }
    }

    private var askAction: (() -> Void)? {
        guard viewModel.canAskCoordinator else { return nil }
        return { Task { await viewModel.askCoordinator() } }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil && !showNewProject }, set: { if !$0 { viewModel.error = nil } })
    }
}
```

- [ ] **Step 4: Implement `MacProjectPage.swift`**

```swift
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

struct MacProjectPageActions {
    var onShowHome: () -> Void = {}
    var onOpenMission: (String) -> Void = { _ in }
    var onOpenItem: (String) -> Void = { _ in }
    var onOpenMilestone: (Milestone) -> Void = { _ in }
    var onMoveMission: (String, String?) -> Void = { _, _ in }
    var onAddMission: (String) -> Void = { _ in }
    var onMerge: (String) -> Void = { _ in }
}

/// One project page in the Mac detail (spec 2026-09-30 §2, mockup 02).
/// Owns its `ProjectDetailViewModel`; reports a merge redirect so the
/// shell's selection (and so its Back/Forward place) follows.
struct MacProjectPage: View {
    let projectID: String
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    let actions: MacProjectPageActions
    let onRedirect: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: ProjectDetailViewModel?

    var body: some View {
        VStack(spacing: 0) {
            MacProjectPageTopBar(page: viewModel?.page, actions: wiredActions)
            Divider()
            content
        }
        .task(id: projectID) {
            guard let deps, viewModel?.projectID != projectID else { return }
            viewModel?.stop()
            let vm = deps.makeProjectDetailViewModel(for: session, projectID: projectID)
            viewModel = vm
            vm.start()
        }
        .onChange(of: viewModel?.projectID) { _, id in
            if let id, id != projectID { onRedirect(id) }
        }
        .onAppear { missionsViewModel.projectPageDidAppear() }
        .onDisappear {
            viewModel?.stop()
            missionsViewModel.projectPageDidDisappear()
        }
        .alert("Projects", isPresented: errorShown) {
            Button("OK") { viewModel?.error = nil }
        } message: {
            Text(viewModel?.error ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let page = pageModel {
            MacProjectPageContent(page: page, actions: wiredActions)
        } else if viewModel?.isMissing == true {
            ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                   description: Text("It may have been merged or removed."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageModel: ProjectPageModel? {
        guard var page = viewModel?.page else { return nil }
        page.sessionsByMission = missionsViewModel.sessionsByMission
        return page
    }

    /// The page's own writes go to its view model; navigation goes up.
    private var wiredActions: MacProjectPageActions {
        var wired = actions
        let vm = viewModel
        wired.onMoveMission = { id, target in Task { await vm?.moveMission(id, to: target) } }
        wired.onAddMission = { id in Task { await vm?.addMission(id) } }
        wired.onMerge = { target in Task { _ = await vm?.merge(into: target) } }
        return wired
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel?.error != nil }, set: { if !$0 { viewModel?.error = nil } })
    }
}

/// "‹ Projects" on the left; "Add a mission" and "…" (Merge into…) on the right.
struct MacProjectPageTopBar: View {
    let page: ProjectPageModel?
    let actions: MacProjectPageActions
    @State private var confirmMerge: Project?

    var body: some View {
        HStack(spacing: 16) {
            Button { actions.onShowHome() } label: { Label("Projects", systemImage: "chevron.backward") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("projects.backToHome")
            Spacer()
            if let page {
                Menu {
                    ForEach(page.unfiledMissions) { mission in
                        Button(mission.label) { actions.onAddMission(mission.id) }
                    }
                } label: { Label("Add a mission", systemImage: "plus") }
                    .fixedSize()
                    .disabled(page.unfiledMissions.isEmpty)
                Menu {
                    Menu("Merge into…") {
                        ForEach(page.mergeTargets) { target in Button(target.title) { confirmMerge = target } }
                    }
                    .disabled(page.mergeTargets.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Project actions")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .confirmationDialog(mergeTitle, isPresented: mergeShown) {
            Button("Merge", role: .destructive) {
                if let target = confirmMerge { actions.onMerge(target.id) }
                confirmMerge = nil
            }
            Button("Cancel", role: .cancel) { confirmMerge = nil }
        } message: {
            Text("Its missions move there and this project closes.")
        }
    }

    private var mergeTitle: String {
        guard let target = confirmMerge, let page else { return "" }
        return "Merge “\(page.project.title)” into “\(target.title)”?"
    }

    private var mergeShown: Binding<Bool> {
        Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } })
    }
}

/// The page body: header, status, then two columns (missions and latest
/// steps | needs you, sessions, other items), one column below 900 pt.
struct MacProjectPageContent: View {
    let page: ProjectPageModel
    let actions: MacProjectPageActions

    static func otherOpenItems(_ page: ProjectPageModel) -> Int {
        max(0, page.project.openItems - page.needsYou.count)
    }

    var body: some View {
        GeometryReader { geo in
            let width = MacMissionPageLayout.contentWidth(detailWidth: geo.size.width)
            let twoColumns = MacMissionPageLayout.usesTwoColumns(detailWidth: geo.size.width)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusCard
                    columns(width: width, twoColumns: twoColumns)
                }
                .frame(width: width, alignment: .leading)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(MacMissionPalette.pageBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.project.title).font(.system(size: 26, weight: .bold)).textSelection(.enabled)
                Spacer(minLength: 12)
                NeedsYouPill(count: page.needsYouCount)
            }
            if !page.project.body.isEmpty {
                Text(MissionsDashboardFormat.statusText(page.project.body))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    @ViewBuilder private var statusCard: some View {
        if let status = page.project.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    MacMissionSectionLabel("Status")
                    Spacer(minLength: 12)
                    MacMinuteText { now in
                        MissionsDashboardFormat.statusByline(updatedAt: page.project.statusUpdatedAt,
                                                             by: page.project.statusBy, now: now) ?? ""
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Text(MissionsDashboardFormat.statusText(status)).font(.system(size: 17)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .macMissionCard()
        }
    }

    @ViewBuilder private func columns(width: CGFloat, twoColumns: Bool) -> some View {
        if twoColumns {
            let spacing = MacMissionPageLayout.columnSpacing
            let side = ((width - spacing) * MacMissionPageLayout.sideColumnFraction).rounded()
            HStack(alignment: .top, spacing: spacing) {
                mainColumn.frame(width: width - spacing - side)
                sideColumn.frame(width: side)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) { mainColumn; sideColumn }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            missionsCard
            if !page.recentMilestones.isEmpty { milestonesCard }
        }
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !page.needsYou.isEmpty { needsYouCard }
            if !page.sessionsByBox.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MacMissionSectionLabel("Sessions on it now")
                    Text(ProjectsFormat.sessionsByBox(page.sessionsByBox)).font(.system(size: 15))
                }
            }
            let other = Self.otherOpenItems(page)
            if other > 0 {
                MacMissionSectionLabel("Other open items · \(other) on the missions' boards")
            }
        }
    }

    private var missionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacMissionSectionLabel("Missions · \(page.missions.count) · sorted by needs-you, then activity")
                .padding(.bottom, 12)
            ForEach(Array(page.missions.enumerated()), id: \.element.id) { index, row in
                Button { actions.onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MacMinuteRow(row: row)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [])
                            .padding(.leading, 21)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: page.project.id, targets: page.mergeTargets + [page.project]) {
                        actions.onMoveMission(row.id, $0)
                    }
                }
                if index < page.missions.count - 1 { Divider() }
            }
        }
        .macMissionCard()
    }

    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacMissionSectionLabel("Latest steps across missions")
            ForEach(page.recentMilestones) { milestone in
                Button { actions.onOpenMilestone(milestone) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(MacMissionPalette.milestoneTint(milestone.kind)).frame(width: 9, height: 9)
                        Text(milestone.title).font(.system(size: 16)).foregroundStyle(Color.primary).lineLimit(1)
                        if let num = page.missionNums[milestone.missionID] {
                            Text(verbatim: "#\(num)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 8)
                        MacMinuteText { MissionBoard.ago(milestone.createdAt, now: $0) }
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .macMissionCard()
    }

    private var needsYouCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacMissionSectionLabel("Needs you · \(page.needsYou.count) · across all missions", tint: .red)
            ForEach(page.needsYou) { item in
                Button { actions.onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).font(.system(size: 15)).foregroundStyle(Color.primary).lineLimit(2)
                        if let num = item.missionNum {
                            Text(verbatim: "#\(num)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(MacMissionPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .macMissionCard(fill: Color.red.opacity(0.06), border: Color.red.opacity(0.25))
    }
}

/// `MissionRowView` against the page's fixed snapshot clock.
private struct MacMinuteRow: View {
    let row: MissionRowModel
    @Environment(\.macMissionPageClock) private var fixedNow
    var body: some View { MissionRowView(row: row, now: fixedNow) }
}
```

- [ ] **Step 5: Shell — hoisted detail helpers**

In `MacChatListView`, replace `missionDetail` with three small helpers (CI type-checker budget: no new branch inline in `body`):

```swift
    @ViewBuilder
    private var missionDetail: some View {
        if let id = selectedMissionID, let session {
            missionPage(id, session: session)
        } else if let missionsVM {
            projectsDetail(missionsVM)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func missionPage(_ id: String, session: UserSession) -> some View {
        MacMissionPage(missionID: id, session: session, backConvoID: missionBackConvoID,
                       onBack: showConversation,
                       onOpenMilestone: openMilestone,
                       onOpenItem: { id in showDecisionsItem(id, switchingNav: true) },
                       onOpenConversation: showConversation,
                       onShowDashboard: showMissionsDashboard,
                       missionsViewModel: missionsVM)
    }

    /// The Projects entry with no mission open: today's dashboard on a
    /// journal without `/projects` (spec §7), else a project page or home.
    @ViewBuilder
    private func projectsDetail(_ vm: MissionsDashboardViewModel) -> some View {
        if vm.projectsSupported == false {
            MacMissionsDashboard(viewModel: vm, onAction: handleDashboardAction)
                .id(ObjectIdentifier(vm))
        } else if let projectID = selectedProjectID, let session {
            MacProjectPage(projectID: projectID, session: session, missionsViewModel: vm,
                           actions: projectPageActions, onRedirect: { selectedProjectID = $0 })
        } else {
            MacProjectsHome(viewModel: vm, onAction: handleProjectsHomeAction)
                .id(ObjectIdentifier(vm))
        }
    }

    private var projectPageActions: MacProjectPageActions {
        MacProjectPageActions(onShowHome: showMissionsDashboard, onOpenMission: pickMission,
                              onOpenItem: { showDecisionsItem($0, switchingNav: true) },
                              onOpenMilestone: { openMilestone(convoID: $0.convoID, seq: $0.seq) })
    }

    private func handleProjectsHomeAction(_ action: ProjectsHomeAction) {
        switch action {
        case .openProject(let id): showProject(id)
        case .openMission(let id): pickMission(id)
        case .newProject, .moveMission: break // the home's own
        }
    }
```

(Keep the existing `.alert`/comment lines that sat on the old `MacMissionPage(...)` call; `MacMissionPage` gains `onShowProject` in Task 25.)

- [ ] **Step 6: Record, verify, run the Mac suite**

Run the Step 2 command twice (records, then compares); compare `project-page-1440` with `mockups/02-mac-project-page.png`. Then run the whole Mac suite (Task 9 Step 2 command). Expected: failures limited to the four known ones.

- [ ] **Step 7: Commit**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronMac MatronMacTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "mac: Projects home and the two-column project page" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 25: Mac mission page — breadcrumb, project chip, move, conversations card, 5 milestones

**Files:**
- Modify: `MatronMac/Features/Missions/MacMissionPage.swift` (`MacMissionPage`, `MacMissionPageBody.model`/`actions`, `MacMissionPageTopBar`)
- Modify: `MatronMac/Features/Missions/MacMissionPageContent.swift` (`MacMissionPageModel`, `MacMissionPageActions`, header)
- Modify: `MatronMac/Features/Missions/MacMissionOverview.swift` (columns; new `MacMissionConversationsCard`; `MacMilestonesCard` paging; delete the latest-step and sessions cards)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`missionPage(_:session:)` passes `onShowProject: showProject`)
- Test: `MatronMacTests/MacMissionPageFixtures.swift`, `MatronMacTests/MacMissionPageTests.swift`, re-recorded `MacMissionPageSnapshotTests` PNGs

**Interfaces:**
- Consumes: Task 13 VM fields; Task 10 `MissionConversationGroups`; Task 14 `ProjectChip`, `MoveToProjectMenu`, `ProjectsFormat`.
- Produces: `MacMissionPageModel` loses `latestStep`, gains `project: Project?`, `moveTargets: [Project]`, `conversationGroups: MissionConversationGroups`; `MacMissionPageActions` gains `onOpenProject: (String) -> Void`, `onMove: (String?) -> Void`; `MacMissionPageTopBar.init(mission:project:backConvoID:onBack:onShowDashboard:onShowProject:store:)` (first two and `onShowProject` defaulted nil); `MacMission Page.onShowProject: ((String) -> Void)?`; `MacMilestonesCard.initialCount = 5`, `.pageSize = 20`; `MacMissionPageTopBar.crumbs(mission:project:) -> [String]`.

The audit (spec §1) called the "Latest step" card a repeat of the top milestone; §2's mission page lists no latest step — it goes. The Sessions card becomes the Conversations card (On it now / Earlier).

- [ ] **Step 1: Update fixtures and write the failing tests**

In `MacMissionPageFixtures`: delete `latestStep`; give `mission` `projectID: "pj_1"`; add

```swift
    static let project = Project(id: "pj_1", num: 4000, title: "Promo launch")

    static let conversations: [MissionConversation] = [
        MissionConversation(id: "c-nav", title: "Missions Navigation Refinement", box: "dan-mac", state: "running",
                            isCurrent: true, joinedAt: ago(3 * 86_400), how: "origin", subchatCount: 6),
        MissionConversation(id: "c-verify", title: "production journal verification", box: "dan-mac", state: "waiting",
                            joinedAt: ago(86_400), how: "joined"),
        MissionConversation(id: "c-mem", title: "Coordinator memories rollout", box: "ang", state: "done",
                            joinedAt: ago(2 * 86_400), endedAt: ago(86_400), how: "joined"),
    ]
```

and change `model(showOnlyUserInput:)` to pass `project: project, moveTargets: [project], conversations: conversations, conversationGroups: MissionConversationGroups(conversations: conversations, missionState: .open)` and drop `latestStep:`.

Append to `MacMissionPageTests`:

```swift
    func testBreadcrumbNamesProjectsTheProjectAndTheMission() {
        let mission = Mission(id: "ms_1", num: 4907, title: "Launch", originConvoID: "c1", projectID: "pj_1")
        XCTAssertEqual(MacMissionPageTopBar.crumbs(mission: mission, project: Project(id: "pj_1", num: 1, title: "Promo launch")),
                       ["Projects", "Promo launch", "#4907"])
        XCTAssertEqual(MacMissionPageTopBar.crumbs(mission: mission, project: nil), ["Projects", "#4907"],
                       "an unfiled (or uncached) project drops its crumb")
        XCTAssertEqual(MacMissionPageTopBar.crumbs(mission: nil, project: nil), ["Projects"])
    }

    func testMilestonesStartAtFive() {
        XCTAssertEqual(MacMilestonesCard.initialCount, 5)
        XCTAssertEqual(MacMilestonesCard.pageSize, 20)
    }
```

Delete the `testOverview*` PNGs under `MatronMacTests/__Snapshots__/MacMissionPageSnapshotTests/` (the overview layout changes; the board PNGs stay).

- [ ] **Step 2: Run to verify they fail**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacMissionPageTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `extra argument 'project' in call` / `type 'MacMissionPageTopBar' has no member 'crumbs'`.

- [ ] **Step 3: Model and actions**

`MacMissionPageModel`: remove `var latestStep: Milestone?`; add `var project: Project?`, `var moveTargets: [Project]`, `var conversationGroups: MissionConversationGroups` (declare them after `conversations`). `MacMissionPageActions`: add `var onOpenProject: (String) -> Void = { _ in }` and `var onMove: (String?) -> Void = { _ in }`.

`MacMissionPageBody.model(_:)`:

```swift
    private func model(_ mission: Mission) -> MacMissionPageModel {
        let sessions = missionsViewModel?.pageMissionSessions ?? []
        let live = Dictionary(sessions.map { ($0.id, $0.state.rawValue) }, uniquingKeysWith: { first, _ in first })
        return MacMissionPageModel(
            mission: mission, milestones: viewModel.milestones,
            milestoneBodies: bodyCache.bodies(for: viewModel.milestones),
            showOnlyUserInput: viewModel.showOnlyUserInput, openItems: viewModel.openItems,
            openItemsLoaded: viewModel.hasLoadedOpenItems, closedItems: viewModel.closedItems,
            closedItemsTotal: viewModel.closedItemsTotal,
            sessions: sessions, conversations: viewModel.conversations,
            project: viewModel.project, moveTargets: viewModel.moveTargets,
            conversationGroups: MissionConversationGroups(conversations: viewModel.conversations,
                                                          missionState: mission.state, liveStates: live),
            sessionTags: viewModel.sessionTags, isBusy: viewModel.isBusy)
    }
```

In `actions`, add `onOpenProject: onShowProject ?? { _ in }` and `onMove: { target in Task { await viewModel.moveToProject(target) } }` (thread `onShowProject` from `MacMissionPage` into `MacMissionPageBody` as a new `let onShowProject: ((String) -> Void)?`).

- [ ] **Step 4: Breadcrumb top bar**

`MacMissionPage`: add `var onShowProject: ((String) -> Void)? = nil` and build the bar as `MacMissionPageTopBar(mission: Self.pageViewModel(viewModel, missionID: missionID)?.mission, project: Self.pageViewModel(viewModel, missionID: missionID)?.project, backConvoID: backConvoID, onBack: onBack, onShowDashboard: onShowDashboard, onShowProject: onShowProject)`.

`MacMissionPageTopBar`:

```swift
    let mission: Mission?
    let project: Project?
    let onShowProject: ((String) -> Void)?

    init(mission: Mission? = nil, project: Project? = nil, backConvoID: String?, onBack: @escaping (String) -> Void,
         onShowDashboard: (() -> Void)?, onShowProject: ((String) -> Void)? = nil, store: UserDefaults? = nil) {
        self.mission = mission; self.project = project; self.onShowProject = onShowProject
        self.backConvoID = backConvoID; self.onBack = onBack; self.onShowDashboard = onShowDashboard
        if let store { _mode = AppStorage(wrappedValue: .overview, MacMissionPage.modeKey, store: store) }
    }

    /// Projects › Promo launch › #4907 (spec §2 "Mission page").
    static func crumbs(mission: Mission?, project: Project?) -> [String] {
        ["Projects"] + [project?.title].compactMap { $0 } + [mission.map { "#\($0.num)" }].compactMap { $0 }
    }
```

In `body`, replace the `if let onShowDashboard { Button { … } label: { Label("All missions", …) } … }` block with:

```swift
            breadcrumb
```

and add:

```swift
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { onShowDashboard?() } label: { Label("Projects", systemImage: "chevron.backward") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(onShowDashboard == nil)
                .accessibilityIdentifier("missions.allMissions")
            if let project {
                Text("›").foregroundStyle(.tertiary)
                Button(project.title) { onShowProject?(project.id) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("missions.breadcrumb.project")
            }
            if let mission {
                Text("›").foregroundStyle(.tertiary)
                Text(verbatim: "#\(mission.num)").foregroundStyle(Color.accentColor)
            }
        }
    }
```

- [ ] **Step 5: Header chip and move**

In `MacMissionPageContent.header`, inside the title `HStack` after `Spacer(minLength: 12)` and before the closed/needs-you branch:

```swift
                if let project = model.project {
                    ProjectChip(title: project.title) { actions.onOpenProject(project.id) }
                }
                if model.mission.state == .open {
                    MoveToProjectMenu(currentProjectID: model.mission.projectID, targets: model.moveTargets,
                                      onMove: actions.onMove)
                        .menuStyle(.borderlessButton).fixedSize()
                        .labelStyle(.iconOnly)
                        .help("Move to project…")
                }
```

- [ ] **Step 6: Overview columns, conversations card, milestone paging**

In `MacMissionOverview`: `mainColumn` becomes `VStack { MacMissionConversationsCard(model: model, actions: actions); MacMilestonesCard(model: model, actions: actions) }`; `sideColumn` becomes `VStack { needsYouCard; openItemsCard }`. Delete `latestStepCard`, `latestStepRow`, `latestStepMeta` and `sessionsCard` (keep `MacMissionSessionRow`: the board or other callers may still use it — delete it too if `grep -rn MacMissionSessionRow MatronMac` finds no other user).

`MacMilestonesCard`: replace `static let pageSize = 20` and the `@State` with

```swift
    static let initialCount = 5
    static let pageSize = 20
    @State private var limit = MacMilestonesCard.initialCount
```

(the existing `Show more (n)` button already adds `Self.pageSize`).

Add to `MacMissionOverview.swift`:

```swift
/// A mission's conversations, On it now / Earlier (spec §2, mockup 03 left).
struct MacMissionConversationsCard: View {
    let model: MacMissionPageModel
    let actions: MacMissionPageActions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.macMissionPageClock) private var fixedNow

    var body: some View {
        let groups = model.conversationGroups
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MacMissionSectionLabel("Conversations")
                Text(ProjectsFormat.conversationsSummary(groups).uppercased())
                    .font(.system(size: 12)).tracking(0.6).foregroundStyle(.tertiary)
            }
            if groups.onItNow.isEmpty && groups.earlier.isEmpty {
                Text("No conversations yet.").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            if !groups.onItNow.isEmpty { group("On it now", groups.onItNow) }
            if !groups.earlier.isEmpty { group("Earlier", groups.earlier) }
        }
        .macMissionCard()
    }

    private func group(_ title: String, _ rows: [MissionConversationRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                .padding(.vertical, 6)
            ForEach(rows) { row in
                Divider()
                MacMissionConversationRow(row: row, tag: tagText(row.id), age: age(row.id),
                                          onOpen: actions.onOpenConversation)
            }
        }
    }

    private func tagText(_ convoID: String) -> Text? {
        guard let tag = model.sessionTags[convoID] ?? model.sessions.first(where: { $0.id == convoID })?.tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
    }

    private func age(_ convoID: String) -> String? {
        guard let last = model.sessions.first(where: { $0.id == convoID })?.lastActivity else { return nil }
        return MissionBoard.ago(last, now: fixedNow ?? Date())
    }
}

struct MacMissionConversationRow: View {
    let row: MissionConversationRow
    let tag: Text?
    let age: String?
    let onOpen: (String) -> Void
    @State private var showSubchats = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { onOpen(row.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    DashboardStateDot(state: row.state)
                    if let tag { tag.font(.system(size: 13)) } else if let box = row.conversation.box { BoxChip(box) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.conversation.title.isEmpty ? row.id : row.conversation.title)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(1)
                        Text(meta).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let age { Text(age).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            subchats
        }
        .padding(.vertical, 8)
    }

    private var meta: String {
        [row.conversation.box,
         ProjectsFormat.linkSpan(joinedAt: row.conversation.joinedAt, endedAt: row.conversation.endedAt,
                                 how: row.conversation.how)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var subchats: some View {
        if !row.subchats.isEmpty {
            DisclosureGroup("\(row.subchats.count) sub-chat\(row.subchats.count == 1 ? "" : "s")", isExpanded: $showSubchats) {
                ForEach(row.subchats) { child in
                    Button(child.title.isEmpty ? child.id : child.title) { onOpen(child.id) }
                        .buttonStyle(.plain).font(.system(size: 14))
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 20)
        } else if row.subchatCount > 0 {
            Text("\(row.subchatCount) sub-chat\(row.subchatCount == 1 ? "" : "s")")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 20)
        }
    }
}
```

`MacChatListView.missionPage(_:session:)`: add `onShowProject: showProject` to the `MacMissionPage(...)` call.

- [ ] **Step 7: Record, verify, run the Mac suite**

Run the Step 2 command (logic tests pass). Then run `-only-testing:MatronMacTests/MacMissionPageSnapshotTests` twice without the skip variable (records the overview PNGs, then compares). Check `mission-page-overview-1440` against `mockups/03-mac-mission-conversations.png` (left half): breadcrumb, title with the project chip, status, Conversations card with ON IT NOW / EARLIER and "6 sub-chats", five milestones then "Show more". Then the whole Mac suite. Expected: failures limited to the four known ones.

- [ ] **Step 8: Commit**

```bash
xcodegen generate && git checkout Matron/App/Info.plist
git add MatronMac MatronMacTests Matron.xcodeproj
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "mac: mission page breadcrumb, project chip, conversations On it now / Earlier, five milestones" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 26: Mac conversation header — the missions chip and menu; the title stops being a button

**Files:**
- Modify: `MatronMac/Features/Chat/MacChatToolbar.swift` (`missionID` → `missions`, `projectTitles`, `onOpenProject`; `titleItem`; new `missionChipItem`; `MacChatToolbarProps`)
- Modify: `MatronMac/Features/Chat/MacChatHeaderAccessory.swift` (trailing group)
- Modify: `MatronMac/Features/Chat/MacChatView.swift` (`missionID` state ~354, the task ~1256, the props ~1269, new `onOpenProject` var)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`onOpenProject: { showProject($0) }` beside `onOpenMission:` ~1535)
- Test: `MatronMacTests/MacChatToolbarTests.swift`, `MatronMacTests/MacHistoryToolbarTests.swift`

**Interfaces:**
- Consumes: Task 5 `missionsStream(convoID:)`; Task 8 watching; Task 18 `MissionChipLabel`; Task 14 `ProjectsFormat.headerLine`; Task 23 `showProject`.
- Produces: `MacChatToolbar(… missions: ConversationMissions = .init(), projectTitles: [String: String] = [:], onOpenMission:, onOpenProject: (String) -> Void = { _ in }, …)`; `MacChatToolbarProps.missions`, `.projectTitles`, `Actions.onOpenProject`; `MacChatToolbar.menuProjectID(missions:projectTitles:) -> String?`; `titleOpensMission(missionID:)` is deleted.

- [ ] **Step 1: Write the failing tests**

In `MacChatToolbarTests`, replace `testTitleOpensTheMissionOnlyWhenThereIsOne` with:

```swift
    /// "Open project" names the headline mission's project, and only when
    /// this device knows its title.
    func testTheMenusOpenProjectEntryNeedsAKnownProject() {
        let filed = ConversationMissionLink(mission: Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1",
                                                             projectID: "pj_1"), isCurrent: true)
        let missions = ConversationMissions(links: [filed])
        XCTAssertEqual(MacChatToolbar.menuProjectID(missions: missions, projectTitles: ["pj_1": "Promo"]), "pj_1")
        XCTAssertNil(MacChatToolbar.menuProjectID(missions: missions, projectTitles: [:]))
        XCTAssertNil(MacChatToolbar.menuProjectID(missions: ConversationMissions(), projectTitles: ["pj_1": "Promo"]))
    }

    /// The header republishes when the missions change.
    func testPropsEqualityCoversTheMissions() {
        let strip = makeStripVM()
        func props(_ missions: ConversationMissions) -> MacChatToolbarProps {
            MacChatToolbarProps(roomID: "c1", publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                title: "T", boxName: nil, styledTitle: nil, accessibilityTitle: nil, status: nil,
                                stripViewModel: strip, missions: missions, projectTitles: [:], needsYouCount: 0,
                                itemsAvailable: true,
                                actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                                               onOpenProject: { _ in }, showMediaBrowser: .constant(false),
                                               showItemsPane: .constant(false)))
        }
        let link = ConversationMissionLink(mission: Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1"),
                                           isCurrent: true)
        XCTAssertNotEqual(props(ConversationMissions()), props(ConversationMissions(links: [link])))
    }
```

(`FakeChatForToolbar` is the file's existing private `ChatService` stub; `makeStripVM()` would do too.)

In `MacHistoryToolbarTests` (the two `MacChatToolbarProps(...)` literals at ~lines 60 and 85), replace `stripViewModel: strip, missionID: nil,` with `stripViewModel: strip, missions: ConversationMissions(), projectTitles: [:],` and `onOpenMission: { _ in },` with `onOpenMission: { _ in }, onOpenProject: { _ in },`; add `import MatronModels` if the file lacks it.

- [ ] **Step 2: Run to verify they fail**

Run: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacChatToolbarTests -only-testing:MatronMacTests/MacHistoryToolbarTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `type 'MacChatToolbar' has no member 'menuProjectID'`.

- [ ] **Step 3: Toolbar**

In `MacChatToolbar`: replace the stored `missionID: String?` with

```swift
    /// Every mission this conversation touched (spec 2026-09-30 §3, §6).
    let missions: ConversationMissions
    /// Project id → title, for "Open project" in the menu.
    let projectTitles: [String: String]
    let onOpenProject: (String) -> Void
```

In `init(...)` replace `missionID: String? = nil,` with `missions: ConversationMissions = ConversationMissions(), projectTitles: [String: String] = [:],` and add `onOpenProject: @escaping (String) -> Void = { _ in },` after `onOpenMission`; assign them. In `init(props:)` pass `missions: props.missions, projectTitles: props.projectTitles, onOpenProject: props.actions.onOpenProject`.

Delete `titleOpensMission(missionID:)`. `titleItem` becomes:

```swift
    /// The title is only a title now (spec §6: "the title stops being a
    /// hidden button"); the mission lives in `missionChipItem`.
    @ViewBuilder var titleItem: some View {
        cluster {
            titleCluster.accessibilityLabel(accessibilityTitle ?? title)
        }
    }

    static func menuProjectID(missions: ConversationMissions, projectTitles: [String: String]) -> String? {
        guard let id = missions.sections.headline?.mission.projectID, projectTitles[id] != nil else { return nil }
        return id
    }

    /// "⚑ #4791 Promo branch +2 ▾" and its Current / Also on / Earlier menu
    /// (mockup 03 right). Its own glass capsule, like the other clusters.
    @ViewBuilder var missionChipItem: some View {
        if MissionChipLabel.text(missions) != nil {
            Menu { missionMenu } label: { MissionChipLabel(missions: missions) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: Self.clusterHeight)
                .modifier(MacChatHeaderGlass())
                .help("Every mission this conversation worked on")
                .accessibilityIdentifier("chatHeader.missions")
        }
    }

    @ViewBuilder private var missionMenu: some View {
        let sections = missions.sections
        if let current = sections.current { Section("Current") { missionButton(current) } }
        if !sections.alsoOn.isEmpty { Section("Also on") { ForEach(sections.alsoOn) { missionButton($0) } } }
        if !sections.earlier.isEmpty { Section("Earlier") { ForEach(sections.earlier) { missionButton($0) } } }
        if let projectID = Self.menuProjectID(missions: missions, projectTitles: projectTitles),
           let title = projectTitles[projectID] {
            Divider()
            Button("Open project \(title)") { onOpenProject(projectID) }
        }
    }

    private func missionButton(_ link: ConversationMissionLink) -> some View {
        Button { onOpenMission(link.id) } label: {
            Text(verbatim: "#\(link.mission.num) \(link.mission.title)")
            Text(ProjectsFormat.headerLine(link))
        }
    }
```

`MacChatToolbarProps`: replace `let missionID: String?` with `let missions: ConversationMissions` and `let projectTitles: [String: String]`; in `==` replace the `missionID` line with `&& lhs.missions == rhs.missions && lhs.projectTitles == rhs.projectTitles`; add `let onOpenProject: (String) -> Void` to `Actions` after `onOpenMission`.

`MacChatHeaderAccessory.barContent`: make the chip the first item of the trailing group:

```swift
            HStack(spacing: 10) {
                toolbar.missionChipItem
                toolbar.usageItem
                // …unchanged…
```

- [ ] **Step 4: Chat view**

In `MacChatView`: add `var onOpenProject: ((String) -> Void)? = nil` beside `onOpenMission` (line ~412), and replace `@State private var missionID: String?` with

```swift
    @State private var conversationMissions = ConversationMissions()
    @State private var missionProjectTitles: [String: String] = [:]
```

Replace the mission `.task(id: viewModel.roomID)` body:

```swift
        .task(id: viewModel.roomID) {
            conversationMissions = ConversationMissions()
            missionProjectTitles = [:]
            guard let deps, let session else { return }
            let convoID = viewModel.roomID
            let store = deps.journalStore(for: session)
            let projects = deps.projectsSync(for: session)
            await projects.beginWatching(convoID: convoID)
            defer { Task { await projects.endWatching(convoID: convoID) } }
            for await missions in store.missionsStream(convoID: convoID) {
                guard !Task.isCancelled else { return }
                conversationMissions = missions
                let ids = Set(missions.links.compactMap(\.mission.projectID))
                missionProjectTitles = Dictionary(ids.compactMap { id in
                    ((try? store.project(id: id)) ?? nil).map { (id, $0.title) }
                }, uniquingKeysWith: { first, _ in first })
            }
        }
```

In the `MacChatToolbarProps(...)` call, replace `missionID: missionID,` with `missions: conversationMissions, projectTitles: missionProjectTitles,` and add `onOpenProject: { onOpenProject?($0) },` after `onOpenMission:` in `actions:`. Thread `onOpenProject` through the two intermediate wrapper structs that already thread `onOpenMission` (lines ~1407 and ~1555: add a `let onOpenProject: ((String) -> Void)?` beside each `let onOpenMission`, and pass it where they build the next level; pass `nil` at ~1799 where `onOpenMission: nil` is passed).

In `MacChatListView` (~1535), beside `onOpenMission: { showMission($0, from: id) }`, add `onOpenProject: { showProject($0) }`.

- [ ] **Step 5: Run to verify**

Run the Step 2 command, then the whole Mac suite. Expected: the two classes pass; the suite's failures are limited to the four known ones.

- [ ] **Step 6: Look at it**

Build Release and run from Xcode (never install over the live app for this check): open a conversation on two missions; the chip reads `#N title +1` at the right of the header; its menu has Current / Also on sections with dates and "Open project …"; picking a mission opens its page; the title is no longer clickable. Compare with `mockups/03-mac-mission-conversations.png` (right half).

- [ ] **Step 7: Commit**

```bash
git add MatronMac MatronMacTests
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "mac: header chip names the current mission; its menu lists every mission the chat touched" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 27: Mac Chats — "Not on a mission"; PR 4

**Files:**
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`sidebar` passes the VM; `MacChatSidebarList`)
- Test: `MatronMacTests/MacChatListViewTests.swift`

**Interfaces:**
- Consumes: Task 11 `looseSessions`, `looseSectionDidAppear/Disappear`, `projectsSupported`; Task 18 `LooseSessionsSection`.
- Produces: `MacChatSidebarList.missionsVM: MissionsDashboardViewModel?` (defaulted nil); `MacChatSidebarList.showsLooseSection(projectsSupported:) -> Bool`.

- [ ] **Step 1: Write the failing test**

Append to `MacChatListViewTests`:

```swift
    func testTheLooseSectionFollowsProjectsSupport() {
        XCTAssertTrue(MacChatSidebarList.showsLooseSection(projectsSupported: true))
        XCTAssertTrue(MacChatSidebarList.showsLooseSection(projectsSupported: nil))
        XCTAssertFalse(MacChatSidebarList.showsLooseSection(projectsSupported: false))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacChatListViewTests 2>&1 | tee /tmp/mac-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `type 'MacChatSidebarList' has no member 'showsLooseSection'`.

- [ ] **Step 3: Implement**

In `MacChatSidebarList`:

```swift
    /// The session-long dashboard VM, for "Not on a mission" (spec §6).
    var missionsVM: MissionsDashboardViewModel? = nil
    @State private var showLoose = false

    static func showsLooseSection(projectsSupported: Bool?) -> Bool { projectsSupported != false }

    @ViewBuilder private var looseSection: some View {
        if let missionsVM, Self.showsLooseSection(projectsSupported: missionsVM.projectsSupported) {
            LooseSessionsSection(sessions: missionsVM.looseSessions, isExpanded: $showLoose) { selection = $0 }
        }
    }
```

Insert `looseSection` as the first child of `List(selection: $selection) { … }`, before `ForEach(viewModel.groups)`, and add to the `List`:

```swift
            .onAppear { missionsVM?.looseSectionDidAppear() }
            .onDisappear { missionsVM?.looseSectionDidDisappear() }
```

In `MacChatListView.sidebar`, pass `missionsVM: missionsVM` to `MacChatSidebarList(...)`.

- [ ] **Step 4: Run every Mac test and look**

Run the Step 2 command, then the whole Mac suite (Task 9 Step 2 command). Expected: failures limited to the four known ones.
Build Release and run it (from Xcode; do not replace the installed app): ⌘2 shows the Projects home with cards and rows; a card opens the two-column project page; "Merge into…" asks first; a row opens the mission page with the breadcrumb; the breadcrumb's project returns to the project page; Back/Forward walk home → project → mission; the Conversations list shows "Not on a mission (n)" collapsed at the top.

- [ ] **Step 5: Commit, push, open PR 4**

```bash
git add MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/MacChatListViewTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "mac: loose sessions move to the Conversations list" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/projects-mac
gh pr create --base feat/projects-shared-ui --title "Projects (4/4): Mac" --body "$(cat <<'BODY'
Mac for spec 2026-09-30: Projects entry (⌘2) with home, two-column project page, New project / Move to project / Merge into…; mission page breadcrumb, project chip, conversations On it now / Earlier, five milestones; header missions chip + menu; loose sessions in the Conversations list. Old journals keep the missions dashboard.

Plan: docs/superpowers/plans/2026-09-30-projects-apple.md (Tasks 23–27)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## Self-review (done while writing)

- **Spec coverage (§6 line by line):** tab renamed Projects, ⌘2, badge unchanged → Tasks 19, 23. `ProjectsHomeView` from `ProjectCardView` + slim `MissionRowView` + Quiet + Closed folds → Tasks 14, 15. Loose group to Chats → Tasks 18, 22, 27. Project page Mac two-column / iOS List → Tasks 16, 24 (+20). Mission page chip + breadcrumb, On it now / Earlier with sub-chats folded, 5 then Show more, iOS status + needs-you → Tasks 17, 25. Header chip + menu (Mac) / sheet (iOS), title not a button → Tasks 21, 26. Move to project… / New project / Merge into… → Tasks 11, 12, 15, 16, 20, 24. GRDB migration → Task 3. `ProjectsSync` → Task 8. `missionsStream(convoID:)` fed by the route and snapshot fields → Tasks 4, 5, 8. Snapshots at Mac and iOS widths → Tasks 14–18, 23–25. §7 fallback on 404 → Tasks 8, 11, 20, 24. §3 marker actions → Task 2. §4.2 "refresh on any mission marker" → Task 8.
- **Placeholders:** none left; every code step carries the code.
- **Type consistency:** `ConversationMissions` / `ConversationMissionSections` / `ConversationMissionLink` (Task 1) are the names used in Tasks 5, 7, 8, 18, 21, 26; `ProjectsSyncing` methods (Task 11) match `ProjectsSync` (Task 8) and the fakes; `MissionRowModel(closed:)` (Task 10) is what Tasks 14–16 use; `MacPlace.Detail.project(id:)` (Task 23) is what `restore` and the tests use.
- **Review Focus:** each of the five lines has its pinning test in the named task.
