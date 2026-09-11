# Journal Store Launch Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take every cost proportional to store history off the launch path. The boot-time tool-output sweep leaves `JournalStore.init`, the chat list's first paint reads only the `conversation` table, tool-output and diff bodies older than 30 days are tombstoned locally (and dropped from the search index), and the app can finally say what its own launch cost — signposts, a persisted last-launch timing, and a Settings › Storage section on both platforms.

**Architecture:** One additive GRDB migration (`v11`) adds the `event(type, ts)` index and two derived columns on `conversation` (`last_message_type`, `expired_snippet`), backfilled from the stored events. The write path maintains those columns, so `applyReadTimeSnippetTTL` becomes pure column logic and `conversationsStream()` stops reading `event` at all. The two tombstone rules (24 h snippet TTL, 30 day retention) collapse into one pure function, `EventTombstone.apply`, shared by the two insert paths (rows arrive already tombstoned) and by two watermarked sweeps on `JournalStore` — which is what lets the watermarks be complete. A new `JournalMaintenance` actor owns those sweeps plus the matching search-index removal, runs them off the launch path at `.utility`, and replaces the call in `JournalStore.init`. `LaunchTimeline` (OSSignposter + `UserDefaults`) and `StoreDiagnostics.sizes()` make the result measurable in Settings.

**Tech Stack:** Swift 6 toolchain (Swift 5.10 language mode, as the package sets today), GRDB 6 `DatabaseQueue` + `DatabaseMigrator` + `ValueObservation`, SwiftUI, XCTest, swift-snapshot-testing (`assertVariants`), `OSSignposter` / `os.Logger`, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-10-journal-launch-performance-design.md`

## Global Constraints

- **`v11` is the ONLY new migration identifier**, registered in `JournalStore.migrator()` immediately after `v10` (the missions migration, `MatronShared/Sources/Journal/JournalStore.swift:458`) and before `return migrator`. **Never edit an earlier migration body.** GRDB records identifiers, not bodies: an edited `v10` silently never re-runs on an installed device, so the change would exist only on fresh installs.
- **`purgeExpiredToolOutputSnippets(now:)` keeps its name and public signature** — `public func purgeExpiredToolOutputSnippets(now: Date = Date()) throws`. It becomes incremental (watermark + index) and moves off the launch path; it does not get renamed, does not gain a return value, and does not lose its `now:` seam.
- **`toolLogTTL` (24 h) stays the single TTL constant.** It moves to `EventTombstone.toolLogTTL` in `MatronJournal` (the leaf module both the store and the mapper can see) and `JournalTimelineMapper.toolLogTTL` becomes an alias for it. No second literal `24 * 3600` anywhere.
- **Retention window is 30 days; the retained tool-output command stub is 200 characters plus `…`** (spec §4 decisions 1 and 2). Both live as named constants on `EventTombstone`.
- **No `VACUUM`** (spec §3.8). Tombstoning frees pages for reuse; the file does not shrink and that is the accepted outcome. The Storage rows make the size visible.
- **`MatronViewModels` never depends on `MatronDesignSystem`.** Nothing in this plan adds a view model; the Settings sections are written directly in the two app targets and the only shared code they call is the pure formatters in `MatronJournal` / `MatronModels`.
- **The chat-list observation must not track the `event` table after Task 3 lands.** `conversationsStream()`'s tracking closure reads `conversation` only, and Task 3 pins that with a test that rewrites an `event` payload and proves the stream does not deliver a value for it. Do not reintroduce any `event` read into that closure in a later task.
- **Never stage `Matron/App/Info.plist` or `project.yml`.** Both are rewritten in the working tree by builds. `git add` exactly the paths each commit step lists — never `git add -A`, never `git add .`.
- **Run `xcodegen generate` after adding or deleting any file** under `Matron/`, `MatronMac/`, `MatronTests/` or `MatronMacTests/`. This plan adds no files there (every new file is inside the `MatronShared` SPM package, which needs no regeneration), so the command is a no-op safety step before the two `xcodebuild` runs — run it anyway.
- **MatronMacTests only with `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport`** AND `MATRON_APP_SUPPORT_OVERRIDE` set to the same path (`xcodebuild` forwards only `TEST_RUNNER_*` into the runner, while the SPM bundles riding along read the unprefixed name), and always scoped with `-only-testing:MatronMacTests`. The Mac test host has wiped the live journal store before.
- **Snapshot tests are skipped locally with `MATRON_SKIP_SNAPSHOT_TESTS=1`** (`TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1` for the Mac scheme). Drop the variable only in the recording step of Task 7.
- **Assert the `Executed N tests, with 0 failures` line.** A `| tail` / `| grep` pipeline hides a non-zero `xcodebuild` exit code; read the count, never infer success from a quiet log.
- **Commits.** Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  ```
  and every commit is made as `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit …` — never `git config user.*` inside this worktree (`.git/config` is shared with the main clone, and a leaked identity fails CLA).
- **push / unread / `messageTypes` are untouched.** No badge, notification, `recountUnread` or `JournalEventType.messageTypes` change anywhere in this plan. The new columns are derived from `messageTypes`; the set itself does not move.
- **Migrations run synchronously at store open**, so `v11`'s index build plus per-conversation backfill is a one-off cost paid on the first launch after the update — with `JournalStore.init` still synchronous on the main actor (spec §3.7). That cost is exactly what Task 8's timeline must measure: `storeOpen` carries a nested `migration` interval, and Task 10 confirms the first launch after upgrade logs one and later launches do not.

## File map

| File | Responsibility | New / modified |
|---|---|---|
| `MatronShared/Sources/Journal/JournalStore.swift` | `v11` migration + backfill; `lastMessageType` / `expiredSnippet` on `ConversationRecord`; insert-time tombstoning in `applyOne` / `insertHistory`; column-only `applyReadTimeSnippetTTL`; deletion of `newestMessageSeq` and `SnippetTTLMemo`; watermarked `purgeExpiredToolOutputSnippets(now:)` and `applyRetention(now:)`; `maintenanceLastRun()` / `recordMaintenanceRun(at:)`; `rowCounts()`; stored `databaseURL`; removal of the `init` sweep | modified |
| `MatronShared/Sources/Journal/EventTombstone.swift` | The two age rules as one pure function, plus `toolLogTTL` / `retentionWindow` / `commandStubLength` | **new** |
| `MatronShared/Sources/Journal/JournalMaintenance.swift` | `JournalMaintenance` actor: scheduling, the two sweeps, search removal; `MaintenanceSweeping` seam | **new** |
| `MatronShared/Sources/Journal/StoreDiagnostics.swift` | `StoreDiagnostics.Sizes` + `sizes(store:searchURL:)` + the Storage row formatters | **new** |
| `MatronShared/Sources/Journal/SearchBackfill.swift` | `JournalEvent.searchableBody(now:)` — retention-aware, single source of truth for all three feeders | modified |
| `MatronShared/Sources/Journal/JournalSyncEngine.swift` | `attachMaintenance(_:)`; first-run + caught-up triggers; `searchableBody(now:)` at the two feeder sites | modified |
| `MatronShared/Sources/Chat/JournalTimelineService.swift` | `searchableBody(now:)` at the backward-pagination feeder | modified |
| `MatronShared/Sources/Search/SearchService.swift` | `removeAll(eventIDs:)` protocol requirement + looping default | modified |
| `MatronShared/Sources/Search/SearchServiceLive.swift` | Batched `removeAll(eventIDs:)` — one write transaction, chunked `IN (…)` | modified |
| `MatronShared/Sources/Chat/JournalTimelineMapper.swift` | `toolLogTTL` becomes an alias of `EventTombstone.toolLogTTL` | modified |
| `MatronShared/Sources/Events/DiffEvent.swift` | `expired` flag parsed from `payload["expired"]` | modified |
| `MatronShared/Sources/DesignSystem/DiffCard.swift` | Renders "Diff no longer stored on this device" in place of the body | modified |
| `MatronShared/Sources/Models/LaunchTimeline.swift` | `LaunchTimeline`, `LaunchTimeline.Mark`, `LaunchRecord`, the summary formatter, kernel process-start | **new** |
| `Matron/App/AppDependencies.swift` | `JournalMaintenance` in `JournalCore`; `journalMaintenance(for:)`; `searchStoreURL`; `LaunchTimeline` around the store open | modified |
| `MatronMac/App/AppDependencies.swift` | Same, Mac copy | modified |
| `Matron/App/MatronApp.swift` | Foreground `runIfDue()` in the existing `scenePhase == .active` branch | modified |
| `MatronMac/App/MatronMacApp.swift` | Foreground `runIfDue()` in the existing `didBecomeActiveNotification` receiver | modified |
| `Matron/Features/ChatList/ChatListView.swift` | `firstListPaint` mark | modified |
| `MatronMac/Features/ChatList/MacChatListView.swift` | `firstListPaint` mark | modified |
| `Matron/Features/Settings/DeviceSettingsView.swift` | Settings › Storage section | modified |
| `MatronMac/Features/Settings/MacDeviceSettingsView.swift` | Settings › Storage section | modified |
| `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift` | v11 migration, write-path columns, column-only read path, observation pin, watermarked sweeps | **new** |
| `MatronShared/Tests/JournalTests/EventTombstoneTests.swift` | The pure-function table test | **new** |
| `MatronShared/Tests/JournalTests/JournalMaintenanceTests.swift` | Fake clock + recording store | **new** |
| `MatronShared/Tests/JournalTests/LaunchTimelineTests.swift` | Mark ordering, durations, persistence round-trip | **new** |
| `MatronShared/Tests/JournalTests/StoreDiagnosticsTests.swift` | Formatters + `sizes()` on a temp store | **new** |
| `MatronShared/Tests/JournalTests/JournalStoreTests.swift` | Deletes the two `SnippetTTLMemo` tests; updates the purge tests for the watermark | modified |
| `MatronShared/Tests/SearchTests/SearchRetentionTests.swift` | `removeAll(eventIDs:)` batch | **new** |
| `MatronShared/Tests/JournalTests/SearchBackfillCoordinatorTests.swift` | `searchableBody(now:)` past the window; backfill skips them; the coordinator's injected clock | modified |
| `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift` | Expired diff maps to the flagged item | modified |
| `MatronShared/Tests/EventsTests/DiffEventTests.swift` | `expired` parse | modified |
| `MatronShared/Tests/DesignSystemSnapshotTests/DiffCardSnapshotTests.swift` | Expired-diff card snapshot | modified |

---

### Task 1: `v11` — the `event(type, ts)` index and the two derived conversation columns

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift`
- Test: `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift` (new)

**Interfaces:**
- Produces: migration identifier `v11`; index `event_type_ts`; `conversation.last_message_type` / `conversation.expired_snippet`; `ConversationRecord.lastMessageType: String?` and `ConversationRecord.expiredSnippet: String?`; the static helper `JournalStore.expiredSnippet(type:payload:) -> String?` (module-internal, used again in Tasks 3 and 4).
- Consumes: `JournalEventType.messageTypes` (unchanged).

Both new columns are nullable with no default, so the memberwise initializer of `ConversationRecord` keeps its current shape (Swift gives optional `var`s a `nil` default) and every existing construction site compiles untouched.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift`:

```swift
import GRDB
import XCTest
@testable import MatronJournal

/// Launch-performance work (spec 2026-09-10): the v11 migration, the
/// write-path columns that replace the read path's event sub-queries, and
/// the watermarked background sweeps. Kept in its own file so the diff
/// against `JournalStoreTests` stays readable.
final class JournalStoreLaunchPerfTests: XCTestCase {
    func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    /// `ts` is `seq` seconds after the epoch, exactly like
    /// `JournalStoreTests.event` — so a test can make a row arbitrarily
    /// "old" relative to an injected `now` without wall-clock flake.
    func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
               type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// A temp-file database frozen at `v10` with raw rows hand-inserted —
    /// the only way to prove what v11 does to state that predates it.
    /// Mirrors `JournalStoreTests.seedPreBackfillDatabase`, which freezes at
    /// v6 for the v7 summary backfill.
    func seedPreV11Database(at url: URL, conversations: [String], events: [JournalEvent]) throws {
        let dbQueue = try DatabaseQueue(path: url.path)
        try JournalStore.migrator().migrate(dbQueue, upTo: "v10")
        try dbQueue.write { db in
            for id in conversations {
                try db.execute(
                    sql: "INSERT INTO conversation(id, title, session_state, last_seq, snippet, created_at) VALUES(?, ?, 'running', 0, '', 0)",
                    arguments: [id, "T-\(id)"])
            }
            for e in events {
                try db.execute(
                    sql: "INSERT INTO event(seq, convo_id, ts, sender, type, payload) VALUES(?, ?, ?, ?, ?, ?)",
                    arguments: [e.seq, e.convoID, Int64(e.ts.timeIntervalSince1970 * 1000),
                                e.sender, e.type, e.payloadData])
            }
        }
    }

    func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("journal.sqlite")
    }

    // MARK: v11

    func testV11CreatesTheTypeTSIndex() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: [], events: [])
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let names: [String] = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list('event')").map { $0["name"] }
        }
        XCTAssertTrue(names.contains("event_type_ts"),
                      "the sweep's covering index is missing: \(names)")
        let columns: [String] = try store.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_info('event_type_ts')").map { $0["name"] }
        }
        XCTAssertEqual(columns, ["type", "ts"], "column order decides whether the range scan works")
    }

    func testV11BackfillsLastMessageTypeAndExpiredSnippetFromStoredEvents() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: ["c1", "c2", "c3"], events: [
            // c1: newest message-type row is a live-log tool_output.
            event(1, convo: "c1", type: JournalEventType.text),
            event(2, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "make test", "live_log": true, "snippet": "out"]),
            // A non-message frame after it must not win the "last message" race.
            event(3, convo: "c1", type: JournalEventType.readMarker, payload: ["up_to_seq": 2]),
            // c2: newest message-type row is plain text.
            event(4, convo: "c2", type: JournalEventType.toolOutput,
                  payload: ["command": "ls", "live_log": true]),
            event(5, convo: "c2", type: JournalEventType.text, payload: ["body": "after"]),
            // c3: no message-type event at all.
            event(6, convo: "c3", type: JournalEventType.sessionStatus, payload: ["state": "idle"]),
        ])

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let rows = try store.dbQueue.read { db in
            try ConversationRecord.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(rows[0].lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(rows[0].expiredSnippet, "$ make test")
        XCTAssertEqual(rows[1].lastMessageType, JournalEventType.text)
        XCTAssertNil(rows[1].expiredSnippet, "only tool_output gets a command stub")
        XCTAssertNil(rows[2].lastMessageType, "no message-type event means no last message type")
        XCTAssertNil(rows[2].expiredSnippet)
    }

    /// A tool_output with no `live_log` and no `expired` flag keeps its real
    /// snippet forever (offloaded/legacy payloads — pinned by
    /// `JournalStoreTests.testPurgeLeavesYoungAndNonLiveLogRows`), so it
    /// must NOT get a command stub: the stub is what the read path
    /// substitutes, and substituting it here would start hiding snippets
    /// the TTL never applied to.
    func testV11LeavesExpiredSnippetNilForNonLiveLogToolOutput() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: ["c1"], events: [
            event(1, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "legacy", "snippet": "kept"]),
        ])
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertNil(row.expiredSnippet)
    }

    /// A server-tombstoned row (`expired: true`, snippet already gone) is
    /// exactly the case the column exists for: the list has nothing but the
    /// command to show.
    func testV11BackfillsExpiredSnippetForAlreadyTombstonedToolOutput() throws {
        let url = try tempStoreURL()
        try seedPreV11Database(at: url, conversations: ["c1"], events: [
            event(1, convo: "c1", type: JournalEventType.toolOutput,
                  payload: ["command": "make build", "expired": true]),
        ])
        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.expiredSnippet, "$ make build")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreLaunchPerfTests`
Expected: FAIL — `value of type 'ConversationRecord' has no member 'lastMessageType'`.

- [ ] **Step 3: Add the two columns to `ConversationRecord`**

In `MatronShared/Sources/Journal/JournalStore.swift`, after the `participants` property (the last stored property, ~line 78) add:

```swift
    /// The `type` of the newest message-type event in this conversation
    /// (`JournalEventType.messageTypes`), or `nil` when none has landed.
    /// Maintained on write (`applyOne`, `insertHistory`) so the chat list's
    /// read-time tool-output TTL is pure column logic — before v11 it ran a
    /// `MAX(seq)` sub-query on `event` per stale conversation, which is what
    /// made the whole list observation track the `event` table.
    public var lastMessageType: String?
    /// What the list must show instead of `snippet` once that newest
    /// message-type event's 24 h tool-log TTL has passed: `"$ <command>"`,
    /// capped at 120 characters like every other snippet. `nil` whenever
    /// substitution does not apply (not a tool_output, no command, or a
    /// legacy payload that was never a live log and is not tombstoned).
    public var expiredSnippet: String?
```

and in `CodingKeys` add the two mappings:

```swift
        case lastMessageType = "last_message_type"
        case expiredSnippet = "expired_snippet"
```

- [ ] **Step 4: Add the stub helper and the `v11` migration**

Still in `JournalStore.swift`, add the helper next to the existing `snippet(type:payload:)` (the `// MARK: History` neighbourhood — put it immediately after `snippet(type:payload:)` ends):

```swift
    /// The chat-list preview a tool_output falls back to once its output is
    /// gone — the server's own `"$ <command>"` shape, capped at the same 120
    /// characters as `snippet(type:payload:)`.
    ///
    /// Returns `nil` unless the payload is a tool_output that is either a
    /// live log (the only shape the 24 h TTL applies to — see
    /// `EventTombstone`) or already tombstoned (`expired: true`, server-side
    /// or by the retention sweep). A legacy/offloaded tool_output with a
    /// durable snippet and no `live_log` keeps showing that snippet forever,
    /// which is the behaviour `testPurgeLeavesYoungAndNonLiveLogRows` pins.
    static func expiredSnippet(type: String, payload: [String: Any]) -> String? {
        guard type == JournalEventType.toolOutput,
              payload["live_log"] as? Bool == true || payload["expired"] as? Bool == true,
              let command = payload["command"] as? String, !command.isEmpty
        else { return nil }
        return String("$ \(command)".prefix(120))
    }

    /// `expiredSnippet(type:payload:)` over raw stored bytes — the form the
    /// migration and the per-conversation refresh use, where the payload
    /// comes back from SQLite as a BLOB.
    static func expiredSnippet(type: String, payloadData: Data) -> String? {
        guard let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }
        return expiredSnippet(type: type, payload: payload)
    }
```

Then register the migration in `migrator()`, immediately after the `v10` block and before `return migrator`:

```swift
        // v11: launch performance (spec 2026-09-10). Purely ADDITIVE — one
        // index plus two nullable columns on `conversation`, then a
        // one-conversation-at-a-time backfill over the existing `convo_id`
        // index.
        //
        // `event_type_ts` is what makes the tool-output sweep incremental:
        // before it, every sweep was a full `event` scan (1.5 s and 75,791
        // row decodes on the Mac copy, on every store open).
        //
        // `last_message_type` / `expired_snippet` are what let the chat
        // list's TTL be pure column logic, which in turn stops the list
        // observation from tracking the `event` table at all.
        //
        // The backfill is the one-off cost of this migration — an index
        // build over ~457k rows plus one indexed point lookup per
        // conversation (~6k), estimated 2-4 s on the Mac copy, once.
        // `LaunchTimeline` records it as a nested `migration` interval so
        // the number on the phone is known rather than guessed.
        migrator.registerMigration("v11") { db in
            try db.create(index: "event_type_ts", on: "event", columns: ["type", "ts"])
            try db.alter(table: "conversation") { t in
                t.add(column: "last_message_type", .text)
                t.add(column: "expired_snippet", .text)
            }
            let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
            let messageTypes = Array(JournalEventType.messageTypes)
            for id in try String.fetchAll(db, sql: "SELECT id FROM conversation") {
                var arguments: [DatabaseValueConvertible] = [id]
                arguments.append(contentsOf: messageTypes)
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT type, payload FROM event
                    WHERE convo_id = ? AND type IN (\(placeholders))
                    ORDER BY seq DESC LIMIT 1
                    """, arguments: StatementArguments(arguments))
                else { continue }
                let type: String = row["type"]
                let payloadData: Data = row["payload"]
                try db.execute(
                    sql: "UPDATE conversation SET last_message_type = ?, expired_snippet = ? WHERE id = ?",
                    arguments: [type, Self.expiredSnippet(type: type, payloadData: payloadData), id])
            }
        }
```

- [ ] **Step 5: Run the tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreLaunchPerfTests`
Expected: PASS — `Executed 4 tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures` (the whole package; the two new columns are additive and nothing else reads them yet).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "journal: v11 adds event(type, ts) and the derived conversation columns" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `EventTombstone` — the two age rules as one pure function

**Files:**
- Create: `MatronShared/Sources/Journal/EventTombstone.swift`
- Modify: `MatronShared/Sources/Chat/JournalTimelineMapper.swift` (alias the TTL constant)
- Test: `MatronShared/Tests/JournalTests/EventTombstoneTests.swift` (new)

**Interfaces:**
- Produces: `EventTombstone.toolLogTTL: TimeInterval` (86400), `EventTombstone.retentionWindow: TimeInterval` (30 days), `EventTombstone.commandStubLength: Int` (200), and
  `EventTombstone.apply(to payload: [String: Any], type: String, ts: Date, now: Date) -> [String: Any]?` — the rewritten payload, or `nil` when the rules change nothing.
- Consumes: `JournalEventType.toolOutput` / `.diff`.
- Consumed by: Task 3 (both insert paths), Task 4 (both sweeps), Task 5 (`searchableBody(now:)` reuses `retentionWindow`).

Two rules, one function, because the insert paths and the sweeps must agree byte for byte — that agreement is what makes Task 4's watermarks complete (a row older than a watermark can only re-enter the table through an insert path, and it enters already tombstoned).

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/EventTombstoneTests.swift`:

```swift
import XCTest
@testable import MatronJournal

/// The tombstone rules, as a table. Both insert paths and both sweeps route
/// through this one function, so everything either side of the launch path
/// agrees about what an aged-out payload looks like.
final class EventTombstoneTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_000_000)

    private func toolOutput(command: String = "make test", liveLog: Bool = true,
                            expired: Bool? = nil) -> [String: Any] {
        var p: [String: Any] = [
            "message_ref": "toolu_1", "command": command,
            "exit_code": 1, "denied": false, "truncated": false,
            "snippet": "output text", "blob_ref": "blob-1",
        ]
        if liveLog { p["live_log"] = true }
        if let expired { p["expired"] = expired }
        return p
    }

    private func diff() -> [String: Any] {
        ["file_path": "/w/Sources/A.swift", "display_path": "Sources/A.swift",
         "tool": "Edit", "added": 2, "removed": 1, "truncated": false, "new_file": false,
         "diff": "@@ -1 +1 @@\n-a\n+b", "snippet": "short form"]
    }

    // MARK: Nothing to do

    func testFreshToolOutputIsUntouched() {
        XCTAssertNil(EventTombstone.apply(to: toolOutput(), type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(3600)))
    }

    func testFreshDiffIsUntouched() {
        XCTAssertNil(EventTombstone.apply(to: diff(), type: JournalEventType.diff,
                                          ts: ts, now: ts.addingTimeInterval(25 * 3600)),
                     "a diff has no 24h rule — only the 30-day retention one")
    }

    func testOtherTypesAreNeverRewritten() {
        XCTAssertNil(EventTombstone.apply(to: ["body": "hi"], type: JournalEventType.text,
                                          ts: ts, now: ts.addingTimeInterval(400 * 24 * 3600)))
    }

    func testNonLiveLogToolOutputSurvivesThe24hRule() {
        XCTAssertNil(EventTombstone.apply(to: toolOutput(liveLog: false),
                                          type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(25 * 3600)),
                     "offloaded/legacy payloads keep their durable snippet until retention")
    }

    func testAlreadyExpiredRowReturnsNil() {
        var tombstoned = toolOutput(liveLog: false, expired: true)
        tombstoned.removeValue(forKey: "snippet")
        tombstoned["blob_ref"] = NSNull()
        XCTAssertNil(EventTombstone.apply(to: tombstoned, type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(25 * 3600)),
                     "a second sweep over the same row must do no work")
    }

    // MARK: The 24h tool-log rule

    func testStaleLiveLogLosesItsBodyAndGainsExpired() throws {
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertNil(out["snippet"])
        XCTAssertNil(out["live_log"])
        XCTAssertTrue(out["blob_ref"] is NSNull, "the shipped tombstone shape nulls the blob ref")
        XCTAssertEqual(out["expired"] as? Bool, true)
        XCTAssertEqual(out["command"] as? String, "make test", "what ran survives the 24h rule in full")
        XCTAssertEqual((out["exit_code"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(out["denied"] as? Bool, false)
        XCTAssertEqual(out["truncated"] as? Bool, false)
        XCTAssertEqual(out["message_ref"] as? String, "toolu_1")
    }

    func testThe24hRuleDoesNotTruncateALongCommand() throws {
        let long = String(repeating: "x", count: 500)
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(command: long),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(out["command"] as? String, long)
    }

    func testApplyingTwiceIsIdempotent() throws {
        let once = try XCTUnwrap(EventTombstone.apply(to: toolOutput(),
                                                      type: JournalEventType.toolOutput,
                                                      ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        XCTAssertNil(EventTombstone.apply(to: once, type: JournalEventType.toolOutput,
                                          ts: ts, now: ts.addingTimeInterval(26 * 3600)))
    }

    // MARK: The 30-day retention rule

    func testRetentionTruncatesTheCommandTo200CharactersPlusEllipsis() throws {
        let long = String(repeating: "x", count: 500)
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(command: long),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertEqual(out["command"] as? String, String(repeating: "x", count: 200) + "…")
        XCTAssertNil(out["snippet"])
        XCTAssertNil(out["live_log"])
        XCTAssertEqual(out["expired"] as? Bool, true)
        XCTAssertEqual((out["exit_code"] as? NSNumber)?.intValue, 1)
    }

    func testRetentionLeavesAShortCommandAlone() throws {
        let out = try XCTUnwrap(EventTombstone.apply(to: toolOutput(),
                                                     type: JournalEventType.toolOutput,
                                                     ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertEqual(out["command"] as? String, "make test")
    }

    /// A row tombstoned by the 24h rule keeps its full command; when it
    /// later crosses the retention window the sweep must still shorten it,
    /// so "already expired" cannot short-circuit retention.
    func testRetentionStillTruncatesARowThe24hRuleAlreadyTombstoned() throws {
        let long = String(repeating: "y", count: 300)
        let dayOld = try XCTUnwrap(EventTombstone.apply(to: toolOutput(command: long),
                                                        type: JournalEventType.toolOutput,
                                                        ts: ts, now: ts.addingTimeInterval(25 * 3600)))
        let aged = try XCTUnwrap(EventTombstone.apply(to: dayOld, type: JournalEventType.toolOutput,
                                                      ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertEqual(aged["command"] as? String, String(repeating: "y", count: 200) + "…")
    }

    func testRetentionStripsADiffButKeepsEveryOtherKey() throws {
        let out = try XCTUnwrap(EventTombstone.apply(to: diff(), type: JournalEventType.diff,
                                                     ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertNil(out["diff"])
        XCTAssertNil(out["snippet"])
        XCTAssertEqual(out["expired"] as? Bool, true)
        XCTAssertEqual(out["file_path"] as? String, "/w/Sources/A.swift")
        XCTAssertEqual(out["display_path"] as? String, "Sources/A.swift")
        XCTAssertEqual(out["tool"] as? String, "Edit")
        XCTAssertEqual((out["added"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((out["removed"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(out["new_file"] as? Bool, false)
    }

    func testRetentionOnADiffIsIdempotent() throws {
        let once = try XCTUnwrap(EventTombstone.apply(to: diff(), type: JournalEventType.diff,
                                                      ts: ts, now: ts.addingTimeInterval(31 * 24 * 3600)))
        XCTAssertNil(EventTombstone.apply(to: once, type: JournalEventType.diff,
                                          ts: ts, now: ts.addingTimeInterval(40 * 24 * 3600)))
    }

    func testConstantsAreTheOnesTheSpecFixed() {
        XCTAssertEqual(EventTombstone.toolLogTTL, 24 * 3600)
        XCTAssertEqual(EventTombstone.retentionWindow, 30 * 24 * 3600)
        XCTAssertEqual(EventTombstone.commandStubLength, 200)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter EventTombstoneTests`
Expected: FAIL — `cannot find 'EventTombstone' in scope`.

- [ ] **Step 3: Write `MatronShared/Sources/Journal/EventTombstone.swift`**

```swift
import Foundation

/// The two age rules that can rewrite a stored event payload, as one pure
/// function shared by every writer.
///
/// There are exactly two writers of an aged-out payload — the insert paths
/// (`JournalStore.applyOne` / `insertHistory`, which tombstone a row that is
/// already past a cutoff as it lands) and the background sweeps
/// (`JournalStore.purgeExpiredToolOutputSnippets(now:)` /
/// `applyRetention(now:)`). They MUST agree: the sweeps skip everything at or
/// below a persisted watermark, so a row older than that watermark is only
/// ever correct because the insert path applied the identical rule on the way
/// in.
///
/// Both rules are idempotent, and `apply` returns `nil` when it would change
/// nothing — which is how a sweep counts "rows touched" without re-writing
/// the whole range on every pass.
public enum EventTombstone {
    /// The journal server's tool-log TTL (matron-journal docs/protocol.md
    /// Retention): live-streamed output is purged server-side 24 h after the
    /// event, and the client rules make the same TTL binding on local caches.
    /// The single definition — `JournalTimelineMapper.toolLogTTL` aliases it.
    public static let toolLogTTL: TimeInterval = 24 * 3600

    /// How long this device keeps tool-output and diff BODIES (spec §4
    /// decision 1). The server still has them; the local mirror does not,
    /// and the UI already knows how to render a tombstone.
    public static let retentionWindow: TimeInterval = 30 * 24 * 3600

    /// How much of a tool-output `command` survives retention (spec §4
    /// decision 2), before the `…` marker.
    public static let commandStubLength = 200

    /// The rewritten payload, or `nil` when neither rule changes anything.
    ///
    /// - `tool_output` past `retentionWindow`: body keys go, `command` is
    ///   truncated to `commandStubLength` + `…`, `expired: true`.
    ///   `exit_code`, `denied`, `truncated` and `message_ref` stay, so the
    ///   timeline can still say what ran and how it ended.
    /// - `tool_output` past `toolLogTTL` AND `live_log: true`: the same body
    ///   strip with the command left whole. The `live_log` gate is
    ///   deliberate and is the shipped behaviour — an offloaded/legacy
    ///   tool_output carries a durable snippet that no 24 h TTL applies to
    ///   (`JournalStoreTests.testPurgeLeavesYoungAndNonLiveLogRows`).
    /// - `diff` past `retentionWindow`: `diff` and `snippet` go, every other
    ///   key stays so the card can still name the file and its counts.
    public static func apply(to payload: [String: Any], type: String,
                             ts: Date, now: Date) -> [String: Any]? {
        switch type {
        case JournalEventType.toolOutput:
            if ts.addingTimeInterval(retentionWindow) <= now {
                return rewrite(payload, stripping: ["snippet", "live_log"], truncateCommand: true)
            }
            if ts.addingTimeInterval(toolLogTTL) <= now, payload["live_log"] as? Bool == true {
                return rewrite(payload, stripping: ["snippet", "live_log"], truncateCommand: false)
            }
            return nil
        case JournalEventType.diff:
            guard ts.addingTimeInterval(retentionWindow) <= now else { return nil }
            return rewrite(payload, stripping: ["diff", "snippet"], truncateCommand: false)
        default:
            return nil
        }
    }

    /// Applies a strip + `expired: true` (+ optional command truncation) and
    /// reports `nil` when every one of those was already true — the
    /// idempotence the sweeps rely on.
    ///
    /// `blob_ref` is NULLED rather than deleted when present: that is the
    /// shipped tombstone shape, both from the server and from the sweep this
    /// replaces, and readers take it as `payload["blob_ref"] as? String` so
    /// null and absent are indistinguishable to them. An absent key stays
    /// absent, so a server-minted tombstone does not get a pointless rewrite.
    private static func rewrite(_ payload: [String: Any], stripping keys: [String],
                                truncateCommand: Bool) -> [String: Any]? {
        var out = payload
        var changed = false
        for key in keys where out.removeValue(forKey: key) != nil { changed = true }
        if let blobRef = out["blob_ref"], !(blobRef is NSNull) {
            out["blob_ref"] = NSNull()
            changed = true
        }
        if out["expired"] as? Bool != true {
            out["expired"] = true
            changed = true
        }
        if truncateCommand, let command = out["command"] as? String,
           command.count > commandStubLength {
            out["command"] = String(command.prefix(commandStubLength)) + "…"
            changed = true
        }
        return changed ? out : nil
    }
}
```

- [ ] **Step 4: Alias the mapper's constant so there is one TTL**

In `MatronShared/Sources/Chat/JournalTimelineMapper.swift`, replace the `toolLogTTL` definition (line 205) with an alias. `MatronChat` already depends on `MatronJournal`, so this is a plain re-export and every existing reference (`JournalTimelineMapper.toolLogTTL`, and the guard at line 228) keeps compiling:

```swift
    /// The journal server's tool-log TTL (docs/protocol.md Retention).
    /// Defined once, in `EventTombstone` — the leaf module both the store's
    /// sweeps and this mapper can see — so the render-time guard and the
    /// on-disk rewrite can never drift apart.
    public static let toolLogTTL: TimeInterval = EventTombstone.toolLogTTL
```

- [ ] **Step 5: Run the tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter EventTombstoneTests`
Expected: PASS — `Executed 14 tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/EventTombstone.swift \
        MatronShared/Sources/Chat/JournalTimelineMapper.swift \
        MatronShared/Tests/JournalTests/EventTombstoneTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "journal: EventTombstone holds the 24h and 30-day payload rules" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Write path maintains the columns; read path stops touching `event`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift`
- Modify: `MatronShared/Tests/JournalTests/JournalStoreTests.swift` (delete two memo tests; pin `now:` in six TTL tests)
- Test: `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift`

**Interfaces:**
- Produces: `JournalStore.applyJournal(_:now:)`, `applyJournalBatch(_:now:)`, `insertHistory(_:now:)` (all with `now: Date = Date()` defaults, so every existing call site compiles unchanged); `JournalStore.newestMessageColumns(_:convoID:) -> (type: String?, expiredSnippet: String?)`; `JournalStore.tombstonedForStorage(_:now:) -> JournalEvent`.
- Consumes: `EventTombstone.apply` (Task 2), `JournalStore.expiredSnippet(type:payload:)` (Task 1).
- Deletes: `JournalStore.newestMessageSeq(_:convoID:)`, `JournalStore.SnippetTTLMemo`, the `snippetTTLMemo` property and its three `removeAll()` call sites, and the conversation-snippet rewrite inside `purgeExpiredToolOutputSnippets`.

This is goal **B** plus the insert-time half of **A**. After it, the chat list's first paint is one `conversation` query and a pure function.

- [ ] **Step 1: Write the failing tests**

Append to `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift`, inside the same class:

```swift
    // MARK: Write path keeps the columns current

    func testApplyOneMaintainsLastMessageColumns() throws {
        let store = try makeStore()
        let fresh = Date(timeIntervalSince1970: 10)
        try store.applyJournal(event(1, type: JournalEventType.text), now: fresh)
        var row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.text)
        XCTAssertNil(row.expiredSnippet)

        try store.applyJournal(event(2, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: fresh)
        row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(row.expiredSnippet, "$ make test")
        XCTAssertEqual(row.snippet, "out", "the live preview is still the real output while it is fresh")

        // A bookkeeping frame is not a message: the columns must not move.
        try store.applyJournal(event(3, sender: "user:dan", type: JournalEventType.readMarker,
                                     payload: ["up_to_seq": 2]), now: fresh)
        row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(row.expiredSnippet, "$ make test")
    }

    /// The insert-time half of the watermark contract: a row that is already
    /// past a cutoff when it lands is stored tombstoned, so the sweeps can
    /// skip everything below their watermark and still be right.
    func testApplyOneTombstonesAnAlreadyStaleToolOutputAtInsert() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true,
                                               "snippet": "out", "blob_ref": "b1"]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first)
        XCTAssertNil(stored.payload["snippet"], "a stale live log must land already tombstoned")
        XCTAssertEqual(stored.payload["expired"] as? Bool, true)
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.expiredSnippet, "$ make test")
    }

    func testApplyOneTombstonesAPastRetentionDiffAtInsert() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.diff,
                                     payload: ["file_path": "/w/A.swift", "diff": "+ a", "added": 1]),
                               now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600))
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first)
        XCTAssertNil(stored.payload["diff"])
        XCTAssertEqual(stored.payload["expired"] as? Bool, true)
        XCTAssertEqual(stored.payload["file_path"] as? String, "/w/A.swift")
    }

    func testInsertHistoryRecomputesTheColumnsAndTombstones() throws {
        let store = try makeStore()
        let fresh = Date(timeIntervalSince1970: 10)
        try store.applyJournal(event(5, type: JournalEventType.text, payload: ["body": "newest"]), now: fresh)

        // Backfill lands OLDER rows: `last_seq` does not move, so the columns
        // can only stay right if insertHistory recomputes them.
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "live_log": true, "snippet": "out"]),
        ], now: fresh)
        var row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.text, "seq 5 is still the newest message")
        XCTAssertNil(row.expiredSnippet)

        // Now a backfilled row that IS the newest message-type row, and old
        // enough to arrive tombstoned.
        try store.insertHistory([
            event(6, type: JournalEventType.toolOutput,
                  payload: ["command": "backfilled", "live_log": true, "snippet": "out"]),
        ], now: Date(timeIntervalSince1970: 6).addingTimeInterval(25 * 3600))
        row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.lastMessageType, JournalEventType.toolOutput)
        XCTAssertEqual(row.expiredSnippet, "$ backfilled")
        let stored = try XCTUnwrap(try store.events(convoID: "c1").first { $0.seq == 6 })
        XCTAssertNil(stored.payload["snippet"])
    }

    // MARK: Read path is columns only

    /// The pin that matters: delete every `event` row, then read the list.
    /// If the TTL still needed a sub-query the override would vanish.
    func testReadTimeTTLDerivesFromColumnsWithoutReadingEvents() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true, "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 2))
        try store.dbQueue.write { db in try db.execute(sql: "DELETE FROM event") }

        let fresh = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(60))
        XCTAssertEqual(fresh.first?.snippet, "out", "inside the TTL the real output still shows")
        let stale = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
        XCTAssertEqual(stale.first?.snippet, "$ make test",
                       "the TTL override must come from the columns, not from an event sub-query")
    }

    func testReadTimeTTLIgnoresConversationsWhoseNewestMessageIsNotToolOutput() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.text, payload: ["body": "hello"]),
                               now: Date(timeIntervalSince1970: 2))
        let stale = try store.conversations(now: Date(timeIntervalSince1970: 1).addingTimeInterval(48 * 3600))
        XCTAssertEqual(stale.first?.snippet, "hello")
    }

    /// The chat-list observation used to re-run its whole fetch on every
    /// applied frame because the TTL sub-queries read `event`. Rewriting an
    /// `event` payload in a way that WOULD have changed the old derived
    /// snippet must now deliver nothing; the following `conversation` write
    /// proves the stream is still alive rather than merely quiet.
    func testConversationsStreamNoLongerTracksTheEventTable() async throws {
        let store = try makeStore()
        // Newest message is a tool_output with NO live_log: `expired_snippet`
        // is nil, so the list shows the real snippet under the new rules —
        // while the old read path would have started substituting
        // "$ make test" the moment `live_log` appeared in the payload.
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "snippet": "out"]),
                               now: Date(timeIntervalSince1970: 2))

        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.first?.snippet, "out")

        try store.dbQueue.write { db in
            let payload = try JSONSerialization.data(withJSONObject: [
                "command": "make test", "snippet": "out", "live_log": true,
            ] as [String: Any])
            try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = 1", arguments: [payload])
        }
        // Sleep so the two commits cannot coalesce into one notification,
        // which would mask a regression (same guard as
        // `testEventsStreamSuppressesOtherConversationCommits`).
        try await Task.sleep(for: .milliseconds(150))
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET title = 'renamed' WHERE id = 'c1'")
        }

        let next = await iterator.next()
        XCTAssertEqual(next?.first?.title, "renamed",
                       "the event-payload write delivered a value — the list fetch still reads `event`")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreLaunchPerfTests`
Expected: FAIL — `extra argument 'now' in call` on `store.applyJournal(_:now:)`.

- [ ] **Step 3: Thread `now` through the two apply paths and tombstone on insert**

In `MatronShared/Sources/Journal/JournalStore.swift`:

Add the storage helper next to `expiredSnippet(type:payload:)`:

```swift
    /// The form of `event` that actually goes to disk: a `tool_output` or
    /// `diff` that is ALREADY past one of `EventTombstone`'s cutoffs when it
    /// arrives is stored tombstoned, never in full.
    ///
    /// This is what makes the sweeps' watermarks complete. A sweep skips
    /// everything at or below its watermark, so a row older than that can
    /// only be correct if the two insert paths applied the identical rule on
    /// the way in — which is why both of them, and both sweeps, call
    /// `EventTombstone.apply` and nothing else.
    static func tombstonedForStorage(_ event: JournalEvent, now: Date) -> JournalEvent {
        guard let rewritten = EventTombstone.apply(to: event.payload, type: event.type,
                                                   ts: event.ts, now: now),
              let data = try? JSONSerialization.data(withJSONObject: rewritten)
        else { return event }
        return JournalEvent(seq: event.seq, convoID: event.convoID, ts: event.ts,
                            sender: event.sender, type: event.type, payloadData: data)
    }

    /// The newest message-type event's derived facts for `convoID`, or
    /// `(nil, nil)` when the conversation has no message-type event. One
    /// indexed lookup on `convo_id`; called only from write paths, never
    /// from a read.
    static func newestMessageColumns(_ db: Database, convoID: String) throws
        -> (type: String?, expiredSnippet: String?) {
        let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [convoID]
        arguments.append(contentsOf: Array(JournalEventType.messageTypes))
        guard let row = try Row.fetchOne(db, sql: """
            SELECT type, payload FROM event
            WHERE convo_id = ? AND type IN (\(placeholders))
            ORDER BY seq DESC LIMIT 1
            """, arguments: StatementArguments(arguments))
        else { return (nil, nil) }
        let type: String = row["type"]
        let payloadData: Data = row["payload"]
        return (type, expiredSnippet(type: type, payloadData: payloadData))
    }
```

Change the three entry points' signatures (the defaults keep every existing call site source-compatible):

```swift
    @discardableResult
    public func applyJournal(_ event: JournalEvent, now: Date = Date()) throws -> Bool {
        if failApplyForTesting?(event.seq) == true {
            throw JournalStoreTestError.simulatedWriteFailure
        }
        return try dbQueue.write { db in
            try self.applyOne(db, event, now: now)
        }
    }
```

```swift
    public func applyJournalBatch(_ events: [JournalEvent], now: Date = Date()) throws -> [JournalEvent] {
        guard !events.isEmpty else { return [] }
        if let fail = failApplyForTesting, events.contains(where: { fail($0.seq) }) {
            throw JournalStoreTestError.simulatedWriteFailure
        }
        return try dbQueue.write { db in
            var applied: [JournalEvent] = []
            applied.reserveCapacity(events.count)
            for event in events {
                if try self.applyOne(db, event, now: now) { applied.append(event) }
            }
            return applied
        }
    }
```

In `applyOne`, change the signature to `private func applyOne(_ db: Database, _ event: JournalEvent, now: Date) throws -> Bool`, and replace the save + payload read at the top of the body:

```swift
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            guard event.seq > current else { return false }
            // Stored tombstoned when it is already past a cutoff — see
            // `tombstonedForStorage`. Everything below reads `stored`, so the
            // conversation's snippet and columns describe what is on disk.
            let stored = Self.tombstonedForStorage(event, now: now)
            try EventRecord(stored).save(db)
            if let entry = SummaryEntryRecord(event: event) {
                try entry.insert(db, onConflict: .ignore)
            }
```

and, further down, replace `let payload = event.payload` with:

```swift
            let payload = stored.payload
```

Then extend the message-type branch:

```swift
            } else if JournalEventType.messageTypes.contains(event.type) {
                convo.snippet = Self.snippet(type: event.type, payload: payload)
                // The chat list's tool-output TTL reads these two columns and
                // nothing else (see `applyReadTimeSnippetTTL`), so they have
                // to be maintained wherever the snippet is.
                convo.lastMessageType = event.type
                convo.expiredSnippet = Self.expiredSnippet(type: event.type, payload: payload)
                if event.sender != ownSender, event.seq > convo.readUpToSeq {
                    convo.unreadCount += 1
                }
            }
```

- [ ] **Step 4: Tombstone and recompute in `insertHistory`**

Change the signature to `public func insertHistory(_ events: [JournalEvent], now: Date = Date()) throws`, delete the `snippetTTLMemo.removeAll()` line and its comment (the memo is gone in Step 6), store tombstoned rows, and recompute the columns in the existing per-conversation loop:

```swift
    public func insertHistory(_ events: [JournalEvent], now: Date = Date()) throws {
        try dbQueue.write { db in
            for e in events {
                try EventRecord(Self.tombstonedForStorage(e, now: now)).insert(db, onConflict: .ignore)
                if let entry = SummaryEntryRecord(event: e) {
                    try entry.insert(db, onConflict: .ignore)
                }
            }
```

(the outbox-confirmation loop that follows is unchanged), and then the per-conversation loop becomes:

```swift
            // Paginated rows can include unread messages (e.g. the refill
            // after a snapshot_required wipe re-fetches the newest page).
            // Live `applyJournal` counts unread incrementally; without a
            // recount here the chat list under-reports until the next
            // read_marker frame lands (bugbot "History insert skips unread").
            //
            // Backfilled rows can also become a conversation's newest
            // message-type event without moving `last_seq`, so the two TTL
            // columns are recomputed in the same pass — one indexed lookup
            // per touched conversation, exactly like the recount.
            for convoID in Set(events.map(\.convoID)) {
                guard var convo = try ConversationRecord.fetchOne(db, key: convoID) else { continue }
                convo.unreadCount = try Self.recountUnread(db, convoID: convoID,
                                                           after: convo.readUpToSeq, ownSender: ownSender)
                let columns = try Self.newestMessageColumns(db, convoID: convoID)
                convo.lastMessageType = columns.type
                convo.expiredSnippet = columns.expiredSnippet
                try convo.update(db)
            }
```

- [ ] **Step 5: Make the read path pure**

Replace the whole `applyReadTimeSnippetTTL` function (and its doc comment) with:

```swift
    /// Read-time mirror of the tool-output tombstone, applied WITHOUT a
    /// write and WITHOUT reading `event`.
    ///
    /// An app left running past the 24 h tool-output TTL (docs/protocol.md
    /// Retention) must stop surfacing an expired `live_log` snippet in the
    /// conversation list the next time it is read, exactly as
    /// `JournalTimelineMapper` already hides it in the open thread. Before
    /// v11 that answer came from a `MAX(seq)` sub-query plus an event fetch
    /// per stale conversation — ~0.4 s for 526 stale conversations on the
    /// Mac copy, and, worse, it made the whole chat-list observation track
    /// the `event` table, so every applied frame re-ran the entire list
    /// fetch. Both facts now live on the conversation row, maintained on
    /// write (`applyOne`, `insertHistory`, and the sweeps).
    private static func applyReadTimeSnippetTTL(_ record: ConversationRecord,
                                                now: Date) -> ConversationRecord {
        guard record.lastMessageType == JournalEventType.toolOutput,
              let expiredSnippet = record.expiredSnippet,
              let activityTS = record.lastActivityTS
        else { return record }
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.toolLogTTL * 1000)
        guard activityTS <= cutoff else { return record }
        var expired = record
        expired.snippet = expiredSnippet
        return expired
    }
```

In `conversations(now:)`, the last line of the `dbQueue.read` block becomes:

```swift
            return records.map { Self.applyReadTimeSnippetTTL($0, now: now) }
```

In `conversationsStream()`, delete the `let memo = snippetTTLMemo` line, make the tracking closure's last line:

```swift
            // Fresh `Date()` per re-run: the tracking closure re-executes on
            // every change GRDB observes for the tables it reads, so a
            // long-lived subscriber still gets the TTL re-evaluated against
            // current wall time rather than "now" at subscribe time.
            return records.map { Self.applyReadTimeSnippetTTL($0, now: Date()) }
```

and replace the trailing comment + return with:

```swift
        // This observation reads ONLY the `conversation` table: the TTL is
        // pure column logic (see `applyReadTimeSnippetTTL`), so an applied
        // journal frame re-runs the list fetch only when it actually touches
        // a conversation row. `removeDuplicates()` stays as the guard
        // against re-render churn from writes that change a row the list
        // does not display.
        return Self.stream(observation.removeDuplicates(), in: dbQueue)
```

- [ ] **Step 6: Delete the memo, `newestMessageSeq`, and the purge's conversation rewrite**

1. Delete the `snippetTTLMemo` stored property and its doc comment from the `JournalStore` class body.
2. Delete the whole `final class SnippetTTLMemo: @unchecked Sendable { … }` declaration and its doc comment.
3. Delete `private static func newestMessageSeq(_ db: Database, convoID: String) throws -> Int64?` entirely.
4. In `wipe()`, delete the `self.snippetTTLMemo.removeAll()` line and its `// Inside the write block …` comment.
5. Rewrite `purgeExpiredToolOutputSnippets(now:)`'s body so it routes through `EventTombstone` and no longer rewrites `conversation.snippet` (the read path covers that from the columns now). Task 4 turns this into the watermarked, chunked form; this step only removes the deleted machinery so the tree compiles and stays green in between:

```swift
    /// Rewrites every aged-out `tool_output` payload to the tombstone shape
    /// (`EventTombstone`). Idempotent; `now` is injectable for tests.
    public func purgeExpiredToolOutputSnippets(now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.toolLogTTL * 1000)
        try dbQueue.write { db in
            let rows = try EventRecord
                .filter(Column("type") == JournalEventType.toolOutput && Column("ts") <= cutoff)
                .fetchAll(db)
            for var row in rows {
                guard let payload = (try? JSONSerialization.jsonObject(with: row.payload)) as? [String: Any],
                      let rewritten = EventTombstone.apply(
                        to: payload, type: row.type,
                        ts: Date(timeIntervalSince1970: Double(row.ts) / 1000), now: now)
                else { continue }
                row.payload = try JSONSerialization.data(withJSONObject: rewritten)
                try row.update(db)
            }
        }
    }
```

- [ ] **Step 7: Update the existing tests the new write path invalidates**

In `MatronShared/Tests/JournalTests/JournalStoreTests.swift`:

1. Delete `testSnippetTTLMemoInvalidatedByInsertHistory` and `testSnippetTTLMemoInvalidatedByWipe` in full, together with the `// MARK: Snippet-TTL memo invalidation` header above them. The memo they pin no longer exists; the behaviour they protected (a backfilled or wiped conversation re-deriving its preview) is now pinned by `testInsertHistoryRecomputesTheColumnsAndTombstones` and `testReadTimeTTLDerivesFromColumnsWithoutReadingEvents` in `JournalStoreLaunchPerfTests`.

2. Six tests insert epoch-era tool-output rows and then assert on the STORED payload or the pre-TTL preview. With insert-time tombstoning those rows would arrive already stripped under a wall-clock `now`, so each insert must pin its own `now`. Make exactly these edits:

```swift
    func testPurgeRewritesStaleLiveLogToTombstone() throws {
        let store = try makeStore()
        // The event helper stamps ts = seq seconds after epoch, so seq 1 is
        // ancient relative to any injected `now` past 1970-01-02. Pin the
        // INSERT inside the TTL too, or the insert-time tombstone would do
        // the sweep's job and this test would prove nothing.
        try store.applyJournal(event(1, type: "tool_output", payload: toolOutputPayload()),
                               now: Date(timeIntervalSince1970: 1))
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600))
```

(the assertions below it are unchanged), and the same `now: Date(timeIntervalSince1970: 1)` (or `…: 2` where the test inserts a seq-2 row) added to every `applyJournal` in:
- `testPurgeLeavesYoungAndNonLiveLogRows` — both inserts take `now: Date(timeIntervalSince1970: 2)`.
- `testPurgeRewritesConvoPreviewWhenPurgedEventIsNewest` — the single insert takes `now: Date(timeIntervalSince1970: 1)`.
- `testPurgeKeepsConvoPreviewWhenNewerMessageExists` — both inserts take `now: Date(timeIntervalSince1970: 2)`.
- `testPurgeIsIdempotent` — the single insert takes `now: Date(timeIntervalSince1970: 1)`.
- `testConversationsAppliesTTLAtReadTimeWithoutPurge` — the single insert takes `now: Date(timeIntervalSince1970: 1)`.
- `testConversationsReadTimeTTLLeavesNonLiveLogSnippetsAlone` — the single insert takes `now: Date(timeIntervalSince1970: 1)`.

`testConversationsReadTimeTTLLeavesTextSnippetsAlone` needs no change: `text` has no tombstone rule.

- [ ] **Step 8: Run the tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreLaunchPerfTests`
Expected: PASS — `Executed 11 tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreTests`
Expected: PASS — `Executed N tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`. `MediaBrowserQueryTests` inserts a `tool_output` row carrying only `blob_ref`, which now lands with `blob_ref: null` — it asserts on types and ordering, not on that payload, so it stays green. `JournalTimelineServiceTests` serves an epoch-era `tool_output` frame through the engine (no `now:` seam there, by design — production always wants the wall clock) and asserts only that the row renders, so it stays green too. If either goes red, the fix is to give that fixture a realistic `ts`, never to weaken the insert rule.

- [ ] **Step 9: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Tests/JournalTests/JournalStoreTests.swift \
        MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "journal: chat-list TTL is column-only; inserts tombstone aged-out payloads" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Watermarked, chunked sweeps on `JournalStore`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift`
- Test: `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift`

**Interfaces:**
- Produces: `JournalStore.purgeExpiredToolOutputSnippets(now:)` (same name and signature, now watermarked at `meta.snippet_ttl_ts`), `JournalStore.applyRetention(now: Date = Date()) throws -> [Int64]` (watermarked at `meta.retention_ts`, returns the tombstoned seqs), `JournalStore.maintenanceLastRun() throws -> Date?`, `JournalStore.recordMaintenanceRun(at: Date) throws`, `JournalStore.refreshLastMessageColumns(_:convoID:)`.
- Consumes: `EventTombstone.apply` (Task 2), `newestMessageColumns` (Task 3), the `event_type_ts` index (Task 1).
- Consumed by: Task 5 (the returned seqs feed `SearchService.removeAll(eventIDs:)`), Task 6 (`JournalMaintenance`).

`wipe()` already runs `DELETE FROM meta`, which resets all three keys — no change needed there.

- [ ] **Step 1: Write the failing tests**

Append to `MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift`, inside the same class:

```swift
    // MARK: Watermarked sweeps

    private func rawPayload(_ store: JournalStore, seq: Int64) throws -> [String: Any] {
        let data: Data = try XCTUnwrap(try store.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM event WHERE seq = ?", arguments: [seq])
        })
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    private func watermark(_ store: JournalStore, key: String) throws -> Int64? {
        try store.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func testPurgeRecordsItsWatermarkAndTheSecondSweepSkipsThatRange() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 1)
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "make test", "live_log": true,
                                               "snippet": "out", "blob_ref": "b1"]),
                               now: insertAt)
        let sweepAt = Date(timeIntervalSince1970: 1).addingTimeInterval(25 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: sweepAt)
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"])
        XCTAssertEqual(try watermark(store, key: "snippet_ttl_ts"),
                       Int64(sweepAt.timeIntervalSince1970 * 1000) - Int64(24 * 3600 * 1000))

        // Put an un-tombstoned payload back under the watermark by hand. A
        // second sweep must not see it — that is what "incremental" means,
        // and the insert paths are what guarantee no real row can be there.
        try store.dbQueue.write { db in
            let payload = try JSONSerialization.data(withJSONObject: [
                "command": "make test", "live_log": true, "snippet": "back",
            ] as [String: Any])
            try db.execute(sql: "UPDATE event SET payload = ? WHERE seq = 1", arguments: [payload])
        }
        try store.purgeExpiredToolOutputSnippets(now: sweepAt.addingTimeInterval(60))
        XCTAssertEqual(try rawPayload(store, seq: 1)["snippet"] as? String, "back",
                       "the second sweep rescanned a range its watermark had already covered")
    }

    /// The other half of the watermark contract: a row older than the
    /// watermark that lands AFTER it arrives tombstoned (Task 3), so
    /// skipping the range is safe.
    func testAnOldRowInsertedAfterTheWatermarkArrivesTombstoned() throws {
        let store = try makeStore()
        let sweepAt = Date(timeIntervalSince1970: 100).addingTimeInterval(25 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: sweepAt)

        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "ancient", "live_log": true, "snippet": "out"]),
        ], now: sweepAt.addingTimeInterval(60))
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"],
                     "a below-watermark row must arrive already tombstoned")
        XCTAssertEqual(try rawPayload(store, seq: 1)["expired"] as? Bool, true)
    }

    func testSweepCoversMoreRowsThanOneChunk() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 1)
        // 1200 rows = three chunks of 500 (the last partial), so a
        // single-chunk implementation leaves 700 rows un-tombstoned.
        let events = (1...1200).map { seq in
            event(Int64(seq), type: JournalEventType.toolOutput,
                  payload: ["command": "c\(seq)", "live_log": true, "snippet": "out"])
        }
        try store.insertHistory(events, now: insertAt)
        try store.purgeExpiredToolOutputSnippets(
            now: Date(timeIntervalSince1970: 1200).addingTimeInterval(25 * 3600))
        let remaining = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event WHERE payload LIKE '%snippet%'") ?? -1
        }
        XCTAssertEqual(remaining, 0, "the sweep stopped after the first chunk")
    }

    func testApplyRetentionReturnsTheSeqsItTombstoned() throws {
        let store = try makeStore()
        let insertAt = Date(timeIntervalSince1970: 3)
        try store.insertHistory([
            event(1, type: JournalEventType.toolOutput,
                  payload: ["command": "old", "snippet": "out", "exit_code": 0]),
            event(2, type: JournalEventType.diff, payload: ["file_path": "/w/A.swift", "diff": "+ a"]),
            event(3, type: JournalEventType.text, payload: ["body": "kept forever"]),
        ], now: insertAt)

        let seqs = try store.applyRetention(
            now: Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600))
        XCTAssertEqual(seqs.sorted(), [1, 2], "text rows are never retention-tombstoned")
        XCTAssertNil(try rawPayload(store, seq: 1)["snippet"])
        XCTAssertNil(try rawPayload(store, seq: 2)["diff"])
        XCTAssertEqual(try rawPayload(store, seq: 2)["file_path"] as? String, "/w/A.swift")
        XCTAssertEqual(try rawPayload(store, seq: 3)["body"] as? String, "kept forever")

        XCTAssertEqual(try store.applyRetention(
            now: Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600 + 60)), [],
            "a second retention sweep over the same range must tombstone nothing")
    }

    /// A tool_output that was never a live log has no `expired_snippet` at
    /// insert time; once retention tombstones it, the list has nothing but
    /// the command to show, so the sweep refreshes the columns of the
    /// conversations it touched.
    func testRetentionRefreshesTheConversationColumns() throws {
        let store = try makeStore()
        try store.applyJournal(event(1, type: JournalEventType.toolOutput,
                                     payload: ["command": "legacy", "snippet": "durable"]),
                               now: Date(timeIntervalSince1970: 2))
        XCTAssertNil(try XCTUnwrap(try store.dbQueue.read {
            try ConversationRecord.fetchOne($0, key: "c1")
        }).expiredSnippet)

        _ = try store.applyRetention(now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600))
        let row = try XCTUnwrap(try store.dbQueue.read { try ConversationRecord.fetchOne($0, key: "c1") })
        XCTAssertEqual(row.expiredSnippet, "$ legacy")
        XCTAssertEqual(try store.conversations(
            now: Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)).first?.snippet,
            "$ legacy")
    }

    func testWipeResetsBothWatermarksAndTheMaintenanceStamp() throws {
        let store = try makeStore()
        let sweepAt = Date(timeIntervalSince1970: 100).addingTimeInterval(31 * 24 * 3600)
        try store.purgeExpiredToolOutputSnippets(now: sweepAt)
        _ = try store.applyRetention(now: sweepAt)
        try store.recordMaintenanceRun(at: sweepAt)
        XCTAssertNotNil(try watermark(store, key: "snippet_ttl_ts"))
        XCTAssertNotNil(try watermark(store, key: "retention_ts"))
        XCTAssertNotNil(try store.maintenanceLastRun())

        try store.wipe()
        XCTAssertNil(try watermark(store, key: "snippet_ttl_ts"))
        XCTAssertNil(try watermark(store, key: "retention_ts"))
        XCTAssertNil(try store.maintenanceLastRun())
    }

    func testMaintenanceLastRunRoundTripsToTheSecond() throws {
        let store = try makeStore()
        XCTAssertNil(try store.maintenanceLastRun())
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordMaintenanceRun(at: at)
        XCTAssertEqual(try store.maintenanceLastRun(), at)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreLaunchPerfTests`
Expected: FAIL — `value of type 'JournalStore' has no member 'applyRetention'`.

- [ ] **Step 3: Write the sweeps**

In `MatronShared/Sources/Journal/JournalStore.swift`, replace the `// MARK: Tool-output TTL` section's `purgeExpiredToolOutputSnippets` (the interim body from Task 3, Step 6) with the watermarked pair plus their shared engine:

```swift
    // MARK: Background maintenance sweeps

    /// `meta` keys written by the sweeps. None is written by a migration;
    /// `wipe()`'s `DELETE FROM meta` resets all three, which is exactly
    /// right — a re-bootstrapped mirror must re-sweep from scratch.
    static let snippetTTLWatermarkKey = "snippet_ttl_ts"
    static let retentionWatermarkKey = "retention_ts"
    static let maintenanceLastRunKey = "maintenance_last_run"

    /// Rows per write transaction. The store is a single-connection
    /// `DatabaseQueue`, so a sweep that took one transaction for the whole
    /// range would block every UI read for its duration; 500 keeps each
    /// transaction short enough to interleave.
    static let sweepChunkSize = 500

    /// Rewrites aged-out `tool_output` payloads to the tombstone shape,
    /// incrementally: everything at or below `meta.snippet_ttl_ts` was
    /// covered by an earlier sweep and is skipped, and the range scan uses
    /// the `event_type_ts` index rather than reading the whole table.
    ///
    /// Same name and signature as the boot-time sweep it replaces — the
    /// difference is that nothing calls it from `JournalStore.init` any
    /// more (`JournalMaintenance` owns it, off the launch path).
    ///
    /// First run after the update has no watermark and therefore scans every
    /// tool-output row older than 24 h once, in the background.
    public func purgeExpiredToolOutputSnippets(now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.toolLogTTL * 1000)
        _ = try sweepTombstones(types: [JournalEventType.toolOutput],
                                watermarkKey: Self.snippetTTLWatermarkKey,
                                cutoffMs: cutoff, now: now)
    }

    /// Local retention (spec §3.4 / §4 decision 1): tool-output and diff
    /// BODIES older than 30 days are tombstoned on this device. The server
    /// still has them; recovering them locally means a wipe + re-sync, which
    /// is the existing `snapshot_required` path.
    ///
    /// Returns the `seq`s it tombstoned so the caller can drop their search
    /// rows (`JournalMaintenance`).
    @discardableResult
    public func applyRetention(now: Date = Date()) throws -> [Int64] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.retentionWindow * 1000)
        return try sweepTombstones(types: [JournalEventType.toolOutput, JournalEventType.diff],
                                   watermarkKey: Self.retentionWatermarkKey,
                                   cutoffMs: cutoff, now: now)
    }

    /// The shared sweep engine: walk `(type, ts)` forward from the watermark
    /// to `cutoffMs` in chunks, rewrite what `EventTombstone` changes, then
    /// move the watermark to the cutoff.
    ///
    /// Paging is keyset-based on `(ts, seq)` rather than OFFSET: rows sharing
    /// a millisecond are common (a batch apply stamps many at once), and an
    /// offset walk over a table being written underneath would skip them.
    private func sweepTombstones(types: [String], watermarkKey: String,
                                 cutoffMs: Int64, now: Date) throws -> [Int64] {
        var tombstoned: [Int64] = []
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        var afterTS = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [watermarkKey]) ?? 0
        }
        // `Int64.max` on the first page makes the seed behave as `ts >
        // watermark`, so a row exactly at the watermark is not re-swept.
        var afterSeq = Int64.max
        while true {
            let chunk: [EventRecord] = try dbQueue.write { db in
                var arguments: [DatabaseValueConvertible] = types
                arguments.append(contentsOf: [cutoffMs, afterTS, afterTS, afterSeq])
                let rows = try EventRecord.fetchAll(db, sql: """
                    SELECT * FROM event
                    WHERE type IN (\(placeholders)) AND ts <= ?
                      AND (ts > ? OR (ts = ? AND seq > ?))
                    ORDER BY ts, seq
                    LIMIT \(Self.sweepChunkSize)
                    """, arguments: StatementArguments(arguments))
                var touched = Set<String>()
                for var row in rows {
                    guard let payload = (try? JSONSerialization.jsonObject(with: row.payload)) as? [String: Any],
                          let rewritten = EventTombstone.apply(
                            to: payload, type: row.type,
                            ts: Date(timeIntervalSince1970: Double(row.ts) / 1000), now: now)
                    else { continue }
                    row.payload = try JSONSerialization.data(withJSONObject: rewritten)
                    try row.update(db)
                    tombstoned.append(row.seq)
                    touched.insert(row.convoID)
                }
                // A tombstoned row can be its conversation's newest message —
                // and a payload that was never a live log had no
                // `expired_snippet` at insert time, so the list would keep
                // showing a body that is no longer on disk. One indexed
                // lookup per touched conversation, and no write at all when
                // the columns already agree (so the chat-list observation
                // does not re-fire for a sweep that changed nothing it shows).
                for convoID in touched {
                    try Self.refreshLastMessageColumns(db, convoID: convoID)
                }
                return rows
            }
            guard let last = chunk.last else { break }
            afterTS = last.ts
            afterSeq = last.seq
        }
        try dbQueue.write { db in
            try Self.setMeta(db, key: watermarkKey, value: String(cutoffMs))
        }
        return tombstoned
    }

    /// Recomputes `last_message_type` / `expired_snippet` for one
    /// conversation, writing only when a value actually changed.
    static func refreshLastMessageColumns(_ db: Database, convoID: String) throws {
        guard var convo = try ConversationRecord.fetchOne(db, key: convoID) else { return }
        let columns = try newestMessageColumns(db, convoID: convoID)
        guard convo.lastMessageType != columns.type || convo.expiredSnippet != columns.expiredSnippet
        else { return }
        convo.lastMessageType = columns.type
        convo.expiredSnippet = columns.expiredSnippet
        try convo.update(db)
    }

    /// When the maintenance sweeps last completed a full pass — the Settings
    /// › Storage "Last maintenance" row, and the foreground scheduler's
    /// due-check. Stored as epoch milliseconds in `meta`, like the cursor.
    public func maintenanceLastRun() throws -> Date? {
        try dbQueue.read { db in
            guard let ms = try Int64.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Self.maintenanceLastRunKey]) else { return nil }
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
    }

    public func recordMaintenanceRun(at date: Date) throws {
        try dbQueue.write { db in
            try Self.setMeta(db, key: Self.maintenanceLastRunKey,
                             value: String(Int64(date.timeIntervalSince1970 * 1000)))
        }
    }

    static func setMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value])
    }
```

- [ ] **Step 4: Run the tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreLaunchPerfTests`
Expected: PASS — `Executed 18 tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`. The existing purge tests in `JournalStoreTests` still pass: each pins its own `now`, and a first sweep with no watermark covers the whole range exactly as before.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Tests/JournalTests/JournalStoreLaunchPerfTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "journal: watermarked, chunked TTL and retention sweeps" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Search side — retention-aware indexing and batch removal

**Files:**
- Modify: `MatronShared/Sources/Journal/SearchBackfill.swift`
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift`
- Modify: `MatronShared/Sources/Chat/JournalTimelineService.swift`
- Modify: `MatronShared/Sources/Search/SearchService.swift`
- Modify: `MatronShared/Sources/Search/SearchServiceLive.swift`
- Modify: `MatronShared/Tests/JournalTests/SearchBackfillCoordinatorTests.swift`
- Test: `MatronShared/Tests/SearchTests/SearchRetentionTests.swift` (new)

**Interfaces:**
- Produces: `JournalEvent.searchableBody(now: Date = Date()) -> String?` (replacing the `searchableBody` property); `SearchBackfillCoordinator.init(search:fetchPage:pageSize:throttle:now:)`; `SearchService.removeAll(eventIDs: [String]) async throws`.
- Consumes: `EventTombstone.retentionWindow` (Task 2).
- Consumed by: Task 6 (`JournalMaintenance` calls `removeAll(eventIDs:)` with the seqs `applyRetention` returned).

All three index feeders — live sync, backward pagination, history backfill — go through `searchableBody`, so making that one function retention-aware is what stops the server-backed feeders from re-adding bodies the sweep just removed.

- [ ] **Step 1: Write the failing tests**

In `MatronShared/Tests/JournalTests/SearchBackfillCoordinatorTests.swift`, first pin the helper's clock so every existing expectation survives (the fixtures stamp `ts = seq` seconds after the epoch, which is decades past the retention window in wall-clock terms):

```swift
    private func makeCoordinator(search: InMemorySearchService, pager: ScriptedPager,
                                 pageSize: Int = 2,
                                 now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 10) }
    ) -> SearchBackfillCoordinator {
        SearchBackfillCoordinator(
            search: search,
            fetchPage: { convoID, beforeSeq, limit in
                try await pager.page(convoID: convoID, beforeSeq: beforeSeq, limit: limit)
            },
            pageSize: pageSize, throttle: .zero, now: now
        )
    }
```

then replace `test_searchableBody_mapsEventTypesLikeTheTimelineMapper` and add the two retention tests:

```swift
    func test_searchableBody_mapsEventTypesLikeTheTimelineMapper() {
        let now = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(makeEvent(seq: 1, payload: ["body": "hi"]).searchableBody(now: now), "hi")
        XCTAssertEqual(makeEvent(seq: 2, type: JournalEventType.toolOutput,
                                 payload: ["snippet": "out"]).searchableBody(now: now), "out")
        // diff precedence: `diff` wins over `snippet`, snippet is the fallback.
        XCTAssertEqual(makeEvent(seq: 3, type: JournalEventType.diff,
                                 payload: ["diff": "+ d", "snippet": "s"]).searchableBody(now: now), "+ d")
        XCTAssertEqual(makeEvent(seq: 4, type: JournalEventType.diff,
                                 payload: ["snippet": "s"]).searchableBody(now: now), "s")
        XCTAssertNil(makeEvent(seq: 5, type: JournalEventType.image,
                               payload: ["blob_ref": "b"]).searchableBody(now: now))
        XCTAssertNil(makeEvent(seq: 6, payload: ["body": ""]).searchableBody(now: now))
    }

    /// Retention removed these rows from the index; the server-backed
    /// feeders (backfill, backward pagination) would otherwise put them
    /// straight back, because the server keeps bodies forever.
    func test_searchableBody_isNilForToolOutputAndDiffPastTheRetentionWindow() {
        let past = Date(timeIntervalSince1970: 1).addingTimeInterval(31 * 24 * 3600)
        XCTAssertNil(makeEvent(seq: 1, type: JournalEventType.toolOutput,
                               payload: ["snippet": "out"]).searchableBody(now: past))
        XCTAssertNil(makeEvent(seq: 1, type: JournalEventType.diff,
                               payload: ["diff": "+ d"]).searchableBody(now: past))
        XCTAssertEqual(makeEvent(seq: 1, payload: ["body": "text is kept forever"]).searchableBody(now: past),
                       "text is kept forever",
                       "retention covers tool output and diffs only — message text stays searchable")
    }

    func test_backfill_skipsToolOutputAndDiffPastTheRetentionWindow() async throws {
        let search = InMemorySearchService()
        let events: [JournalEvent] = [
            makeEvent(seq: 1, payload: ["body": "real text"]),
            makeEvent(seq: 2, type: JournalEventType.toolOutput, payload: ["snippet": "tool says"]),
            makeEvent(seq: 3, type: JournalEventType.diff, payload: ["diff": "+ added line"]),
        ]
        let pager = ScriptedPager(events: events)
        let coordinator = makeCoordinator(search: search, pager: pager, pageSize: 10,
                                          now: { Date(timeIntervalSince1970: 3).addingTimeInterval(31 * 24 * 3600) })

        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete, "skipping bodies must not stall the walk")
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1"]),
                       "the backfill re-indexed rows retention had removed")
    }
```

Create `MatronShared/Tests/SearchTests/SearchRetentionTests.swift`:

```swift
import XCTest
@testable import MatronSearch

/// `removeAll(eventIDs:)` — the batch form the retention sweep needs. The
/// one-at-a-time `remove(eventID:)` meant one write transaction (and one
/// fsync) per retired row, and a first retention pass retires thousands.
final class SearchRetentionTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func makeService() throws -> SearchServiceLive {
        try SearchServiceLive.open(databaseURL: url)
    }

    func testRemoveAllDropsEveryListedRowAndLeavesTheRest() async throws {
        let service = try makeService()
        for seq in 1...5 {
            try await service.index(roomID: "c1", eventID: String(seq), sender: "agent:dev-2",
                                    timestamp: Date(timeIntervalSince1970: Double(seq)),
                                    body: "body number \(seq)")
        }
        try await service.removeAll(eventIDs: ["2", "4"])

        let hits = try await service.query("body", limit: 50)
        XCTAssertEqual(Set(hits.map(\.eventID)), Set(["1", "3", "5"]))
    }

    func testRemoveAllIgnoresUnknownIDsAndAnEmptyBatch() async throws {
        let service = try makeService()
        try await service.index(roomID: "c1", eventID: "1", sender: "agent:dev-2",
                                timestamp: Date(timeIntervalSince1970: 1), body: "kept")
        try await service.removeAll(eventIDs: [])
        try await service.removeAll(eventIDs: ["nope", "also-nope"])
        XCTAssertEqual(try await service.query("kept", limit: 10).map(\.eventID), ["1"])
    }

    /// The FTS mirror is an external-content table kept in step by triggers;
    /// a batch delete has to fire them exactly like the single-row form, or
    /// the tokens of the deleted rows are stranded (the 2026-08-06 ghost
    /// corruption).
    func testRemoveAllLeavesTheFTSMirrorConsistent() async throws {
        let service = try makeService()
        for seq in 1...200 {
            try await service.index(roomID: "c1", eventID: String(seq), sender: "agent:dev-2",
                                    timestamp: Date(timeIntervalSince1970: Double(seq)),
                                    body: "phrase \(seq)")
        }
        try await service.removeAll(eventIDs: (1...150).map(String.init))
        XCTAssertEqual(try await service.query("phrase", limit: 500).count, 50)
        try await service.integrityCheck()
    }
}
```

> If `SearchServiceLive` has no `integrityCheck()`, drop that single line and keep the count assertion — the FTS mirror is still proven by the query returning exactly the 50 survivors.

- [ ] **Step 2: Run them to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter SearchRetentionTests`
Expected: FAIL — `value of type 'SearchServiceLive' has no member 'removeAll'`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter SearchBackfillCoordinatorTests`
Expected: FAIL — `extra argument 'now' in call`.

- [ ] **Step 3: Make `searchableBody` retention-aware**

In `MatronShared/Sources/Journal/SearchBackfill.swift`, replace the computed property with a method:

```swift
extension JournalEvent {
    /// The text the search index should hold for this event, or `nil` when
    /// the event carries nothing searchable. Single source of truth for all
    /// three index feeders — live sync (`JournalSyncEngine`), backward
    /// pagination (`JournalTimelineService`), and the history backfill — so
    /// what the user can SEE is what search can FIND.
    ///
    /// `now` exists because the last two feeders fetch from the SERVER,
    /// which keeps bodies forever. Local retention (`EventTombstone`)
    /// tombstones tool-output and diff bodies after 30 days and the
    /// maintenance sweep drops their index rows; without this guard the very
    /// next backfill pass or backward page would put them straight back.
    public func searchableBody(now: Date = Date()) -> String? {
        switch type {
        case JournalEventType.toolOutput, JournalEventType.diff:
            guard ts.addingTimeInterval(EventTombstone.retentionWindow) > now else { return nil }
        default:
            break
        }
        let body: String? = switch type {
        case JournalEventType.text: payload["body"] as? String
        case JournalEventType.toolOutput: payload["snippet"] as? String
        // diff → snippet precedence mirrors JournalTimelineMapper.
        case JournalEventType.diff: payload["diff"] as? String ?? payload["snippet"] as? String
        default: nil
        }
        guard let body, !body.isEmpty else { return nil }
        return body
    }
}
```

In the same file, give `SearchBackfillCoordinator` a clock and use it. Add the stored property and init parameter:

```swift
    /// Wall clock for the retention guard in `searchableBody(now:)`.
    /// Injectable so a test can walk fixture events without their epoch-era
    /// timestamps tripping the 30-day window.
    private let now: @Sendable () -> Date

    public init(search: any SearchService, fetchPage: @escaping FetchPage,
                pageSize: Int = 200, throttle: Duration = .milliseconds(100),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.search = search
        self.fetchPage = fetchPage
        self.pageSize = pageSize
        self.throttle = throttle
        self.now = now
    }
```

and in the batching `compactMap` (the `let entries = older.compactMap { … }` block):

```swift
            let indexedAt = now()
            let entries = older.compactMap { event -> SearchIndexEntry? in
                guard let body = event.searchableBody(now: indexedAt) else { return nil }
                return SearchIndexEntry(roomID: event.convoID, eventID: String(event.seq),
                                        sender: event.sender, timestamp: event.ts, body: body)
            }
```

- [ ] **Step 4: Update the other two feeders**

In `MatronShared/Sources/Journal/JournalSyncEngine.swift`, `didApplyBatch`:

```swift
        let indexedAt = Date()
        let entries = events.compactMap { event -> SearchIndexEntry? in
            guard let body = event.searchableBody(now: indexedAt) else { return nil }
            return SearchIndexEntry(roomID: event.convoID, eventID: String(event.seq),
                                    sender: event.sender, timestamp: event.ts, body: body)
        }
```

and `indexForSearch`:

```swift
        guard let body = event.searchableBody() else { return }
```

In `MatronShared/Sources/Chat/JournalTimelineService.swift`, the backward-pagination feeder:

```swift
        if let search {
            let indexedAt = Date()
            for event in newOnes {
                if let body = event.searchableBody(now: indexedAt) {
                    try? await search.index(roomID: event.convoID, eventID: String(event.seq),
                                            sender: event.sender, timestamp: event.ts, body: body)
                }
            }
        }
```

- [ ] **Step 5: Add `removeAll(eventIDs:)`**

In `MatronShared/Sources/Search/SearchService.swift`, add the requirement next to `remove(eventID:)`:

```swift
    /// Removes many events in one call — the retention sweep's form. A
    /// protocol requirement (not just an extension helper) so `any
    /// SearchService` dispatches to the live override; the extension default
    /// below keeps existing fakes compiling, exactly as `indexBatch` does.
    func removeAll(eventIDs: [String]) async throws
```

and, in the same file's `extension SearchService` that already defaults `indexBatch`:

```swift
    /// Default: one call per id. Correct but slow — `SearchServiceLive`
    /// overrides it with a single transaction.
    func removeAll(eventIDs: [String]) async throws {
        for eventID in eventIDs { try await remove(eventID: eventID) }
    }
```

In `MatronShared/Sources/Search/SearchServiceLive.swift`, immediately after `remove(eventID:)`:

```swift
    public func removeAll(eventIDs: [String]) async throws {
        guard !eventIDs.isEmpty else { return }
        // One write transaction for the whole batch — a first retention pass
        // retires thousands of rows, and a transaction each was the shape
        // that dirtied 8.6 GB in twelve minutes during the 2026-08-10 search
        // backfill incident. Chunked at 500 so the `IN (…)` list stays well
        // inside SQLITE_MAX_VARIABLE_NUMBER.
        try await queue.write { db in
            for chunk in stride(from: 0, to: eventIDs.count, by: 500).map({
                Array(eventIDs[$0..<min($0 + 500, eventIDs.count)])
            }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                // DELETE on `messages` fires the AFTER DELETE trigger which
                // removes the matching FTS row — the same path the
                // single-row form takes, so no tokens are stranded.
                try db.execute(sql: "DELETE FROM messages WHERE event_id IN (\(placeholders))",
                               arguments: StatementArguments(chunk))
            }
        }
    }
```

- [ ] **Step 6: Run the tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter SearchRetentionTests`
Expected: PASS — `Executed 3 tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter SearchBackfillCoordinatorTests`
Expected: PASS — `Executed N tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`. If a fake `SearchService` in `ViewModelTests` or `ChatTests` fails to compile, it is missing nothing: the protocol extension supplies `removeAll(eventIDs:)`. A compile error there means the fake declared its own `remove(eventID:)` in an extension rather than the type body — move it into the body.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Journal/SearchBackfill.swift \
        MatronShared/Sources/Journal/JournalSyncEngine.swift \
        MatronShared/Sources/Chat/JournalTimelineService.swift \
        MatronShared/Sources/Search/SearchService.swift \
        MatronShared/Sources/Search/SearchServiceLive.swift \
        MatronShared/Tests/JournalTests/SearchBackfillCoordinatorTests.swift \
        MatronShared/Tests/SearchTests/SearchRetentionTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "search: retention-aware indexing and batched removal" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `JournalMaintenance` — one background sweeper, and the `init` sweep goes

**Files:**
- Create: `MatronShared/Sources/Journal/JournalMaintenance.swift`
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (remove the `init` sweep)
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift`
- Modify: `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift`
- Modify: `Matron/App/MatronApp.swift`, `MatronMac/App/MatronMacApp.swift`
- Test: `MatronShared/Tests/JournalTests/JournalMaintenanceTests.swift` (new)

**Interfaces:**
- Produces: `MaintenanceSweeping` (the store seam), `JournalMaintenance` actor with `start()`, `stop()`, `runIfDue(now:)`; `JournalSyncEngine.attachMaintenance(_:)`; `AppDependencies.journalMaintenance(for:)` on both platforms.
- Consumes: `JournalStore.purgeExpiredToolOutputSnippets(now:)` / `applyRetention(now:)` / `maintenanceLastRun()` / `recordMaintenanceRun(at:)` (Task 4), `SearchService.removeAll(eventIDs:)` (Task 5).

**This is the task that removes `try purgeExpiredToolOutputSnippets()` from `JournalStore.init` — not any earlier one.** Every intermediate commit still purges at boot, so no commit in this series ships a store that silently stopped enforcing the TTL.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/JournalMaintenanceTests.swift`:

```swift
import XCTest
@testable import MatronJournal
import MatronSearch

/// Scheduling and sequencing of the background sweeper. The cadence is
/// driven entirely through `runIfDue(now:)` with an injected clock — the
/// 10 s / 60 min timers in `start()` are a thin wrapper around it, so no
/// test has to sleep.
final class JournalMaintenanceTests: XCTestCase {
    private final class RecordingSearch: SearchService, @unchecked Sendable {
        private let lock = NSLock()
        private var _removed: [[String]] = []
        var removed: [[String]] { lock.lock(); defer { lock.unlock() }; return _removed }

        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
        func indexBatch(_ entries: [SearchIndexEntry]) async throws {}
        func remove(eventID: String) async throws {}
        func removeAll(eventIDs: [String]) async throws {
            lock.lock(); _removed.append(eventIDs); lock.unlock()
        }
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
        func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] { [] }
        func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] { [] }
        func wipe() async throws {}
        func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
        func backfillComplete(roomID: String) async throws -> Bool { true }
        func backfillOldestEventID(roomID: String) async throws -> String? { nil }
        func resetBackfill() async throws {}
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstRunSweepsWhenNothingHasEverRun() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(store.purgeCalls, [t0])
        XCTAssertEqual(store.retentionCalls, [t0])
        XCTAssertEqual(store.lastRunStamp, t0, "a completed sweep stamps maintenance_last_run")
    }

    func testASecondRunInsideTheHourDoesNothing() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        await maintenance.runIfDue(now: t0.addingTimeInterval(59 * 60))
        XCTAssertEqual(store.purgeCalls.count, 1, "the hourly cadence is the whole point of the watermark")
    }

    func testARunPastTheHourSweepsAgain() async throws {
        let store = SpyStore()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        let later = t0.addingTimeInterval(61 * 60)
        await maintenance.runIfDue(now: later)
        XCTAssertEqual(store.purgeCalls, [t0, later])
    }

    /// The foreground path: a process that starts with a stamp older than an
    /// hour sweeps immediately rather than waiting out a timer.
    func testAStaleStoredStampSweepsOnTheFirstForegroundCheck() async throws {
        let store = SpyStore(lastRun: t0.addingTimeInterval(-2 * 3600))
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(store.purgeCalls, [t0])
    }

    func testAFreshStoredStampSkipsTheFirstRun() async throws {
        let store = SpyStore(lastRun: t0.addingTimeInterval(-10 * 60))
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertTrue(store.purgeCalls.isEmpty,
                      "a launch ten minutes after the last sweep must not re-sweep")
    }

    func testRetiredSeqsAreRemovedFromTheSearchIndexInOneBatch() async throws {
        let store = SpyStore()
        store.retentionResult = [11, 12, 13]
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertEqual(search.removed, [["11", "12", "13"]],
                       "search rows are keyed by String(seq) — see JournalSyncEngine.indexForSearch")
    }

    func testNothingRetiredMeansNoSearchWrite() async throws {
        let store = SpyStore()
        let search = RecordingSearch()
        let maintenance = JournalMaintenance(store: store, search: search, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertTrue(search.removed.isEmpty)
    }

    /// A failed sweep must not stamp `maintenance_last_run`: the next tick
    /// has to retry, and nothing about a failure may block the app.
    func testAFailedSweepIsNotStampedAndIsRetriedNextTick() async throws {
        let store = SpyStore()
        store.purgeError = SpyStore.Boom()
        let maintenance = JournalMaintenance(store: store, search: nil, now: { self.t0 })
        await maintenance.runIfDue()
        XCTAssertNil(store.lastRunStamp)

        store.purgeError = nil
        let later = t0.addingTimeInterval(60)
        await maintenance.runIfDue(now: later)
        XCTAssertEqual(store.lastRunStamp, later, "the retry does not wait out the hour")
    }
}

/// Plain (non-actor) recorder: `MaintenanceSweeping` is synchronous and
/// throwing, which an actor cannot satisfy without hops, and every call
/// lands on the maintenance actor's single executor anyway.
final class SpyStore: MaintenanceSweeping, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    private var _purgeCalls: [Date] = []
    private var _retentionCalls: [Date] = []
    private var _lastRun: Date?
    var retentionResult: [Int64] = []
    var purgeError: Error?

    init(lastRun: Date? = nil) { _lastRun = lastRun }

    var purgeCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _purgeCalls }
    var retentionCalls: [Date] { lock.lock(); defer { lock.unlock() }; return _retentionCalls }
    var lastRunStamp: Date? { lock.lock(); defer { lock.unlock() }; return _lastRun }

    func purgeExpiredToolOutputSnippets(now: Date) throws {
        if let purgeError { throw purgeError }
        lock.lock(); _purgeCalls.append(now); lock.unlock()
    }
    func applyRetention(now: Date) throws -> [Int64] {
        lock.lock(); _retentionCalls.append(now); lock.unlock()
        return retentionResult
    }
    func maintenanceLastRun() throws -> Date? { lastRunStamp }
    func recordMaintenanceRun(at date: Date) throws {
        lock.lock(); _lastRun = date; lock.unlock()
    }
}
```

> `SpyStore` is declared at the BOTTOM of the same file, outside the test
> class, because `MaintenanceSweeping`'s methods are synchronous and
> throwing: an actor cannot witness them without hops, so the recorder is a
> lock-protected final class. Every call lands on the maintenance actor's
> executor anyway.

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalMaintenanceTests`
Expected: FAIL — `cannot find 'JournalMaintenance' in scope`.

- [ ] **Step 3: Write `MatronShared/Sources/Journal/JournalMaintenance.swift`**

```swift
import Foundation
import MatronSearch
import os

/// What `JournalMaintenance` needs from the store. A protocol so the
/// scheduler can be tested against a recorder without a SQLite file;
/// `JournalStore` satisfies it as written.
public protocol MaintenanceSweeping: Sendable {
    func purgeExpiredToolOutputSnippets(now: Date) throws
    func applyRetention(now: Date) throws -> [Int64]
    func maintenanceLastRun() throws -> Date?
    func recordMaintenanceRun(at date: Date) throws
}

extension JournalStore: MaintenanceSweeping {}

/// The store's background housekeeping: the tool-output TTL sweep, the
/// 30-day retention sweep, and the search-index removal that follows it.
///
/// This replaces the sweep that used to run inside `JournalStore.init`,
/// synchronously, on the main actor, before any caller could read the store
/// — 1.5 s of SQL and 75,791 row decodes on the Mac copy, on every single
/// launch, growing forever. Nothing here is on the launch path: the first
/// run is 10 s after the sync engine starts (or as soon as the first
/// catch-up batch lands, whichever comes first), and everything runs at
/// `.utility`, never on the main actor.
///
/// Failures are logged and retried at the next tick. `maintenance_last_run`
/// is stamped only after a complete pass, so a failed sweep does not buy
/// itself an hour of silence.
public actor JournalMaintenance {
    /// How long between passes. Also the staleness threshold the foreground
    /// check uses (spec §3.4).
    public static let interval: TimeInterval = 60 * 60
    /// Long enough for the connect + first catch-up replay to have the disk
    /// to themselves; short enough that a session left open still gets swept.
    public static let firstRunDelay: Duration = .seconds(10)

    private let store: any MaintenanceSweeping
    private let search: (any SearchService)?
    private let now: @Sendable () -> Date
    private let interval: TimeInterval
    private var isRunning = false
    private var schedule: Task<Void, Never>?
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-maintenance")

    public init(store: any MaintenanceSweeping, search: (any SearchService)?,
                now: @escaping @Sendable () -> Date = { Date() },
                interval: TimeInterval = JournalMaintenance.interval) {
        self.store = store
        self.search = search
        self.now = now
        self.interval = interval
    }

    /// Arms the first run and the hourly cadence. Idempotent.
    public func start() {
        guard schedule == nil else { return }
        schedule = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.firstRunDelay)
            if Task.isCancelled { return }
            await self?.runIfDue()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                if Task.isCancelled { return }
                await self?.runIfDue()
            }
        }
    }

    public func stop() {
        schedule?.cancel()
        schedule = nil
    }

    /// Sweeps when the stored `maintenance_last_run` is older than
    /// `interval` (or absent). Every trigger — the 10 s first run, the
    /// hourly tick, the sync engine's first catch-up, and app foreground —
    /// funnels through here, so "whichever comes first" needs no extra
    /// state: the first caller does the work and the rest are no-ops.
    public func runIfDue(now overrideNow: Date? = nil) async {
        let current = overrideNow ?? now()
        guard !isRunning else { return }
        if let last = try? store.maintenanceLastRun(),
           let last, current.timeIntervalSince(last) < interval { return }
        isRunning = true
        defer { isRunning = false }
        do {
            try store.purgeExpiredToolOutputSnippets(now: current)
            let retired = try store.applyRetention(now: current)
            if let search, !retired.isEmpty {
                // Search rows are keyed by `String(seq)` by every feeder
                // (JournalSyncEngine.indexForSearch), so the seqs the
                // retention sweep returns ARE the index's event ids.
                try await search.removeAll(eventIDs: retired.map(String.init))
            }
            try store.recordMaintenanceRun(at: current)
            Self.logger.info("maintenance pass done; retired \(retired.count, privacy: .public) bodies")
        } catch {
            // No stamp on failure: the next tick retries immediately rather
            // than waiting out the hour.
            Self.logger.error("maintenance pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 4: Run the scheduler tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalMaintenanceTests`
Expected: PASS — `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Take the sweep out of `JournalStore.init` and hook the engine**

In `MatronShared/Sources/Journal/JournalStore.swift`, delete the whole boot-time sweep block from `init` — the comment starting `// Boot-time TTL sweep, mirroring the server's expire-logs job` through the closing brace of its `do { … } catch { … }` — leaving:

```swift
        try Self.migrator().migrate(dbQueue)
    }
```

In `MatronShared/Sources/Journal/JournalSyncEngine.swift`, add the stored property beside `backfill`:

```swift
    /// Background store housekeeping for this session. Attached after
    /// construction (it is built from the same store) and poked when the
    /// first catch-up reaches the live cursor — the "whichever comes first"
    /// half of the first-run rule, with `JournalMaintenance.start()`'s 10 s
    /// timer as the other half.
    private var maintenance: JournalMaintenance?

    public func attachMaintenance(_ sweeper: JournalMaintenance) {
        guard maintenance == nil else { return }
        maintenance = sweeper
    }
```

and in `setState(_:)`:

```swift
    private func setState(_ new: SyncConnectionState) {
        guard new != state else { return }
        state = new
        for continuation in stateContinuations.values { continuation.yield(new) }
        if case .running = new {
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
            // Caught up with the live cursor: the disk is free again, so the
            // sweeper may run. `runIfDue` is watermark-gated, so the
            // reconnects that also land here cost one `meta` read.
            if let maintenance {
                Task(priority: .utility) { await maintenance.runIfDue() }
            }
        }
    }
```

- [ ] **Step 6: Wire both apps**

In `Matron/App/AppDependencies.swift` — and then the identical edit in `MatronMac/App/AppDependencies.swift`:

In `JournalCore`, after `backfillTask`:

```swift
        /// Background store housekeeping (TTL + retention sweeps and the
        /// matching search removal). Replaces the sweep `JournalStore.init`
        /// used to run on the launch path.
        let maintenance: JournalMaintenance
        /// Handle for the `maintenance.start()` kickoff — awaited before
        /// `stop()` in the sign-out teardown, same rule as `itemsStartTask`.
        var maintenanceStartTask: Task<Void, Never>?
```

and in its `init`, add the parameter `maintenance: JournalMaintenance` and `self.maintenance = maintenance`.

In `core(for:)`, after the `missions` line and before `let core = JournalCore(…)`:

```swift
        let maintenance = JournalMaintenance(store: store, search: search)
```

pass it into the `JournalCore(…)` call, and after `core.backfillTask = …`:

```swift
        core.maintenanceStartTask = Task {
            await engine.attachMaintenance(maintenance)
            await maintenance.start()
        }
```

Add the accessor next to `journalStore(for:)`:

```swift
    /// The session's background sweeper — the app-foreground trigger calls
    /// `runIfDue()` on it.
    func journalMaintenance(for session: UserSession) -> JournalMaintenance {
        core(for: session).maintenance
    }
```

In the sign-out teardown, immediately after the two `core.backfillTask` lines:

```swift
                // Await the start kickoff BEFORE stop(), same rule as the
                // items sync: a not-yet-run start could otherwise arm the
                // hourly timer after teardown and sweep a wiped store.
                await core.maintenanceStartTask?.value
                await core.maintenance.stop()
```

In `Matron/App/MatronApp.swift`, inside the existing `.onChange(of: scenePhase)` `if phase == .active` branch, after the `nudge()` line:

```swift
                            // Foreground sweep (spec §3.4): a process that
                            // has been backgrounded past the hour sweeps now
                            // rather than waiting out the in-process timer,
                            // which does not tick while suspended.
                            Task(priority: .utility) {
                                await dependencies.journalMaintenance(for: session).runIfDue()
                            }
```

In `MatronMac/App/MatronMacApp.swift`, inside the existing `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))` closure, after the `nudge()` line:

```swift
                        Task(priority: .utility) {
                            await dependencies.journalMaintenance(for: session).runIfDue()
                        }
```

- [ ] **Step 7: Run everything**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`.

Run: `xcodegen generate`
Expected: `Created project at …/Matron.xcodeproj` (no file was added under the app targets; this is the safety step).

Run:
```bash
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: PASS — `Executed N tests, with 0 failures`.

Run:
```bash
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 \
  MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO
```
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add MatronShared/Sources/Journal/JournalMaintenance.swift \
        MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Sources/Journal/JournalSyncEngine.swift \
        MatronShared/Tests/JournalTests/JournalMaintenanceTests.swift \
        Matron/App/AppDependencies.swift Matron/App/MatronApp.swift \
        MatronMac/App/AppDependencies.swift MatronMac/App/MatronMacApp.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "journal: JournalMaintenance sweeps in the background; store open stops sweeping" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: An expired diff says so

**Files:**
- Modify: `MatronShared/Sources/Events/DiffEvent.swift`
- Modify: `MatronShared/Sources/DesignSystem/DiffCard.swift`
- Test: `MatronShared/Tests/EventsTests/DiffEventTests.swift`, `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/DiffCardSnapshotTests.swift`

**Interfaces:**
- Produces: `DiffEvent.expired: Bool` (defaulted `false` in the memberwise init, so every existing construction site compiles).
- Consumes: the `expired: true` key the retention sweep writes (Task 4).

The mapper's diff branch is `JournalTimelineMapper.swift:79-80` — `kind = .diff(eventID: String(event.seq), DiffEvent.parse(payload: payload))`. Both platforms' diff rows (`Matron/Features/Chat/Rendering/TimelineItemView.swift:278`, `MatronMac/Features/Chat/MacTimelineItemView.swift:248`) hand the same `DiffEvent` to the same shared `DiffCard`, so the flag belongs on the event and the copy belongs in the card: one change covers both rows, and neither per-platform file is touched.

- [ ] **Step 1: Write the failing tests**

Append to `MatronShared/Tests/EventsTests/DiffEventTests.swift`:

```swift
    /// Local retention (spec §3.4) strips `diff` and `snippet` and sets
    /// `expired: true`, keeping every other key so the card can still name
    /// the file. The parse must surface that as a flag, not as an empty diff
    /// indistinguishable from a header-only payload.
    func testParseCarriesTheExpiredFlagAndKeepsTheMetadata() {
        let event = DiffEvent.parse(payload: [
            "file_path": "/w/Sources/A.swift", "display_path": "Sources/A.swift",
            "tool": "Edit", "added": 2, "removed": 1, "new_file": false, "expired": true,
        ])
        XCTAssertTrue(event.expired)
        XCTAssertEqual(event.diff, "")
        XCTAssertEqual(event.filename, "A.swift")
        XCTAssertEqual(event.added, 2)
        XCTAssertEqual(event.removed, 1)
    }

    func testParseDefaultsExpiredToFalse() {
        XCTAssertFalse(DiffEvent.parse(payload: ["diff": "+ a"]).expired)
    }
```

Append to `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`:

```swift
    func testExpiredDiffMapsToAFlaggedDiffItem() {
        let event = JournalEvent(
            seq: 7, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:dev-2",
            type: JournalEventType.diff,
            payloadData: try! JSONSerialization.data(withJSONObject: [
                "file_path": "/w/Sources/A.swift", "added": 2, "removed": 1, "expired": true,
            ] as [String: Any]))
        let item = JournalTimelineMapper.item(from: event, ownSender: "user:dan")
        guard case .diff(_, let diff) = item.kind else {
            return XCTFail("expected a diff item, got \(item.kind)")
        }
        XCTAssertTrue(diff.expired)
        XCTAssertEqual(diff.filename, "A.swift", "the row must still be able to name the file")
    }
```

> `JournalTimelineMapper.item(from:ownSender:)` is the mapper entry point the file's other tests already use — match whatever call they make (same function, same labels) rather than inventing one.

Append to `MatronShared/Tests/DesignSystemSnapshotTests/DiffCardSnapshotTests.swift`:

```swift
    func test_expired_showsTheNotStoredNotice() {
        let expired = DiffEvent(filePath: "/w/Sources/A.swift", displayPath: "Sources/A.swift",
                                viewerURL: nil, tool: "Edit", label: nil, diff: "",
                                added: 2, removed: 1, truncated: false, newFile: false,
                                expired: true)
        assertVariants(of: DiffCard(event: expired).frame(width: 420), named: "expired")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter DiffEventTests`
Expected: FAIL — `value of type 'DiffEvent' has no member 'expired'`.

- [ ] **Step 3: Add the flag to `DiffEvent`**

In `MatronShared/Sources/Events/DiffEvent.swift`, add the property after `newFile`:

```swift
    /// The body is gone from this device: either the server tombstoned the
    /// event or local retention did (30 days, `EventTombstone`). Every other
    /// field is still present, so the card renders its header and says the
    /// diff is no longer stored rather than showing an empty body.
    public let expired: Bool
```

add `expired: Bool = false` as the last parameter of the memberwise `init` and `self.expired = expired` in its body, and extend `parse`:

```swift
            truncated: payload["truncated"] as? Bool ?? false,
            newFile: payload["new_file"] as? Bool ?? false,
            expired: payload["expired"] as? Bool ?? false
```

- [ ] **Step 4: Render the notice**

In `MatronShared/Sources/DesignSystem/DiffCard.swift`, replace the body's `if !visible.isEmpty { … }` block's leading condition so the expired state wins:

```swift
        VStack(alignment: .leading, spacing: 8) {
            header
            if event.expired {
                // Local retention (spec §3.4) or a server tombstone: the
                // header still names the file and its counts, so the row
                // stays useful — only the body is gone. Same treatment
                // ToolCallCard already gives an expired tool output.
                Text("Diff no longer stored on this device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !visible.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
```

and guard the two trailing rows so an expired card cannot offer to expand nothing:

```swift
            if hidden > 0, !event.expired {
                Button { expanded = true } label: {
                    Text("+\(hidden) more line\(hidden == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if expanded && event.truncated && !event.expired {
```

- [ ] **Step 5: Run the non-snapshot tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "DiffEventTests|JournalTimelineMapperTests|DiffCardAccessibilityTests"`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 6: Record the snapshot baseline**

Run (no skip variable — this is the recording step): `swift test --package-path MatronShared --filter DiffCardSnapshotTests`
Expected: FAIL on the first pass, with new `__Snapshots__` PNGs written for `ios-expired-light`, `ios-expired-dark` (and the macOS variants when run on a Mac host, per `SnapshotVariants.swift`).

Run it again, unchanged.
Expected: PASS — `Executed N tests, with 0 failures`.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Events/DiffEvent.swift \
        MatronShared/Sources/DesignSystem/DiffCard.swift \
        MatronShared/Tests/EventsTests/DiffEventTests.swift \
        MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/DiffCardSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "chat: an expired diff says the body is no longer stored" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `LaunchTimeline` — the app can say what launch cost

**Files:**
- Create: `MatronShared/Sources/Models/LaunchTimeline.swift`
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (nested `migration` interval)
- Modify: `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift`
- Modify: `Matron/Features/ChatList/ChatListView.swift`, `MatronMac/Features/ChatList/MacChatListView.swift`
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift`
- Test: `MatronShared/Tests/JournalTests/LaunchTimelineTests.swift` (new)

**Interfaces:**
- Produces: `LaunchTimeline` (process-wide `shared`, plus an injectable initializer), `LaunchTimeline.Mark`, `LaunchRecord`, `LaunchTimeline.summary(_:)`, `LaunchTimeline.lastLaunch(defaults:)`.
- Consumed by: Task 9 (the Settings "Last launch" row).

`LaunchTimeline` lives in `MatronModels`, the leaf both `MatronJournal` and the two app targets already depend on — which is what lets `JournalStore.init` report its own migration interval without any new dependency edge. Its tests live in `JournalTests`, the only test target that links `MatronModels` alongside the store.

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/LaunchTimelineTests.swift`:

```swift
import XCTest
import MatronModels

/// Ordering, durations and persistence. Deliberately no signpost
/// assertions: `OSSignposter` has no read-back API, and the durations these
/// tests pin are the same numbers the signposts carry.
final class LaunchTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A timeline whose clock is a script: each read returns the next value,
    /// and the last value repeats.
    private func makeTimeline(_ offsets: [TimeInterval]) -> (LaunchTimeline, UserDefaults) {
        let defaults = UserDefaults(suiteName: "launch-timeline-\(UUID().uuidString)")!
        let box = Box(offsets.map { start.addingTimeInterval($0) })
        return (LaunchTimeline(defaults: defaults, processStart: start, clock: { box.next() }), defaults)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Date]
        init(_ values: [Date]) { self.values = values }
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            return values.count > 1 ? values.removeFirst() : values[0]
        }
    }

    func testDurationsAreStoreOpenElapsedAndTheRestLaunchRelative() {
        let (timeline, _) = makeTimeline([0.2, 2.1, 2.4, 6.1])
        timeline.beginStoreOpen()          // t = 0.2
        timeline.endStoreOpen()            // t = 2.1 → storeOpen 1.9
        timeline.mark(.firstListPaint)     // t = 2.4 → 2.4 since process start
        timeline.mark(.catchUpComplete)    // t = 6.1
        let record = timeline.record
        XCTAssertEqual(try XCTUnwrap(record.storeOpen), 1.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.firstListPaint), 2.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.catchUpComplete), 6.1, accuracy: 0.001)
        XCTAssertNil(record.migration, "no migration ran")
    }

    func testMigrationIsNestedInsideStoreOpen() {
        let (timeline, _) = makeTimeline([0.0, 0.1, 3.3, 3.5])
        timeline.beginStoreOpen()   // 0.0
        timeline.beginMigration()   // 0.1
        timeline.endMigration()     // 3.3 → migration 3.2
        timeline.endStoreOpen()     // 3.5 → storeOpen 3.5
        let record = timeline.record
        XCTAssertEqual(try XCTUnwrap(record.migration), 3.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.storeOpen), 3.5, accuracy: 0.001)
    }

    func testTheFirstMarkWins() {
        let (timeline, _) = makeTimeline([2.0, 9.0])
        timeline.mark(.firstListPaint)
        timeline.mark(.firstListPaint)
        XCTAssertEqual(try XCTUnwrap(timeline.record.firstListPaint), 2.0, accuracy: 0.001,
                       "a re-appearing list must not overwrite the launch number")
    }

    func testAnUnmatchedEndIsIgnored() {
        let (timeline, _) = makeTimeline([1.0])
        timeline.endStoreOpen()
        timeline.endMigration()
        XCTAssertNil(timeline.record.storeOpen)
        XCTAssertNil(timeline.record.migration)
    }

    func testTheRecordRoundTripsThroughUserDefaults() throws {
        let (timeline, defaults) = makeTimeline([0.0, 1.9, 2.4, 6.1])
        timeline.beginStoreOpen()
        timeline.endStoreOpen()
        timeline.mark(.firstListPaint)
        timeline.mark(.catchUpComplete)

        let restored = try XCTUnwrap(LaunchTimeline.lastLaunch(defaults: defaults))
        XCTAssertEqual(try XCTUnwrap(restored.storeOpen), 1.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(restored.catchUpComplete), 6.1, accuracy: 0.001)
        XCTAssertNotNil(defaults.data(forKey: "launch.last"), "the key the Settings row reads")
    }

    func testSummaryReadsLikeTheSpecExample() {
        let record = LaunchRecord(storeOpen: 1.9, migration: nil, firstListPaint: 2.4,
                                  catchUpComplete: 6.1, recordedAt: start)
        XCTAssertEqual(LaunchTimeline.summary(record),
                       "store 1.9 s · first list 2.4 s · catch-up 6.1 s")
    }

    func testSummaryAppendsMigrationWhenOneRan() {
        let record = LaunchRecord(storeOpen: 4.0, migration: 3.2, firstListPaint: 4.4,
                                  catchUpComplete: 8.0, recordedAt: start)
        XCTAssertEqual(LaunchTimeline.summary(record),
                       "store 4.0 s · first list 4.4 s · catch-up 8.0 s · migration 3.2 s")
    }

    func testSummaryOmitsMarksThatNeverLandedAndHandlesNoRecord() {
        let partial = LaunchRecord(storeOpen: 0.4, migration: nil, firstListPaint: nil,
                                   catchUpComplete: nil, recordedAt: start)
        XCTAssertEqual(LaunchTimeline.summary(partial), "store 0.4 s")
        XCTAssertEqual(LaunchTimeline.summary(nil), "—")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter LaunchTimelineTests`
Expected: FAIL — `cannot find 'LaunchTimeline' in scope`.

- [ ] **Step 3: Write `MatronShared/Sources/Models/LaunchTimeline.swift`**

```swift
import Foundation
import os

/// What the last launch cost, in seconds. `storeOpen` and `migration` are
/// durations; `firstListPaint` and `catchUpComplete` are measured from the
/// kernel's process start, so they are what the user actually waited.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public var storeOpen: TimeInterval?
    public var migration: TimeInterval?
    public var firstListPaint: TimeInterval?
    public var catchUpComplete: TimeInterval?
    public var recordedAt: Date

    public init(storeOpen: TimeInterval? = nil, migration: TimeInterval? = nil,
                firstListPaint: TimeInterval? = nil, catchUpComplete: TimeInterval? = nil,
                recordedAt: Date = Date()) {
        self.storeOpen = storeOpen
        self.migration = migration
        self.firstListPaint = firstListPaint
        self.catchUpComplete = catchUpComplete
        self.recordedAt = recordedAt
    }
}

/// Process-wide launch recorder: `OSSignposter` intervals for Instruments,
/// one `os.Logger` line per mark so `log show` / `devicectl` gives the
/// numbers on a phone without Instruments, and the whole record persisted to
/// `UserDefaults` so Settings › Storage can show the LAST launch (the
/// current one is not finished when the user opens Settings).
///
/// Before this existed there was no launch instrumentation anywhere in the
/// app, so which cost dominated on the phone was guesswork.
public final class LaunchTimeline: @unchecked Sendable {
    public enum Mark: String, Sendable, CaseIterable {
        case processStart, storeOpen, migration, firstListPaint, catchUpComplete
    }

    /// The `UserDefaults` key the Settings row reads.
    public static let defaultsKey = "launch.last"

    public static let shared = LaunchTimeline()

    private static let signposter = OSSignposter(
        subsystem: subsystem, category: "launch")
    private static let logger = os.Logger(subsystem: subsystem, category: "launch")

    private static var subsystem: String {
        #if os(macOS)
        "chat.matron.mac"
        #else
        "chat.matron"
        #endif
    }

    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let processStart: Date
    private let lock = NSLock()
    private var _record: LaunchRecord
    private var storeOpenBegan: Date?
    private var migrationBegan: Date?
    private var storeOpenSignpost: OSSignpostIntervalState?
    private var migrationSignpost: OSSignpostIntervalState?

    /// `processStart` defaults to the kernel's start time for this process,
    /// so every mark is launch-relative rather than relative to whenever the
    /// first Swift code happened to run.
    public init(defaults: UserDefaults = .standard,
                processStart: Date? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        self.processStart = processStart ?? Self.kernelProcessStart() ?? clock()
        self._record = LaunchRecord(recordedAt: self.processStart)
    }

    public var record: LaunchRecord {
        lock.lock(); defer { lock.unlock() }
        return _record
    }

    public func beginStoreOpen() {
        lock.lock()
        storeOpenBegan = clock()
        storeOpenSignpost = Self.signposter.beginInterval("storeOpen")
        lock.unlock()
    }

    public func endStoreOpen() {
        lock.lock()
        guard let began = storeOpenBegan else { lock.unlock(); return }
        let elapsed = clock().timeIntervalSince(began)
        _record.storeOpen = elapsed
        storeOpenBegan = nil
        if let state = storeOpenSignpost {
            Self.signposter.endInterval("storeOpen", state)
            storeOpenSignpost = nil
        }
        let snapshot = _record
        lock.unlock()
        persist(snapshot)
        Self.logger.info("launch storeOpen \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
    }

    public func beginMigration() {
        lock.lock()
        migrationBegan = clock()
        migrationSignpost = Self.signposter.beginInterval("migration")
        lock.unlock()
    }

    public func endMigration() {
        lock.lock()
        guard let began = migrationBegan else { lock.unlock(); return }
        let elapsed = clock().timeIntervalSince(began)
        _record.migration = elapsed
        migrationBegan = nil
        if let state = migrationSignpost {
            Self.signposter.endInterval("migration", state)
            migrationSignpost = nil
        }
        let snapshot = _record
        lock.unlock()
        persist(snapshot)
        Self.logger.info("launch migration \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
    }

    /// Records a point mark, launch-relative. First one wins: the chat list
    /// re-appears every time the user navigates back, and a reconnect
    /// re-reaches the live cursor — neither is "the launch".
    public func mark(_ mark: Mark) {
        lock.lock()
        let elapsed = clock().timeIntervalSince(processStart)
        switch mark {
        case .firstListPaint:
            guard _record.firstListPaint == nil else { lock.unlock(); return }
            _record.firstListPaint = elapsed
        case .catchUpComplete:
            guard _record.catchUpComplete == nil else { lock.unlock(); return }
            _record.catchUpComplete = elapsed
        case .processStart, .storeOpen, .migration:
            // Intervals, not point marks — see begin/end above.
            lock.unlock()
            return
        }
        let snapshot = _record
        lock.unlock()
        Self.signposter.emitEvent(.init(stringLiteral: mark.rawValue))
        persist(snapshot)
        Self.logger.info("launch \(mark.rawValue, privacy: .public) \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
    }

    private func persist(_ record: LaunchRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The previous (or, mid-launch, the current) launch's record.
    public static func lastLaunch(defaults: UserDefaults = .standard) -> LaunchRecord? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(LaunchRecord.self, from: data)
    }

    /// The Settings row's copy: `store 1.9 s · first list 2.4 s · catch-up
    /// 6.1 s`, with `· migration 3.2 s` appended on the one launch that ran
    /// one. Pure, so it is testable without a launch.
    public static func summary(_ record: LaunchRecord?) -> String {
        guard let record else { return "—" }
        var parts: [String] = []
        func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
        if let storeOpen = record.storeOpen { parts.append("store \(seconds(storeOpen))") }
        if let paint = record.firstListPaint { parts.append("first list \(seconds(paint))") }
        if let catchUp = record.catchUpComplete { parts.append("catch-up \(seconds(catchUp))") }
        if let migration = record.migration { parts.append("migration \(seconds(migration))") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Kernel process start time via `sysctl(KERN_PROC_PID)` — the same
    /// number Instruments anchors a launch on, and the only way to include
    /// the time before the first line of Swift ran.
    private static func kernelProcessStart() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }
}
```

- [ ] **Step 4: Run the timeline tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter LaunchTimelineTests`
Expected: PASS — `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Report the migration from inside `JournalStore.init`**

In `MatronShared/Sources/Journal/JournalStore.swift`, add `import MatronModels` if it is not already there, and replace `try Self.migrator().migrate(dbQueue)` with:

```swift
        // Migrations run synchronously here, before any caller can read the
        // store, so the one launch that runs v11 pays its index build and
        // backfill up front. Report it as a nested interval inside the
        // launch timeline's `storeOpen` so that cost is a number rather than
        // a guess — and so a later launch can be shown NOT to pay it.
        let migrator = Self.migrator()
        let applied = (try? dbQueue.read { try migrator.appliedIdentifiers($0) }) ?? []
        let hasPending = migrator.migrations.contains { !applied.contains($0) }
        if hasPending { LaunchTimeline.shared.beginMigration() }
        try migrator.migrate(dbQueue)
        if hasPending { LaunchTimeline.shared.endMigration() }
```

(An in-memory store — every `makeStore()` in the tests — always has pending migrations and so always marks one. That is harmless: `LaunchTimeline.shared` is not read by any test, and `LaunchTimelineTests` builds its own instance with its own `UserDefaults` suite.)

- [ ] **Step 6: Wire the three app marks**

`Matron/App/AppDependencies.swift`, in `core(for:)` — and the identical edit at `MatronMac/App/AppDependencies.swift`:

```swift
        let dbURL = journalDirectory.appendingPathComponent("\(session.userID).sqlite")
        LaunchTimeline.shared.beginStoreOpen()
        let store = try! JournalStore(databaseURL: dbURL, ownSender: "user:\(session.userID)")
        LaunchTimeline.shared.endStoreOpen()
```

`Matron/Features/ChatList/ChatListView.swift`, on `chatListContent` in `body` (the first modifier, before `.navigationTitle("Chats")`):

```swift
        chatListContent
        .onAppear { LaunchTimeline.shared.mark(.firstListPaint) }
        .navigationTitle("Chats")
```

`MatronMac/Features/ChatList/MacChatListView.swift`, on the `sidebarColumn` `VStack` (after its closing brace, alongside the other modifiers on that stack):

```swift
        .onAppear { LaunchTimeline.shared.mark(.firstListPaint) }
```

`MatronShared/Sources/Journal/JournalSyncEngine.swift`, in `setState(_:)`'s `.running` branch, beside the maintenance trigger added in Task 6:

```swift
        if case .running = new {
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
            // First time the replay reaches the live cursor — `mark` keeps
            // the first value, so later reconnects do not overwrite it.
            LaunchTimeline.shared.mark(.catchUpComplete)
            if let maintenance {
                Task(priority: .utility) { await maintenance.runIfDue() }
            }
        }
```

Add `import MatronModels` to `ChatListView.swift` / `MacChatListView.swift` / `JournalSyncEngine.swift` if they do not already import it.

- [ ] **Step 7: Run everything**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`.

Run: `xcodegen generate`, then:
```bash
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: PASS — `Executed N tests, with 0 failures`.

```bash
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 \
  MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO
```
Expected: PASS — `Executed N tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add MatronShared/Sources/Models/LaunchTimeline.swift \
        MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Sources/Journal/JournalSyncEngine.swift \
        MatronShared/Tests/JournalTests/LaunchTimelineTests.swift \
        Matron/App/AppDependencies.swift Matron/Features/ChatList/ChatListView.swift \
        MatronMac/App/AppDependencies.swift MatronMac/Features/ChatList/MacChatListView.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "diag: LaunchTimeline records store open, migration, first paint and catch-up" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `StoreDiagnostics` and the Settings › Storage section

**Files:**
- Create: `MatronShared/Sources/Journal/StoreDiagnostics.swift`
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (`databaseURL`, `rowCounts()`)
- Modify: `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift` (`searchStoreURL`)
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift`, `MatronMac/Features/Settings/MacDeviceSettingsView.swift`
- Test: `MatronShared/Tests/JournalTests/StoreDiagnosticsTests.swift` (new)

**Interfaces:**
- Produces: `StoreDiagnostics.Sizes` (`journalBytes`, `searchBytes`, `eventCount`, `conversationCount`, `lastMaintenance`), `StoreDiagnostics.sizes(store:searchURL:) async -> Sizes`, `StoreDiagnostics.byteText(_:)`, `StoreDiagnostics.countsText(events:conversations:)`, `StoreDiagnostics.lastMaintenanceText(_:now:)`; `JournalStore.databaseURL`, `JournalStore.rowCounts()`; `AppDependencies.searchStoreURL` on both platforms.
- Consumes: `LaunchTimeline.lastLaunch(defaults:)` / `summary(_:)` (Task 8), `JournalStore.maintenanceLastRun()` (Task 4).

- [ ] **Step 1: Write the failing test**

Create `MatronShared/Tests/JournalTests/StoreDiagnosticsTests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class StoreDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Formatters

    func testByteTextUsesTheSystemByteFormatter() {
        // ByteCountFormatter is locale- and unit-sensitive; pin the shape
        // rather than an exact string so this does not break on a machine
        // with different measurement settings.
        let text = StoreDiagnostics.byteText(440 * 1_000_000)
        XCTAssertTrue(text.contains("MB") || text.contains("GB"), "got \(text)")
        XCTAssertEqual(StoreDiagnostics.byteText(0), StoreDiagnostics.byteText(0))
    }

    func testCountsTextIsEventsThenConversations() {
        XCTAssertEqual(StoreDiagnostics.countsText(events: 457_102, conversations: 6_214),
                       "457,102 / 6,214")
    }

    func testLastMaintenanceTextIsRelativeAndHandlesNever() {
        XCTAssertEqual(StoreDiagnostics.lastMaintenanceText(nil, now: now), "Never")
        let text = StoreDiagnostics.lastMaintenanceText(now.addingTimeInterval(-3600), now: now)
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, "Never")
    }

    // MARK: sizes()

    func testSizesReadsBothFilesAndBothCounts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let journalURL = dir.appendingPathComponent("journal.sqlite")
        let searchURL = dir.appendingPathComponent("search.sqlite")

        let store = try JournalStore(databaseURL: journalURL, ownSender: "user:dan")
        for seq in 1...3 {
            try store.applyJournal(JournalEvent(
                seq: Int64(seq), convoID: seq == 3 ? "c2" : "c1",
                ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:dev-2",
                type: JournalEventType.text,
                payloadData: try JSONSerialization.data(withJSONObject: ["body": "hi"])),
                now: Date(timeIntervalSince1970: 10))
        }
        try store.recordMaintenanceRun(at: now)
        try Data(repeating: 7, count: 2048).write(to: searchURL)

        let sizes = await StoreDiagnostics.sizes(store: store, searchURL: searchURL)
        XCTAssertGreaterThan(sizes.journalBytes, 0, "the sqlite file (plus -wal/-shm) has a size")
        XCTAssertEqual(sizes.searchBytes, 2048)
        XCTAssertEqual(sizes.eventCount, 3)
        XCTAssertEqual(sizes.conversationCount, 2)
        XCTAssertEqual(sizes.lastMaintenance, now)
    }

    func testSizesReportsZeroForAnInMemoryStoreAndAMissingIndex() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let sizes = await StoreDiagnostics.sizes(
            store: store,
            searchURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/does-not-exist.sqlite"))
        XCTAssertEqual(sizes.journalBytes, 0, "an in-memory store has no file")
        XCTAssertEqual(sizes.searchBytes, 0)
        XCTAssertEqual(sizes.eventCount, 0)
        XCTAssertNil(sizes.lastMaintenance)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter StoreDiagnosticsTests`
Expected: FAIL — `cannot find 'StoreDiagnostics' in scope`.

- [ ] **Step 3: Expose the store's URL and row counts**

In `MatronShared/Sources/Journal/JournalStore.swift`, add the stored property next to `dbQueue`:

```swift
    /// Where this mirror lives, or `nil` for an in-memory store. Read by
    /// `StoreDiagnostics` for the Settings › Storage size row.
    public let databaseURL: URL?
```

and set it at the very top of `init`:

```swift
    public init(databaseURL: URL?, ownSender: String) throws {
        self.ownSender = ownSender
        self.databaseURL = databaseURL
```

Add the counts read beside `allConversationIDs()`:

```swift
    /// Row counts for the Settings › Storage section. Two `COUNT(*)`s, run
    /// on demand only — never on the launch path.
    public func rowCounts() throws -> (events: Int, conversations: Int) {
        try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0)
        }
    }
```

- [ ] **Step 4: Write `MatronShared/Sources/Journal/StoreDiagnostics.swift`**

```swift
import Foundation
import MatronModels

/// On-demand answers for Settings › Storage. Nothing here runs unless the
/// user opens that screen: the whole point of this work was to stop doing
/// store-sized reads on the launch path.
public enum StoreDiagnostics {
    public struct Sizes: Equatable, Sendable {
        /// `.sqlite` + `-wal` + `-shm` for the journal mirror.
        public let journalBytes: Int64
        /// The same three files for the FTS index.
        public let searchBytes: Int64
        public let eventCount: Int
        public let conversationCount: Int
        /// `meta.maintenance_last_run`, or `nil` when no sweep has finished
        /// on this device yet.
        public let lastMaintenance: Date?

        public init(journalBytes: Int64, searchBytes: Int64, eventCount: Int,
                    conversationCount: Int, lastMaintenance: Date?) {
            self.journalBytes = journalBytes
            self.searchBytes = searchBytes
            self.eventCount = eventCount
            self.conversationCount = conversationCount
            self.lastMaintenance = lastMaintenance
        }
    }

    /// Not `@MainActor`: this does file stats and two `COUNT(*)`s, and the
    /// caller is a SwiftUI `.task` that must not block a paint.
    public static func sizes(store: JournalStore, searchURL: URL?) async -> Sizes {
        let counts = (try? store.rowCounts()) ?? (events: 0, conversations: 0)
        return Sizes(
            journalBytes: fileGroupSize(store.databaseURL),
            searchBytes: fileGroupSize(searchURL),
            eventCount: counts.events,
            conversationCount: counts.conversations,
            lastMaintenance: try? store.maintenanceLastRun())
    }

    /// A SQLite database is three files in WAL mode; reporting only the main
    /// one understates a busy store by the whole write-ahead log.
    private static func fileGroupSize(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        return paths.reduce(into: Int64(0)) { total, path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return }
            total += size.int64Value
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    public static func byteText(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// `457,102 / 6,214` — the "Events / Conversations" row's value.
    public static func countsText(events: Int, conversations: Int) -> String {
        "\(events.formatted(.number.grouping(.automatic))) / \(conversations.formatted(.number.grouping(.automatic)))"
    }

    /// "Never", or a relative time like "1 hour ago".
    public static func lastMaintenanceText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
```

- [ ] **Step 5: Run the diagnostics tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter StoreDiagnosticsTests`
Expected: PASS — `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Expose the search index path from both `AppDependencies`**

`Matron/App/AppDependencies.swift`, next to `var journalStoreDirectory: URL { journalDirectory }`:

```swift
    /// Where the FTS index lives — the Settings › Storage size row's second
    /// file group. Optional on iOS because the App Group container is
    /// (`searchDatabaseURL` is resolved with a fallback, so this is only nil
    /// in a build that has neither).
    var searchStoreURL: URL? { searchDatabaseURL }
```

`MatronMac/App/AppDependencies.swift`, in the same place:

```swift
    /// Mirror of the iOS accessor. `searchDBPath` is non-optional on macOS.
    var searchStoreURL: URL? { StoragePaths.searchDBPath }
```

- [ ] **Step 7: Add the Storage section on iOS**

In `Matron/Features/Settings/DeviceSettingsView.swift`, add the state property beside the others:

```swift
    /// Filled by the `.task` below; `nil` while the read is in flight, which
    /// is what the spinner renders.
    @State private var storage: StoreDiagnostics.Sizes?
```

and insert the section immediately after the `if let deps { CoordinatorSettingRow(…) }` block and before the `Privacy` section:

```swift
            if let deps {
                Section("Storage") {
                    if let storage {
                        LabeledContent("Journal store", value: StoreDiagnostics.byteText(storage.journalBytes))
                        LabeledContent("Search index", value: StoreDiagnostics.byteText(storage.searchBytes))
                        LabeledContent("Events / Conversations",
                                       value: StoreDiagnostics.countsText(events: storage.eventCount,
                                                                          conversations: storage.conversationCount))
                        LabeledContent("Last launch", value: LaunchTimeline.summary(LaunchTimeline.lastLaunch()))
                        LabeledContent("Last maintenance",
                                       value: StoreDiagnostics.lastMaintenanceText(storage.lastMaintenance, now: Date()))
                    } else {
                        HStack {
                            Text("Journal store")
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .task {
                    // On demand only: two file stats and two COUNT(*)s, off
                    // the main actor, when the user opens this screen.
                    storage = await StoreDiagnostics.sizes(store: deps.journalStore(for: session),
                                                           searchURL: deps.searchStoreURL)
                }
            }
```

Add `import MatronJournal` / `import MatronModels` at the top if they are not already there (`MatronJournal` already is).

- [ ] **Step 8: Add the same section on Mac**

In `MatronMac/Features/Settings/MacDeviceSettingsView.swift`, add the same `@State private var storage: StoreDiagnostics.Sizes?` and insert the identical `if let deps { Section("Storage") { … } .task { … } }` block immediately after the `if let deps { MacCoordinatorSettingRow(…) }` block and before the `Appearance` section. The body is byte-for-byte the iOS one — `LabeledContent`, `ProgressView` and the two formatters all exist on both platforms. Add `import MatronJournal` and `import MatronModels` to the file's imports.

The Mac view has a fixed `.frame(width: 420, height: 640)`; bump it to `height: 760` so the new six rows do not push Sign Out out of the sheet.

- [ ] **Step 9: Run everything**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
Expected: PASS — `Executed N tests, with 0 failures`.

Run: `xcodegen generate`, then:
```bash
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```
Expected: PASS — `Executed N tests, with 0 failures`.

```bash
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 \
  MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO
```
Expected: PASS — `Executed N tests, with 0 failures`. If a `MacDeviceSettingsView` snapshot test exists and now differs, re-record it exactly as Task 7 Step 6 does (run without the skip variable twice) and include its `__Snapshots__` folder in the commit.

- [ ] **Step 10: Commit**

```bash
git add MatronShared/Sources/Journal/StoreDiagnostics.swift \
        MatronShared/Sources/Journal/JournalStore.swift \
        MatronShared/Tests/JournalTests/StoreDiagnosticsTests.swift \
        Matron/App/AppDependencies.swift Matron/Features/Settings/DeviceSettingsView.swift \
        MatronMac/App/AppDependencies.swift MatronMac/Features/Settings/MacDeviceSettingsView.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "settings: a Storage section with store sizes, last launch and last maintenance" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: End-to-end verification against a real store

No code. Run all of it before opening the PR — the point of this work is a number, and nothing so far has measured a real store.

- [ ] **Step 1: Full local suites**

```bash
MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared
xcodegen generate
xcodebuild test -project Matron.xcodeproj -scheme Matron \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 \
  MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport \
  xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO
```

Expected: three `Executed N tests, with 0 failures` lines. Read each count; do not pipe through `tail` or `grep`.

- [ ] **Step 2: Take a copy of the Mac live store**

Never point a test or an experiment at the live store — copy it first. The Mac app is sandboxed, so its real mirror is under its container:

```bash
LIVE="$HOME/Library/Containers/chat.matron.app/Data/Library/Application Support/chat.matron.app"
rm -rf /tmp/matron-upgrade-check
mkdir -p /tmp/matron-upgrade-check/journal-store
cp "$LIVE/journal-store/dan.sqlite" /tmp/matron-upgrade-check/journal-store/
cp "$LIVE/journal-store/dan.sqlite-wal" /tmp/matron-upgrade-check/journal-store/ 2>/dev/null || true
cp "$LIVE/journal-store/dan.sqlite-shm" /tmp/matron-upgrade-check/journal-store/ 2>/dev/null || true
# The session JSON rides along so the copy launches signed in rather than
# stopping at the login screen.
cp -R "$LIVE/sessions" /tmp/matron-upgrade-check/
cp "$LIVE/matron-search.sqlite" /tmp/matron-upgrade-check/ 2>/dev/null || true
ls -la /tmp/matron-upgrade-check/journal-store
```

Expected: `dan.sqlite` present, hundreds of MB. Confirm it is still at `v10` before the app touches it:

```bash
sqlite3 /tmp/matron-upgrade-check/journal-store/dan.sqlite \
  "SELECT identifier FROM grdb_migrations ORDER BY identifier;"
```

Expected: the list ends at `v9`/`v10` and does NOT contain `v11`.

- [ ] **Step 3: First launch after the upgrade — the migration is measured**

`MATRON_APP_SUPPORT_OVERRIDE` is DEBUG-gated in `StoragePaths`, so build and run the Debug binary:

```bash
xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Debug \
  -derivedDataPath /tmp/matron-upgrade-dd CODE_SIGNING_ALLOWED=NO build
MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-upgrade-check \
  /tmp/matron-upgrade-dd/Build/Products/Debug/MatronMac.app/Contents/MacOS/MatronMac
```

With the app up, in another shell:

```bash
log show --last 3m --info --style compact \
  --predicate 'subsystem == "chat.matron.mac" AND category == "launch"'
```

Expected: a `launch migration <seconds> s` line (2-4 s on the Mac copy, per the spec's estimate) followed by `launch storeOpen <seconds> s` whose value is larger than the migration's, then `launch firstListPaint …` and `launch catchUpComplete …`.

Confirm the migration actually landed:

```bash
sqlite3 /tmp/matron-upgrade-check/journal-store/dan.sqlite \
  "SELECT identifier FROM grdb_migrations WHERE identifier = 'v11';
   SELECT COUNT(*) FROM conversation WHERE last_message_type IS NOT NULL;
   SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'event_type_ts';"
```

Expected: `v11`, a non-zero conversation count, and `event_type_ts`.

Open **Settings (⌘,) › Storage** in the running app. Expected: a brief spinner, then Journal store and Search index sizes that match `du -h` on the two files, an Events / Conversations pair matching `SELECT COUNT(*)`, a **Last launch** row reading `store 4.1 s · first list 4.6 s · catch-up 9.2 s · migration 3.2 s` (your numbers, that shape, migration present), and **Last maintenance** reading `Never` if you check within ten seconds of launch, otherwise a relative time.

- [ ] **Step 4: The maintenance sweep runs off the launch path, once**

Still on the first launch:

```bash
log show --last 5m --info --style compact \
  --predicate 'subsystem == "chat.matron.mac" AND category == "journal-maintenance"'
```

Expected: exactly one `maintenance pass done; retired <N> bodies` line, at least ten seconds after launch, with a large `N` (the first retention pass over years of history). Confirm it moved the watermarks:

```bash
sqlite3 /tmp/matron-upgrade-check/journal-store/dan.sqlite \
  "SELECT key, value FROM meta WHERE key IN ('snippet_ttl_ts','retention_ts','maintenance_last_run');"
```

Expected: all three present.

- [ ] **Step 5: Second launch — no migration, and the sweep touches nothing**

Quit the app (⌘Q), wait a moment, and relaunch it with the same command. Then:

```bash
log show --last 2m --info --style compact \
  --predicate 'subsystem == "chat.matron.mac" AND category == "launch"'
```

Expected: `launch storeOpen` in the low milliseconds and **no `launch migration` line at all** — the one-off cost is genuinely one-off. Settings › Storage now shows a **Last launch** row with no `· migration` segment.

The maintenance sweep is watermark-gated at an hour, so the second launch's 10 s timer finds `maintenance_last_run` fresh and does nothing (no new `maintenance pass done` line). To prove the sweep itself is now incremental rather than just skipped, force one:

```bash
sqlite3 /tmp/matron-upgrade-check/journal-store/dan.sqlite \
  "DELETE FROM meta WHERE key = 'maintenance_last_run';"
```

Quit and relaunch, wait fifteen seconds, then re-read the maintenance log.

Expected: one `maintenance pass done; retired 0 bodies` — zero, because the watermarks from Step 4 are still in place and everything below them is already tombstoned. That zero is the whole design: the sweep is now proportional to what arrived since the last pass, not to the store.

- [ ] **Step 6: Spot-check the UI the retention sweep changed**

In the running app, scroll a conversation back past 30 days.

Expected: old tool-output cards show their command with no captured output (unchanged behaviour — they already rendered the server's tombstone that way), and old diff cards show their filename, counts and **"Diff no longer stored on this device"** in place of the body. Recent tool output and diffs are untouched. Search for a phrase you know appears only in a >30-day-old diff: no hit. Search for a phrase in a recent one: a hit.

- [ ] **Step 7: Clean up and hand over**

```bash
rm -rf /tmp/matron-upgrade-check /tmp/matron-upgrade-dd
```

Then open the PR. Note in its body the three numbers from Step 3 and the `retired 0 bodies` line from Step 5 — they are the evidence this work did what it set out to do.

---

## Self-review

### 1. Spec coverage

| Spec section / requirement | Task |
|---|---|
| §3.1 `v11`: `CREATE INDEX event_type_ts`, `conversation.last_message_type`, `conversation.expired_snippet` | 1 |
| §3.1 backfill: newest message-type row per conversation, `"$ " + command` for tool_output | 1 |
| §3.1 `meta` gains `snippet_ttl_ts` / `retention_ts` / `maintenance_last_run`, none written by the migration; `wipe()` resets them | 4 (written by the sweeps; `wipe()` reset pinned by `testWipeResetsBothWatermarksAndTheMaintenanceStamp`) |
| §3.2 `applyOne` maintains both columns | 3 |
| §3.2 `insertHistory` recomputes both columns per touched conversation | 3 |
| §3.2 insert-time tombstoning on both insert paths; one shared pure function `EventTombstone.apply` | 2 (function), 3 (both call sites) |
| §3.3 `applyReadTimeSnippetTTL` is column-only; `newestMessageSeq` and `SnippetTTLMemo` deleted with their tests; `conversationsStream()` tracks only `conversation` | 3 |
| §3.3 the purge stops rewriting `conversation.snippet`; `toolLogTTL` stays the single constant | 2 (constant), 3 (rewrite removed) |
| §3.4 sweep 1 `purgeExpiredToolOutputSnippets(now:)` — same name/signature, `snippet_ttl_ts` watermark, `event_type_ts` range scan | 4 |
| §3.4 sweep 2 `applyRetention(now:)` — `retention_ts` watermark, the tool_output and diff tombstone rules, returns the seqs | 2 (rules), 4 (sweep) |
| §3.4 sweep 3 search removal keyed by `String(seq)`, batched per sweep | 5 (`removeAll(eventIDs:)`), 6 (the call) |
| §3.4 chunks of 500 rows per write transaction | 4 |
| §3.4 scheduling: 10 s after engine start or first catch-up, hourly, foreground when stale, `.utility`, never main, failures logged and retried, nothing blocks store open | 6 |
| §3.4 feeders stop re-adding what retention removed — `searchableBody(now:)` in all three | 5 |
| §3.5 expired diff renders "Diff no longer stored on this device" on iOS and Mac | 7 |
| §3.6 `LaunchTimeline`: signposts, `processStart` via `sysctl`, `storeOpen` with nested `migration`, `firstListPaint`, `catchUpComplete`, one log line per mark, `UserDefaults` key `launch.last` | 8 |
| §3.6 `StoreDiagnostics.sizes()` — both file groups plus both counts, async, on demand | 9 |
| §3.6 Settings › Storage on both platforms, five row groups, `ByteCountFormatter`, spinner while loading | 9 |
| §3.7 store open stays synchronous; the sweep is what leaves `init` | 6 |
| §3.8 no VACUUM | Global Constraints (no task adds one) |
| §3.9 sequencing: v11 → B → A → D → maintenance → diff → timeline → diagnostics | Tasks 1-9, in that order, with Task 2 inserted before the write path because both insert paths depend on the pure function |
| §3.10 v11 migration test with `migrate(upTo: "v10")`; column maintenance; observation does not re-fire on an event rewrite; watermarks; retention keys, chunking, returned seqs; `EventTombstone` table test; `runIfDue` with an injected clock | 1, 3, 4, 2, 6 |
| §3.10 `SearchTests`: batch removal; `searchableBody(now:)` past the window; backfill skips them | 5 |
| §3.10 mapper: expired diff maps to the flagged item; app-target timeline tests | 7, 8 |
| §3.11 the v11 one-off cost is measured by the same PR's timeline; retention is destructive locally; search results shrink | 8 (measurement), 10 (both confirmed on a real store copy) |
| §4 decisions: 30 days, 200-character command stub, no VACUUM, retention-aligned search removal, diagnostics in Settings › Storage | 2, 4, 5, 9 |

**One deliberate scope note.** The spec's §3.6 table says `firstListPaint` is set by "the first `onAppear` of the conversations list (iOS `ChatListView`, Mac sidebar list)". On Mac the sidebar list is nested inside `MacChatListView`'s `sidebarColumn`, and the row-level `ForEach` has no single `onAppear` — the mark goes on the `sidebarColumn` stack, which appears once when the split view mounts. Same event, one hook instead of N.

### 2. Placeholder scan

Searched the plan for "TBD", "TODO", "implement later", "add error handling", "and so on", "similar to Task", "write tests for the above", "etc.", and for steps that describe an edit without showing it. None remain. Three places deliberately describe rather than reprint, and each names the exact file, the exact anchor and the exact replacement text:

- Task 3 Step 7 lists the six existing tests that need an explicit `now:` at their insert, naming each test and the value to pass, rather than reprinting six test bodies.
- Task 6 Step 6 says the `MatronMac/App/AppDependencies.swift` edit is identical to the iOS one; both files carry the "keep in sync" comment already and the inserted text is quoted in full once.
- Task 9 Step 8 says the Mac Storage section is byte-for-byte the iOS one; the block is quoted in full in Step 7, plus the one Mac-only difference (the sheet height).

Two places name an assumption the implementer must check against the tree rather than assume: `SearchServiceLive.integrityCheck()` (Task 5 Step 1, with the fallback spelled out) and the exact spelling of the mapper entry point in `JournalTimelineMapperTests` (Task 7 Step 1, "match whatever call the file's other tests make").

### 3. Type consistency

Every name used across a task boundary, checked against its definition:

- `EventTombstone.apply(to:type:ts:now:) -> [String: Any]?` — defined Task 2; called in Task 3 (`tombstonedForStorage`) and Task 4 (`sweepTombstones`). Same argument labels in all three.
- `EventTombstone.toolLogTTL` / `.retentionWindow` / `.commandStubLength` — Task 2; read in Task 3 (`applyReadTimeSnippetTTL`), Task 4 (both cutoffs), Task 5 (`searchableBody(now:)`). `JournalTimelineMapper.toolLogTTL` is an alias of the first, so the mapper's render-time guard cannot drift from the on-disk rule.
- `ConversationRecord.lastMessageType: String?` / `.expiredSnippet: String?` — Task 1; written in Tasks 1, 3 and 4, read in Task 3. Both optional `var`s, so the compiler-generated memberwise initializer keeps every existing construction site (including `applyOne`'s) compiling.
- `JournalStore.expiredSnippet(type:payload:)` and its `(type:payloadData:)` overload — Task 1; used by the v11 backfill (Task 1), `applyOne` (Task 3) and `newestMessageColumns` (Task 3).
- `JournalStore.newestMessageColumns(_:convoID:) -> (type: String?, expiredSnippet: String?)` — Task 3; used by `insertHistory` (Task 3) and `refreshLastMessageColumns` (Task 4). Tuple labels are identical at both call sites.
- `JournalStore.tombstonedForStorage(_:now:) -> JournalEvent` — Task 3; both insert paths.
- `JournalStore.applyJournal(_:now:)` / `applyJournalBatch(_:now:)` / `insertHistory(_:now:)` — Task 3. All three take `now: Date = Date()`, so `JournalSyncEngine`, `JournalTimelineService` and every existing test call site are unchanged; only the tests that need determinism pass it.
- `JournalStore.purgeExpiredToolOutputSnippets(now: Date = Date()) throws` — unchanged name and signature from today's code through Tasks 3 and 4, as the Global Constraints require.
- `JournalStore.applyRetention(now: Date = Date()) throws -> [Int64]` — Task 4; consumed by `JournalMaintenance` (Task 6) and by `MaintenanceSweeping` (Task 6), which declares it without the default — a defaulted parameter satisfies a protocol requirement that has none.
- `JournalStore.maintenanceLastRun() throws -> Date?` / `recordMaintenanceRun(at:) throws` — Task 4; used by `JournalMaintenance` (Task 6) and `StoreDiagnostics.sizes` (Task 9).
- `JournalStore.refreshLastMessageColumns(_:convoID:)` — Task 4; called only from `sweepTombstones`.
- `JournalStore.databaseURL: URL?` and `rowCounts() -> (events: Int, conversations: Int)` — Task 9; read only by `StoreDiagnostics.sizes`.
- `MaintenanceSweeping` — Task 6; its four requirements are exactly the four `JournalStore` methods listed above, which is why `extension JournalStore: MaintenanceSweeping {}` needs no body.
- `JournalMaintenance.init(store:search:now:interval:)`, `.start()`, `.stop()`, `.runIfDue(now:)` — Task 6; `runIfDue` is called from `JournalSyncEngine.setState` (Task 6), both app foreground hooks (Task 6) and its own timer, always with no argument in production and with an explicit `now:` in tests.
- `JournalSyncEngine.attachMaintenance(_:)` — Task 6; called once per session from each `AppDependencies.core(for:)`, guarded by the same "no-op once set" rule as `attachSearch`/`attachBackfillCoordinator`.
- `AppDependencies.journalMaintenance(for:) -> JournalMaintenance` and `AppDependencies.searchStoreURL: URL?` — Tasks 6 and 9; same names and shapes on both platforms, so the two copies of the Settings and foreground code are identical.
- `SearchService.removeAll(eventIDs: [String]) async throws` — Task 5; a protocol requirement with an extension default, overridden in `SearchServiceLive`; called by `JournalMaintenance` (Task 6) with `retired.map(String.init)`, which matches the `String(seq)` key every index feeder writes.
- `JournalEvent.searchableBody(now: Date = Date()) -> String?` — Task 5; replaces the property of the same name and is used at all three feeders (`JournalSyncEngine.indexForSearch`, `JournalSyncEngine.didApplyBatch`, `JournalTimelineService` backward pagination) plus `SearchBackfillCoordinator`.
- `SearchBackfillCoordinator.init(search:fetchPage:pageSize:throttle:now:)` — Task 5; the one production call site in each `AppDependencies.startBackfill` omits `now:` and takes the default.
- `DiffEvent.expired: Bool` — Task 7; produced by `DiffEvent.parse`, consumed by `DiffCard` and by the mapper test. Defaulted in the memberwise initializer, so `DiffCardSnapshotTests`, `DiffCardAccessibilityTests` and `DiffEventTests` compile unchanged except where they opt in.
- `LaunchTimeline.shared`, `.Mark` (`processStart`, `storeOpen`, `migration`, `firstListPaint`, `catchUpComplete`), `.beginStoreOpen()` / `.endStoreOpen()` / `.beginMigration()` / `.endMigration()` / `.mark(_:)`, `LaunchRecord`, `LaunchTimeline.summary(_:)`, `LaunchTimeline.lastLaunch(defaults:)` — Task 8; `beginMigration`/`endMigration` are called from `JournalStore.init` (Task 8), the store-open pair from both `AppDependencies` (Task 8), `.firstListPaint` from both list views (Task 8), `.catchUpComplete` from `JournalSyncEngine.setState` (Task 8), and `summary`/`lastLaunch` from both Settings views (Task 9).
- `StoreDiagnostics.Sizes` (`journalBytes`, `searchBytes`, `eventCount`, `conversationCount`, `lastMaintenance`), `StoreDiagnostics.sizes(store:searchURL:)`, `.byteText(_:)`, `.countsText(events:conversations:)`, `.lastMaintenanceText(_:now:)` — Task 9; the two Settings views read exactly these five properties and call exactly these three formatters.
- `meta` key strings — `"snippet_ttl_ts"`, `"retention_ts"`, `"maintenance_last_run"` — defined once as `JournalStore.snippetTTLWatermarkKey` / `.retentionWatermarkKey` / `.maintenanceLastRunKey` (Task 4) and spelled literally only in the tests that assert on raw SQL, which is deliberate: a test that used the constant could not catch a rename that silently orphans a shipped watermark.
- `UserDefaults` key `"launch.last"` — `LaunchTimeline.defaultsKey` (Task 8), spelled literally only in the persistence test, for the same reason.
