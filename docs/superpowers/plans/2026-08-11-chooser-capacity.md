# New Chat Chooser Capacity Implementation Plan (Apple)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each connected box's live-session count, all usage-limit lines, and logged-in account email on the New Chat machine-picker rows (Mac + iOS).

**Architecture:** `NewChatViewModel` fans `recent_folders` out to every connected agent when the roster loads, filling a `capacities` map and a folders cache as replies land. A new `BoxCapacity` value type owns the defensive parsing. Both sheets render the same row content from the map; percent-tint thresholds live in one shared helper.

**Tech Stack:** SwiftUI, `@Observable`, XCTest (SPM package `MatronShared` — run `swift test` from `MatronShared/`). Snapshot tests in `MatronMacTests` via xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-11-chooser-capacity-design.md`

## Global Constraints

- Every capacity key is optional wire-side; a malformed block degrades to nil/empty and must never fail the folders parse.
- Rows stay pickable at all times — capacity is display-only, never a gate.
- Percent tints: green < 50, orange < 80, red ≥ 80.
- `xcodegen generate` before any xcodebuild; Mac tests ONLY with `MATRON_APP_SUPPORT_OVERRIDE` set and `-only-testing:MatronMacTests`.
- SPM tests: `cd MatronShared && swift test --filter <Name>` must report "Executed N tests" — never trust a grep-piped pass.

---

### Task 1: `BoxCapacity` parsing

**Files:**
- Create: `MatronShared/Sources/ViewModels/BoxCapacity.swift`
- Test: `MatronShared/Tests/ViewModelTests/BoxCapacityTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–4):

```swift
public struct LimitLine: Equatable, Sendable, Identifiable {
    public var id: String        // bridge line id, unique per box in practice
    public let label: String
    public let percent: Int      // clamped 0...999
    public let resetsAt: Date?
    public init(id: String, label: String, percent: Int, resetsAt: Date?)
}
public struct BoxCapacity: Equatable, Sendable {
    public let liveSessions: Int?      // activity.live_sessions
    public let limitLines: [LimitLine] // limits.lines, bridge order
    public let accountEmail: String?   // account.email
    public init(liveSessions: Int?, limitLines: [LimitLine], accountEmail: String?)
    /// Parses the capacity blocks out of a recent_folders reply object.
    /// Never throws; every block degrades independently.
    public static func parse(replyObject: [String: Any]) -> BoxCapacity
    /// Compact reset caption: "resets 11:59 PM" if today (local calendar),
    /// else "resets Jul 15". Nil resetsAt → nil.
    public static func resetText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String?
}
```

- [ ] **Step 1: Write the failing tests** in `BoxCapacityTests.swift`:

```swift
import XCTest
@testable import MatronViewModels

final class BoxCapacityTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
    }

    func test_parse_fullBlock() {
        let c = BoxCapacity.parse(replyObject: obj(#"""
        {"folders":[],
         "activity":{"live_sessions":2,"last_hour":[{"path":"/w","sessions":1}]},
         "limits":{"as_of":1754900000000,"lines":[
            {"id":"session","label":"Current session","percent":39,"resets_at":"2026-08-11T23:59:00Z"},
            {"id":"week","label":"Current week (all models)","percent":66}]},
         "account":{"email":"pat@yearbook.com"}}
        """#))
        XCTAssertEqual(c.liveSessions, 2)
        XCTAssertEqual(c.limitLines.map(\.label), ["Current session", "Current week (all models)"])
        XCTAssertEqual(c.limitLines[0].percent, 39)
        XCTAssertNotNil(c.limitLines[0].resetsAt)
        XCTAssertNil(c.limitLines[1].resetsAt, "missing resets_at parses as nil")
        XCTAssertEqual(c.accountEmail, "pat@yearbook.com")
    }

    func test_parse_missingBlocks_degradeToEmpty() {
        let c = BoxCapacity.parse(replyObject: obj(#"{"folders":[]}"#))
        XCTAssertNil(c.liveSessions)
        XCTAssertEqual(c.limitLines, [])
        XCTAssertNil(c.accountEmail)
    }

    func test_parse_malformedEntries_dropLineNotBlock() {
        let c = BoxCapacity.parse(replyObject: obj(#"""
        {"limits":{"lines":[
            {"id":"ok","label":"Fine","percent":10},
            {"id":"bad","label":"No percent"},
            {"label":"No id","percent":5}]},
         "account":{"email":42},
         "activity":{"live_sessions":"two"}}
        """#))
        XCTAssertEqual(c.limitLines.map(\.id), ["ok"], "lines missing id/label/percent are dropped")
        XCTAssertNil(c.accountEmail, "non-string email → nil")
        XCTAssertNil(c.liveSessions, "non-numeric live_sessions → nil")
    }

    func test_parse_percentClamped() {
        let c = BoxCapacity.parse(replyObject: obj(#"{"limits":{"lines":[{"id":"a","label":"A","percent":-5},{"id":"b","label":"B","percent":5000}]}}"#))
        XCTAssertEqual(c.limitLines.map(\.percent), [0, 999])
    }

    func test_resetText_todayVsLater() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_754_900_000) // 2026-08-11 UTC
        let today = now.addingTimeInterval(2 * 3600)
        let nextWeek = now.addingTimeInterval(4 * 86_400)
        XCTAssertTrue(BoxCapacity.resetText(today, now: now, calendar: cal)!.hasPrefix("resets "))
        XCTAssertFalse(BoxCapacity.resetText(today, now: now, calendar: cal)!.contains("Aug"),
                       "same-day reset shows time only")
        XCTAssertTrue(BoxCapacity.resetText(nextWeek, now: now, calendar: cal)!.contains("Aug"),
                      "later reset shows the date")
        XCTAssertNil(BoxCapacity.resetText(nil))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd MatronShared && swift test --filter BoxCapacityTests 2>&1 | tail -5`
Expected: compile FAILURE (`BoxCapacity` not defined).

- [ ] **Step 3: Implement `BoxCapacity.swift`**

```swift
import Foundation

/// One usage-limit meter from a bridge's `limits.lines`
/// (spec: 2026-08-11-chooser-capacity-design.md).
public struct LimitLine: Equatable, Sendable, Identifiable {
    public var id: String
    public let label: String
    public let percent: Int
    public let resetsAt: Date?

    public init(id: String, label: String, percent: Int, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// The capacity blocks a bridge attaches to its `recent_folders` reply:
/// live-session count, usage-limit lines, logged-in account. Every block is
/// optional wire-side (an old bridge omits them all), so parsing degrades
/// per-block and can never fail the folders parse it rides along with.
public struct BoxCapacity: Equatable, Sendable {
    public let liveSessions: Int?
    public let limitLines: [LimitLine]
    public let accountEmail: String?

    public init(liveSessions: Int?, limitLines: [LimitLine], accountEmail: String?) {
        self.liveSessions = liveSessions
        self.limitLines = limitLines
        self.accountEmail = accountEmail
    }

    public static func parse(replyObject: [String: Any]) -> BoxCapacity {
        let activity = replyObject["activity"] as? [String: Any]
        let liveSessions = (activity?["live_sessions"] as? NSNumber)?.intValue

        let lines = ((replyObject["limits"] as? [String: Any])?["lines"] as? [[String: Any]]) ?? []
        let limitLines = lines.compactMap { line -> LimitLine? in
            guard let id = line["id"] as? String, !id.isEmpty,
                  let label = line["label"] as? String, !label.isEmpty,
                  let percent = (line["percent"] as? NSNumber)?.intValue else { return nil }
            let resetsAt = (line["resets_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            return LimitLine(id: id, label: label,
                             percent: min(max(percent, 0), 999), resetsAt: resetsAt)
        }

        let email = (replyObject["account"] as? [String: Any])?["email"] as? String
        return BoxCapacity(liveSessions: liveSessions, limitLines: limitLines,
                           accountEmail: (email?.isEmpty == false) ? email : nil)
    }

    public static func resetText(_ date: Date?, now: Date = Date(),
                                 calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Same-day resets read best as a clock time; anything later as a date.
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d"
        return "resets \(formatter.string(from: date))"
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd MatronShared && swift test --filter BoxCapacityTests 2>&1 | tail -5`
Expected: "Executed 5 tests, with 0 failures".

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/BoxCapacity.swift MatronShared/Tests/ViewModelTests/BoxCapacityTests.swift
git commit -m "feat(new-chat): parse the recent_folders capacity blocks"
```

---

### Task 2: Fan-out + caches in `NewChatViewModel`

**Files:**
- Modify: `MatronShared/Sources/ViewModels/NewChatViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/NewChatViewModelTests.swift`

**Interfaces:**
- Consumes: `BoxCapacity.parse(replyObject:)` (Task 1).
- Produces (used by Tasks 3–4):

```swift
public private(set) var capacities: [Int64: BoxCapacity]   // by agent device id
public private(set) var capacityPending: Set<Int64>        // fan-out in flight
```

Behaviour: `load()` starts the fan-out after setting `.agents(...)`; `select(agent:)` uses the cached folders when that box's fan-out reply already landed, else does the live RPC as today.

- [ ] **Step 1: Write the failing tests** (append to `NewChatViewModelTests`; the existing `FakeAgentRPCProvider` scripts one reply per method — extend it minimally with a per-device override):

```swift
// In FakeAgentRPCProvider, add:
//   var repliesByDevice: [Int64: RPCReply] = [:]   // recent_folders per device
// and in agentRequest(...), before the `replies[method]` lookup:
//   if method == "recent_folders", let scripted = repliesByDevice[agentDeviceID] { return scripted }

func test_load_fansOutToConnectedAgentsOnly() async {
    let fake = FakeAgentRPCProvider()
    fake.devicesResult = .success([
        agent(1, name: "a", connected: true),
        agent(2, name: "b", connected: true),
        agent(3, name: "c", connected: false),
    ])
    fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"account":{"email":"pat@yearbook.com"},"activity":{"live_sessions":2}}"#.utf8))
    fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
    let vm = NewChatViewModel(api: fake)
    await vm.load()
    await vm.capacityFanOutForTesting?.value
    let fanned = fake.requests.filter { $0.method == "recent_folders" }.map(\.agentDeviceID).sorted()
    XCTAssertEqual(fanned, [1, 2], "offline agents are never queried")
    XCTAssertEqual(vm.capacities[1]?.accountEmail, "pat@yearbook.com")
    XCTAssertEqual(vm.capacities[1]?.liveSessions, 2)
    XCTAssertEqual(vm.capacities[2], BoxCapacity(liveSessions: nil, limitLines: [], accountEmail: nil))
    XCTAssertTrue(vm.capacityPending.isEmpty)
}

func test_fanOut_oneFailingBoxDegradesAlone() async {
    let fake = FakeAgentRPCProvider()
    fake.devicesResult = .success([agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)])
    fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":1}}"#.utf8))
    fake.repliesByDevice[2] = .failure(code: "agent_unreachable", detail: nil)
    let vm = NewChatViewModel(api: fake)
    await vm.load()
    await vm.capacityFanOutForTesting?.value
    XCTAssertEqual(vm.capacities[1]?.liveSessions, 1)
    XCTAssertNil(vm.capacities[2], "failed box has no capacity entry")
    XCTAssertTrue(vm.capacityPending.isEmpty, "failure still clears pending")
}

func test_select_usesFannedFoldersWithoutSecondRPC() async {
    let fake = FakeAgentRPCProvider()
    let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
    fake.devicesResult = .success(agents)
    fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/w/app","last_used":100}]}"#.utf8))
    fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
    let vm = NewChatViewModel(api: fake)
    await vm.load()
    await vm.capacityFanOutForTesting?.value
    let callsBefore = fake.requests.filter { $0.method == "recent_folders" }.count
    await vm.select(agent: agents[0])
    XCTAssertEqual(vm.folders.map(\.path), ["/w/app"])
    XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, callsBefore,
                   "cached folder list — no second RPC")
}

func test_select_fallsBackToLiveRPCWhenFanOutFailed() async {
    let fake = FakeAgentRPCProvider()
    let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
    fake.devicesResult = .success(agents)
    fake.repliesByDevice[1] = .failure(code: "agent_unreachable", detail: nil)
    fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
    let vm = NewChatViewModel(api: fake)
    await vm.load()
    await vm.capacityFanOutForTesting?.value
    fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/late","last_used":1}]}"#.utf8))
    await vm.select(agent: agents[0])
    XCTAssertEqual(vm.folders.map(\.path), ["/late"], "live RPC fallback after failed fan-out")
}
```

Note: the single-connected-agent auto-skip path must NOT fan out (it goes straight to folders); the existing `test_load_singleConnectedAgent_skipsStraightToFolders` pins that no extra RPC fires — verify it still passes unmodified.

- [ ] **Step 2: Run to verify failure**

Run: `cd MatronShared && swift test --filter NewChatViewModelTests 2>&1 | tail -5`
Expected: compile FAILURE (`capacities`/`capacityFanOutForTesting` undefined).

- [ ] **Step 3: Implement** in `NewChatViewModel`:

```swift
    /// Per-box capacity blocks, filled by the roster fan-out as replies land.
    public private(set) var capacities: [Int64: BoxCapacity] = [:]
    /// Boxes whose fan-out reply hasn't landed yet ("Checking…" rows).
    public private(set) var capacityPending: Set<Int64> = []
    /// Folder lists learned by the fan-out, keyed by device — lets `select`
    /// skip the second RPC.
    private var folderCache: [Int64: [RecentFolder]] = [:]
    /// The in-flight fan-out task; tests await it for determinism.
    public private(set) var capacityFanOutForTesting: Task<Void, Never>?
```

In `load()`, after `phase = .agents(Self.sorted(agents))`:

```swift
                let connectedIDs = connected.map(\.id)
                capacityPending = Set(connectedIDs)
                capacityFanOutForTesting = Task { [weak self] in
                    await withTaskGroup(of: Void.self) { group in
                        for id in connectedIDs {
                            group.addTask { await self?.fetchCapacity(agentID: id) }
                        }
                    }
                }
```

New method (MainActor-isolated like the rest of the class):

```swift
    private func fetchCapacity(agentID: Int64) async {
        defer { capacityPending.remove(agentID) }
        guard let reply = try? await api.agentRequest(
            agentDeviceID: agentID, method: "recent_folders", paramsData: Data("{}".utf8)),
              case .ok(let resultData) = reply,
              let obj = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        else { return }
        capacities[agentID] = BoxCapacity.parse(replyObject: obj)
        folderCache[agentID] = Self.parseFolders(resultData)
    }
```

In `select(agent:)`, before the live RPC:

```swift
        if let cached = folderCache[agent.id] {
            folders = cached
            return
        }
```

Also refactor `parseFolders` so both paths share it (it already takes `Data` — keep as is; `fetchCapacity` calls it with `resultData`).

- [ ] **Step 4: Run the whole VM suite**

Run: `cd MatronShared && swift test --filter NewChatViewModelTests 2>&1 | tail -5`
Expected: "Executed N tests, with 0 failures" — all pre-existing tests (auto-skip, sort, degrade, start) still green.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/NewChatViewModel.swift MatronShared/Tests/ViewModelTests/NewChatViewModelTests.swift
git commit -m "feat(new-chat): fan recent_folders out to every connected box on sheet open"
```

---

### Task 3: Shared row content + percent tint helper

**Files:**
- Create: `MatronShared/Sources/DesignSystem/UsagePercentColor.swift`
- Create: `MatronShared/Sources/DesignSystem/AgentCapacityRowContent.swift`
- Test: `MatronShared/Tests/DesignSystemTests/UsagePercentColorTests.swift`

**Interfaces:**
- Consumes: `BoxCapacity`, `LimitLine` (Task 1); VM state (Task 2).
- Produces:

```swift
public enum UsagePercentColor {
    /// green < 50, orange < 80, red ≥ 80 — the /usage card idiom.
    public static func color(forPercent percent: Int) -> Color
}
/// The capacity lines under an agent's name in the New Chat chooser —
/// shared verbatim by the Mac and iOS sheets.
public struct AgentCapacityRowContent: View {
    public init(capacity: BoxCapacity?, pending: Bool)
}
```

- [ ] **Step 1: Write the failing tint test**

```swift
import XCTest
import SwiftUI
@testable import MatronDesignSystem

final class UsagePercentColorTests: XCTestCase {
    func test_thresholds() {
        XCTAssertEqual(UsagePercentColor.color(forPercent: 0), .green)
        XCTAssertEqual(UsagePercentColor.color(forPercent: 49), .green)
        XCTAssertEqual(UsagePercentColor.color(forPercent: 50), .orange)
        XCTAssertEqual(UsagePercentColor.color(forPercent: 79), .orange)
        XCTAssertEqual(UsagePercentColor.color(forPercent: 80), .red)
        XCTAssertEqual(UsagePercentColor.color(forPercent: 999), .red)
    }
}
```

(If `MatronDesignSystem` has no test target yet, add the test to whichever existing test target imports it — check `MatronShared/Package.swift` and follow its layout; create `DesignSystemTests` only if none exists.)

- [ ] **Step 2: Run to verify failure**

Run: `cd MatronShared && swift test --filter UsagePercentColorTests 2>&1 | tail -5`
Expected: compile FAILURE.

- [ ] **Step 3: Implement both files.** `UsagePercentColor.swift`:

```swift
import SwiftUI

/// Percent-meter tinting shared by every usage surface
/// (green under half, orange approaching, red at/over 80 — the same
/// thresholds the bridge's /usage card uses).
public enum UsagePercentColor {
    public static func color(forPercent percent: Int) -> Color {
        if percent < 50 { return .green }
        if percent < 80 { return .orange }
        return .red
    }
}
```

`AgentCapacityRowContent.swift` (module imports per package layout — `MatronViewModels` for `BoxCapacity`):

```swift
import SwiftUI
import MatronViewModels

/// The capacity block under an agent's name in the New Chat chooser:
/// active-session count and every usage-limit line, or a "Checking…"
/// placeholder while the fan-out reply is in flight. Shared by the Mac and
/// iOS sheets so the two choosers can't drift.
public struct AgentCapacityRowContent: View {
    let capacity: BoxCapacity?
    let pending: Bool

    public init(capacity: BoxCapacity?, pending: Bool) {
        self.capacity = capacity
        self.pending = pending
    }

    public var body: some View {
        if let capacity {
            VStack(alignment: .leading, spacing: 2) {
                if let live = capacity.liveSessions {
                    Text(live == 0 ? "No active sessions"
                         : "^[\(live) active session](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(capacity.limitLines) { line in
                    HStack(spacing: 4) {
                        Text(line.label)
                            .foregroundStyle(.secondary)
                        Text("\(line.percent)%")
                            .fontWeight(.medium)
                            .foregroundStyle(UsagePercentColor.color(forPercent: line.percent))
                        if let reset = BoxCapacity.resetText(line.resetsAt) {
                            Text("· \(reset)")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
            }
        } else if pending {
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd MatronShared && swift test --filter UsagePercentColorTests 2>&1 | tail -5`
Expected: "Executed 1 test, with 0 failures". Also `swift build` to confirm the view compiles.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem MatronShared/Tests
git commit -m "feat(new-chat): shared capacity row content + usage percent tints"
```

---

### Task 4: Wire the rows into both sheets

**Files:**
- Modify: `MatronMac/Features/ChatList/MacNewChatSheet.swift` (agentPicker rows, list frame at ~line 115)
- Modify: `Matron/Features/ChatList/NewChatSheet.swift` (agentPicker rows at ~line 83–108)

**Interfaces:**
- Consumes: `viewModel.capacities`, `viewModel.capacityPending` (Task 2), `AgentCapacityRowContent` (Task 3).

- [ ] **Step 1: Mac row.** In `MacNewChatSheet.agentPicker`, replace the row `VStack` body:

```swift
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name.isEmpty ? "Unnamed agent" : agent.name)
                                    .fontWeight(.medium)
                                    .foregroundStyle(agent.connected ? .primary : .secondary)
                                if let email = viewModel.capacities[agent.id]?.accountEmail {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Text(agent.connected
                                 ? "Connected"
                                 : "Offline · Last seen \(agent.lastSeenText())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if agent.connected {
                                AgentCapacityRowContent(
                                    capacity: viewModel.capacities[agent.id],
                                    pending: viewModel.capacityPending.contains(agent.id))
                            }
                        }
```

and relax the fixed list height: `.frame(height: 200)` → `.frame(minHeight: 200, maxHeight: 360)` (the sheet stays `width: 480`; the list scrolls beyond the cap).

Add `import MatronDesignSystem` if the file doesn't already have it (check the module the DesignSystem sources belong to — follow existing imports like `LiveOutputSession` users).

- [ ] **Step 2: iOS row.** Same insertion in `NewChatSheet.agentPicker`'s row `VStack` (after the Connected/Offline caption):

```swift
                            if agent.connected {
                                AgentCapacityRowContent(
                                    capacity: viewModel.capacities[agent.id],
                                    pending: viewModel.capacityPending.contains(agent.id))
                            }
```

and the email on the name line, same `HStack` treatment as the Mac.

- [ ] **Step 3: Build both platforms**

```bash
xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Debug build 2>&1 | tail -3
xcodebuild -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED twice.

- [ ] **Step 4: Commit**

```bash
git add MatronMac/Features/ChatList/MacNewChatSheet.swift Matron/Features/ChatList/NewChatSheet.swift
git commit -m "feat(new-chat): capacity + account rows in both machine pickers"
```

---

### Task 5: Mac snapshot test

**Files:**
- Test: `MatronMacTests/NewChatSheetCapacitySnapshotTests.swift` (follow the harness conventions of the existing `MatronMacTests/__Snapshots__`-producing tests, e.g. `MacSearchViewSnapshotTests`)

**Interfaces:**
- Consumes: `MacNewChatSheet` (Task 4) — but snapshot the picker CONTENT via a `NewChatViewModel` fed by the test fake, not the full sheet (the sheet's `.task` would fire live loads).

- [ ] **Step 1: Write the snapshot test.** Copy the setup idiom (snapshot strategy, appearance pinning, `MATRON_SKIP_SNAPSHOT_TESTS` guard) from the newest existing Mac snapshot test file, then render a fixed-state chooser: build the row content directly —

```swift
// Three rows, one VStack, 480pt wide:
//  1. full capacity (2 sessions, two limit lines 39%/85%, email)
//  2. connected, no capacity (old bridge)
//  3. offline
// Construct DeviceDTOs + a BoxCapacity literal; no VM, no async.
```

Use `AgentCapacityRowContent(capacity:pending:)` and the same name/caption stack as the sheet. Record on first run, verify the committed snapshot on the second.

- [ ] **Step 2: Run**

```bash
xcodegen generate
MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild -project Matron.xcodeproj -scheme MatronMac \
  -only-testing:MatronMacTests/NewChatSheetCapacitySnapshotTests test 2>&1 | grep -E "Executed|passed|failed" | tail -3
```

Expected: "Executed 1 test, with 0 failures" (after the record run).

- [ ] **Step 3: Commit**

```bash
git add MatronMacTests
git commit -m "test(new-chat): pin the capacity chooser rows in a Mac snapshot"
```
