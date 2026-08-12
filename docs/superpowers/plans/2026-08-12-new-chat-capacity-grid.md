# New Chat Adaptive Sheet + Usage Columns (Mac) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac New Chat sheet grows with the window and shows each box's usage as aligned columns instead of a stacked list.

**Architecture:** A pure `limitColumns(across:)` on `BoxCapacity` (MatronModels) computes the fleet-wide column set; `MacAgentPickerRow` renders fixed-width trailing cells inside the existing `List`; a pure `MacNewChatSheet.layout(for:)` maps the presenting window's size to a rigid sheet frame (Mac sheets ignore flexible frames).

**Tech Stack:** SwiftUI, XCTest, swift-snapshot-testing, xcodegen/xcodebuild for the Mac test bundle.

## Global Constraints

- Mac sheets adopt only RIGID content sizes — never use flexible/ideal frames for the sheet dimensions.
- NEVER run MatronMacTests without `MATRON_APP_SUPPORT_OVERRIDE` (pass as `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE` too — xcodebuild only forwards `TEST_RUNNER_*`); the test host once wiped the live journal store.
- Scope Mac test runs to `-only-testing:MatronMacTests` (unsigned XCUITest runner fails Gatekeeper locally).
- Run `xcodegen generate` after adding any file before an xcodebuild run.
- Assert the "Executed N tests" line on every test run — grep/tail pipelines have masked xcodebuild failures before.
- iOS `NewChatSheet` and `AgentCapacityRowContent` are untouched.

---

### Task 1: `LimitColumn` + `BoxCapacity.limitColumns(across:)`

**Files:**
- Modify: `MatronShared/Sources/Models/BoxCapacity.swift`
- Test: `MatronShared/Tests/ViewModelTests/BoxCapacityTests.swift`

**Interfaces:**
- Produces: `public struct LimitColumn: Equatable, Sendable, Identifiable { public let id: String; public let label: String }` and `public static func limitColumns(across capacities: [BoxCapacity]) -> [LimitColumn]` on `BoxCapacity`.

- [ ] **Step 1: Write the failing tests**

Append inside the class in `BoxCapacityTests.swift`:

```swift
    // MARK: limitColumns(across:)

    private func capacity(_ lines: [LimitLine]) -> BoxCapacity {
        BoxCapacity(liveSessions: nil, limitLines: lines, accountEmail: nil)
    }

    func test_limitColumns_unionInFirstEncounterOrder() {
        let a = capacity([
            LimitLine(id: "session", label: "Current session", percent: 10, resetsAt: nil),
            LimitLine(id: "week", label: "Current week (all models)", percent: 20, resetsAt: nil),
        ])
        let b = capacity([
            LimitLine(id: "session", label: "Session (renamed)", percent: 30, resetsAt: nil),
            LimitLine(id: "opus", label: "Current week (Opus)", percent: 40, resetsAt: nil),
        ])
        let columns = BoxCapacity.limitColumns(across: [a, b])
        XCTAssertEqual(columns.map(\.id), ["session", "week", "opus"])
        // Label comes from the first box that reported the line.
        XCTAssertEqual(columns.map(\.label),
                       ["Current session", "Current week (all models)", "Current week (Opus)"])
    }

    func test_limitColumns_duplicateIdsWithinOneBoxNotDuplicated() {
        let a = capacity([
            LimitLine(id: "session", label: "First", percent: 1, resetsAt: nil),
            LimitLine(id: "session", label: "Second", percent: 2, resetsAt: nil),
        ])
        XCTAssertEqual(BoxCapacity.limitColumns(across: [a]).map(\.label), ["First"])
    }

    func test_limitColumns_emptyInEmptyOut() {
        XCTAssertTrue(BoxCapacity.limitColumns(across: []).isEmpty)
        XCTAssertTrue(BoxCapacity.limitColumns(across: [capacity([])]).isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path MatronShared --filter BoxCapacityTests 2>&1 | grep -E "error:|Executed" | head -5`
Expected: compile FAILURE — `type 'BoxCapacity' has no member 'limitColumns'`.

- [ ] **Step 3: Implement**

In `BoxCapacity.swift`, add above `struct BoxCapacity`:

```swift
/// One fleet-wide usage column in the Mac New Chat chooser: the union of
/// every box's limit-line ids, so all rows align to the same columns even
/// when an individual bridge reports fewer lines.
public struct LimitColumn: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
```

and inside `BoxCapacity` (after `parse`):

```swift
    /// Union of limit lines across a fleet, in first-encounter order — the
    /// caller passes capacities in its display (sorted-agents) order, which
    /// keeps the result deterministic. The label is the first one seen for
    /// an id; bridges of one journal all derive labels the same way.
    public static func limitColumns(across capacities: [BoxCapacity]) -> [LimitColumn] {
        var seen = Set<String>()
        var columns: [LimitColumn] = []
        for capacity in capacities {
            for line in capacity.limitLines where seen.insert(line.id).inserted {
                columns.append(LimitColumn(id: line.id, label: line.label))
            }
        }
        return columns
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path MatronShared --filter BoxCapacityTests 2>&1 | grep -E "Executed" | head -1`
Expected: PASS, "Executed N tests, with 0 failures" where N = previous count + 3.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Models/BoxCapacity.swift MatronShared/Tests/ViewModelTests/BoxCapacityTests.swift
git commit -m "feat(models): fleet-wide limit columns for the New Chat chooser

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `MacNewChatSheet.layout(for:)`

**Files:**
- Modify: `MatronMac/Features/ChatList/MacNewChatSheet.swift`
- Create: `MatronMacTests/MacNewChatLayoutTests.swift`

**Interfaces:**
- Produces: `struct MacNewChatSheet.Layout: Equatable { let width: CGFloat; let listMaxHeight: CGFloat }` and `static func layout(for windowSize: CGSize?) -> Layout` (internal, on `MacNewChatSheet`).

- [ ] **Step 1: Write the failing tests**

Create `MatronMacTests/MacNewChatLayoutTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import MatronMac

/// Pins the New Chat sheet's rigid sizing rule: 70% of the window's width
/// (480…880) and 60% of its height (300…650) for the lists, with today's
/// exact dimensions when no window size is known (previews, tests).
final class MacNewChatLayoutTests: XCTestCase {
    func test_nilWindow_usesLegacyDimensions() {
        let layout = MacNewChatSheet.layout(for: nil)
        XCTAssertEqual(layout.width, 480)
        XCTAssertEqual(layout.listMaxHeight, 360)
    }

    func test_mediumWindow_scalesProportionally() {
        let layout = MacNewChatSheet.layout(for: CGSize(width: 900, height: 600))
        XCTAssertEqual(layout.width, 630)          // 0.7 × 900
        XCTAssertEqual(layout.listMaxHeight, 360)  // 0.6 × 600
    }

    func test_largeWindow_clampsToCeilings() {
        let layout = MacNewChatSheet.layout(for: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(layout.width, 880)
        XCTAssertEqual(layout.listMaxHeight, 650)
    }

    func test_tinyWindow_clampsToFloors() {
        let layout = MacNewChatSheet.layout(for: CGSize(width: 500, height: 400))
        XCTAssertEqual(layout.width, 480)
        XCTAssertEqual(layout.listMaxHeight, 300)
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project and run to verify failure**

```bash
xcodegen generate
TESTHOME=$(mktemp -d)
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests/MacNewChatLayoutTests \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE="$TESTHOME" \
  TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 2>&1 | grep -E "error:|Executed|TEST" | head -10
```
Expected: compile FAILURE — `type 'MacNewChatSheet' has no member 'layout'`.

- [ ] **Step 3: Implement**

In `MacNewChatSheet.swift`, add inside `struct MacNewChatSheet` (below the `@State` block):

```swift
    /// Rigid sheet dimensions — Mac sheets ignore flexible frames, so the
    /// size is computed once from the presenting window and frozen.
    struct Layout: Equatable {
        let width: CGFloat
        let listMaxHeight: CGFloat
    }

    /// 70% of the window's width (480…880); lists get 60% of its height
    /// (300…650). nil (previews/tests/no window) → the pre-adaptive sizes.
    static func layout(for windowSize: CGSize?) -> Layout {
        guard let windowSize else { return Layout(width: 480, listMaxHeight: 360) }
        return Layout(
            width: min(max(windowSize.width * 0.7, 480), 880),
            listMaxHeight: min(max(windowSize.height * 0.6, 300), 650))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Re-run the Step 2 command (skip `xcodegen generate` — no files added).
Expected: "Executed 4 tests, with 0 failures" and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/ChatList/MacNewChatSheet.swift MatronMacTests/MacNewChatLayoutTests.swift
git commit -m "feat(mac): rigid adaptive layout rule for the New Chat sheet

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Column cells, header, adaptive frames

**Files:**
- Modify: `MatronMac/Features/ChatList/MacNewChatSheet.swift`
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift:287` (pass window size)
- Test: `MatronMacTests/NewChatSheetCapacitySnapshotTests.swift` (rewrite + re-record baselines)

**Interfaces:**
- Consumes: `BoxCapacity.limitColumns(across:)`, `LimitColumn` (Task 1), `MacNewChatSheet.layout(for:)` (Task 2), `UsageMetersFormat.barColor(percent:)` (existing, public).
- Produces: `MacAgentPickerRow(agent:capacity:pending:columns:fixedNow:)` (adds `columns: [LimitColumn]`), `MacAgentPickerHeader(columns:)` (new, internal), `MacNewChatSheet.init(deps:session:windowSize:onCreated:)` (adds `windowSize: CGSize? = nil`).

- [ ] **Step 1: Rewrite the snapshot test for the new row shape**

Replace the body of `testAgentPickerRowStates` in `NewChatSheetCapacitySnapshotTests.swift` (keep `now` and the `agent(...)` helper):

```swift
    @MainActor
    func testAgentPickerRowStates() {
        let full = BoxCapacity(
            liveSessions: 2,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 39,
                          resetsAt: now.addingTimeInterval(10 * 3600)),
                LimitLine(id: "week", label: "Current week (all models)", percent: 85,
                          resetsAt: now.addingTimeInterval(4 * 86_400)),
            ],
            accountEmail: "pat@yearbook.com")
        // Reports only one of the fleet's two lines — its other cell is "—".
        let partial = BoxCapacity(
            liveSessions: 0,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 92,
                          resetsAt: now.addingTimeInterval(2 * 3600)),
            ],
            accountEmail: nil)
        let columns = BoxCapacity.limitColumns(across: [full, partial])

        let view = VStack(alignment: .leading, spacing: 10) {
            MacAgentPickerHeader(columns: columns)
            // 1. Everything the bridge can send.
            MacAgentPickerRow(agent: agent(1, "studio-mac", connected: true),
                              capacity: full, pending: false, columns: columns, fixedNow: now)
            // 2. Missing one fleet column → em-dash cell.
            MacAgentPickerRow(agent: agent(2, "build-7", connected: true),
                              capacity: partial, pending: false, columns: columns, fixedNow: now)
            // 3. Connected, capacity still in flight.
            MacAgentPickerRow(agent: agent(3, "dev-2", connected: true),
                              capacity: nil, pending: true, columns: columns, fixedNow: now)
            // 4. Connected box on an old bridge — no capacity blocks at all.
            MacAgentPickerRow(agent: agent(4, "old-bridge", connected: true),
                              capacity: nil, pending: false, columns: columns, fixedNow: now)
            // 5. Offline: em-dash cells, caption unchanged.
            MacAgentPickerRow(agent: agent(5, "sleeping-box", connected: false),
                              capacity: nil, pending: false, columns: columns, fixedNow: now)
        }
        .padding(12)
        .frame(width: 700)
        // Opaque, appearance-derived backdrop: `NSHostingView` has no window
        // here, so label colors resolve against the host app's appearance
        // while the snapshot canvas stays transparent — without this the
        // secondary/primary text records as invisible pixels.
        .background(Color(nsColor: .windowBackgroundColor))

        assertVariants(of: view, named: "MacNewChatAgentRows_states")
    }
```

- [ ] **Step 2: Rewrite `MacAgentPickerRow` and add the header**

In `MacNewChatSheet.swift`, replace the whole `MacAgentPickerRow` struct with:

```swift
/// One machine row in the New Chat picker: the flexible box cell (icon,
/// name + account email, connection caption) followed by fixed-width data
/// cells — sessions, then one cell per fleet-wide usage column — so every
/// row aligns under `MacAgentPickerHeader`. Split out of the sheet so a
/// snapshot test can pin the real row against fixed state (the sheet
/// itself would fire a live `.task` load).
struct MacAgentPickerRow: View {
    let agent: DeviceDTO
    let capacity: BoxCapacity?
    let pending: Bool
    /// Fleet-wide column set — same array for every row in the list.
    let columns: [LimitColumn]
    /// Frozen clock for the reset captions; nil = now.
    var fixedNow: Date?

    /// Cell width contract shared with `MacAgentPickerHeader`.
    static let sessionsCellWidth: CGFloat = 64
    static let limitCellWidth: CGFloat = 108
    static let chevronGutter: CGFloat = 12

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name.isEmpty ? "Unnamed agent" : agent.name)
                        .fontWeight(.medium)
                        .foregroundStyle(agent.connected ? .primary : .secondary)
                    if let email = capacity?.accountEmail {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sessionsCell
            ForEach(columns) { column in
                limitCell(column)
            }
            Group {
                if agent.connected {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: Self.chevronGutter)
        }
    }

    /// "…" while the fan-out is in flight on a connected box; "—" for
    /// offline boxes and old bridges that sent no capacity blocks.
    private var placeholderText: String {
        pending && agent.connected ? "…" : "—"
    }

    private var sessionsCell: some View {
        Group {
            if let live = capacity?.liveSessions {
                Text("\(live)")
                    .fontWeight(.medium)
                    .monospacedDigit()
            } else {
                Text(placeholderText).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .frame(width: Self.sessionsCellWidth, alignment: .trailing)
        .accessibilityLabel(sessionsAccessibilityLabel)
    }

    private var sessionsAccessibilityLabel: String {
        guard let live = capacity?.liveSessions else { return "Sessions unknown" }
        switch live {
        case ...0: return "No active sessions"
        case 1: return "1 active session"
        default: return "\(live) active sessions"
        }
    }

    private func limitCell(_ column: LimitColumn) -> some View {
        let line = capacity?.limitLines.first { $0.id == column.id }
        let reset = line.flatMap { BoxCapacity.resetText($0.resetsAt, now: fixedNow ?? Date()) }
        return VStack(alignment: .trailing, spacing: 1) {
            if let line {
                Text("\(line.percent)%")
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(UsageMetersFormat.barColor(percent: line.percent))
                if let reset {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(placeholderText).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .frame(width: Self.limitCellWidth, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            line.map { "\(column.label), \($0.percent) percent used" + (reset.map { ", \($0)" } ?? "") }
                ?? "\(column.label), no data")
    }
}

/// Column captions above the machine list, width-matched to the row cells.
/// Rendered outside the `List` so it never scrolls away.
struct MacAgentPickerHeader: View {
    let columns: [LimitColumn]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text("Machine")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions")
                .frame(width: MacAgentPickerRow.sessionsCellWidth, alignment: .trailing)
            ForEach(columns) { column in
                Text(column.label)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .frame(width: MacAgentPickerRow.limitCellWidth, alignment: .trailing)
            }
            Color.clear.frame(width: MacAgentPickerRow.chevronGutter, height: 1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .accessibilityHidden(true)
    }
}
```

Note: the stacked `AgentCapacityRowContent` import/usage disappears from the Mac row — it remains in the iOS sheet.

- [ ] **Step 3: Wire the sheet — columns, header, adaptive frames, window size**

In `MacNewChatSheet.swift`:

a) Add the stored layout + new init parameter (replace the existing `init`):

```swift
    private let layout: Layout

    init(deps: AppDependencies, session: UserSession, windowSize: CGSize? = nil,
         onCreated: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onCreated = onCreated
        self.layout = Self.layout(for: windowSize)
        _viewModel = State(initialValue: NewChatViewModel(api: deps.agentRPCService(for: session)))
    }
```

b) `body`: change `.frame(width: 480)` → `.frame(width: layout.width)`.

c) In `agentPicker(_:)`, replace the `List(agents) { ... }` block and its `.frame(minHeight: 200, maxHeight: 360)` with:

```swift
            let columns = BoxCapacity.limitColumns(
                across: agents.compactMap { viewModel.capacities[$0.id] })
            // Header only when there is anything to head — a fleet of old
            // bridges keeps today's plain, headerless picker.
            if !viewModel.capacities.isEmpty || !viewModel.capacityPending.isEmpty {
                MacAgentPickerHeader(columns: columns)
            }
            List(agents) { agent in
                Button {
                    Task { await viewModel.select(agent: agent) }
                } label: {
                    MacAgentPickerRow(
                        agent: agent,
                        capacity: viewModel.capacities[agent.id],
                        pending: viewModel.capacityPending.contains(agent.id),
                        columns: columns)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!agent.connected)
            }
            .listStyle(.inset)
            // Capacity makes the rows variable-height: grow with them up to
            // the window-derived cap, then scroll.
            .frame(minHeight: 200, maxHeight: layout.listMaxHeight)
```

(`import MatronModels` is already present in the file — `BoxCapacity` and `LimitColumn` come from there.)

d) In `folderPicker(_:)`, change the folder `List`'s `.frame(height: 160)` → `.frame(minHeight: 160, maxHeight: layout.listMaxHeight)`.

e) In `MacChatListView.swift:287`, pass the window size:

```swift
                MacNewChatSheet(deps: deps, session: session,
                                windowSize: NSApp.keyWindow?.contentLayoutRect.size) { convoID in
```

- [ ] **Step 4: Re-record the chooser snapshots**

```bash
rm MatronMacTests/__Snapshots__/NewChatSheetCapacitySnapshotTests/*.png
TESTHOME=$(mktemp -d)
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests/NewChatSheetCapacitySnapshotTests \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE="$TESTHOME" 2>&1 | grep -E "Executed|recorded|error:" | head -8
```
Expected: FIRST run fails with "Automatically recorded snapshot" ×3; re-run the same command → "Executed 1 test, with 0 failures".

- [ ] **Step 5: Eyeball the baselines**

Read the three recorded PNGs under `MatronMacTests/__Snapshots__/NewChatSheetCapacitySnapshotTests/` — header labels aligned over cells, percents threshold-coloured, em-dash and ellipsis states distinct, offline row intact.

- [ ] **Step 6: Commit**

```bash
git add MatronMac/Features/ChatList/MacNewChatSheet.swift MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/NewChatSheetCapacitySnapshotTests.swift MatronMacTests/__Snapshots__/NewChatSheetCapacitySnapshotTests/
git commit -m "feat(mac): New Chat sheet sizes to the window; usage as columns

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Full sweep + PR

**Files:** none new.

- [ ] **Step 1: Shared package sweep**

Run: `swift test --package-path MatronShared 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 0 failures beyond the pre-existing `MessageBubbleSnapshotTests` drift (fails on main too — do NOT re-record it here).

- [ ] **Step 2: Mac unit-test sweep**

```bash
TESTHOME=$(mktemp -d)
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' \
  -only-testing:MatronMacTests \
  TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE="$TESTHOME" \
  TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 2>&1 | grep -E "Executed|TEST " | tail -4
```
Expected: `** TEST SUCCEEDED **` with a non-zero "Executed N tests" count. (Snapshot suites skipped — ours was verified in Task 3; MacSearchView baselines in the tree are another branch's untracked leftovers.)

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/new-chat-capacity-grid
gh pr create --repo Matronhq/matron-apple --base main --head feat/new-chat-capacity-grid \
  --title "Mac New Chat: size to the window, usage as columns" \
  --body "<summary of both changes, test evidence, spec link, Claude Code footer>"
```
