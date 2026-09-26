# iOS UIKit Chat Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iOS chat's SwiftUI `ScrollViewReader`/`ScrollView` timeline with a `UICollectionView` timeline whose text rows are TextKit 2 text views with exactly pre-measured, cached heights. The new timeline sits behind the `chat.timeline.uikit` flag, and the SwiftUI path and the Mac stay behaviourally untouched.

**Architecture:** `ChatTimelineController` is a `UIViewController` that `ChatView` hosts through `ChatTimelineView`, a `UIViewControllerRepresentable`. It reads the unchanged `ChatViewModel` API through `withObservationTracking` and maps `windowedRows` into value-typed `TimelineRowContent`. Every row is measured before it is applied, so nothing is estimated:
- Text rows use `TextRowRenderer`: the shared `MarkdownAttributed` renderer, now compiled for UIKit, plus a standalone TextKit 2 stack. This work runs off the main thread in batches.
- Hosted rows use `HostedSizer`, a reused `UIHostingController` on the main thread.
- Results are cached in `TimelineMeasureCache`.

A pure `TimelineScrollModel` owns the geometry: row tops, the bottom-hug pad, follow-tail, top-row anchoring, jumps and viewport resizes. The custom `TimelineLayout` only reads the model. The controller is the single writer of `contentOffset`: it writes it once, right after each layout invalidation.

**Tech Stack:** Swift 5.10 language mode, iOS 18 floor, UIKit (`UICollectionView`, diffable data source, `UITextView` on TextKit 2, `NSTextLayoutManager`), SwiftUI (`UIViewControllerRepresentable`, `UIHostingConfiguration`), Observation, XCTest in `MatronTests` / `MatronUITests` / `MatronShared` SPM tests, swift-snapshot-testing 1.17+, xcodegen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-09-26-ios-uikit-timeline-design.md` (approved by Dan; binding).

## Global Constraints

Brief constraints (verbatim):

- Never run MatronMacTests without a real env prefix: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/<dir> xcodebuild …`.
- Run `xcodegen generate` after adding files or folders.
- Commit with `git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit …`, never `git config`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never commit Matron/App/Info.plist.
- Use iPhone 17 simulators.
- Set MATRON_SKIP_SNAPSHOT_TESTS=1 when running locally, except when recording snapshots.

From the spec and the codebase:

- **Worktree:** `/Users/danbarker/Dev/matron-apple-uikittimeline`, branch `feat/ios-uikit-timeline`, based on `origin/main` 6ea49825. Every path below is relative to that worktree.
- **Flag:** `@AppStorage("chat.timeline.uikit")`.
  - On by default in Debug and TestFlight builds, off by default in App Store builds.
  - The toggle lives in Settings ▸ Advanced.
  - With the flag off, `ChatView` runs today's SwiftUI branch byte-for-byte.
- **Mac untouched:** no file under `MatronMac/` changes. Shared-module edits must not change Mac behaviour:
  - `MarkdownAttributed` is pinned by the fingerprint fixture from Task 2.
  - `ChatScrollPositionMemory` changes are additive only.
- **View model:** `ChatViewModel` behaviour and window values are unchanged in this plan: default 120, growth step 120, cap 360, entry window 40. Phase 2 (raising the cap) is out of scope.
- **What the new path must not use:**
  - SwiftUI scroll APIs or estimated heights.
  - Animated programmatic scrolls.
  - Retry timers for position.
  - Any writer of `contentOffset` other than `ChatTimelineController` (the user's own finger aside).
- **Anchor id spaces:**
  - Timeline row ids are "anchor ids": the item id for message rows, and the `TimelineRow.id` (`sep:<epoch>`) for separators. `pendingFocusID`, `rowAnchorIDs`, `historyPinTarget` and `ChatScrollPositionMemory` use the same space.
  - `ChatViewModel.windowTailAnchorID` is in `msg:` row-id space. The new code never compares it with anchor ids.
- **Performance gate** (Task 29):
  - At 25 pt/frame: ≤ 1.0 s app CPU per 15 s run (mean of 3) and 0 hitches.
  - At 150 pt/frame: ≤ 1 hitch per second (mean of 3).
- **Merging:** nothing merges until Dan has tried the device build and said so (Task 30).

## Review Focus

These are the inputs the spec implies but no task's own tests would otherwise exercise. Each one has a test added to the owning task.

1. **A streaming row retires while the reader is scrolled up.** When an `eph:` row is replaced by its durable row (or an `echo:` by its server id), the text on screen must not move. Covered by Task 20 `test_streamingRowRetiringBelowTheViewportDoesNotMoveTheReader` and Task 9 `test_vanishedAnchor_rescuedByNearestSurvivor`.
2. **The same item id appears twice in one snapshot.** Diffable data sources trap on duplicate identifiers. The row must render once, with no crash and a breadcrumb. Covered by Task 7 `test_duplicateAnchorIDs_areDroppedAfterTheFirst` and Task 20 `test_duplicateItemIDsRenderOnce`.
3. **Pathological bodies.**
   - An empty body renders a bubble with only its timestamp.
   - A 500-character unbroken token wraps inside the bubble and never makes the row wider than the screen. (The SwiftUI path needed `HorizontalOverflowLock` for this.)
   - Covered by Task 14 `test_emptyBody_rendersATimestampOnlyBubble` and `test_unbrokenToken_wrapsInsideTheBubble`.
4. **Rotation or a Dynamic Type change while reading history.** Every row is re-measured, and the message at the top of the screen must stay the message at the top. Covered by Task 25 `test_widthChangeWhileReading_keepsTheTopMessage` and `test_dynamicTypeChangeWhileReading_keepsTheTopMessage`.
5. **A conversation shorter than the screen.** One or two messages must hug the composer as today (`defaultScrollAnchor(.bottom, for: .alignment)`), including after a keyboard resize. Covered by Task 8 `test_shortContent_hugsTheBottom` and Task 20 `test_shortConversationHugsTheComposer`.

---

## Architecture at a glance

```
ChatView (SwiftUI)  ── flag off ──▶ today's ScrollViewReader/ScrollView branch (unchanged)
   │
   └─ flag on ──▶ ChatTimelineView (UIViewControllerRepresentable)
                     │  passes TimelineHostedEnvironment (openTrackerItem, openConversation,
                     │  conversationLinkHost) + ChatTimelineActions (sub-chat, spawn, item, mission,
                     │  file preview, image tap)
                     ▼
               ChatTimelineController (UIViewController, the ONLY contentOffset writer)
                 │ withObservationTracking ─▶ ChatViewModel.windowedRows / activityLabel /
                 │                              pendingFocusID / lastRenderableItemID / …
                 │ FrameCoalescer (CADisplayLink, one sync per frame)
                 ├─ TimelineRowContentBuilder  rows ─▶ [TimelineRowContent] (.text | .hosted)
                 ├─ TimelineHeightProvider ─▶ TimelineMeasureCache (shared, content-checked)
                 │       └─ TimelineMeasurer
                 │             ├─ TextRowRenderer (any thread): MarkdownAttributed.rendered(…).segments
                 │             │     + TextKitMeasure (TextKit 2) + TextBubbleGeometry + CodeBlockMetrics
                 │             └─ HostedSizer (main): UIHostingController.sizeThatFits (pills, tables,
                 │                   HostedTimelineRow, ActivityIndicatorRow footer)
                 ├─ TimelineScrollModel (pure struct): tops, hug pad, follow-tail, anchors, jumps,
                 │       viewport resize, near-top/near-bottom triggers
                 ├─ TimelineLayout (UICollectionViewLayout) reads the model; footer = supplementary
                 └─ cells: TextMessageCell (UITextView TK2 + CodeBlockSegmentView + hosted table/pills,
                           UIKit timestamp/avatar/send state) · HostedRowCell (UIHostingConfiguration,
                           self-reports height changes) · TimelineFooterView (activity indicator)
```

## File structure

New iOS files live in `Matron/Features/Chat/Timeline/`, a new folder, so run `xcodegen generate` after creating it.

| File | Responsibility |
|---|---|
| `Matron/Features/Chat/Timeline/ChatTimelineFlag.swift` | Flag key, and the default for each distribution channel |
| `Matron/Features/Chat/Timeline/TimelineLinkRouter.swift` | Routes a tapped URL through `MatronItemLink.action(for:)` |
| `Matron/Features/Chat/Timeline/TimelineRowContent.swift` | `TextRowContent`, `HostedRowContent`, `TimelineRowContent`, `TimelineRowContentBuilder` |
| `Matron/Features/Chat/Timeline/TimelineScrollModel.swift` | Pure geometry and scroll-state model |
| `Matron/Features/Chat/Timeline/TimelineMeasureCache.swift` | `TimelineMeasureKey`, `TimelineMeasurement`, `TimelineMeasureCache`, `TimelineRowMeasuring`, `TimelineHeightProvider` |
| `Matron/Features/Chat/Timeline/TimelineTextStyle.swift` | Fonts and markdown style for each Dynamic Type size |
| `Matron/Features/Chat/Timeline/TextKitMeasure.swift` | TextKit 2 standalone measurement, and `TimelineTextViewFactory` |
| `Matron/Features/Chat/Timeline/TextBubbleGeometry.swift` | Pure bubble geometry mirroring `MessageBubble`, plus `TextRowLayout` |
| `Matron/Features/Chat/Timeline/TextRowRenderer.swift` | `TextRowRender`, `HostedPiece`, `CodeBlockMetrics`, `TextRowRenderer` |
| `Matron/Features/Chat/Timeline/HostedTimelineRow.swift` | Mirror of `TimelineRowView` for hosted rows, plus `ChatTimelineActions`, `TimelineHostedEnvironment`, `HostedRowFactory` |
| `Matron/Features/Chat/Timeline/HostedSizer.swift` | Measures SwiftUI content off-screen |
| `Matron/Features/Chat/Timeline/TimelineMeasurer.swift` | The concrete `TimelineRowMeasuring` |
| `Matron/Features/Chat/Timeline/TimelineSegmentViews.swift` | `CodeBlockSegmentView`, `MarkdownTableGrid`, `SenderAvatarView`, `SendStateView` |
| `Matron/Features/Chat/Timeline/TextMessageCell.swift` | The text row cell |
| `Matron/Features/Chat/Timeline/HostedRowCell.swift` | `HostedRowCell` and `TimelineFooterView` |
| `Matron/Features/Chat/Timeline/TimelineLayout.swift` | `UICollectionViewLayout` over `TimelineScrollModel` |
| `Matron/Features/Chat/Timeline/ChatTimelineController.swift` | Controller, `FrameCoalescer`, `ChatTimelineBridge` |
| `Matron/Features/Chat/Timeline/ChatTimelineView.swift` | The representable |
| `Matron/Features/Chat/Timeline/TimelinePerfProbe.swift` | `#if DEBUG \|\| MATRON_PERF_PROBE` auto-scroll, CPU and hitch probe |
| `MatronShared/Sources/DesignSystem/MarkdownPlatform.swift` | Platform typealiases, palette and font factory for `MarkdownAttributed` |
| `MatronShared/Sources/DesignSystem/MarkdownSegments.swift` | iOS-only `MarkdownSegment`, `MarkdownTable`, `MarkdownSegmenter` |
| `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedFingerprintTests.swift` and `Fixtures/markdown-fingerprint-mac.txt` | Mac byte-identity pin |
| `MatronTests/TimelineTestFixtures.swift`, `MatronTests/TimelineSnapshotSupport.swift` | Shared iOS test fixtures and snapshot helper |
| `MatronUITests/ChatTimelineUITests.swift`, `MatronUITests/RigAgent.swift` | UI tests against the rig |
| `MatronUITests/rig/seed-timeline.mjs`, `MatronUITests/rig/perf-gate.sh` | Rig seed and performance gate |
| `scripts/ios-test.sh` | Loud iOS test runner |

Files that change:

- `Matron/Features/Chat/ChatView.swift`: one flagged branch in `chatPage`, a gated scroll-memory store in `onDisappear`, and a new `uikitTimeline` view.
- `Matron/Features/Settings/DeviceSettingsView.swift`: a new Advanced section.
- `Matron/Features/Chat/Composer/ComposerView.swift`: two accessibility identifiers.
- `Matron/App/AppShellView.swift`: the `MATRON_PERF_OPEN_CONVO` hook, compiled only in DEBUG or perf-probe builds.
- `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift`: now compiles on both platforms.
- `MatronShared/Sources/DesignSystem/SenderAvatar.swift`: `diameter` becomes public.
- `MatronShared/Sources/DesignSystem/MatronPalette.swift`: an additive `UIColor` palette.
- `MatronShared/Sources/ViewModels/ChatScrollPositionMemory.swift`: an additive in-row offset.
- `project.yml`: new `MatronTests` dependencies.
- `.github/workflows/ci.yml`: skip iOS snapshots on CI.
- `MatronUITests/rig/rebuild-rig.sh` and `README.md`: the timeline seed.

## Running tests (used by every task)

- **iOS tests:** use `scripts/ios-test.sh <Target/Class> [...]`, created in Task 1. It prints the `Executed N tests, with M failures` line and the log path, and exits non-zero on failure. Always compare the `Executed N` count with the number the step expects, because a filter that matches nothing reports `Executed 0 tests` and passes.
- **Shared package, on macOS:**
  ```bash
  cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter <Pattern> 2>&1 | tail -5
  ```
- **Mac app regression:** run in Task 3 and Task 30 only.
  ```bash
  cd /Users/danbarker/Dev/matron-apple-uikittimeline && mkdir -p /tmp/matron-mac-test-home && env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-home TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -3
  ```
  Expect `Executed N tests, with 0 failures`, where N is the baseline recorded in Task 2 Step 4.

---

## Phase 0: Scaffolding

### Task 1: Flag, Settings toggle, test runner, test-target dependencies

**Files:**
- Create: `Matron/Features/Chat/Timeline/ChatTimelineFlag.swift`
- Create: `scripts/ios-test.sh`
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (add a stored flag property after `@State private var storage`, and a new Section after the `Section("Appearance")` block)
- Modify: `project.yml` (the `MatronTests` target's `dependencies`)
- Test: `MatronTests/ChatTimelineFlagTests.swift`

**Interfaces:**
- Produces:
  - `enum ChatTimelineFlag { static let key: String; enum Channel { case debug, testFlight, appStore } }`
  - `ChatTimelineFlag.defaultValue(for: Channel) -> Bool`
  - `ChatTimelineFlag.channel(isDebugBuild: Bool, receiptURL: URL?) -> Channel`
  - `static var defaultValue: Bool`
  - `scripts/ios-test.sh`
  - `MatronTests` can now `import MatronDesignSystem` and `import SnapshotTesting`.

- [ ] **Step 1: Create the test runner script**

`scripts/ios-test.sh`:

```bash
#!/usr/bin/env bash
# Runs iOS tests on an iPhone 17 simulator and fails loudly.
#   scripts/ios-test.sh MatronTests/TimelineScrollModelTests [MatronTests/Other ...]
# Env:
#   MATRON_SKIP_SNAPSHOT_TESTS (default 1) — 0 to compare snapshots.
#   MATRON_RECORD_SNAPSHOTS    (default 0) — 1 to (re)record baselines.
#   IOS_TEST_DESTINATION       (default 'platform=iOS Simulator,name=iPhone 17').
# Any TEST_RUNNER_* variable already in the environment reaches the runner.
set -euo pipefail
cd "$(dirname "$0")/.."
SKIP="${MATRON_SKIP_SNAPSHOT_TESTS:-1}"
RECORD="${MATRON_RECORD_SNAPSHOTS:-0}"
DEST="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
args=()
for t in "$@"; do args+=("-only-testing:$t"); done
log=$(mktemp /tmp/ios-test.XXXXXX)
set +e
env MATRON_SKIP_SNAPSHOT_TESTS="$SKIP" \
    TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS="$SKIP" \
    TEST_RUNNER_MATRON_RECORD_SNAPSHOTS="$RECORD" \
  xcodebuild test -project Matron.xcodeproj -scheme Matron \
    -destination "$DEST" CODE_SIGNING_ALLOWED=NO "${args[@]}" > "$log" 2>&1
status=$?
set -e
grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$log" | tail -1 || true
grep -E "error:|: error|failed \(" "$log" | head -40 || true
echo "log: $log"
exit $status
```

Run: `chmod +x /Users/danbarker/Dev/matron-apple-uikittimeline/scripts/ios-test.sh`

- [ ] **Step 2: Add the test-target dependencies**

In `project.yml`, under `MatronTests:` → `dependencies:`, append these two entries after the existing `MatronEvents` entry:

```yaml
      # UIKit timeline (spec 2026-09-26): renderer / segment tests reach the
      # public MarkdownAttributed + MarkdownSegment API, cell tests snapshot.
      - package: MatronShared
        product: MatronDesignSystem
      - package: swift-snapshot-testing
        product: SnapshotTesting
```

- [ ] **Step 3: Write the failing test**

`MatronTests/ChatTimelineFlagTests.swift`:

```swift
import XCTest
@testable import Matron

/// Spec §3: `chat.timeline.uikit` is on by default in Debug and TestFlight
/// builds, off in App Store builds, and switchable in Settings ▸ Advanced.
final class ChatTimelineFlagTests: XCTestCase {
    func test_key_isTheSpecKey() {
        XCTAssertEqual(ChatTimelineFlag.key, "chat.timeline.uikit")
    }

    func test_debugAndTestFlightDefaultOn_appStoreDefaultsOff() {
        XCTAssertTrue(ChatTimelineFlag.defaultValue(for: .debug))
        XCTAssertTrue(ChatTimelineFlag.defaultValue(for: .testFlight))
        XCTAssertFalse(ChatTimelineFlag.defaultValue(for: .appStore))
    }

    func test_channel_readsTheBuildAndTheReceipt() {
        XCTAssertEqual(ChatTimelineFlag.channel(isDebugBuild: true, receiptURL: nil), .debug)
        XCTAssertEqual(ChatTimelineFlag.channel(
            isDebugBuild: false, receiptURL: URL(fileURLWithPath: "/c/StoreKit/sandboxReceipt")), .testFlight)
        XCTAssertEqual(ChatTimelineFlag.channel(
            isDebugBuild: false, receiptURL: URL(fileURLWithPath: "/c/StoreKit/receipt")), .appStore)
        XCTAssertEqual(ChatTimelineFlag.channel(isDebugBuild: false, receiptURL: nil), .appStore)
    }

    /// Source pin: Settings ▸ Advanced carries the toggle on the flag's key.
    func test_settingsOffersTheToggle() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Settings/DeviceSettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("@AppStorage(ChatTimelineFlag.key)"))
        XCTAssertTrue(source.contains("Text(\"Advanced\")"))
        XCTAssertTrue(source.contains("settings.uikitTimeline"))
    }
}
```

- [ ] **Step 4: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/ChatTimelineFlagTests`

Expected: a build failure containing `cannot find 'ChatTimelineFlag' in scope`.

- [ ] **Step 5: Implement the flag**

`Matron/Features/Chat/Timeline/ChatTimelineFlag.swift`:

```swift
import Foundation

/// `chat.timeline.uikit` (spec §3): which iOS chat timeline renders.
/// `true` → `ChatTimelineController` (UIKit, TextKit cells); `false` → the
/// SwiftUI `ScrollViewReader` timeline, byte-for-byte as before.
enum ChatTimelineFlag {
    static let key = "chat.timeline.uikit"

    /// Where this binary was distributed — decides the flag's default.
    enum Channel: Equatable {
        case debug
        case testFlight
        case appStore
    }

    /// On by default in Debug and TestFlight, off for the App Store until
    /// the flag has soaked (spec §3).
    static func defaultValue(for channel: Channel) -> Bool {
        switch channel {
        case .debug, .testFlight: return true
        case .appStore: return false
        }
    }

    /// TestFlight installs carry a sandbox receipt; App Store installs a
    /// production one (`receipt`); a dev-signed Release install has none.
    static func channel(isDebugBuild: Bool, receiptURL: URL?) -> Channel {
        if isDebugBuild { return .debug }
        return receiptURL?.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
    }

    static var currentChannel: Channel {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return channel(isDebugBuild: isDebugBuild, receiptURL: Bundle.main.appStoreReceiptURL)
    }

    /// The `@AppStorage` default for this binary.
    static var defaultValue: Bool { defaultValue(for: currentChannel) }
}
```

- [ ] **Step 6: Add the Settings toggle**

In `Matron/Features/Settings/DeviceSettingsView.swift`, add after `@State private var storage: StorageSettingsRows.Model?`:

```swift
    /// Settings ▸ Advanced: which chat timeline renders (spec §3).
    @AppStorage(ChatTimelineFlag.key) private var usesUIKitTimeline = ChatTimelineFlag.defaultValue
```

Insert this section directly after the closing brace of `Section("Appearance") { … }`:

```swift
            Section {
                Toggle("New chat timeline", isOn: $usesUIKitTimeline)
                    .accessibilityIdentifier("settings.uikitTimeline")
            } header: {
                Text("Advanced")
            } footer: {
                Text("Renders conversations with the faster UIKit timeline. Applies the next time a chat opens.")
            }
```

- [ ] **Step 7: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/ChatTimelineFlagTests`

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add scripts/ios-test.sh project.yml Matron/Features/Chat/Timeline/ChatTimelineFlag.swift Matron/Features/Settings/DeviceSettingsView.swift MatronTests/ChatTimelineFlagTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: chat.timeline.uikit flag, Settings ▸ Advanced toggle, loud iOS test runner" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 1: Renderer — `MarkdownAttributed` on UIKit (shared source)

**Ruling on the spec:** the spec says "a UIKit port of `MarkdownAttributed`, which the Mac already uses". The renderer is not in the Mac target. It lives in the shared `MatronDesignSystem` module (`MatronShared/Sources/DesignSystem/MarkdownAttributed.swift`), and the whole file sits inside `#if os(macOS)`. "Porting" therefore means removing that gate behind platform typealiases. The Mac output is pinned by a fingerprint fixture recorded before the port.

### Task 2: Mac fingerprint safety net

**Files:**
- Create: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedFingerprintTests.swift`
- Create (generated by the test): `MatronShared/Tests/DesignSystemSnapshotTests/Fixtures/markdown-fingerprint-mac.txt`

**Interfaces:**
- Consumes: `MarkdownAttributed.attributedString(for:style:)` and `MarkdownAttributed.Style.chat` / `.item`, both unchanged and Mac-only.
- Produces: a committed fixture. Every later task that touches `MarkdownAttributed.swift` must keep `test_macRenderingIsUnchangedByThePort` green.

- [ ] **Step 1: Write the fingerprint test**

```swift
#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// Pins the Mac renderer's exact output — every run's range, text, font,
/// colours, link, underline/strike and paragraph metrics (table blocks
/// included) — for a corpus covering every block and inline kind, in both
/// styles. Recorded on `main` BEFORE the UIKit port (plan Task 2); the port
/// must reproduce it byte for byte. Re-record ONLY on purpose:
/// `MATRON_RECORD_MARKDOWN_FINGERPRINT=1 swift test --filter MarkdownAttributedFingerprintTests`.
final class MarkdownAttributedFingerprintTests: XCTestCase {
    static let corpus: [String] = [
        "Plain paragraph with **bold**, *italic*, ~~struck~~ and `inline code`.",
        "# Heading one\n\nBody under it.\n\n## Heading two\n\n### Heading three\n\nClosing.",
        "Intro paragraph.\n\n## A heading after a paragraph",
        "- alpha\n- beta with **bold**\n  - nested gamma\n\n1. first\n2. second",
        "> A quoted line\n> that continues.\n\nAfter the quote.",
        "Before code.\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nAfter code.",
        "Ends with code:\n\n```\nmake test\n```",
        "Links: [web](https://example.com/a), [#65](matron://item/65), [room](matron://convo/abc-123), [matrix](matrix:r/room:server), [pair](matron://link?code=AAAA-BBBB).",
        "| Left | Center | Right |\n|:-----|:------:|------:|\n| a | **b** | `c` |\n| d | e | f |\n\nAfter the table.",
        "| A |\n|---|\n| 1 |\n\n| B |\n|---|\n| 2 |",
        "Ends with a table:\n\n| K | V |\n|---|---|\n| x | y |",
        "[Voice note transcription]: Hello there.",
        "Line one\nline two in the same paragraph.\n\n\n\nFar paragraph.",
    ]

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/markdown-fingerprint-mac.txt")
    }

    func test_macRenderingIsUnchangedByThePort() throws {
        var sections: [String] = []
        for (styleName, style) in [("chat", MarkdownAttributed.Style.chat), ("item", MarkdownAttributed.Style.item)] {
            for (index, source) in Self.corpus.enumerated() {
                let rendered = MarkdownAttributed.attributedString(for: source, style: style)
                sections.append("## \(styleName) \(index)\n" + Self.fingerprint(rendered))
            }
        }
        let actual = sections.joined(separator: "\n")
        if ProcessInfo.processInfo.environment["MATRON_RECORD_MARKDOWN_FINGERPRINT"] == "1" {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: fixtureURL, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertEqual(actual, expected, "Mac MarkdownAttributed output changed — the UIKit port must not alter it")
    }

    static func fingerprint(_ string: NSAttributedString) -> String {
        var lines: [String] = []
        let text = string.string as NSString
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            var parts = ["\(range.location)+\(range.length) \(String(reflecting: text.substring(with: range)))"]
            if let font = attributes[.font] as? NSFont {
                parts.append("font=\(font.fontName)@\(font.pointSize) traits=\(font.fontDescriptor.symbolicTraits.rawValue)")
            }
            if let color = attributes[.foregroundColor] as? NSColor { parts.append("fg=\(color)") }
            if let color = attributes[.backgroundColor] as? NSColor { parts.append("bg=\(color)") }
            if let link = attributes[.link] { parts.append("link=\(link)") }
            if let underline = attributes[.underlineStyle] { parts.append("underline=\(underline)") }
            if let strike = attributes[.strikethroughStyle] { parts.append("strike=\(strike)") }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle { parts.append(paragraph(style)) }
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    static func paragraph(_ style: NSParagraphStyle) -> String {
        var line = "para ls=\(style.lineSpacing) ps=\(style.paragraphSpacing) psb=\(style.paragraphSpacingBefore)"
            + " hi=\(style.headIndent) fhi=\(style.firstLineHeadIndent) al=\(style.alignment.rawValue)"
            + " blocks=\(style.textBlocks.count)"
        for case let block as NSTextTableBlock in style.textBlocks {
            line += " cell(r\(block.startingRow),c\(block.startingColumn),cols\(block.table.numberOfColumns)"
                + ",pad\(block.width(for: .padding, edge: .minX)),border\(block.width(for: .border, edge: .minX))"
                + ",marginMaxY\(block.width(for: .margin, edge: .maxY))"
                + ",bg\(block.backgroundColor.map { "\($0)" } ?? "nil"))"
        }
        return line
    }
}
#endif
```

- [ ] **Step 2: Record the fixture from unmodified code**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_RECORD_MARKDOWN_FINGERPRINT=1 MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MarkdownAttributedFingerprintTests 2>&1 | tail -3 && wc -l Tests/DesignSystemSnapshotTests/Fixtures/markdown-fingerprint-mac.txt`

Expected: `Executed 1 test, with 0 failures`, and a fixture of more than 150 lines.

- [ ] **Step 3: Verify the pin compares**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MarkdownAttributedFingerprintTests 2>&1 | tail -3`

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 4: Record the Mac app baseline**

Run the Mac-app regression command from "Running tests" now, before any shared code changes.

Expected: `Executed N tests, with 0 failures`. Write N into the commit message below. Tasks 3 and 30 compare against it.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedFingerprintTests.swift MatronShared/Tests/DesignSystemSnapshotTests/Fixtures/markdown-fingerprint-mac.txt
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "shared: fingerprint-pin the Mac MarkdownAttributed output before the UIKit port" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Compile `MarkdownAttributed` for UIKit

**Files:**
- Create: `MatronShared/Sources/DesignSystem/MarkdownPlatform.swift`
- Modify: `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift` (edits listed in Step 3)
- Test: `MatronTests/MarkdownAttributedPhoneTests.swift`

**Interfaces:**
- Consumes: the Task 2 fixture.
- Produces:
  - `public static func MarkdownAttributed.rendered(for source: String, style: Style, cache: Bool) -> Rendered`
  - `public static func MarkdownAttributed.Style.phoneChat(bodySize: CGFloat) -> Style` (iOS only)
  - `typealias MarkdownFont` / `MarkdownColor` and `enum MarkdownPalette` (internal to the module)
  - The Mac overloads `rendered(for:style: = .chat)` and `attributedString(for:style: = .chat)` stay exactly as today.

- [ ] **Step 1: Write the failing iOS renderer tests**

`MatronTests/MarkdownAttributedPhoneTests.swift`:

```swift
import XCTest
import UIKit
import MatronDesignSystem

/// Spec §4 renderer tests: the UIKit build of the shared `MarkdownAttributed`
/// renders the same structure the Mac does (headings, lists, quotes, code,
/// tables, the `[label]:` escape) with UIKit fonts/colours, and routes links
/// through the shared `MatronItemLink` policy.
final class MarkdownAttributedPhoneTests: XCTestCase {
    private let style = MarkdownAttributed.Style.phoneChat(bodySize: 17)

    private func render(_ source: String) -> NSAttributedString {
        MarkdownAttributed.rendered(for: source, style: style, cache: false).attributed
    }

    private func attributes(_ string: NSAttributedString, at substring: String,
                            file: StaticString = #filePath, line: UInt = #line) -> [NSAttributedString.Key: Any] {
        let range = (string.string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            XCTFail("\(substring.debugDescription) not in \(string.string.debugDescription)", file: file, line: line)
            return [:]
        }
        return string.attributes(at: range.location, effectiveRange: nil)
    }

    func test_body_usesThePhoneMetrics() {
        let attrs = attributes(render("Hello world.\n\nSecond."), at: "Hello")
        XCTAssertEqual((attrs[.font] as? UIFont)?.pointSize, 17)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineSpacing, 4)
        XCTAssertEqual(paragraph?.paragraphSpacing, 8)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, UIColor.label)
    }

    func test_inlineStyles_mapToUIKitTraits() {
        let string = render("A **bold** and *italic* and ~~gone~~ and `code`.")
        let bold = attributes(string, at: "bold")[.font] as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let italic = attributes(string, at: "italic")[.font] as? UIFont
        XCTAssertTrue(italic?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        XCTAssertNotNil(attributes(string, at: "gone")[.strikethroughStyle])
        let code = attributes(string, at: "code")
        XCTAssertTrue((code[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        XCTAssertEqual(code[.backgroundColor] as? UIColor, UIColor.systemGray6)
    }

    func test_headings_scaleAndBold() {
        let string = render("# Big\n\nBody")
        let font = attributes(string, at: "Big")[.font] as? UIFont
        XCTAssertEqual(font?.pointSize ?? 0, 17 * 1.3, accuracy: 0.01)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    func test_lists_getTheSameMarkersAsTheMac() {
        let string = render("- alpha\n- beta\n\n1. first\n2. second").string
        XCTAssertTrue(string.contains("\u{2022} alpha"))
        XCTAssertTrue(string.contains("1. first"))
        XCTAssertTrue(string.contains("2. second"))
    }

    func test_quote_isSecondaryAndIndented() {
        let attrs = attributes(render("> quoted\n\nafter"), at: "quoted")
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, UIColor.secondaryLabel)
        XCTAssertEqual((attrs[.paragraphStyle] as? NSParagraphStyle)?.headIndent, 12)
    }

    func test_links_followTheSharedPolicy() {
        let string = render("[web](https://example.com) [#5](matron://item/5) [room](matron://convo/c-1) [mx](matrix:r/x:s)")
        XCTAssertEqual(attributes(string, at: "web")[.link] as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(attributes(string, at: "#5")[.link] as? URL, URL(string: "matron://item/5"))
        XCTAssertEqual(attributes(string, at: "room")[.link] as? URL, URL(string: "matron://convo/c-1"))
        let swallowed = attributes(string, at: "mx")
        XCTAssertNil(swallowed[.link], "matrix: links are swallowed, never clickable")
        XCTAssertEqual(swallowed[.foregroundColor] as? UIColor, UIColor.tintColor)
    }

    func test_referenceDefinitionShapedBody_rendersAsText() {
        let string = render("[Voice note transcription]: Hello.").string
        XCTAssertTrue(string.contains("Hello."))
        XCTAssertTrue(string.contains("[Voice note transcription]:"))
    }

    func test_tableCells_renderAsAlignedParagraphs() {
        let string = render("| L | R |\n|:--|--:|\n| a | b |")
        XCTAssertEqual((attributes(string, at: "b")[.paragraphStyle] as? NSParagraphStyle)?.alignment, .right)
        XCTAssertEqual((attributes(string, at: "a")[.paragraphStyle] as? NSParagraphStyle)?.alignment, .left)
    }

    func test_output_neverEndsWithNewline() {
        for source in ["para\n\n```swift\nlet x = 1\n```", "para\n\n- a\n- b", "Closing.\n\n\n"] {
            XCTAssertFalse(render(source).string.hasSuffix("\n"), source.debugDescription)
        }
    }

    func test_cacheFlag_controlsMemoisation() {
        let source = "memo probe \(UUID().uuidString)"
        let a = MarkdownAttributed.rendered(for: source, style: style, cache: false)
        let b = MarkdownAttributed.rendered(for: source, style: style, cache: false)
        XCTAssertFalse(a === b, "cache: false (streaming rows) must not store")
        let c = MarkdownAttributed.rendered(for: source, style: style, cache: true)
        let d = MarkdownAttributed.rendered(for: source, style: style, cache: true)
        XCTAssertTrue(c === d)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/MarkdownAttributedPhoneTests`

Expected: a build failure containing `cannot find 'MarkdownAttributed' in scope`, because the type is Mac-only today.

- [ ] **Step 3: Add the platform layer**

`MatronShared/Sources/DesignSystem/MarkdownPlatform.swift`:

```swift
#if os(macOS)
import AppKit

/// Platform types for `MarkdownAttributed` — one renderer source, AppKit on
/// the Mac (unchanged output, pinned by `MarkdownAttributedFingerprintTests`)
/// and UIKit on iOS (the UIKit chat timeline, spec 2026-09-26).
typealias MarkdownFont = NSFont
typealias MarkdownColor = NSColor

enum MarkdownPalette {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var accent: NSColor { .controlAccentColor }
    static var codeBackground: NSColor { .controlBackgroundColor }
}

enum MarkdownPlatform {
    /// System font for body text, monospaced system font for code, traits
    /// via symbolic traits so the descriptor reliably reports bold/italic.
    static func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> NSFont {
        let base: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
#else
import UIKit

typealias MarkdownFont = UIFont
typealias MarkdownColor = UIColor

enum MarkdownPalette {
    static var label: UIColor { .label }
    static var secondaryLabel: UIColor { .secondaryLabel }
    /// `Color.accentColor` on iOS is the system tint — MarkdownUI's link colour.
    static var accent: UIColor { .tintColor }
    /// `Color.matronInlineCodeBg` / `.matronCodeBg` on iOS.
    static var codeBackground: UIColor { .systemGray6 }
}

enum MarkdownPlatform {
    static func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> UIFont {
        let base: UIFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
#endif
```

- [ ] **Step 4: Edit `MarkdownAttributed.swift`**

Make these exact edits in `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift`.

1. Lines 1–4: replace
   ```swift
   #if os(macOS)
   import AppKit
   import Foundation
   import os
   ```
   with
   ```swift
   #if os(macOS)
   import AppKit
   #else
   import UIKit
   #endif
   import Foundation
   import os
   ```
   Then delete the final `#endif` on line 948. The `MarkdownReconstruction.swift` and `SelectableMessageText.swift` files keep their own `#if os(macOS)` gates.

2. Update the doc comment's first line, `/// Mac-only Markdown → NSAttributedString converter.`, to:
   ```swift
   /// Markdown → `NSAttributedString` converter shared by the Mac timeline (AppKit) and the iOS UIKit timeline.
   ```

3. Wrap `public static let chat = …` (line 50) in `#if os(macOS)` … `#endif`, together with its doc comment. Directly after that `#endif`, inside `struct Style`, add:
   ```swift
   #if !os(macOS)
   /// The iOS UIKit chat timeline: `bodySize` is the Dynamic-Type-scaled body
   /// size (17pt at the default category — `Theme.matronMessage`'s system
   /// body); leading 4 matches the SwiftUI path's `MarkdownText(lineSpacing: 4)`,
   /// block gap 8 matches the Mac chat style.
   public static func phoneChat(bodySize: CGFloat) -> Style {
       Style(baseFontSize: bodySize, paragraphSpacing: 8, lineSpacing: 4)
   }
   #endif
   ```

4. Wrap `static let baseFontSize: CGFloat = Style.chat.baseFontSize` (line 63) and its doc comment in `#if os(macOS)` … `#endif`.

5. In `final class Rendered`, wrap the `containsTable` property together with its doc comment in `#if os(macOS)` … `#endif`. In `init`, wrap the probe block that starts `var found = false` and ends `self.containsTable = found` the same way, and add after its `#endif`:
   ```swift
   #if !os(macOS)
   self.segments = MarkdownSegmenter.segments(of: attributed)
   #endif
   ```
   Also add this stored property after `public let attributed: NSAttributedString`:
   ```swift
   #if !os(macOS)
   /// The message split into prose / fenced code / table blocks for the iOS
   /// timeline (iOS has no `NSTextTable`; code gets its own scrollable view).
   public let segments: [MarkdownSegment]
   #endif
   ```
   Task 5 creates `MarkdownSegmenter`. Until it lands, write `self.segments = []` here and change it to the segmenter call in Task 5 Step 3.

6. Change `NSSize(width: width, height: .greatestFiniteMagnitude)` to `CGSize(width: width, height: .greatestFiniteMagnitude)`. It appears twice, at lines 220 and 325.

7. Replace the two Mac cache entry points (lines 275–289, `static func rendered(for:style:)` and `static func attributedString(for:style:)`) with:
   ```swift
   /// Everything derived from markdown `source`, memoised per source and style
   /// (countLimit 400). `cache: false` still reads the memo but never stores —
   /// a streaming row's every intermediate text would otherwise evict the
   /// immutable history the memo exists for (same rule as `MarkdownText(cacheParsed:)`).
   public static func rendered(for source: String, style: Style, cache: Bool) -> Rendered {
       let key = source as NSString
       let memo = renderedCache(for: style)
       if let cached = memo.object(forKey: key) { return cached }
       let built = Rendered(attributed: build(from: source, style: style))
       if cache { memo.setObject(built, forKey: key) }
       return built
   }

   #if os(macOS)
   /// Mac entry point (unchanged contract): memoised, chat style by default.
   static func rendered(for source: String, style: Style = .chat) -> Rendered {
       rendered(for: source, style: style, cache: true)
   }

   /// Thin wrapper over `rendered(for:style:)` for callers that only need
   /// the string (copy-time reconstruction, tests).
   static func attributedString(for source: String, style: Style = .chat) -> NSAttributedString {
       rendered(for: source, style: style).attributed
   }
   #endif
   ```

8. In `build(from:style:)`, change the parse-failure fallback's `.foregroundColor: NSColor.labelColor` to `.foregroundColor: MarkdownPalette.label`.

9. In `build`, replace the table state declarations
   ```swift
           var currentTable: NSTextTable?
           var currentRowBlocks: [Int: [NSTextTableBlock]] = [:]
           var currentCellStyle: NSMutableParagraphStyle?
           var previousCell: (row: Int, column: Int)?
   ```
   with
   ```swift
           #if os(macOS)
           var currentTable: NSTextTable?
           var currentRowBlocks: [Int: [NSTextTableBlock]] = [:]
           var previousCell: (row: Int, column: Int)?
           #endif
           var currentCellStyle: NSMutableParagraphStyle?
   ```
   Replace the body of the nested `func endTable()` with:
   ```swift
           func endTable() {
               #if os(macOS)
               if let lastRow = currentRowBlocks.keys.max() {
                   for cellBlock in currentRowBlocks[lastRow] ?? [] {
                       cellBlock.setWidth(
                           tableBottomMargin, type: .absoluteValueType, for: .margin, edge: .maxY
                       )
                   }
               }
               currentTable = nil
               currentRowBlocks = [:]
               previousCell = nil
               #endif
               currentCellStyle = nil
           }
   ```

10. Replace the whole `if isNewBlock { if case .tableCell(…) = block { … } else { endTable() } }` statement (lines 455–502) with:
    ```swift
            if isNewBlock {
                if case .tableCell(let row, let column, let isHeader, let columnCount, let alignments) = block {
                    let style = NSMutableParagraphStyle()
                    #if os(macOS)
                    let table: NSTextTable
                    let continues = BlockKind.tableCellContinues((row, column), after: previousCell)
                    if let open = currentTable, continues {
                        table = open
                    } else {
                        endTable()
                        table = NSTextTable()
                        table.numberOfColumns = columnCount
                        table.layoutAlgorithm = .automaticLayoutAlgorithm
                        table.setContentWidth(100, type: .percentageValueType)
                        currentTable = table
                    }

                    let cellBlock = NSTextTableBlock(
                        table: table, startingRow: row, rowSpan: 1,
                        startingColumn: column, columnSpan: 1
                    )
                    cellBlock.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
                    cellBlock.setBorderColor(.separatorColor)
                    cellBlock.setWidth(tableCellPadding, type: .absoluteValueType, for: .padding)
                    // A label-colour tint, not `controlBackgroundColor`: bot
                    // bubbles are pure white in light mode (`matronBubbleBot`),
                    // where `controlBackgroundColor` is ALSO white — the shade
                    // must be an overlay that reads on either appearance's
                    // bubble.
                    if isHeader { cellBlock.backgroundColor = .labelColor.withAlphaComponent(0.05) }
                    currentRowBlocks[row, default: []].append(cellBlock)
                    previousCell = (row, column)
                    style.textBlocks = [cellBlock]
                    #else
                    // iOS has no NSTextTable: cells stay plain aligned
                    // paragraphs here, and `MarkdownSegmenter` lifts them
                    // into a `MarkdownTable` segment for the hosted grid.
                    _ = (row, isHeader, columnCount)
                    #endif
                    style.paragraphSpacing = 0
                    // The render style's leading applies inside cells too —
                    // an item-style table read at chat leading beside 4pt
                    // prose (Bugbot, PR #232).
                    style.lineSpacing = renderStyle.lineSpacing
                    if column < alignments.count {
                        style.alignment = nsAlignment(alignments[column])
                    }
                    currentCellStyle = style
                } else {
                    endTable()
                }
            }
    ```

11. In the trailing-newline trim loop, wrap the table-terminator check:
    ```swift
            #if os(macOS)
            if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textBlocks.isEmpty {
                break // table-cell terminator — structural, not dead space
            }
            #endif
    ```
    With this in place, `let attrs = …` is unused on iOS. Move `let attrs = output.attributes(at: output.length - 1, effectiveRange: nil)` inside the `#if os(macOS)` block as well.

12. In `runAttributes`:
    - Change `attrs[.backgroundColor] = NSColor.controlBackgroundColor` to `attrs[.backgroundColor] = MarkdownPalette.codeBackground`.
    - Change both `NSColor.controlAccentColor` to `MarkdownPalette.accent`.

13. Replace the whole `private static func font(size:bold:italic:monospaced:) -> NSFont { … }` with:
    ```swift
    private static func font(
        size: CGFloat,
        bold: Bool = false,
        italic: Bool = false,
        monospaced: Bool = false
    ) -> MarkdownFont {
        MarkdownPlatform.font(size: size, bold: bold, italic: italic, monospaced: monospaced)
    }
    ```

14. Replace `var foreground: NSColor { switch self { case .blockQuote: return .secondaryLabelColor default: return .labelColor } }` in `BlockKind` with:
    ```swift
    var foreground: MarkdownColor {
        switch self {
        case .blockQuote: return MarkdownPalette.secondaryLabel
        default: return MarkdownPalette.label
        }
    }
    ```

- [ ] **Step 5: Add a temporary segments stub**

Task 5 replaces this stub. Create `MatronShared/Sources/DesignSystem/MarkdownSegments.swift` holding just the public types, so iOS compiles:

```swift
#if !os(macOS)
import UIKit

/// One block-level piece of a rendered message on iOS: flowing prose (one
/// `UITextView`), a fenced code block (its own horizontally scrollable
/// monospaced view with a copy button), or a table (a hosted grid — iOS has
/// no `NSTextTable`).
public enum MarkdownSegment: Equatable {
    case text(NSAttributedString)
    case code(language: String?, code: String)
    case table(MarkdownTable)

    public var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}

/// A parsed markdown table. `rows[0]` is the header row; every row has
/// exactly `columnCount` cells (missing trailing cells are empty strings).
public struct MarkdownTable: Equatable {
    public enum Alignment: Equatable { case left, center, right }
    public let columnCount: Int
    public let alignments: [Alignment]
    public let rows: [[NSAttributedString]]

    public init(columnCount: Int, alignments: [Alignment], rows: [[NSAttributedString]]) {
        self.columnCount = columnCount
        self.alignments = alignments
        self.rows = rows
    }
}
#endif
```

- [ ] **Step 6: Run the iOS tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/MarkdownAttributedPhoneTests`

Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 7: Prove the Mac output is unchanged**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'MarkdownAttributed|MarkdownCopy|SelectableMessageText|ItemTypography|MessageCopyTextView|MessageLinkClick|LinkClickTracking' 2>&1 | tail -3`

Expected: `Executed N tests, with 0 failures`, with `MarkdownAttributedFingerprintTests` among them.

Then run the Mac-app regression command from "Running tests".

Expected: the same `Executed N` as the Task 2 baseline, and 0 failures.

- [ ] **Step 8: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add MatronShared/Sources/DesignSystem/MarkdownPlatform.swift MatronShared/Sources/DesignSystem/MarkdownAttributed.swift MatronShared/Sources/DesignSystem/MarkdownSegments.swift MatronTests/MarkdownAttributedPhoneTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "shared: compile MarkdownAttributed for UIKit behind platform typealiases (Mac output fingerprint-identical)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: Phone text style

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineTextStyle.swift`
- Test: `MatronTests/TimelineTextStyleTests.swift`

**Interfaces:**
- Consumes: `MarkdownAttributed.Style.phoneChat(bodySize:)`.
- Produces: `struct TimelineTextStyle: Hashable, @unchecked Sendable` with:
  - `init(sizeCategory: UIContentSizeCategory)` and `let sizeCategory`
  - `var bodySize: CGFloat`, `var markdown: MarkdownAttributed.Style`, `var segmentSpacing: CGFloat`
  - `var timestampFont: UIFont`, `var codeFont: UIFont`, `var codeHeaderFont: UIFont`, `var copyIconFont: UIFont`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import UIKit
import MatronDesignSystem
@testable import Matron

final class TimelineTextStyleTests: XCTestCase {
    func test_defaultCategory_isTheSystemBody() {
        let style = TimelineTextStyle(sizeCategory: .large)
        XCTAssertEqual(style.bodySize, 17)
        XCTAssertEqual(style.markdown, .phoneChat(bodySize: 17))
        XCTAssertEqual(style.segmentSpacing, 8)
    }

    func test_dynamicType_scalesBodyAndCaption() {
        let small = TimelineTextStyle(sizeCategory: .large)
        let big = TimelineTextStyle(sizeCategory: .accessibilityExtraLarge)
        XCTAssertGreaterThan(big.bodySize, small.bodySize)
        XCTAssertGreaterThan(big.timestampFont.pointSize, small.timestampFont.pointSize)
        XCTAssertNotEqual(big, small, "the style is half of every measurement cache key")
    }

    func test_codeFont_isMonospacedCallout() {
        let style = TimelineTextStyle(sizeCategory: .large)
        XCTAssertTrue(style.codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertEqual(style.codeFont.pointSize, UIFont.preferredFont(forTextStyle: .callout).pointSize)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineTextStyleTests`

Expected: the build fails with `cannot find 'TimelineTextStyle' in scope`.

- [ ] **Step 3: Implement**

```swift
import UIKit
import MatronDesignSystem

/// Every font and markdown metric one text row is rendered and measured
/// with, for one Dynamic Type size. Half of every measurement cache key —
/// a category change is a guaranteed miss (spec: cache key includes the
/// Dynamic Type size). `@unchecked Sendable`: a plain value; the category
/// is an immutable string wrapper.
struct TimelineTextStyle: Hashable, @unchecked Sendable {
    let sizeCategory: UIContentSizeCategory

    init(sizeCategory: UIContentSizeCategory) {
        self.sizeCategory = sizeCategory
    }

    private var traits: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: sizeCategory)
    }

    /// The system body (17pt at `.large`), scaled — what MarkdownUI renders
    /// `Theme.matronMessage` at on the SwiftUI path.
    var bodySize: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
    }

    var markdown: MarkdownAttributed.Style { .phoneChat(bodySize: bodySize) }

    /// Vertical gap between a message's prose / code / table segments.
    var segmentSpacing: CGFloat { markdown.paragraphSpacing }

    /// `MessageBubble`'s `.caption2` time.
    var timestampFont: UIFont { .preferredFont(forTextStyle: .caption2, compatibleWith: traits) }

    /// `CodeBlock`'s `.system(.callout, design: .monospaced)`.
    var codeFont: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traits).pointSize,
                              weight: .regular)
    }

    /// `CodeBlock`'s language label (`.caption2`).
    var codeHeaderFont: UIFont { .preferredFont(forTextStyle: .caption2, compatibleWith: traits) }

    /// `CodeBlock`'s copy icon (`.caption`).
    var copyIconFont: UIFont { .preferredFont(forTextStyle: .caption1, compatibleWith: traits) }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineTextStyleTests`

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineTextStyle.swift MatronTests/TimelineTextStyleTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineTextStyle — phone markdown metrics per Dynamic Type size" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: Segment code blocks and tables out of a rendered message (iOS)

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/MarkdownSegments.swift` (add `MarkdownSegmenter`)
- Modify: `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift` (in `Rendered.init`, change `self.segments = []` to `self.segments = MarkdownSegmenter.segments(of: attributed)`)
- Test: `MatronTests/MarkdownSegmentTests.swift`

**Interfaces:**
- Consumes:
  - `MarkdownRunSemantics` and `BlockKind` (module-internal)
  - `MarkdownAttributed.semanticsKey`
  - `BlockKind.tableCellContinues(_:after:)`
- Produces:
  - `MarkdownSegmenter.segments(of: NSAttributedString) -> [MarkdownSegment]` (module-internal)
  - `Rendered.segments` (public, iOS only)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
import MatronDesignSystem

/// Spec §2: code blocks and tables become their own block segments on iOS.
final class MarkdownSegmentTests: XCTestCase {
    private func segments(_ source: String) -> [MarkdownSegment] {
        MarkdownAttributed.rendered(for: source, style: .phoneChat(bodySize: 17), cache: false).segments
    }

    private func text(_ segment: MarkdownSegment) -> String? {
        if case .text(let string) = segment { return string.string }
        return nil
    }

    func test_plainMessage_isOneTextSegment() {
        let result = segments("Just a sentence.\n\nAnd another.")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(text(result[0]), "Just a sentence.\nAnd another.")
    }

    func test_codeBlock_splitsProseAroundIt() {
        let result = segments("Intro line.\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nOutro line.")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(text(result[0]), "Intro line.")
        XCTAssertEqual(result[1], .code(language: "swift", code: "let x = 1\n\nlet y = 2"))
        XCTAssertEqual(text(result[2]), "Outro line.")
    }

    func test_messageEndingInCode_hasNoTrailingProse() {
        let result = segments("Run:\n\n```\nmake test\n```")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1], .code(language: nil, code: "make test"))
    }

    func test_table_becomesATableSegment_withAlignmentsAndInlineStyles() throws {
        let result = segments("Before.\n\n| Case | Result |\n|:--|--:|\n| retry | **failed** |\n\nAfter.")
        XCTAssertEqual(result.count, 3)
        guard case .table(let table) = result[1] else { return XCTFail("expected a table, got \(result[1])") }
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows.map { $0.map(\.string) }, [["Case", "Result"], ["retry", "failed"]])
        let bold = table.rows[1][1].attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        XCTAssertEqual(text(result[2]), "After.")
    }

    func test_backToBackTables_areTwoSegments() {
        let result = segments("| A |\n|---|\n| 1 |\n\n| B |\n|---|\n| 2 |")
        XCTAssertEqual(result.filter(\.isTable).count, 2)
    }

    func test_emptyBody_hasNoSegments() {
        XCTAssertEqual(segments(""), [])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/MarkdownSegmentTests`

Expected: every test except `test_emptyBody_hasNoSegments` fails (`XCTAssertEqual failed: ("0") is not equal to ("1")` and similar), because the stub returns `[]`. The summary is `Executed 6 tests, with 5 failures`.

- [ ] **Step 3: Implement the segmenter**

Append this to `MarkdownSegments.swift`, inside the `#if !os(macOS)` block, before its `#endif`:

```swift
/// Splits a `MarkdownAttributed`-rendered string into block segments using
/// the `MarkdownRunSemantics` annotations every run already carries (the
/// Mac copy path's source of truth), so segmentation and rendering can't
/// disagree about where a block starts.
///
/// - Fenced code: consecutive runs of one code block (same `blockIdentity`)
///   → `.code`, trailing newlines trimmed, language from the fence.
/// - Tables: consecutive `.tableCell` runs whose coordinates keep advancing
///   (`BlockKind.tableCellContinues`) → one `.table`; each cell's text is its
///   runs minus the cell-terminator newline.
/// - Everything else → `.text`, leading/trailing block newlines trimmed,
///   empty prose dropped.
enum MarkdownSegmenter {
    private enum Group {
        case prose(NSRange)
        case code(NSRange, language: String?)
        case table([(row: Int, column: Int, columnCount: Int, alignments: [TableAlignment], range: NSRange)])
    }

    static func segments(of attributed: NSAttributedString) -> [MarkdownSegment] {
        let text = attributed.string as NSString
        var groups: [Group] = []
        var lastCodeIdentity: Int?
        var lastCell: (row: Int, column: Int, identity: Int)?

        attributed.enumerateAttribute(
            MarkdownAttributed.semanticsKey,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            let semantics = value as? MarkdownRunSemantics
            switch semantics?.block {
            case .codeBlock(let language)?:
                let identity = semantics!.blockIdentity
                if case .code(let open, let openLanguage)? = groups.last, lastCodeIdentity == identity {
                    groups[groups.count - 1] = .code(NSUnionRange(open, range), language: openLanguage)
                } else {
                    groups.append(.code(range, language: language))
                }
                lastCodeIdentity = identity
                lastCell = nil
            case .tableCell(let row, let column, _, let columnCount, let alignments)?:
                let identity = semantics!.blockIdentity
                if case .table(var cells)? = groups.last, let previous = lastCell {
                    if previous.identity == identity, var last = cells.last {
                        // Another run of the same cell (inline styling).
                        last.range = NSUnionRange(last.range, range)
                        cells[cells.count - 1] = last
                        groups[groups.count - 1] = .table(cells)
                    } else if BlockKind.tableCellContinues((row, column), after: (previous.row, previous.column)) {
                        cells.append((row, column, columnCount, alignments, range))
                        groups[groups.count - 1] = .table(cells)
                    } else {
                        groups.append(.table([(row, column, columnCount, alignments, range)]))
                    }
                } else {
                    groups.append(.table([(row, column, columnCount, alignments, range)]))
                }
                lastCell = (row, column, identity)
                lastCodeIdentity = nil
            default:
                if case .prose(let open)? = groups.last {
                    groups[groups.count - 1] = .prose(NSUnionRange(open, range))
                } else {
                    groups.append(.prose(range))
                }
                lastCodeIdentity = nil
                lastCell = nil
            }
        }

        return groups.compactMap { group -> MarkdownSegment? in
            switch group {
            case .prose(let range):
                let trimmed = trimNewlines(range, in: text)
                guard trimmed.length > 0 else { return nil }
                return .text(attributed.attributedSubstring(from: trimmed))
            case .code(let range, let language):
                let code = text.substring(with: trimNewlines(range, in: text))
                return .code(language: language, code: code)
            case .table(let cells):
                guard let first = cells.first else { return nil }
                let rowCount = (cells.map(\.row).max() ?? 0) + 1
                var rows = Array(repeating: Array(repeating: NSAttributedString(), count: first.columnCount),
                                 count: rowCount)
                for cell in cells where cell.row < rowCount && cell.column < first.columnCount {
                    rows[cell.row][cell.column] = attributed.attributedSubstring(from: trimNewlines(cell.range, in: text))
                }
                let alignments = first.alignments.map { alignment -> MarkdownTable.Alignment in
                    switch alignment {
                    case .left: return .left
                    case .center: return .center
                    case .right: return .right
                    }
                }
                return .table(MarkdownTable(columnCount: first.columnCount, alignments: alignments, rows: rows))
            }
        }
    }

    /// `range` without leading/trailing "\n" — block separators and code /
    /// cell terminators, never content.
    private static func trimNewlines(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, text.character(at: start) == 0x0A { start += 1 }
        while end > start, text.character(at: end - 1) == 0x0A { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
```

Then, in `MarkdownAttributed.swift` `Rendered.init`, change `self.segments = []` to `self.segments = MarkdownSegmenter.segments(of: attributed)`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/MarkdownSegmentTests MatronTests/MarkdownAttributedPhoneTests`

Expected: `Executed 16 tests, with 0 failures`.

Then re-run the Task 3 Step 7 shared filter. Expected: 0 failures, because the Mac never compiles this code.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add MatronShared/Sources/DesignSystem/MarkdownSegments.swift MatronShared/Sources/DesignSystem/MarkdownAttributed.swift MatronTests/MarkdownSegmentTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "shared: iOS MarkdownSegmenter lifts code blocks and tables into their own segments" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: Link router

**Ruling on the spec:** the spec routes link taps "through the existing `MarkdownText.handle` / `MatronItemLink` policy". `MarkdownText.handle` returns SwiftUI's `OpenURLAction.Result`, which only means something inside SwiftUI's `openURL`. The shared decision is `MatronItemLink.action(for:)`, and the Mac text view (`SelectableMessageText.Coordinator`) already switches on it directly. The UIKit router does the same, so no shared code changes.

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineLinkRouter.swift`
- Test: `MatronTests/TimelineLinkRouterTests.swift`

**Interfaces:**
- Produces: `struct TimelineLinkRouter` with:
  - `var openTrackerItem: ((Int) -> Void)?`
  - `var openConversation: ((String) -> Void)?`
  - `var openExternally: @MainActor (URL) -> Void`
  - `enum Outcome: Equatable { case trackerItem(Int), conversation(String), swallowed, external(URL) }`
  - `@MainActor @discardableResult func route(_ url: URL) -> Outcome`
  - `static func isSystemLink(_ url: URL) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Matron

/// Spec §2 link taps: items, conversations and http route exactly as the
/// shared `MatronItemLink` policy says; `matron://` never reaches the OS.
@MainActor
final class TimelineLinkRouterTests: XCTestCase {
    private var items: [Int] = []
    private var convos: [String] = []
    private var external: [URL] = []

    private func router() -> TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: { self.items.append($0) },
                           openConversation: { self.convos.append($0) },
                           openExternally: { self.external.append($0) })
    }

    func test_itemLink_opensTheItemInApp() {
        XCTAssertEqual(router().route(URL(string: "matron://item/65")!), .trackerItem(65))
        XCTAssertEqual(items, [65])
        XCTAssertTrue(external.isEmpty)
    }

    func test_conversationLink_opensTheConversationInApp() {
        XCTAssertEqual(router().route(URL(string: "matron://convo/abc-1")!), .conversation("abc-1"))
        XCTAssertEqual(convos, ["abc-1"])
    }

    func test_httpLink_goesToTheSystem() {
        let url = URL(string: "https://example.com/x")!
        XCTAssertEqual(router().route(url), .external(url))
        XCTAssertEqual(external, [url])
        XCTAssertTrue(TimelineLinkRouter.isSystemLink(url))
    }

    func test_unknownMatronAndMatrixLinks_areSwallowed() {
        for string in ["matron://link?code=AAAA", "matrix:r/room:s", "matron://item/0"] {
            XCTAssertEqual(router().route(URL(string: string)!), .swallowed, string)
            XCTAssertFalse(TimelineLinkRouter.isSystemLink(URL(string: string)!))
        }
        XCTAssertTrue(items.isEmpty && convos.isEmpty && external.isEmpty)
    }

    func test_noHandlerInstalled_stillNeverOpensExternally() {
        var opened: [URL] = []
        let bare = TimelineLinkRouter(openTrackerItem: nil, openConversation: nil, openExternally: { opened.append($0) })
        XCTAssertEqual(bare.route(URL(string: "matron://item/7")!), .trackerItem(7))
        XCTAssertTrue(opened.isEmpty)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineLinkRouterTests`

Expected: the build fails with `cannot find 'TimelineLinkRouter' in scope`.

- [ ] **Step 3: Implement**

```swift
import UIKit
import MatronDesignSystem

/// Link taps from the UIKit timeline's text views and table grids. The
/// decision is `MatronItemLink.action(for:)` — the policy `MarkdownText`
/// and the Mac's `SelectableMessageText` share — so the three renderers
/// cannot drift. Item and conversation links resolve in-app (the `matron`
/// scheme is registered with nothing); with no handler installed they are
/// swallowed, never handed to the OS.
struct TimelineLinkRouter {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    /// Seam for tests; production hands the URL to the OS.
    var openExternally: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

    enum Outcome: Equatable {
        case trackerItem(Int)
        case conversation(String)
        case swallowed
        case external(URL)
    }

    @MainActor
    @discardableResult
    func route(_ url: URL) -> Outcome {
        switch MatronItemLink.action(for: url) {
        case .openTrackerItem(let number):
            openTrackerItem?(number)
            return .trackerItem(number)
        case .openConversation(let convoID):
            openConversation?(convoID)
            return .conversation(convoID)
        case .swallow, .openConsent:
            return .swallowed
        case .system(let url):
            openExternally(url)
            return .external(url)
        }
    }

    /// Whether UIKit's own default link action (Safari / universal links)
    /// should handle `url` — exactly the `.system` policy branch.
    static func isSystemLink(_ url: URL) -> Bool {
        if case .system = MatronItemLink.action(for: url) { return true }
        return false
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineLinkRouterTests`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineLinkRouter.swift MatronTests/TimelineLinkRouterTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineLinkRouter over the shared MatronItemLink policy" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase 2: Pure core

### Task 7: Row content and anchor ids

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineRowContent.swift`
- Test: `MatronTests/TimelineRowContentTests.swift`

**Interfaces:**
- Consumes:
  - `TimelineRow` and `TimelineItem`
  - `SubChatStripViewModel.subtaskDescription(fromMessageBody:)` and `.resolveSubtaskTarget(description:among:)`
  - `TimelineItemView.avatarSender(for:hasMultipleSenders:)` and `TimelineItemView.displayName(for:)`
  - `ConversationLinkRefs.extract(from:cache:)`
- Produces:
  - `struct TextRowContent: Equatable, Sendable` with:
    - `itemID`, `body`, `isOwn`, `sendState: TimelineSendState`, `timestamp`
    - `avatarSender: String?`, `senderLabel: String`, `pills: [ConversationLinkRef]`
    - `var isStreaming: Bool`
  - `struct HostedRowContent: Equatable, Sendable` with `row: TimelineRow`, `subtaskChild: SubChatSummary?`, `hasMultipleSenders: Bool`, `imagePixelSize: CGSize?`
  - `enum TimelineRowContent: Equatable, Sendable { case text(TextRowContent), hosted(HostedRowContent); var anchorID: String }`
  - `struct TimelineRowSource`
  - `enum TimelineRowContentBuilder` with `static func anchorID(for: TimelineRow) -> String` and `static func build(_ source: TimelineRowSource) -> BuiltRows`
  - `struct BuiltRows { let contents: [TimelineRowContent]; let droppedDuplicates: [String] }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import Matron

final class TimelineRowContentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func text(_ id: String, _ body: String, own: Bool = false, sender: String = "matron",
                      state: TimelineSendState = .sent) -> TimelineRow {
        .message(TimelineItem(id: id, sender: sender, timestamp: t0, kind: .text(body: body, formattedHTML: nil),
                              isOwn: own, sendState: state))
    }

    private func build(_ rows: [TimelineRow], multi: Bool = false, children: [SubChatSummary] = [],
                       pixel: CGSize? = nil) -> BuiltRows {
        TimelineRowContentBuilder.build(TimelineRowSource(
            rows: rows, hasMultipleSenders: multi, children: children, imagePixelSize: { _ in pixel }))
    }

    func test_anchorIDs_useItemIDsForMessages_andRowIDsForSeparators() {
        XCTAssertEqual(TimelineRowContentBuilder.anchorID(for: text("42", "hi")), "42")
        let separator = TimelineRow.separator(date: t0)
        XCTAssertEqual(TimelineRowContentBuilder.anchorID(for: separator), separator.id)
        XCTAssertTrue(separator.id.hasPrefix("sep:"))
    }

    func test_textMessages_becomeTextRows_everythingElseHosted() {
        let image = TimelineRow.message(TimelineItem(id: "7", sender: "matron", timestamp: t0,
            kind: .image(url: URL(string: "mxc://s/a"), caption: nil, sizeBytes: nil, expired: false), isOwn: false))
        let built = build([.separator(date: t0), text("1", "hello"), image], pixel: CGSize(width: 800, height: 600))
        XCTAssertEqual(built.contents.map(\.anchorID), [TimelineRow.separator(date: t0).id, "1", "7"])
        guard case .hosted = built.contents[0], case .text(let row) = built.contents[1],
              case .hosted(let hosted) = built.contents[2] else { return XCTFail("\(built.contents)") }
        XCTAssertEqual(row.body, "hello")
        XCTAssertEqual(row.senderLabel, "matron")
        XCTAssertEqual(hosted.imagePixelSize, CGSize(width: 800, height: 600),
                       "an image row's resolution is part of its content — resolving re-measures only that row")
    }

    func test_ownRow_carriesSendStateAndMeLabel_andNoAvatar() {
        let built = build([text("1", "sending…", own: true, sender: "@dan:s", state: .sending)], multi: true)
        guard case .text(let row) = built.contents[0] else { return XCTFail() }
        XCTAssertEqual(row.sendState, .sending)
        XCTAssertEqual(row.senderLabel, "Me")
        XCTAssertNil(row.avatarSender)
    }

    func test_multiSenderRoom_givesBotRowsAnAvatar_exceptTheStreamingPlaceholder() {
        let built = build([text("1", "a", sender: "dev-2"), text("eph:r", "streaming", sender: "agent")], multi: true)
        guard case .text(let real) = built.contents[0], case .text(let streaming) = built.contents[1] else { return XCTFail() }
        XCTAssertEqual(real.avatarSender, "dev-2")
        XCTAssertNil(streaming.avatarSender)
        XCTAssertTrue(streaming.isStreaming)
    }

    func test_conversationLinks_becomePills() {
        let built = build([text("1", "See [Auth](matron://convo/auth-1) and [Dark](matron://convo/dark-2).")])
        guard case .text(let row) = built.contents[0] else { return XCTFail() }
        XCTAssertEqual(row.pills.map(\.id), ["auth-1", "dark-2"])
    }

    func test_subtaskIndicator_withAMatchingChild_isHosted() throws {
        let body = "🔀 Subtask: Explore auth call sites"
        let description = try XCTUnwrap(SubChatStripViewModel.subtaskDescription(fromMessageBody: body))
        let child = SubChatSummary(id: "child-1", title: description, isRunning: true)
        let built = build([text("1", body)], children: [child])
        guard case .hosted(let hosted) = built.contents[0] else { return XCTFail("\(built.contents)") }
        XCTAssertEqual(hosted.subtaskChild?.id, "child-1")
    }

    func test_duplicateAnchorIDs_areDroppedAfterTheFirst() {
        let built = build([text("1", "first"), text("2", "two"), text("1", "again")])
        XCTAssertEqual(built.contents.map(\.anchorID), ["1", "2"])
        XCTAssertEqual(built.droppedDuplicates, ["1"])
    }
}
```

`SubChatSummary.init(id:title:isRunning:)` is the public initializer (`ChatSummary.swift` line 100), and `SubChatStripViewModel.subtaskDescription(fromMessageBody:)` parses a body that is exactly `"🔀 Subtask: <description>"`, which is the shape this test uses.

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineRowContentTests`

Expected: the build fails with `cannot find 'TimelineRowContentBuilder' in scope`.

- [ ] **Step 3: Implement**

`Matron/Features/Chat/Timeline/TimelineRowContent.swift`:

```swift
import Foundation
import CoreGraphics
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Everything a text row's pixels depend on — the measurement cache compares
/// it by value, so a change to any field is a re-measure (spec: cache key
/// includes the content). Value-only and `Sendable`: text rows are measured
/// off the main thread.
struct TextRowContent: Equatable, Sendable {
    let itemID: String
    let body: String
    let isOwn: Bool
    let sendState: TimelineSendState
    let timestamp: Date
    /// Non-nil only in multi-sender rooms, never for own rows or the
    /// streaming placeholder (`TimelineItemView.avatarSender`).
    let avatarSender: String?
    /// "Me" or the sender's display name — the text view's VoiceOver label.
    let senderLabel: String
    /// Conversation links in the body → the pill row under the bubble.
    let pills: [ConversationLinkRef]

    /// The mid-turn streaming overlay row (`eph:`), re-rendered per commit.
    var isStreaming: Bool { itemID.hasPrefix("eph:") }
}

/// A row rendered by existing SwiftUI views in a hosted cell: separators,
/// tool calls, diffs, ask-user / agent-chat / agent-spawn cards, markers,
/// subtask cards, images and files. Hosted views read their live
/// `ChatViewModel` state themselves (Observation) and self-report size
/// changes; the fields here are what the controller must re-measure for.
struct HostedRowContent: Equatable, Sendable {
    let row: TimelineRow
    /// Resolved child for a bridge "🔀 Subtask:" indicator → tappable card.
    let subtaskChild: SubChatSummary?
    let hasMultipleSenders: Bool
    /// `ChatViewModel.imagePixelSize(for:)` for image rows — flips from nil
    /// when the bytes land, so resolving an image re-measures that row only.
    let imagePixelSize: CGSize?
}

enum TimelineRowContent: Equatable, Sendable {
    case text(TextRowContent)
    case hosted(HostedRowContent)

    /// Scroll-anchor id: ITEM id for messages, row id for separators — the
    /// id space `pendingFocusID`, `rowAnchorIDs` and scroll memory use.
    var anchorID: String {
        switch self {
        case .text(let text): return text.itemID
        case .hosted(let hosted): return TimelineRowContentBuilder.anchorID(for: hosted.row)
        }
    }
}

/// The view-model state one build reads. `imagePixelSize` runs on the main
/// actor (the builder only runs there).
struct TimelineRowSource {
    let rows: [TimelineRow]
    let hasMultipleSenders: Bool
    let children: [SubChatSummary]
    let imagePixelSize: (URL) -> CGSize?
}

struct BuiltRows {
    let contents: [TimelineRowContent]
    /// Anchor ids seen more than once; the later copies were dropped (a
    /// diffable data source traps on duplicate identifiers).
    let droppedDuplicates: [String]
}

enum TimelineRowContentBuilder {
    static func anchorID(for row: TimelineRow) -> String {
        if case .message(let item) = row { return item.id }
        return row.id
    }

    static func build(_ source: TimelineRowSource) -> BuiltRows {
        var seen = Set<String>()
        var contents: [TimelineRowContent] = []
        var dropped: [String] = []
        contents.reserveCapacity(source.rows.count)
        for row in source.rows {
            let id = anchorID(for: row)
            guard seen.insert(id).inserted else {
                dropped.append(id)
                continue
            }
            contents.append(content(for: row, source: source))
        }
        return BuiltRows(contents: contents, droppedDuplicates: dropped)
    }

    private static func content(for row: TimelineRow, source: TimelineRowSource) -> TimelineRowContent {
        guard case .message(let item) = row else {
            return .hosted(HostedRowContent(row: row, subtaskChild: nil,
                                            hasMultipleSenders: source.hasMultipleSenders, imagePixelSize: nil))
        }
        let child = subtaskChild(for: item, children: source.children)
        if case .text(let body, _) = item.kind, child == nil {
            return .text(TextRowContent(
                itemID: item.id,
                body: body,
                isOwn: item.isOwn,
                sendState: item.sendState,
                timestamp: item.timestamp,
                avatarSender: TimelineItemView.avatarSender(for: item, hasMultipleSenders: source.hasMultipleSenders),
                senderLabel: item.isOwn ? "Me" : TimelineItemView.displayName(for: item.sender),
                pills: ConversationLinkRefs.extract(from: body, cache: !item.isEphemeralStreamingPlaceholder)))
        }
        var pixelSize: CGSize?
        if case .image(let url?, _, _, _) = item.kind { pixelSize = source.imagePixelSize(url) }
        return .hosted(HostedRowContent(row: row, subtaskChild: child,
                                        hasMultipleSenders: source.hasMultipleSenders, imagePixelSize: pixelSize))
    }

    /// Same resolution as the SwiftUI path's `TimelineListContent.subtaskChild(for:)`.
    private static func subtaskChild(for item: TimelineItem, children: [SubChatSummary]) -> SubChatSummary? {
        guard case .text(let body, _) = item.kind, !item.isOwn,
              let description = SubChatStripViewModel.subtaskDescription(fromMessageBody: body)
        else { return nil }
        return SubChatStripViewModel.resolveSubtaskTarget(description: description, among: children)
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineRowContentTests`

Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineRowContent.swift MatronTests/TimelineRowContentTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineRowContent — value-typed text/hosted rows in anchor-id space, duplicates dropped" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: `TimelineScrollModel`: geometry and follow-tail

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineScrollModel.swift`
- Test: `MatronTests/TimelineScrollModelTests.swift`

**Interfaces:**
- Produces a `struct TimelineScrollModel: Equatable` with:
  - Nested types: `Metrics` (`topInset` 16, `bottomInset` 16, `rowSpacing` 8, `nearBottomThreshold` 100, `nearTopScreens` 1.5), `Row { let id: String; var height: CGFloat }`, `Anchor { let rowID: String; let offsetInRow: CGFloat }`.
  - State: `rows`, `footerHeight`, `viewportHeight`, `contentOffsetY`, `isFollowingTail`, `windowContainsTail`.
  - Geometry: `stackHeight`, `alignmentPad`, `contentHeight`, `maxOffsetY`, `rowMinY(at:)`, `index(of:)`, `height(of:)`, `footerMinY`.
  - Mutators: `replaceRows(_:footerHeight:)`, `updateHeight(ofRow:to:)`, `setFooterHeight(_:)`, `setViewportHeight(_:)`, `followTail()`, `stopFollowing()`.
  - Tasks 9–10 add anchoring, gestures, jumps, triggers and restores.

The SwiftUI geometry this mirrors is `VStack(spacing: 8)` inside `.padding(.vertical)` (16), with the activity footer placed after the bottom padding and `defaultScrollAnchor(.bottom, for: .alignment)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Matron

/// Spec §4 unit tests — geometry + follow-tail. Rows are 100pt unless noted;
/// stack = 16 + rows + 8·(n−1) + 16 + footer.
final class TimelineScrollModelTests: XCTestCase {
    func rows(_ ids: [String], height: CGFloat = 100) -> [TimelineScrollModel.Row] {
        ids.map { .init(id: $0, height: height) }
    }

    func model(_ ids: [String], viewport: CGFloat, height: CGFloat = 100) -> TimelineScrollModel {
        var model = TimelineScrollModel()
        model.setViewportHeight(viewport)
        model.replaceRows(rows(ids, height: height), footerHeight: 0)
        return model
    }

    func test_emptyModel_hasViewportContent_andZeroOffset() {
        var model = TimelineScrollModel()
        model.setViewportHeight(500)
        XCTAssertEqual(model.contentHeight, 500)
        XCTAssertEqual(model.contentOffsetY, 0)
    }

    func test_stackGeometry_matchesTheVStack() {
        let model = model(["a", "b", "c"], viewport: 250)
        XCTAssertEqual(model.stackHeight, 16 + 300 + 16 + 16)
        XCTAssertEqual(model.rowMinY(at: 0), 16)
        XCTAssertEqual(model.rowMinY(at: 1), 124)
        XCTAssertEqual(model.rowMinY(at: 2), 232)
        XCTAssertEqual(model.maxOffsetY, 348 - 250)
    }

    func test_opensFollowingTheTail_atTheBottom() {
        let model = model(["a", "b", "c"], viewport: 250)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_shortContent_hugsTheBottom() {
        let model = model(["only"], viewport: 400, height: 50)
        XCTAssertEqual(model.alignmentPad, 400 - (16 + 50 + 16))
        XCTAssertEqual(model.rowMinY(at: 0) + 50 + 16, 400, "row bottom + bottom inset sits on the viewport bottom")
        XCTAssertEqual(model.contentOffsetY, 0)
    }

    func test_followTail_pinsThroughGrowth() {
        var model = model(["a", "b", "c"], viewport: 250)
        model.updateHeight(ofRow: "c", to: 400)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        model.replaceRows(rows(["a", "b", "c", "d"]), footerHeight: 0)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_footer_sitsBelowTheBottomInset_andPinsWhileFollowing() {
        var model = model(["a", "b"], viewport: 150)
        let before = model.maxOffsetY
        model.setFooterHeight(40)
        XCTAssertEqual(model.footerMinY, model.rowMinY(at: 1) + 100 + 16)
        XCTAssertEqual(model.maxOffsetY, before + 40)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"], "the footer never enters the anchor space")
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineScrollModelTests`

Expected: the build fails with `cannot find 'TimelineScrollModel' in scope`.

- [ ] **Step 3: Implement the geometry core**

`Matron/Features/Chat/Timeline/TimelineScrollModel.swift`:

```swift
import CoreGraphics

/// The UIKit timeline's geometry and scroll state, with no UIKit in it
/// (spec §2 "pure-logic core"). Heights come in exact (measured, never
/// estimated); the model answers where every row sits and where the
/// viewport must be after any change — `ChatTimelineController` writes
/// `contentOffsetY` to the collection view and nothing else moves it.
///
/// Coordinates: content space, top-down. A conversation shorter than the
/// viewport hugs the bottom (`alignmentPad`), like the SwiftUI path's
/// `defaultScrollAnchor(.bottom, for: .alignment)`.
struct TimelineScrollModel: Equatable {
    struct Metrics: Equatable {
        /// `.padding(.vertical)` around the SwiftUI `VStack`.
        var topInset: CGFloat = 16
        var bottomInset: CGFloat = 16
        /// `VStack(spacing: 8)`.
        var rowSpacing: CGFloat = 8
        /// "At the bottom" — `ChatView.nearBottomThresholdPt`.
        var nearBottomThreshold: CGFloat = 100
        /// Reveal older history within this many screens of the top (spec).
        var nearTopScreens: CGFloat = 1.5
    }

    struct Row: Equatable {
        let id: String
        var height: CGFloat
    }

    /// A viewport position by row identity: the row and how far the
    /// reference edge sits below that row's top.
    struct Anchor: Equatable {
        let rowID: String
        let offsetInRow: CGFloat
    }

    let metrics: Metrics
    private(set) var rows: [Row] = []
    private(set) var footerHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0
    private(set) var contentOffsetY: CGFloat = 0
    private(set) var isFollowingTail = true
    /// Mirrors `ChatViewModel.windowContainsTail`: follow-tail may only
    /// re-arm when the rendered window really ends at the live tail.
    var windowContainsTail = true

    private var tops: [CGFloat] = []
    private var indexByID: [String: Int] = [:]
    private var rowsBottom: CGFloat = 0

    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
        rowsBottom = metrics.topInset
    }

    // MARK: Geometry

    var stackHeight: CGFloat { rowsBottom + metrics.bottomInset + footerHeight }
    var alignmentPad: CGFloat { max(0, viewportHeight - stackHeight) }
    var contentHeight: CGFloat { max(stackHeight, viewportHeight) }
    var maxOffsetY: CGFloat { max(0, contentHeight - viewportHeight) }
    var footerMinY: CGFloat { alignmentPad + rowsBottom + metrics.bottomInset }

    func rowMinY(at index: Int) -> CGFloat { alignmentPad + tops[index] }
    func index(of id: String) -> Int? { indexByID[id] }
    func height(of id: String) -> CGFloat? { indexByID[id].map { rows[$0].height } }

    // MARK: Content changes

    mutating func replaceRows(_ newRows: [Row], footerHeight newFooter: CGFloat) {
        rows = newRows
        footerHeight = newFooter
        rebuild()
        settle()
    }

    mutating func updateHeight(ofRow id: String, to height: CGFloat) {
        guard let index = indexByID[id], rows[index].height != height else { return }
        rows[index].height = height
        rebuild()
        settle()
    }

    mutating func setFooterHeight(_ height: CGFloat) {
        guard height != footerHeight else { return }
        footerHeight = height
        settle()
    }

    // MARK: Viewport

    mutating func setViewportHeight(_ height: CGFloat) {
        guard height != viewportHeight else { return }
        viewportHeight = height
        settle()
    }

    // MARK: Follow-tail

    mutating func followTail() {
        isFollowingTail = true
        contentOffsetY = maxOffsetY
    }

    mutating func stopFollowing() {
        isFollowingTail = false
    }

    // MARK: Internals

    private mutating func rebuild() {
        tops.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        var y = metrics.topInset
        for (index, row) in rows.enumerated() {
            tops.append(y)
            indexByID[row.id] = index
            y += row.height
            if index < rows.count - 1 { y += metrics.rowSpacing }
        }
        rowsBottom = y
    }

    /// After any change: pinned while following, else clamped (Task 9
    /// replaces this with anchor preservation).
    private mutating func settle() {
        if isFollowingTail {
            contentOffsetY = maxOffsetY
        } else {
            contentOffsetY = min(max(0, contentOffsetY), maxOffsetY)
        }
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineScrollModelTests`

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineScrollModel.swift MatronTests/TimelineScrollModelTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineScrollModel geometry — exact stack, bottom hug, follow-tail pin" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 9: `TimelineScrollModel`: anchor preservation and rescue

**Files:**
- Modify: `Matron/Features/Chat/Timeline/TimelineScrollModel.swift`
- Test: `MatronTests/TimelineScrollModelAnchorTests.swift`

**Interfaces:**
- Consumes: Task 8's model.
- Produces:
  - `func topAnchor() -> Anchor?` and `func bottomAnchor() -> Anchor?`
  - `mutating func noteUserOffset(_ y: CGFloat)`
  - `struct Rescue: Equatable { let lostRowID: String; let survivorID: String? }`
  - `private(set) var lastRescue: Rescue?`
  - The content mutators now keep the top anchor fixed whenever the model is not following.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Matron

/// Spec §4: prepend keeps the anchor exactly; unpinned growth above the
/// viewport doesn't move content; vanished-anchor rescue.
final class TimelineScrollModelAnchorTests: XCTestCase {
    private func rows(_ ids: [String], height: CGFloat = 100) -> [TimelineScrollModel.Row] {
        ids.map { .init(id: $0, height: height) }
    }

    /// Ten 100pt rows a…j, viewport 300, reader parked at y = 450.
    private func reading() -> TimelineScrollModel {
        var model = TimelineScrollModel()
        model.setViewportHeight(300)
        model.replaceRows(rows(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]), footerHeight: 0)
        model.stopFollowing()
        model.noteUserOffset(450)
        return model
    }

    private func onScreenY(_ model: TimelineScrollModel, _ id: String) -> CGFloat {
        model.rowMinY(at: model.index(of: id)!) - model.contentOffsetY
    }

    func test_topAnchor_isTheFirstVisibleRow() {
        let model = reading()
        // d spans 340…440, e spans 448…548 → e is the first row still visible at 450.
        XCTAssertEqual(model.topAnchor(), .init(rowID: "e", offsetInRow: 2))
    }

    func test_prepend_keepsTheAnchorExactly() {
        var model = reading()
        let before = onScreenY(model, "e")
        model.replaceRows(rows(["x", "y", "z"]) + model.rows, footerHeight: 0)
        XCTAssertEqual(onScreenY(model, "e"), before)
        XCTAssertEqual(model.contentOffsetY, 450 + 3 * 108)
    }

    func test_growthAboveTheViewport_doesNotMoveContent() {
        var model = reading()
        let before = onScreenY(model, "f")
        model.updateHeight(ofRow: "b", to: 150)
        XCTAssertEqual(onScreenY(model, "f"), before)
    }

    func test_growthBelowTheViewport_leavesTheOffsetAlone() {
        var model = reading()
        model.updateHeight(ofRow: "j", to: 600)
        XCTAssertEqual(model.contentOffsetY, 450)
    }

    func test_separatorsNeverAnchor() {
        var model = TimelineScrollModel()
        model.setViewportHeight(300)
        model.replaceRows([.init(id: "sep:1", height: 30), .init(id: "a", height: 100), .init(id: "b", height: 400)],
                          footerHeight: 0)
        model.stopFollowing()
        model.noteUserOffset(20)
        XCTAssertEqual(model.topAnchor()?.rowID, "a", "day separators relocate when the window head moves")
    }

    func test_vanishedAnchor_rescuedByNearestSurvivor() {
        var model = reading()
        var next = model.rows
        next.removeAll { $0.id == "e" }
        model.replaceRows(next, footerHeight: 0)
        XCTAssertEqual(model.lastRescue, .init(lostRowID: "e", survivorID: "f"))
        XCTAssertEqual(model.contentOffsetY, model.rowMinY(at: model.index(of: "f")!))
    }

    func test_nothingSurvives_goesToTheBottom() {
        var model = reading()
        model.replaceRows(rows(["p", "q", "r", "s"]), footerHeight: 0)
        XCTAssertEqual(model.lastRescue, .init(lostRowID: "e", survivorID: nil))
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_bottomAnchor_isTheLastRowStartingAboveTheBottomEdge() {
        let model = reading()
        // Bottom edge at 750: h spans 772…, g spans 664…764 → g, 86pt below its top.
        XCTAssertEqual(model.bottomAnchor(), .init(rowID: "g", offsetInRow: 86))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineScrollModelAnchorTests`

Expected: the build fails with `value of type 'TimelineScrollModel' has no member 'noteUserOffset'`.

- [ ] **Step 3: Implement anchoring**

In `TimelineScrollModel.swift`, add these properties after `var windowContainsTail = true`:

```swift
    /// Set by the last content change whose anchor row vanished — the
    /// controller breadcrumbs it (spec: nearest-survivor rescue).
    struct Rescue: Equatable {
        let lostRowID: String
        let survivorID: String?
    }
    private(set) var lastRescue: Rescue?
```

Replace the three content mutators (`replaceRows`, `updateHeight`, `setFooterHeight`) with:

```swift
    mutating func replaceRows(_ newRows: [Row], footerHeight newFooter: CGFloat) {
        let anchor = isFollowingTail ? nil : topAnchor()
        let previousIDs = rows.map(\.id)
        rows = newRows
        footerHeight = newFooter
        rebuild()
        settle(keeping: anchor, previousIDs: previousIDs)
    }

    mutating func updateHeight(ofRow id: String, to height: CGFloat) {
        guard let index = indexByID[id], rows[index].height != height else { return }
        let anchor = isFollowingTail ? nil : topAnchor()
        rows[index].height = height
        rebuild()
        settle(keeping: anchor, previousIDs: rows.map(\.id))
    }

    mutating func setFooterHeight(_ height: CGFloat) {
        guard height != footerHeight else { return }
        let anchor = isFollowingTail ? nil : topAnchor()
        footerHeight = height
        settle(keeping: anchor, previousIDs: rows.map(\.id))
    }

    /// The user's own scrolling (and UIKit bounce) — recorded, not clamped.
    mutating func noteUserOffset(_ y: CGFloat) {
        contentOffsetY = y
    }

    // MARK: Anchors

    /// First visible non-separator row, and how far the viewport's TOP edge
    /// sits below that row's top. Separators never anchor: they are day-keyed
    /// and relocate when the window head moves.
    func topAnchor() -> Anchor? {
        for (index, row) in rows.enumerated() where !row.id.hasPrefix("sep:") {
            let minY = rowMinY(at: index)
            if minY + row.height > contentOffsetY {
                return Anchor(rowID: row.id, offsetInRow: contentOffsetY - minY)
            }
        }
        return nil
    }

    /// Last non-separator row starting above the viewport's BOTTOM edge, and
    /// how far that edge sits below the row's top — what a keyboard resize
    /// keeps fixed while reading history (Messages behaviour).
    func bottomAnchor() -> Anchor? {
        let bottomEdge = contentOffsetY + viewportHeight
        for index in rows.indices.reversed() where !rows[index].id.hasPrefix("sep:") {
            let minY = rowMinY(at: index)
            if minY < bottomEdge {
                return Anchor(rowID: rows[index].id, offsetInRow: bottomEdge - minY)
            }
        }
        return nil
    }
```

Replace `private mutating func settle()` with:

```swift
    private mutating func settle() {
        settle(keeping: nil, previousIDs: [])
    }

    /// After any change: pinned while following; otherwise the anchor row
    /// keeps its on-screen position, or its nearest survivor takes its
    /// place, or — nothing survives — the viewport goes to the bottom.
    private mutating func settle(keeping anchor: Anchor?, previousIDs: [String]) {
        lastRescue = nil
        if isFollowingTail {
            contentOffsetY = maxOffsetY
            return
        }
        guard let anchor else {
            clampOffset()
            return
        }
        if let index = indexByID[anchor.rowID] {
            contentOffsetY = rowMinY(at: index) + min(anchor.offsetInRow, rows[index].height)
        } else if let survivor = nearestSurvivor(of: anchor.rowID, in: previousIDs),
                  let index = indexByID[survivor] {
            lastRescue = Rescue(lostRowID: anchor.rowID, survivorID: survivor)
            contentOffsetY = rowMinY(at: index)
        } else {
            lastRescue = Rescue(lostRowID: anchor.rowID, survivorID: nil)
            contentOffsetY = maxOffsetY
        }
        clampOffset()
    }

    /// Nearest still-present, non-separator neighbour of `id` in the
    /// previous row order — below first (the row that slides into its
    /// place), then above, widening one step at a time.
    private func nearestSurvivor(of id: String, in previousIDs: [String]) -> String? {
        guard let origin = previousIDs.firstIndex(of: id) else { return nil }
        var step = 1
        while origin + step < previousIDs.count || origin - step >= 0 {
            for candidate in [origin + step, origin - step] where previousIDs.indices.contains(candidate) {
                let candidateID = previousIDs[candidate]
                if !candidateID.hasPrefix("sep:"), indexByID[candidateID] != nil { return candidateID }
            }
            step += 1
        }
        return nil
    }

    private mutating func clampOffset() {
        contentOffsetY = min(max(0, contentOffsetY), maxOffsetY)
    }
```

Also change `setViewportHeight` to call `settle()`, unchanged for now. Task 10 replaces it.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineScrollModelAnchorTests MatronTests/TimelineScrollModelTests`

Expected: `Executed 14 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineScrollModel.swift MatronTests/TimelineScrollModelAnchorTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineScrollModel keeps the top anchor through prepends/growth, nearest-survivor rescue" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 10: `TimelineScrollModel`: gestures, jumps, viewport resize, triggers, restore

**Files:**
- Modify: `Matron/Features/Chat/Timeline/TimelineScrollModel.swift`
- Test: `MatronTests/TimelineScrollModelInteractionTests.swift`

**Interfaces:**
- Produces:
  - `mutating func beginUserDrag() -> Bool` and `mutating func endUserScroll() -> Bool`; both return whether the follow mode changed.
  - `mutating func jumpOffset(toRow:) -> CGFloat?`
  - `mutating func restore(_ anchor: Anchor) -> Bool` and `mutating func restoreBottomAligned(rowID:) -> Bool`
  - `var isNearTop: Bool`, `var isNearBottom: Bool`, `var visibleRowIDs: [String]`
  - `setViewportHeight` now keeps the bottom-visible row fixed while not following.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Matron

/// Spec §4: follow-tail transitions, jump offset math, keyboard resize while
/// pinned or unpinned, edge triggers.
final class TimelineScrollModelInteractionTests: XCTestCase {
    private func model(count: Int = 10, viewport: CGFloat = 300) -> TimelineScrollModel {
        var model = TimelineScrollModel()
        model.setViewportHeight(viewport)
        model.replaceRows((0..<count).map { .init(id: "r\($0)", height: 100) }, footerHeight: 0)
        return model
    }

    func test_drag_releasesFollow_andGrowthNoLongerPins() {
        var model = model()
        XCTAssertTrue(model.beginUserDrag())
        XCTAssertFalse(model.beginUserDrag(), "already released")
        model.noteUserOffset(200)
        model.updateHeight(ofRow: "r9", to: 500)
        XCTAssertEqual(model.contentOffsetY, 200)
    }

    func test_settleNearTheBottom_reArmsFollow_onlyWhenTheWindowHoldsTheTail() {
        var model = model()
        _ = model.beginUserDrag()
        model.noteUserOffset(model.maxOffsetY - 60)
        model.windowContainsTail = false
        XCTAssertFalse(model.endUserScroll(), "a detached window's bottom is not the tail")
        model.windowContainsTail = true
        XCTAssertTrue(model.endUserScroll())
        XCTAssertTrue(model.isFollowingTail)
    }

    func test_settleFarFromTheBottom_staysReleased() {
        var model = model()
        _ = model.beginUserDrag()
        model.noteUserOffset(100)
        XCTAssertFalse(model.endUserScroll())
        XCTAssertFalse(model.isFollowingTail)
    }

    func test_jump_landsTheRowTopAtTheViewportTop_orClampsAtTheBottom() {
        var model = model()
        XCTAssertEqual(model.jumpOffset(toRow: "r3"), model.rowMinY(at: 3))
        XCTAssertFalse(model.isFollowingTail)
        XCTAssertEqual(model.jumpOffset(toRow: "r9"), model.maxOffsetY)
        XCTAssertNil(model.jumpOffset(toRow: "missing"))
    }

    func test_keyboardResize_whilePinned_staysAtTheBottom() {
        var model = model(viewport: 600)
        model.setViewportHeight(300)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        model.setViewportHeight(600)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_keyboardResize_whileReading_keepsTheBottomVisibleRowFixed() {
        var model = model(viewport: 600)
        _ = model.beginUserDrag()
        model.noteUserOffset(100)
        let before = model.bottomAnchor()!
        let onScreenBottom = model.rowMinY(at: model.index(of: before.rowID)!) - model.contentOffsetY
        model.setViewportHeight(300)
        let after = model.rowMinY(at: model.index(of: before.rowID)!) - model.contentOffsetY
        XCTAssertEqual(after, onScreenBottom - 300, "the row keeps its distance from the viewport's bottom edge")
    }

    func test_edgeTriggers() {
        var model = model(count: 20, viewport: 300)
        _ = model.beginUserDrag()
        model.noteUserOffset(449)
        XCTAssertTrue(model.isNearTop, "within 1.5 screens")
        model.noteUserOffset(451)
        XCTAssertFalse(model.isNearTop)
        model.noteUserOffset(model.maxOffsetY - 100)
        XCTAssertTrue(model.isNearBottom)
        model.noteUserOffset(model.maxOffsetY - 101)
        XCTAssertFalse(model.isNearBottom)
    }

    func test_visibleRowIDs() {
        var model = model()
        _ = model.beginUserDrag()
        model.noteUserOffset(100)
        // [100, 400): r0 ends at 116, r3 starts at 340, r4 starts at 448.
        XCTAssertEqual(model.visibleRowIDs, ["r0", "r1", "r2", "r3"])
    }

    func test_restore_topAnchor_andBottomAligned() {
        var model = model()
        XCTAssertTrue(model.restore(.init(rowID: "r4", offsetInRow: 30)))
        XCTAssertEqual(model.contentOffsetY, model.rowMinY(at: 4) + 30)
        XCTAssertFalse(model.isFollowingTail)
        XCTAssertTrue(model.restoreBottomAligned(rowID: "r5"))
        XCTAssertEqual(model.contentOffsetY, model.rowMinY(at: 5) + 100 - 300)
        XCTAssertFalse(model.restore(.init(rowID: "gone", offsetInRow: 0)))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineScrollModelInteractionTests`

Expected: the build fails with `value of type 'TimelineScrollModel' has no member 'beginUserDrag'`.

- [ ] **Step 3: Implement**

Replace `setViewportHeight` with:

```swift
    /// Keyboard / composer / rotation resize. Following: stay pinned.
    /// Reading: the bottom-visible row keeps its distance from the bottom
    /// edge, the way Messages behaves (spec §2 Keyboard).
    mutating func setViewportHeight(_ height: CGFloat) {
        guard height != viewportHeight else { return }
        guard !isFollowingTail, viewportHeight > 0, let anchor = bottomAnchor() else {
            viewportHeight = height
            settle()
            return
        }
        viewportHeight = height
        if let index = indexByID[anchor.rowID] {
            contentOffsetY = rowMinY(at: index) + anchor.offsetInRow - height
        }
        clampOffset()
    }
```

Add these after `stopFollowing()`:

```swift
    /// A real drag began: only a user gesture releases follow-tail.
    mutating func beginUserDrag() -> Bool {
        guard isFollowingTail else { return false }
        isFollowingTail = false
        return true
    }

    /// Scrolling settled: re-arm follow when parked at the true tail.
    mutating func endUserScroll() -> Bool {
        guard !isFollowingTail, isNearBottom, windowContainsTail else { return false }
        isFollowingTail = true
        return true
    }

    /// Jump (seq / search / milestone): the row's top at the viewport top,
    /// or as close as the content allows. Releases follow-tail.
    mutating func jumpOffset(toRow id: String) -> CGFloat? {
        guard let index = indexByID[id] else { return nil }
        isFollowingTail = false
        contentOffsetY = rowMinY(at: index)
        clampOffset()
        return contentOffsetY
    }

    /// Scroll-memory restore of a top anchor (UIKit timeline's own entries).
    mutating func restore(_ anchor: Anchor) -> Bool {
        guard let index = indexByID[anchor.rowID] else { return false }
        isFollowingTail = false
        contentOffsetY = rowMinY(at: index) + anchor.offsetInRow
        clampOffset()
        return true
    }

    /// Scroll-memory restore of a SwiftUI-path entry (bottom-anchored id).
    mutating func restoreBottomAligned(rowID id: String) -> Bool {
        guard let index = indexByID[id] else { return false }
        isFollowingTail = false
        contentOffsetY = rowMinY(at: index) + rows[index].height - viewportHeight
        clampOffset()
        return true
    }

    // MARK: Edges

    var isNearTop: Bool { contentOffsetY < metrics.nearTopScreens * viewportHeight }
    var isNearBottom: Bool { maxOffsetY - contentOffsetY <= metrics.nearBottomThreshold }

    var visibleRowIDs: [String] {
        let top = contentOffsetY
        let bottom = contentOffsetY + viewportHeight
        return rows.indices.compactMap { index in
            let minY = rowMinY(at: index)
            return (minY + rows[index].height > top && minY < bottom) ? rows[index].id : nil
        }
    }
```

- [ ] **Step 4: Run all model tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineScrollModelInteractionTests MatronTests/TimelineScrollModelAnchorTests MatronTests/TimelineScrollModelTests`

Expected: `Executed 23 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineScrollModel.swift MatronTests/TimelineScrollModelInteractionTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineScrollModel gestures, jumps, keyboard resize, edge triggers, restores" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 11: Measurement cache and height provider

**Ruling on the spec:** the spec's cache key is "(row id, content hash, width, Dynamic Type size)". `TimelineItem.Kind` is `Equatable` but not `Hashable`, so the key here is (room id, row id, width, size category), and each entry stores the content it was measured for. A lookup hits only when the stored content `==` the current content. The effect is the same as a hash, with no false-hit risk.

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineMeasureCache.swift`
- Test: `MatronTests/TimelineHeightProviderTests.swift`

**Interfaces:**
- Consumes: `TimelineRowContent`, `TextRowContent`, `TimelineTextStyle`.
- Produces:
  - `struct TimelineMeasureKey: Hashable, Sendable`
  - `enum TimelineMeasurement: Sendable { case text(TextRowRender), hosted(CGFloat); var height: CGFloat }`
  - `final class TimelineMeasureCache: @unchecked Sendable` with `static let shared`, `init(countLimit:)`, `measurement(for:content:)`, `store(_:content:key:)` and `removeAll()`
  - `protocol TimelineRowMeasuring: AnyObject, Sendable` with `backgroundTextRender(_:width:style:) -> TextRowRender?`, `@MainActor measure(_:width:style:) -> TimelineMeasurement` and `@MainActor footerHeight(label:width:style:) -> CGFloat`
  - `@MainActor final class TimelineHeightProvider` with `cached`, `measurement`, `storeHostedHeight`, `missingText(in:width:style:excluding:)` and `precompute(_:width:style:) async -> Set<String>`. The last one returns the ids that need the main thread.
  - `TextRowRender` is created in Task 14. This task declares a minimal `final class TextRowRender` placeholder with exactly the Task 14 initializer signature, and Task 14 replaces the file section. See Step 3.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import MatronModels
@testable import Matron

/// Spec §4: cache invalidation on width or Dynamic Type change, with a fake
/// measurer; precompute fills the cache off the main thread.
@MainActor
final class TimelineHeightProviderTests: XCTestCase {
    final class FakeMeasurer: TimelineRowMeasuring, @unchecked Sendable {
        var mainCalls = 0
        let backgroundCalls = LockedCounter()
        func backgroundTextRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender? {
            backgroundCalls.increment()
            if content.body.contains("NEEDS-MAIN") { return nil }
            return TextRowRender(content: content, segments: [], layout: .fixed(height: CGFloat(content.body.count)),
                                 timestampText: "", style: style)
        }
        func measure(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement {
            mainCalls += 1
            return .hosted(width / 10 + style.bodySize)
        }
        func footerHeight(label: String, width: CGFloat, style: TimelineTextStyle) -> CGFloat { 30 }
    }

    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let large = TimelineStyleFixture.large
    private let huge = TimelineTextStyle(sizeCategory: .accessibilityExtraLarge)

    private func text(_ id: String, _ body: String) -> TextRowContent {
        TextRowContent(itemID: id, body: body, isOwn: false, sendState: .sent,
                       timestamp: Date(timeIntervalSince1970: 0), avatarSender: nil, senderLabel: "matron", pills: [])
    }

    private func provider(_ measurer: FakeMeasurer) -> TimelineHeightProvider {
        TimelineHeightProvider(roomID: "!r", cache: TimelineMeasureCache(countLimit: 100), measurer: measurer)
    }

    func test_secondLookup_isACacheHit() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "hello"))
        _ = heights.measurement(row, width: 390, style: large)
        _ = heights.measurement(row, width: 390, style: large)
        XCTAssertEqual(fake.mainCalls, 1)
    }

    func test_widthChange_isAMiss() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "hello"))
        _ = heights.measurement(row, width: 390, style: large)
        XCTAssertEqual(heights.measurement(row, width: 600, style: large).height, 60 + 17)
        XCTAssertEqual(fake.mainCalls, 2)
    }

    func test_dynamicTypeChange_isAMiss() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "hello"))
        _ = heights.measurement(row, width: 390, style: large)
        _ = heights.measurement(row, width: 390, style: huge)
        XCTAssertEqual(fake.mainCalls, 2)
    }

    func test_contentChange_underTheSameID_isAMiss() {
        let fake = FakeMeasurer(), heights = provider(fake)
        _ = heights.measurement(.text(text("1", "hello")), width: 390, style: large)
        _ = heights.measurement(.text(text("1", "hello, edited")), width: 390, style: large)
        XCTAssertEqual(fake.mainCalls, 2)
    }

    func test_precompute_fillsTheCache_andReportsMainThreadOnlyRows() async {
        let fake = FakeMeasurer(), heights = provider(fake)
        let rows = [text("1", "one"), text("2", "NEEDS-MAIN table"), text("3", "three")]
        let needsMain = await heights.precompute(rows, width: 390, style: large)
        XCTAssertEqual(needsMain, ["2"])
        XCTAssertEqual(fake.backgroundCalls.count, 3)
        XCTAssertEqual(heights.cached(.text(rows[0]), width: 390, style: large)?.height, 3)
        XCTAssertNil(heights.cached(.text(rows[1]), width: 390, style: large))
        let missing = heights.missingText(in: rows.map(TimelineRowContent.text), width: 390, style: large,
                                          excluding: needsMain)
        XCTAssertTrue(missing.isEmpty, "precomputed rows and main-thread-only rows are both excluded")
        XCTAssertEqual(fake.mainCalls, 0)
    }

    func test_storeHostedHeight_overridesTheEntry() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "x"))
        _ = heights.measurement(row, width: 390, style: large)
        heights.storeHostedHeight(123, for: row, width: 390, style: large)
        XCTAssertEqual(heights.cached(row, width: 390, style: large)?.height, 123)
    }
}

enum TimelineStyleFixture {
    static let large = TimelineTextStyle(sizeCategory: .large)
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineHeightProviderTests`

Expected: the build fails with `cannot find type 'TimelineRowMeasuring' in scope`.

- [ ] **Step 3: Implement**

`Matron/Features/Chat/Timeline/TimelineMeasureCache.swift`:

```swift
import Foundation
import CoreGraphics
import MatronDesignSystem

struct TimelineMeasureKey: Hashable, Sendable {
    let roomID: String
    let rowID: String
    let width: CGFloat
    /// `UIContentSizeCategory.rawValue` — Dynamic Type is part of the key.
    let sizeCategory: String
}

enum TimelineMeasurement: Sendable {
    /// A text row: its full render (segments + frames), laid out once.
    case text(TextRowRender)
    /// A hosted row or a self-reported override: the height only.
    case hosted(CGFloat)

    var height: CGFloat {
        switch self {
        case .text(let render): return render.layout.rowHeight
        case .hosted(let height): return height
        }
    }
}

/// Process-wide measurement memo (reopening a room is a cache walk, not a
/// re-layout). An entry hits only when its stored content `==` the row's
/// current content. `NSCache` is thread-safe; precompute writes from a
/// background task.
final class TimelineMeasureCache: @unchecked Sendable {
    static let shared = TimelineMeasureCache(countLimit: 4000)

    private final class KeyBox: NSObject {
        let key: TimelineMeasureKey
        init(_ key: TimelineMeasureKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }

    private final class EntryBox: NSObject {
        let content: TimelineRowContent
        let measurement: TimelineMeasurement
        init(content: TimelineRowContent, measurement: TimelineMeasurement) {
            self.content = content
            self.measurement = measurement
        }
    }

    private let storage = NSCache<KeyBox, EntryBox>()

    init(countLimit: Int) {
        storage.countLimit = countLimit
    }

    func measurement(for key: TimelineMeasureKey, content: TimelineRowContent) -> TimelineMeasurement? {
        guard let entry = storage.object(forKey: KeyBox(key)), entry.content == content else { return nil }
        return entry.measurement
    }

    func store(_ measurement: TimelineMeasurement, content: TimelineRowContent, key: TimelineMeasureKey) {
        storage.setObject(EntryBox(content: content, measurement: measurement), forKey: KeyBox(key))
    }

    func removeAll() {
        storage.removeAllObjects()
    }
}

/// How rows get measured. `backgroundTextRender` runs on any thread and
/// returns nil when the row needs the main thread (pills, tables — hosted
/// SwiftUI pieces); everything else happens on the main actor.
protocol TimelineRowMeasuring: AnyObject, Sendable {
    func backgroundTextRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender?
    @MainActor func measure(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement
    @MainActor func footerHeight(label: String, width: CGFloat, style: TimelineTextStyle) -> CGFloat
}

/// The controller's measuring front: cache first, measure synchronously on
/// a miss (spec), precompute batches off the main thread.
@MainActor
final class TimelineHeightProvider {
    let roomID: String
    let measurer: TimelineRowMeasuring
    private let cache: TimelineMeasureCache

    init(roomID: String, cache: TimelineMeasureCache, measurer: TimelineRowMeasuring) {
        self.roomID = roomID
        self.cache = cache
        self.measurer = measurer
    }

    private func key(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasureKey {
        TimelineMeasureKey(roomID: roomID, rowID: content.anchorID, width: width,
                           sizeCategory: style.sizeCategory.rawValue)
    }

    func cached(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement? {
        cache.measurement(for: key(content, width: width, style: style), content: content)
    }

    func measurement(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement {
        if let hit = cached(content, width: width, style: style) { return hit }
        let measured = measurer.measure(content, width: width, style: style)
        cache.store(measured, content: content, key: key(content, width: width, style: style))
        return measured
    }

    /// A hosted cell reported a new height (ask card answered, image landed).
    func storeHostedHeight(_ height: CGFloat, for content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) {
        cache.store(.hosted(height), content: content, key: key(content, width: width, style: style))
    }

    /// Text rows with no cache entry, minus those known to need the main
    /// thread (`excluding`) and those with pills (always main-thread).
    func missingText(in contents: [TimelineRowContent], width: CGFloat, style: TimelineTextStyle,
                     excluding mainThreadOnly: Set<String>) -> [TextRowContent] {
        contents.compactMap { content in
            guard case .text(let text) = content, text.pills.isEmpty,
                  !mainThreadOnly.contains(text.itemID),
                  cached(content, width: width, style: style) == nil else { return nil }
            return text
        }
    }

    /// Renders `texts` on a background task and stores them. Returns the
    /// ids that turned out to need the main thread (tables).
    func precompute(_ texts: [TextRowContent], width: CGFloat, style: TimelineTextStyle) async -> Set<String> {
        let measurer = measurer, cache = cache, roomID = roomID
        return await Task.detached(priority: .userInitiated) {
            var needsMain = Set<String>()
            for text in texts {
                guard let render = measurer.backgroundTextRender(text, width: width, style: style) else {
                    needsMain.insert(text.itemID)
                    continue
                }
                let content = TimelineRowContent.text(text)
                cache.store(.text(render), content: content,
                            key: TimelineMeasureKey(roomID: roomID, rowID: text.itemID, width: width,
                                                    sizeCategory: style.sizeCategory.rawValue))
            }
            return needsMain
        }.value
    }
}
```

Task 14 owns `TextRowRender` and `TextRowLayout`. So that this task compiles and is testable now, create `Matron/Features/Chat/Timeline/TextRowRenderer.swift` with only the following. Task 13 moves `TextRowLayout` to `TextBubbleGeometry.swift`, and Task 14 extends this file.

```swift
import CoreGraphics
import MatronDesignSystem

/// Every frame of one laid-out text row (cell coordinates unless noted).
struct TextRowLayout: Equatable {
    var rowHeight: CGFloat
    var bubbleFrame: CGRect
    /// Bubble coordinates.
    var segmentFrames: [CGRect]
    /// Bubble coordinates.
    var timestampFrame: CGRect
    var avatarFrame: CGRect?
    var pillsFrame: CGRect?
    var sendStateFrame: CGRect?

    /// Test/fake convenience: a row of `height` with no content frames.
    static func fixed(height: CGFloat) -> TextRowLayout {
        TextRowLayout(rowHeight: height, bubbleFrame: .zero, segmentFrames: [], timestampFrame: .zero,
                      avatarFrame: nil, pillsFrame: nil, sendStateFrame: nil)
    }
}

/// One measured text row: what the cell draws and the layout it draws it in.
/// Immutable, so `@unchecked Sendable` is sound (NSAttributedString segments
/// are never mutated after rendering).
final class TextRowRender: @unchecked Sendable {
    let content: TextRowContent
    let segments: [MarkdownSegment]
    let layout: TextRowLayout
    let timestampText: String
    let style: TimelineTextStyle

    init(content: TextRowContent, segments: [MarkdownSegment], layout: TextRowLayout,
         timestampText: String, style: TimelineTextStyle) {
        self.content = content
        self.segments = segments
        self.layout = layout
        self.timestampText = timestampText
        self.style = style
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineHeightProviderTests`

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineMeasureCache.swift Matron/Features/Chat/Timeline/TextRowRenderer.swift MatronTests/TimelineHeightProviderTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: content-checked measurement cache + height provider with background precompute" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase 3: Measurement

**Ruling on the spec:** the Mac measures with TextKit 1 (`NSLayoutManager`) because its `NSTextView` uses TextKit 1 for tables. iOS cells are TextKit 2 `UITextView`s, as the spec requires, so iOS measures with a standalone TextKit 2 stack. Measurement and display then run on the same engine, and Task 12 pins the two to agree.

### Task 12: TextKit 2 measurement and the shared text view factory

**Files:**
- Create: `Matron/Features/Chat/Timeline/TextKitMeasure.swift`
- Test: `MatronTests/TextKitMeasureTests.swift`

**Interfaces:**
- Produces:
  - `enum TextKitMeasure` with `struct Result: Equatable { var size: CGSize; var lastBaseline: CGFloat }`, `static func measure(_:width:) -> Result` and `static func hugging(_:width:) -> Result`
  - `enum TimelineTextViewFactory { @MainActor static func make() -> UITextView }`. This is the one configuration every timeline text view uses.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import UIKit
import MatronDesignSystem
@testable import Matron

/// The measured size must be exactly what a live TextKit 2 `UITextView`
/// renders — that equality is what lets the layout know exact content
/// height with no estimates (spec §2 Self-sizing).
@MainActor
final class TextKitMeasureTests: XCTestCase {
    private let style = MarkdownAttributed.Style.phoneChat(bodySize: 17)
    private func rendered(_ source: String) -> NSAttributedString {
        MarkdownAttributed.rendered(for: source, style: style, cache: false).attributed
    }

    func test_emptyString_measuresZero() {
        XCTAssertEqual(TextKitMeasure.measure(NSAttributedString(), width: 300),
                       .init(size: .zero, lastBaseline: 0))
    }

    func test_shortText_hugsItsWidth() {
        let result = TextKitMeasure.hugging(rendered("Hi"), width: 300)
        XCTAssertLessThan(result.size.width, 40)
        XCTAssertGreaterThan(result.size.height, 15)
    }

    func test_longText_wrapsAtTheWidth() {
        let one = TextKitMeasure.hugging(rendered("word"), width: 200).size.height
        let result = TextKitMeasure.hugging(rendered(String(repeating: "word ", count: 60)), width: 200)
        XCTAssertLessThanOrEqual(result.size.width, 200)
        XCTAssertGreaterThan(result.size.height, one * 3)
    }

    func test_lastBaseline_sitsInsideTheLastLine() {
        let text = rendered("First line that wraps across several lines at this width for sure.")
        let result = TextKitMeasure.hugging(text, width: 120)
        XCTAssertLessThan(result.lastBaseline, result.size.height)
        XCTAssertGreaterThan(result.lastBaseline, result.size.height - 17 * 1.5)
    }

    func test_matchesALiveTextView() {
        let corpus = [
            "Hi",
            "A paragraph long enough to wrap onto a few lines at phone widths, with **bold** and `code`.",
            "# Heading\n\nBody under it.\n\n- one\n- two with a [link](https://example.com)\n\n> quoted",
            "1. first\n2. second item that goes on and wraps around at narrow widths\n3. third",
            String(repeating: "x", count: 300),
        ]
        for source in corpus {
            for width in [180.0, 269.0, 301.0] as [CGFloat] {
                let text = rendered(source)
                let measured = TextKitMeasure.hugging(text, width: width)
                let view = TimelineTextViewFactory.make()
                view.attributedText = text
                let live = view.sizeThatFits(CGSize(width: measured.size.width, height: .greatestFiniteMagnitude))
                XCTAssertEqual(ceil(live.height), measured.size.height, accuracy: 0.5,
                               "\(source.prefix(20)) @\(width)")
            }
        }
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TextKitMeasureTests`

Expected: the build fails with `cannot find 'TextKitMeasure' in scope`.

- [ ] **Step 3: Implement**

`Matron/Features/Chat/Timeline/TextKitMeasure.swift`:

```swift
import UIKit

/// Exact TextKit 2 measurement of an attributed string at a width — the same
/// engine and geometry (`lineFragmentPadding` 0, no insets) as the timeline's
/// `UITextView`s (`TimelineTextViewFactory`). A pure function of (string,
/// width), safe on any thread: each call owns a private stack.
enum TextKitMeasure {
    struct Result: Equatable {
        var size: CGSize
        /// The last line's baseline, measured from the top of the text —
        /// `MessageBubble` aligns the timestamp to it (`.lastTextBaseline`).
        var lastBaseline: CGFloat
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> Result {
        guard text.length > 0, width > 0 else { return Result(size: .zero, lastBaseline: 0) }
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.attributedString = text
        manager.ensureLayout(for: manager.documentRange)

        var lastBaseline: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.endLocation,
                                             options: [.reverse, .ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.last {
                lastBaseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            }
            return false
        }
        let used = manager.usageBoundsForTextContainer
        return Result(size: CGSize(width: min(ceil(used.width), width), height: ceil(used.maxY)),
                      lastBaseline: lastBaseline)
    }

    /// Measures at `width`, then — when the text is narrower — re-measures
    /// at its own hugged width, because that is the frame the live view
    /// gets (bubbles hug their text). Same two-pass rule as the Mac's
    /// `MarkdownAttributed.Rendered.size(width:)`.
    static func hugging(_ text: NSAttributedString, width: CGFloat) -> Result {
        let first = measure(text, width: width)
        guard first.size.width > 0, first.size.width < width.rounded(.down) else { return first }
        let rewrapped = measure(text, width: first.size.width)
        return Result(size: CGSize(width: first.size.width, height: rewrapped.size.height),
                      lastBaseline: rewrapped.lastBaseline)
    }
}

/// The one configuration every timeline text view uses — measured parity
/// (`TextKitMeasureTests.test_matchesALiveTextView`) depends on it.
enum TimelineTextViewFactory {
    @MainActor
    static func make() -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.dataDetectorTypes = []
        view.linkTextAttributes = [
            .foregroundColor: UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        return view
    }
}
```

Never touch `view.layoutManager` on these views: that call switches them to TextKit 1.

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TextKitMeasureTests`

Expected: `Executed 5 tests, with 0 failures`.

If `test_matchesALiveTextView` fails, the measurement is not the engine the view uses. Diagnose it with the `sizeThatFits` numbers the failure prints. Do not add tolerance.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TextKitMeasure.swift MatronTests/TextKitMeasureTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TextKit 2 measurement pinned equal to the live timeline UITextView" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 13: Bubble geometry (the UIKit `MessageBubble`)

**Ruling on the spec:** "timestamp and send state drawn in UIKit" copies `MessageBubble` exactly.
- The time is not inline in the last line. It is a column to the right of the content, in `HStack(alignment: .lastTextBaseline, spacing: 6)`, so the text wraps at the bubble width minus 6 minus the time's width.
- When the message ends in a code block or table, the time's baseline sits at that block's bottom edge.

**Files:**
- Create: `Matron/Features/Chat/Timeline/TextBubbleGeometry.swift` (moves `TextRowLayout` here from `TextRowRenderer.swift`)
- Modify: `Matron/Features/Chat/Timeline/TextRowRenderer.swift` (delete the `TextRowLayout` struct; it now lives in `TextBubbleGeometry.swift`)
- Modify: `MatronShared/Sources/DesignSystem/SenderAvatar.swift` (`static let diameter` becomes `public static let diameter`)
- Test: `MatronTests/TextBubbleGeometryTests.swift`

**Interfaces:**
- Produces:
  - `enum TextBubbleGeometry` with the constants `rowPadding` 16, `ownLeadingInset` 32, `avatarDiameter` 24, `avatarGap` 6, `bubblePaddingH` 12, `bubblePaddingV` 8, `timestampGap` 6, `maxBubbleWidth` 760, `pillsGap` 4, `sendStateGap` 2 and `cornerRadius` 8
  - `struct Timestamp { size; ascent }` and `struct Content { size; lastBaseline; segmentFrames }`
  - `static func wrapWidth(rowWidth:isOwn:hasAvatar:timestampWidth:) -> CGFloat`
  - `static func layout(rowWidth:isOwn:hasAvatar:timestamp:content:pillsHeight:sendStateHeight:) -> TextRowLayout`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Matron

/// Mirrors `MessageBubble` + `TimelineItemView`'s own-row VStack exactly.
final class TextBubbleGeometryTests: XCTestCase {
    private let stamp = TextBubbleGeometry.Timestamp(size: CGSize(width: 30, height: 13), ascent: 10)
    private var wraps: [CGFloat] = []

    private func content(_ size: CGSize = CGSize(width: 100, height: 20), baseline: CGFloat = 16)
        -> (CGFloat) -> TextBubbleGeometry.Content {
        { wrap in
            self.wraps.append(wrap)
            return .init(size: size, lastBaseline: baseline, segmentFrames: [CGRect(origin: .zero, size: size)])
        }
    }

    private func layout(width: CGFloat = 393, own: Bool = false, avatar: Bool = false,
                        pills: ((CGFloat) -> CGFloat)? = nil, sendState: CGFloat? = nil,
                        size: CGSize = CGSize(width: 100, height: 20), baseline: CGFloat = 16) -> TextRowLayout {
        TextBubbleGeometry.layout(rowWidth: width, isOwn: own, hasAvatar: avatar, timestamp: stamp,
                                  content: content(size, baseline: baseline), pillsHeight: pills,
                                  sendStateHeight: sendState)
    }

    func test_botBubble_hugsItsContent_atTheLeadingEdge() {
        let result = layout()
        XCTAssertEqual(wraps, [361 - 24 - 6 - 30])
        XCTAssertEqual(result.bubbleFrame, CGRect(x: 16, y: 0, width: 160, height: 36))
        XCTAssertEqual(result.segmentFrames, [CGRect(x: 12, y: 8, width: 100, height: 20)])
        XCTAssertEqual(result.timestampFrame, CGRect(x: 118, y: 14, width: 30, height: 13))
        XCTAssertEqual(result.rowHeight, 36)
        XCTAssertNil(result.avatarFrame)
    }

    func test_ownBubble_sitsAtTheTrailingEdge_withTheOwnInset() {
        let result = layout(own: true)
        XCTAssertEqual(wraps, [361 - 32 - 60])
        XCTAssertEqual(result.bubbleFrame.maxX, 393 - 16)
    }

    func test_avatar_indentsTheBubble_andBottomAligns() {
        let result = layout(avatar: true)
        XCTAssertEqual(wraps, [361 - 30 - 60])
        XCTAssertEqual(result.bubbleFrame.minX, 46)
        XCTAssertEqual(result.avatarFrame, CGRect(x: 16, y: 12, width: 24, height: 24))
    }

    func test_ownRows_neverGetAnAvatar() {
        let result = layout(own: true, avatar: true)
        XCTAssertNil(result.avatarFrame)
        XCTAssertEqual(wraps, [361 - 32 - 60])
    }

    func test_timestampTallerThanTheContentBaseline_liftsTheContent() {
        let result = layout(size: CGSize(width: 100, height: 8), baseline: 5)
        XCTAssertEqual(result.segmentFrames[0].minY, 8 + 5)
        XCTAssertEqual(result.timestampFrame.minY, 8)
        XCTAssertEqual(result.bubbleFrame.height, 16 + 13)
    }

    func test_pillsAndSendState_stackUnderTheBubble() {
        let result = layout(own: true, pills: { _ in 30 }, sendState: 14)
        XCTAssertEqual(result.pillsFrame, CGRect(x: 0, y: 40, width: 393, height: 30))
        XCTAssertEqual(result.sendStateFrame, CGRect(x: 16, y: 72, width: 361, height: 14))
        XCTAssertEqual(result.rowHeight, 86)
    }

    func test_wideWindow_capsTheBubbleAt760() {
        _ = layout(width: 1200)
        XCTAssertEqual(wraps, [760 - 60])
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TextBubbleGeometryTests`

Expected: the build fails with `cannot find 'TextBubbleGeometry' in scope`.

- [ ] **Step 3: Implement**

In `MatronShared/Sources/DesignSystem/SenderAvatar.swift`, change `static let diameter: CGFloat = 24` to `public static let diameter: CGFloat = 24`.

Cut the `TextRowLayout` struct, including its `fixed(height:)` helper, from `TextRowRenderer.swift`, and paste it at the bottom of the new `Matron/Features/Chat/Timeline/TextBubbleGeometry.swift`:

```swift
import CoreGraphics
import MatronDesignSystem

/// UIKit twin of `MessageBubble` (+ `TimelineItemView`'s pill row and
/// own-message send-state VStack). Every number here is read off the
/// SwiftUI source so the two timelines lay a message out identically:
///   - row: `.padding(.horizontal)` = 16 each side
///   - own: `.padding(.leading, 32)`; bot with avatar: avatar 24 + gap 6
///   - bubble: `.padding(.horizontal, 12).padding(.vertical, 8)`, capped
///     at `MessageBubbleMetrics.maxWidth`, corner radius 8
///   - content + time: `HStack(alignment: .lastTextBaseline, spacing: 6)`
///   - pills: `VStack(spacing: 4)` under the bubble, full row width
///   - send state: `VStack(alignment: .trailing, spacing: 2)`
enum TextBubbleGeometry {
    static let rowPadding: CGFloat = 16
    static let ownLeadingInset: CGFloat = 32
    static let avatarDiameter: CGFloat = SenderAvatar.diameter
    static let avatarGap: CGFloat = 6
    static let bubblePaddingH: CGFloat = 12
    static let bubblePaddingV: CGFloat = 8
    static let timestampGap: CGFloat = 6
    static let maxBubbleWidth: CGFloat = MessageBubbleMetrics.maxWidth
    static let pillsGap: CGFloat = 4
    static let sendStateGap: CGFloat = 2
    static let cornerRadius: CGFloat = 8

    struct Timestamp: Equatable {
        let size: CGSize
        /// The time font's ascender — its baseline below the label top.
        let ascent: CGFloat
    }

    /// The message's content column measured at a wrap width.
    struct Content: Equatable {
        let size: CGSize
        let lastBaseline: CGFloat
        /// Content-column coordinates.
        let segmentFrames: [CGRect]
    }

    private static func leadingInset(isOwn: Bool, hasAvatar: Bool) -> CGFloat {
        if isOwn { return ownLeadingInset }
        return hasAvatar ? avatarDiameter + avatarGap : 0
    }

    /// The width the message text wraps at inside a row `rowWidth` wide.
    static func wrapWidth(rowWidth: CGFloat, isOwn: Bool, hasAvatar: Bool, timestampWidth: CGFloat) -> CGFloat {
        let inner = rowWidth - 2 * rowPadding
        let bubbleMax = min(inner - leadingInset(isOwn: isOwn, hasAvatar: hasAvatar), maxBubbleWidth)
        return max(0, bubbleMax - 2 * bubblePaddingH - timestampGap - timestampWidth)
    }

    static func layout(rowWidth: CGFloat, isOwn: Bool, hasAvatar: Bool, timestamp: Timestamp,
                       content measure: (CGFloat) -> Content,
                       pillsHeight: ((CGFloat) -> CGFloat)?, sendStateHeight: CGFloat?) -> TextRowLayout {
        let showsAvatar = hasAvatar && !isOwn
        let wrap = wrapWidth(rowWidth: rowWidth, isOwn: isOwn, hasAvatar: showsAvatar,
                             timestampWidth: timestamp.size.width)
        let content = measure(wrap)

        // `.lastTextBaseline`: the content's last baseline and the time's
        // baseline share one line; whichever sits lower sets the offset.
        let contentTop: CGFloat
        let timestampTop: CGFloat
        if content.lastBaseline >= timestamp.ascent {
            contentTop = 0
            timestampTop = content.lastBaseline - timestamp.ascent
        } else {
            contentTop = timestamp.ascent - content.lastBaseline
            timestampTop = 0
        }
        let stackHeight = max(contentTop + content.size.height, timestampTop + timestamp.size.height)
        let bubbleWidth = 2 * bubblePaddingH + content.size.width + timestampGap + timestamp.size.width
        let bubbleHeight = 2 * bubblePaddingV + stackHeight
        let bubbleX = isOwn
            ? rowWidth - rowPadding - bubbleWidth
            : rowPadding + leadingInset(isOwn: false, hasAvatar: showsAvatar)
        let bubble = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)

        let segments = content.segmentFrames.map {
            $0.offsetBy(dx: bubblePaddingH, dy: bubblePaddingV + contentTop)
        }
        let time = CGRect(x: bubblePaddingH + content.size.width + timestampGap, y: bubblePaddingV + timestampTop,
                          width: timestamp.size.width, height: timestamp.size.height)
        let avatar = showsAvatar
            ? CGRect(x: rowPadding, y: bubble.maxY - avatarDiameter, width: avatarDiameter, height: avatarDiameter)
            : nil

        var bottom = bubble.maxY
        var pills: CGRect?
        if let pillsHeight {
            let frame = CGRect(x: 0, y: bottom + pillsGap, width: rowWidth, height: pillsHeight(rowWidth))
            pills = frame
            bottom = frame.maxY
        }
        var sendState: CGRect?
        if let sendStateHeight {
            let frame = CGRect(x: rowPadding, y: bottom + sendStateGap,
                               width: rowWidth - 2 * rowPadding, height: sendStateHeight)
            sendState = frame
            bottom = frame.maxY
        }
        return TextRowLayout(rowHeight: ceil(bottom), bubbleFrame: bubble, segmentFrames: segments,
                             timestampFrame: time, avatarFrame: avatar, pillsFrame: pills, sendStateFrame: sendState)
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TextBubbleGeometryTests MatronTests/TimelineHeightProviderTests`

Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TextBubbleGeometry.swift Matron/Features/Chat/Timeline/TextRowRenderer.swift MatronShared/Sources/DesignSystem/SenderAvatar.swift MatronTests/TextBubbleGeometryTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TextBubbleGeometry — MessageBubble's layout as pure math" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 14: Text row renderer

**Files:**
- Modify: `Matron/Features/Chat/Timeline/TextRowRenderer.swift` (add `HostedPiece`, `CodeBlockMetrics` and `TextRowRenderer`; `TextRowRender` stays)
- Test: `MatronTests/TextRowRendererTests.swift`

**Interfaces:**
- Consumes: `MarkdownAttributed.rendered(for:style:cache:)`, `MarkdownSegment`, `TextKitMeasure`, `TextBubbleGeometry`, `TimelineTextStyle`.
- Produces:
  - `enum HostedPiece { case pills(TextRowContent), table(MarkdownTable) }`
  - `enum CodeBlockMetrics` with `headerSpacing` 4, `codePadding` 8, `unboundedWidth` 100_000, `headerHeight(style:)`, `attributed(_:style:)`, `codeSize(_:style:)` and `height(code:style:)`
  - `enum TextRowRenderer` with:
    - `segments(for:style:) -> [MarkdownSegment]`
    - `needsHosting(_:segments:) -> Bool`
    - `backgroundRender(_:width:style:) -> TextRowRender?`
    - `render(_:width:style:hosted: @escaping (HostedPiece, CGFloat) -> CGFloat) -> TextRowRender`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import UIKit
import MatronModels
import MatronDesignSystem
@testable import Matron

final class TextRowRendererTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func content(_ body: String, own: Bool = false, state: TimelineSendState = .sent,
                         pills: [ConversationLinkRef] = []) -> TextRowContent {
        TextRowContent(itemID: "1", body: body, isOwn: own, sendState: state, timestamp: t0,
                       avatarSender: nil, senderLabel: own ? "Me" : "matron", pills: pills)
    }

    private func wrap(_ render: TextRowRender) -> CGFloat {
        TextBubbleGeometry.wrapWidth(rowWidth: 393, isOwn: render.content.isOwn, hasAvatar: false,
                                     timestampWidth: render.layout.timestampFrame.width)
    }

    func test_plainRow_layoutMatchesItsParts() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content("Hello there"), width: 393, style: style))
        XCTAssertEqual(render.segments.count, 1)
        XCTAssertEqual(render.layout.bubbleFrame.minX, 16)
        XCTAssertEqual(render.layout.rowHeight, render.layout.bubbleFrame.height)
        guard case .text(let text) = render.segments[0] else { return XCTFail() }
        XCTAssertEqual(render.layout.segmentFrames[0].height, TextKitMeasure.hugging(text, width: wrap(render)).size.height)
    }

    func test_ownSendingRow_addsTheSendStateLine() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content("On my way", own: true, state: .sending),
                                                                    width: 393, style: style))
        let sendState = try XCTUnwrap(render.layout.sendStateFrame)
        XCTAssertEqual(render.layout.rowHeight, ceil(sendState.maxY))
    }

    func test_codeBlock_takesTheFullWrapWidth_andItsOwnHeight() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(
            content("Run this:\n\n```sh\nmake test\n```"), width: 393, style: style))
        XCTAssertEqual(render.segments.count, 2)
        XCTAssertEqual(render.layout.segmentFrames[1].width, wrap(render))
        XCTAssertEqual(render.layout.segmentFrames[1].height, CodeBlockMetrics.height(code: "make test", style: style))
    }

    func test_backgroundRender_refusesRowsThatNeedHosting() {
        XCTAssertNil(TextRowRenderer.backgroundRender(content("| a |\n|---|\n| 1 |"), width: 393, style: style))
        XCTAssertNil(TextRowRenderer.backgroundRender(
            content("see [x](matron://convo/x)", pills: [ConversationLinkRef(id: "x", text: "x")]), width: 393, style: style))
        XCTAssertNotNil(TextRowRenderer.backgroundRender(content("plain"), width: 393, style: style))
    }

    func test_render_usesTheHostedPiecesHeights() {
        let render = TextRowRenderer.render(content("Table:\n\n| a |\n|---|\n| 1 |"), width: 393, style: style) { piece, _ in
            if case .table = piece { return 77 }
            return 0
        }
        XCTAssertEqual(render.layout.segmentFrames.last?.height, 77)
    }

    func test_emptyBody_rendersATimestampOnlyBubble() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content(""), width: 393, style: style))
        XCTAssertTrue(render.segments.isEmpty)
        XCTAssertGreaterThan(render.layout.rowHeight, 0)
        XCTAssertEqual(render.layout.bubbleFrame.width, 24 + 6 + render.layout.timestampFrame.width)
    }

    func test_unbrokenToken_wrapsInsideTheBubble() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content(String(repeating: "a", count: 500)),
                                                                    width: 393, style: style))
        XCTAssertLessThanOrEqual(render.layout.segmentFrames[0].width, wrap(render))
        XCTAssertLessThanOrEqual(render.layout.bubbleFrame.maxX, 393 - 16)
        XCTAssertGreaterThan(render.layout.segmentFrames[0].height, 17 * 3)
    }

    func test_timestampText_matchesTheSwiftUIFormat() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content("x"), width: 393, style: style))
        XCTAssertEqual(render.timestampText, t0.formatted(.dateTime.hour().minute()))
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TextRowRendererTests`

Expected: the build fails with `cannot find 'TextRowRenderer' in scope`.

- [ ] **Step 3: Implement**

Add the following to `TextRowRenderer.swift`, below `TextRowRender`, and add `import UIKit` at the top of the file:

```swift
/// A SwiftUI piece inside a text row that only a hosting controller can
/// measure — so a row containing one is measured on the main thread.
enum HostedPiece {
    case pills(TextRowContent)
    case table(MarkdownTable)
}

/// Geometry of `CodeBlockSegmentView` — mirrors `CodeBlock` (language label
/// + copy button, 4pt gap, monospaced callout in a horizontally scrolling
/// box with 8pt padding). Code never wraps, so height is width-independent.
enum CodeBlockMetrics {
    static let headerSpacing: CGFloat = 4
    static let codePadding: CGFloat = 8
    static let unboundedWidth: CGFloat = 100_000

    static func headerHeight(style: TimelineTextStyle) -> CGFloat {
        ceil(max(style.codeHeaderFont.lineHeight, style.copyIconFont.lineHeight))
    }

    static func attributed(_ code: String, style: TimelineTextStyle) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: style.codeFont, .foregroundColor: UIColor.label])
    }

    static func codeSize(_ code: String, style: TimelineTextStyle) -> CGSize {
        TextKitMeasure.measure(attributed(code, style: style), width: unboundedWidth).size
    }

    static func height(code: String, style: TimelineTextStyle) -> CGFloat {
        headerHeight(style: style) + headerSpacing + codeSize(code, style: style).height + 2 * codePadding
    }
}

/// Renders and lays out one text row: markdown → segments → measured
/// content column → `TextBubbleGeometry`. Thread-safe except for `hosted`,
/// which the caller supplies (main thread) or refuses (`backgroundRender`).
enum TextRowRenderer {
    static func segments(for content: TextRowContent, style: TimelineTextStyle) -> [MarkdownSegment] {
        MarkdownAttributed.rendered(for: content.body, style: style.markdown, cache: !content.isStreaming).segments
    }

    static func needsHosting(_ content: TextRowContent, segments: [MarkdownSegment]) -> Bool {
        !content.pills.isEmpty || segments.contains(where: \.isTable)
    }

    /// Off-main precompute: nil when the row has pills or a table.
    static func backgroundRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender? {
        let segments = segments(for: content, style: style)
        guard !needsHosting(content, segments: segments) else { return nil }
        return render(content, segments: segments, width: width, style: style) { _, _ in
            preconditionFailure("hosted pieces are measured on the main thread")
        }
    }

    static func render(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle,
                       hosted: @escaping (HostedPiece, CGFloat) -> CGFloat) -> TextRowRender {
        render(content, segments: segments(for: content, style: style), width: width, style: style, hosted: hosted)
    }

    private static func render(_ content: TextRowContent, segments: [MarkdownSegment], width: CGFloat,
                               style: TimelineTextStyle,
                               hosted: @escaping (HostedPiece, CGFloat) -> CGFloat) -> TextRowRender {
        // `Text(timestamp, format: .dateTime.hour().minute())` in MessageBubble.
        let timestampText = content.timestamp.formatted(.dateTime.hour().minute())
        let font = style.timestampFont
        let timeWidth = TextKitMeasure.measure(
            NSAttributedString(string: timestampText, attributes: [.font: font]), width: 1_000).size.width
        let timestamp = TextBubbleGeometry.Timestamp(size: CGSize(width: timeWidth, height: ceil(font.lineHeight)),
                                                     ascent: font.ascender)
        let layout = TextBubbleGeometry.layout(
            rowWidth: width, isOwn: content.isOwn, hasAvatar: content.avatarSender != nil, timestamp: timestamp,
            content: { wrap in measureSegments(segments, wrapWidth: wrap, style: style, hosted: hosted) },
            pillsHeight: content.pills.isEmpty ? nil : { rowWidth in hosted(.pills(content), rowWidth) },
            sendStateHeight: (content.isOwn && content.sendState != .sent) ? ceil(font.lineHeight) : nil)
        return TextRowRender(content: content, segments: segments, layout: layout,
                             timestampText: timestampText, style: style)
    }

    /// Stacks segments with the style's block gap. Prose hugs; code and
    /// tables are greedy (MarkdownUI's code block fills the bubble width).
    /// A message ending in a code block or table puts its "last baseline"
    /// at that block's bottom edge.
    private static func measureSegments(_ segments: [MarkdownSegment], wrapWidth: CGFloat, style: TimelineTextStyle,
                                        hosted: (HostedPiece, CGFloat) -> CGFloat) -> TextBubbleGeometry.Content {
        var frames: [CGRect] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var lastBaseline: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { y += style.segmentSpacing }
            switch segment {
            case .text(let text):
                let measured = TextKitMeasure.hugging(text, width: wrapWidth)
                frames.append(CGRect(x: 0, y: y, width: measured.size.width, height: measured.size.height))
                lastBaseline = y + measured.lastBaseline
                y += measured.size.height
                width = max(width, measured.size.width)
            case .code(_, let code):
                let height = CodeBlockMetrics.height(code: code, style: style)
                frames.append(CGRect(x: 0, y: y, width: wrapWidth, height: height))
                y += height
                lastBaseline = y
                width = wrapWidth
            case .table(let table):
                let height = hosted(.table(table), wrapWidth)
                frames.append(CGRect(x: 0, y: y, width: wrapWidth, height: height))
                y += height
                lastBaseline = y
                width = wrapWidth
            }
        }
        return TextBubbleGeometry.Content(size: CGSize(width: width, height: y), lastBaseline: lastBaseline,
                                          segmentFrames: frames)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TextRowRendererTests`

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TextRowRenderer.swift MatronTests/TextRowRendererTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TextRowRenderer — segments measured into the bubble geometry, code block metrics" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 15: Segment views (code block, table grid, avatar, send state)

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineSegmentViews.swift`
- Create: `MatronTests/TimelineSnapshotSupport.swift`
- Modify: `.github/workflows/ci.yml` (the "Run MatronTests (iOS)" step)
- Test: `MatronTests/TimelineSegmentViewsTests.swift`

**Interfaces:**
- Consumes: `CodeBlockMetrics`, `TimelineTextViewFactory`, `TimelineTextStyle`, `MarkdownTable`, `TimelineLinkRouter`, `SenderAvatar.initials(for:)`, `BoxChip.tint(for:)` / `.contrastingForeground(for:)`, `SendStateGlyph`.
- Produces:
  - `final class CodeBlockSegmentView: UIView` with `configure(language:code:style:)`, `copyCode()` and `var codeScrollFrame: CGRect`
  - `struct MarkdownTableGrid: View` with `init(table:router:)` and `static func attributed(_:) -> AttributedString`
  - `final class SenderAvatarView: UILabel` with `configure(name:)`
  - `final class SendStateView: UIButton` with `configure(state:font:onRetry:)`
  - `@MainActor func assertTimelineSnapshot(_:size:named:file:testName:line:)`

- [ ] **Step 1: Add the snapshot helper and skip snapshots on CI**

`MatronTests/TimelineSnapshotSupport.swift`:

```swift
import XCTest
import UIKit
import SnapshotTesting

/// Light + dark snapshot of a UIKit view. Skipped when
/// `MATRON_SKIP_SNAPSHOT_TESTS=1` (local default via `scripts/ios-test.sh`,
/// and CI); `MATRON_RECORD_SNAPSHOTS=1` re-records. Baselines live under
/// `MatronTests/__Snapshots__/` (run `xcodegen generate` after recording new ones).
@MainActor
func assertTimelineSnapshot(_ view: UIView, size: CGSize, named name: String,
                            file: StaticString = #filePath, testName: String = #function, line: UInt = #line) {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MATRON_SKIP_SNAPSHOT_TESTS"] != "1" else { return }
    let record: SnapshotTestingConfiguration.Record = environment["MATRON_RECORD_SNAPSHOTS"] == "1" ? .all : .missing
    withSnapshotTesting(record: record) {
        for (style, suffix) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            assertSnapshot(of: view, as: .image(size: size, traits: UITraitCollection(userInterfaceStyle: style)),
                           named: "\(name)-\(suffix)", file: file, testName: testName, line: line)
        }
    }
}
```

In `.github/workflows/ci.yml`, give the "Run MatronTests (iOS)" step an `env:` block. Insert it between `- name: Run MatronTests (iOS)` and its `run: |`:

```yaml
        env:
          # iOS timeline snapshots (MatronTests/TimelineSnapshotSupport.swift)
          # are recorded locally; runner rendering differs, same rationale as
          # the Mac job. xcodebuild only forwards TEST_RUNNER_* into the runner.
          TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS: "1"
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import SwiftUI
import UIKit
import MatronDesignSystem
@testable import Matron

@MainActor
final class TimelineSegmentViewsTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    func test_codeBlockView_layoutMatchesItsMetrics() {
        let code = "let x = 1\nlet y = 2"
        let view = CodeBlockSegmentView()
        view.configure(language: "swift", code: code, style: style)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: CodeBlockMetrics.height(code: code, style: style))
        view.layoutIfNeeded()
        XCTAssertEqual(view.codeScrollFrame.height,
                       CodeBlockMetrics.codeSize(code, style: style).height + 2 * CodeBlockMetrics.codePadding)
        XCTAssertEqual(view.codeScrollFrame.maxY, view.bounds.height)
    }

    func test_codeBlockCopy_copiesTheBareCode() {
        let view = CodeBlockSegmentView()
        view.configure(language: nil, code: "make test", style: style)
        view.copyCode()
        XCTAssertEqual(UIPasteboard.general.string, "make test")
    }

    func test_tableGridCellText_keepsBoldAndLinks() {
        let source = NSMutableAttributedString(string: "go ", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        source.append(NSAttributedString(string: "here", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 17), .link: URL(string: "https://example.com")!]))
        let converted = MarkdownTableGrid.attributed(source)
        let runs = Array(converted.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1].link, URL(string: "https://example.com"))
        XCTAssertEqual(String(converted.characters), "go here")
    }

    func test_sendStateView_labelsAndTappability() {
        let view = SendStateView()
        view.configure(state: .failed(reason: "offline"), font: style.timestampFont, onRetry: {})
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertEqual(view.accessibilityLabel, "Send failed: offline. Tap to retry.")
        view.configure(state: .sending, font: style.timestampFont, onRetry: {})
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertEqual(view.accessibilityLabel, "Sending")
        view.configure(state: .sent, font: style.timestampFont, onRetry: {})
        XCTAssertTrue(view.isHidden)
    }

    func test_avatarView_usesTheSharedInitials() {
        let view = SenderAvatarView()
        view.configure(name: "dev-2")
        XCTAssertEqual(view.text, SenderAvatar.initials(for: "dev-2"))
        XCTAssertFalse(view.isAccessibilityElement)
    }

    func test_snapshots_codeBlockAndTable() {
        let code = CodeBlockSegmentView()
        code.configure(language: "swift", code: "let queue = UploadQueue(maxRetries: 3)\nqueue.start()", style: style)
        assertTimelineSnapshot(code, size: CGSize(width: 300, height: CodeBlockMetrics.height(
            code: "let queue = UploadQueue(maxRetries: 3)\nqueue.start()", style: style)), named: "code-block")

        let table = MarkdownTable(columnCount: 2, alignments: [.left, .right], rows: [
            [NSAttributedString(string: "Case"), NSAttributedString(string: "Result")],
            [NSAttributedString(string: "retry"), NSAttributedString(string: "ok")],
        ])
        let host = UIHostingController(rootView: MarkdownTableGrid(table: table, router: TimelineLinkRouter()))
        assertTimelineSnapshot(host.view, size: CGSize(width: 300, height: 80), named: "table-grid")
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineSegmentViewsTests`

Expected: the build fails with `cannot find 'CodeBlockSegmentView' in scope`.

- [ ] **Step 4: Implement**

`Matron/Features/Chat/Timeline/TimelineSegmentViews.swift`:

```swift
import UIKit
import SwiftUI
import MatronDesignSystem

/// UIKit twin of `CodeBlock`: language label + copy button, then the code
/// unwrapped in a horizontally scrolling rounded box. Selectable (TextKit 2).
final class CodeBlockSegmentView: UIView {
    private let languageLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let codeView = TimelineTextViewFactory.make()
    private var code = ""
    private var codeSize: CGSize = .zero
    private var headerHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        languageLabel.textColor = .secondaryLabel
        languageLabel.adjustsFontForContentSizeCategory = false
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(systemName: "doc.on.doc")
        copyButton.configuration = configuration
        copyButton.accessibilityLabel = "Copy"
        copyButton.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .primaryActionTriggered)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .systemGray6
        scrollView.layer.cornerRadius = 6
        scrollView.clipsToBounds = true
        codeView.textContainer.widthTracksTextView = false
        codeView.textContainer.size = CGSize(width: CodeBlockMetrics.unboundedWidth, height: .greatestFiniteMagnitude)
        scrollView.addSubview(codeView)
        addSubview(languageLabel)
        addSubview(copyButton)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(language: String?, code: String, style: TimelineTextStyle) {
        self.code = code
        languageLabel.font = style.codeHeaderFont
        languageLabel.text = (language?.isEmpty ?? true) ? "code" : language
        copyButton.configuration?.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(font: style.copyIconFont)
        codeView.attributedText = CodeBlockMetrics.attributed(code, style: style)
        codeSize = CodeBlockMetrics.codeSize(code, style: style)
        headerHeight = CodeBlockMetrics.headerHeight(style: style)
        setNeedsLayout()
    }

    func copyCode() {
        Pasteboard.copy(code)
    }

    var codeScrollFrame: CGRect { scrollView.frame }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad = CodeBlockMetrics.codePadding
        copyButton.frame = CGRect(x: bounds.width - headerHeight, y: 0, width: headerHeight, height: headerHeight)
        languageLabel.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - headerHeight - 8), height: headerHeight)
        let top = headerHeight + CodeBlockMetrics.headerSpacing
        scrollView.frame = CGRect(x: 0, y: top, width: bounds.width, height: codeSize.height + 2 * pad)
        codeView.frame = CGRect(x: pad, y: pad, width: codeSize.width, height: codeSize.height)
        scrollView.contentSize = CGSize(width: codeSize.width + 2 * pad, height: scrollView.frame.height)
    }
}

/// A markdown table as a SwiftUI grid (iOS has no `NSTextTable`) — the Mac
/// table chrome: hairline borders, 4pt cell padding, a 5% label tint on the
/// header row, 8pt bottom margin. Cell text keeps its inline fonts, colours
/// and links; links route through `TimelineLinkRouter`.
struct MarkdownTableGrid: View {
    let table: MarkdownTable
    let router: TimelineLinkRouter

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        Text(Self.attributed(cell(row, column)))
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                            .background(row == 0 ? Color.primary.opacity(0.05) : Color.clear)
                            .border(Color(uiColor: .separator), width: 0.5)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .environment(\.openURL, OpenURLAction { url in
            // SwiftUI calls openURL handlers on the main thread.
            MainActor.assumeIsolated { router.route(url) }
            return .handled
        })
    }

    private func cell(_ row: Int, _ column: Int) -> NSAttributedString {
        column < table.rows[row].count ? table.rows[row][column] : NSAttributedString()
    }

    private func alignment(_ column: Int) -> Alignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    /// UIKit-attributed cell text → SwiftUI-attributed text (font, colour,
    /// link + underline, strikethrough).
    static func attributed(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        let text = source.string as NSString
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            var run = AttributedString(text.substring(with: range))
            if let font = attributes[.font] as? UIFont { run.font = Font(font as CTFont) }
            if let color = attributes[.foregroundColor] as? UIColor { run.foregroundColor = Color(uiColor: color) }
            if let link = attributes[.link] as? URL {
                run.link = link
                run.underlineStyle = Text.LineStyle.single
            }
            if attributes[.strikethroughStyle] != nil { run.strikethroughStyle = Text.LineStyle.single }
            result.append(run)
        }
        return result
    }
}

/// UIKit twin of `SenderAvatar`: initials on the sender's box tint.
final class SenderAvatarView: UILabel {
    func configure(name: String) {
        text = SenderAvatar.initials(for: name)
        font = .systemFont(ofSize: 11, weight: .semibold)
        textAlignment = .center
        textColor = UIColor(BoxChip.contrastingForeground(for: name))
        backgroundColor = UIColor(BoxChip.tint(for: name))
        layer.cornerRadius = TextBubbleGeometry.avatarDiameter / 2
        layer.masksToBounds = true
        // The sender is already the text view's accessibility label.
        isAccessibilityElement = false
    }
}

/// UIKit twin of `SendStateIndicator`, right-aligned under an own bubble.
final class SendStateView: UIButton {
    private var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHorizontalAlignment = .trailing
        addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(state: SendStateGlyph, font: UIFont, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        let symbol: String, title: String, color: UIColor, tappable: Bool, label: String
        switch state {
        case .sent:
            isHidden = true
            return
        case .sending:
            (symbol, title, color, tappable, label) = ("clock", "Sending…", .secondaryLabel, false, "Sending")
        case .queued:
            (symbol, title, color, tappable, label) = ("clock.arrow.circlepath", "Waiting to send — will retry when online",
                                                      .secondaryLabel, true,
                                                      "Queued. Will send when online. Tap to try now.")
        case .failed(let reason):
            (symbol, title, color, tappable, label) = ("exclamationmark.circle", "Failed — tap to retry", .systemRed,
                                                      true, "Send failed: \(reason). Tap to retry.")
        }
        isHidden = false
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.imagePadding = 4
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font)
        configuration.title = title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        configuration.baseForegroundColor = color
        self.configuration = configuration
        isUserInteractionEnabled = tappable
        accessibilityLabel = label
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineSegmentViewsTests`

Expected: `Executed 6 tests, with 0 failures`. Snapshots are skipped here.

- [ ] **Step 6: Record and review the snapshots**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && MATRON_SKIP_SNAPSHOT_TESTS=0 MATRON_RECORD_SNAPSHOTS=1 scripts/ios-test.sh MatronTests/TimelineSegmentViewsTests/test_snapshots_codeBlockAndTable; MATRON_SKIP_SNAPSHOT_TESTS=0 scripts/ios-test.sh MatronTests/TimelineSegmentViewsTests/test_snapshots_codeBlockAndTable`

Expected: the first run records four PNGs under `MatronTests/__Snapshots__/TimelineSegmentViewsTests/`. The second run shows `Executed 1 test, with 0 failures`.

Open the PNGs and confirm they look like the SwiftUI `CodeBlock` and a bordered table, in both light and dark. Then run `xcodegen generate`.

- [ ] **Step 7: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineSegmentViews.swift MatronTests/TimelineSnapshotSupport.swift MatronTests/TimelineSegmentViewsTests.swift MatronTests/__Snapshots__/TimelineSegmentViewsTests .github/workflows/ci.yml
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit code block, table grid, avatar and send-state segment views" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 16: Hosted rows, `HostedSizer` and the concrete measurer

**Ruling on the spec:** hosted cells live behind a UIKit boundary, so SwiftUI environment values do not flow into them.
- The representable passes `openTrackerItem`, `openConversation` and `conversationLinkHost` in explicitly (`TimelineHostedEnvironment`).
- A subtask card cannot use `NavigationLink(value:)`, because the `NavigationStack` is on the far side of the boundary. It becomes a `Button` that appends to the chat's navigation path, which `ChatView` passes in as `openSubChat`.
- `HostedTimelineRow` mirrors `TimelineRowView`. The SwiftUI copy is left untouched and is deleted along with the SwiftUI path.

**Files:**
- Create: `Matron/Features/Chat/Timeline/HostedTimelineRow.swift`
- Create: `Matron/Features/Chat/Timeline/HostedSizer.swift`
- Create: `Matron/Features/Chat/Timeline/TimelineMeasurer.swift`
- Create: `MatronTests/TimelineTestFixtures.swift`
- Test: `MatronTests/TimelineMeasurerTests.swift`

**Interfaces:**
- Consumes: `TimelineItemView`, its closures and `ChatViewModel` API (exactly as `TimelineRowView` wires them), `TextRowRenderer`, `MarkdownTableGrid`, `ConversationLinkPillRow`, `ActivityIndicatorRow`.
- Produces:
  - `struct ChatTimelineActions` with `openSubChat`, `openSpawnRoom`, `openItem`, `openMission`, `previewFile: (URL, String) -> Void`, `tapImage: (URL, Image) -> Void` and `static var inert`
  - `struct TimelineHostedEnvironment` with `openTrackerItem`, `openConversation`, `conversationLinkHost`, `init(...)` and `init(_ environment: EnvironmentValues)`, plus `View.timelineHostedEnvironment(_:)`
  - `struct HostedTimelineRow: View`
  - `@MainActor struct HostedRowFactory` with `viewModel`, `actions`, `environment`, `router`, `row(_:) -> AnyView`, `piece(_:) -> AnyView` and `footer(label:) -> AnyView`
  - `@MainActor final class HostedSizer` with `height(of:width:sizeCategory:) -> CGFloat`
  - `final class TimelineMeasurer: TimelineRowMeasuring` with `@MainActor init(factory:)` and `@MainActor var factory`
  - The test fixtures `LiveTimelineFixture`, `NoMediaFixture`, `NoChildrenChatFixture` and `TimelineFixtures`

- [ ] **Step 1: Create the shared test fixtures**

`MatronTests/TimelineTestFixtures.swift`:

```swift
import XCTest
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// A `TimelineService` whose snapshots the test pushes live (`emit`), so the
/// view model behaves exactly as with the journal: first snapshot returns
/// `start()`, later ones commit (coalesced ≤ 250ms).
final class LiveTimelineFixture: TimelineService, @unchecked Sendable {
    private let stream: AsyncThrowingStream<[TimelineItem], Error>
    private let continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation
    private(set) var paginateCalls = 0

    init() {
        (stream, continuation) = AsyncThrowingStream<[TimelineItem], Error>.makeStream()
    }

    func emit(_ items: [TimelineItem]) { continuation.yield(items) }

    func items() -> AsyncThrowingStream<[TimelineItem], Error> { stream }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { paginateCalls += 1; return false }
    func markAsRead() async throws {}
}

final class NoMediaFixture: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

final class NoChildrenChatFixture: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

enum TimelineFixtures {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Item ids are numeric strings — journal seqs — so `focus(seq:)` works.
    static func text(_ index: Int, own: Bool = false, body: String? = nil) -> TimelineItem {
        TimelineItem(id: "\(index)", sender: own ? "@me:s" : "matron",
                     timestamp: base.addingTimeInterval(TimeInterval(index * 60)),
                     kind: .text(body: body ?? "Message \(index). "
                                    + String(repeating: "Lorem ipsum dolor sit amet. ", count: index % 4 + 1),
                                 formattedHTML: nil),
                     isOwn: own)
    }

    static func streaming(_ ref: String, body: String) -> TimelineItem {
        TimelineItem(id: "eph:\(ref)", sender: "agent", timestamp: base.addingTimeInterval(1_000_000),
                     kind: .text(body: body, formattedHTML: nil), isOwn: false)
    }

    static func activity(_ label: String) -> TimelineItem {
        TimelineItem(id: "activity", sender: "agent", timestamp: base.addingTimeInterval(2_000_000),
                     kind: .activityIndicator(label: label), isOwn: false)
    }

    static func conversation(_ count: Int) -> [TimelineItem] {
        (1...count).map { text($0, own: $0 % 5 == 0) }
    }

    @MainActor
    static func viewModel(_ service: LiveTimelineFixture, roomID: String = "!timeline:test") -> ChatViewModel {
        ChatViewModel(roomID: roomID, timeline: service, media: NoMediaFixture())
    }
}
```

These fakes implement every requirement `ChatService` and `TimelineService` declare without a default. The protocol extension in `TimelineService.swift` (lines 132–181) supplies `newestOwnMessageSeq`, `ownMessages`, `retrySend`, `discardSend`, `sessionStatus`, `sessionState` and the caption-less / progress media overloads.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import Matron

@MainActor
final class TimelineMeasurerTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    private func measurer() -> TimelineMeasurer {
        let viewModel = TimelineFixtures.viewModel(LiveTimelineFixture())
        return TimelineMeasurer(factory: HostedRowFactory(viewModel: viewModel, actions: .inert,
                                                          environment: TimelineHostedEnvironment()))
    }

    func test_hostedSizer_measuresIdealHeight() {
        XCTAssertEqual(HostedSizer().height(of: Color.clear.frame(height: 37), width: 300, sizeCategory: .large), 37)
    }

    func test_hostedSizer_wrapsToTheWidth() {
        let text = Text(String(repeating: "wrap me ", count: 40))
        let sizer = HostedSizer()
        XCTAssertGreaterThan(sizer.height(of: text, width: 150, sizeCategory: .large),
                             sizer.height(of: text, width: 600, sizeCategory: .large))
    }

    func test_separatorRow_measuresLikeASwiftUIHost() {
        let date = TimelineFixtures.base
        let content = TimelineRowContent.hosted(HostedRowContent(row: .separator(date: date), subtaskChild: nil,
                                                                 hasMultipleSenders: false, imagePixelSize: nil))
        let host = UIHostingController(rootView: DateSeparator(date: date).fixedSize(horizontal: false, vertical: true))
        let expected = ceil(host.sizeThatFits(in: CGSize(width: 393, height: .greatestFiniteMagnitude)).height)
        XCTAssertEqual(measurer().measure(content, width: 393, style: style).height, expected)
    }

    func test_textRowWithPills_isMeasuredOnMain_withAPillsFrame() {
        let text = TextRowContent(itemID: "1", body: "See [Auth](matron://convo/auth-1).", isOwn: false,
                                  sendState: .sent, timestamp: TimelineFixtures.base, avatarSender: nil,
                                  senderLabel: "matron", pills: [ConversationLinkRef(id: "auth-1", text: "Auth")])
        let measurer = measurer()
        XCTAssertNil(measurer.backgroundTextRender(text, width: 393, style: style))
        guard case .text(let render) = measurer.measure(.text(text), width: 393, style: style) else {
            return XCTFail("text rows measure as renders")
        }
        XCTAssertGreaterThan(render.layout.pillsFrame?.height ?? 0, 0)
    }

    func test_footerHeight_isPositive() {
        XCTAssertGreaterThan(measurer().footerHeight(label: "Thinking…", width: 393, style: style), 0)
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineMeasurerTests`

Expected: the build fails with `cannot find 'TimelineMeasurer' in scope`.

- [ ] **Step 4: Implement the hosted row pieces**

`Matron/Features/Chat/Timeline/HostedTimelineRow.swift`:

```swift
import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// What rows in the UIKit timeline can ask the chat screen to do.
struct ChatTimelineActions {
    /// Push a sub-chat onto the chat's navigation path (hosted cells can't
    /// reach the `NavigationStack` through `NavigationLink(value:)`).
    var openSubChat: (String) -> Void
    var openSpawnRoom: ((String) -> Void)?
    var openItem: ((String) -> Void)?
    var openMission: ((String) -> Void)?
    /// A downloaded file attachment → the chat's file preview sheet.
    var previewFile: (URL, String) -> Void
    /// A resolved image tapped → the chat's gallery sheet.
    var tapImage: (URL, Image) -> Void

    static var inert: ChatTimelineActions {
        ChatTimelineActions(openSubChat: { _ in }, openSpawnRoom: nil, openItem: nil, openMission: nil,
                            previewFile: { _, _ in }, tapImage: { _, _ in })
    }
}

/// SwiftUI environment values hosted cells need, carried across the UIKit
/// boundary explicitly (UIKit-hosted SwiftUI doesn't inherit custom keys).
struct TimelineHostedEnvironment {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    var conversationLinkHost: ConversationLinkHost?

    init(openTrackerItem: ((Int) -> Void)? = nil, openConversation: ((String) -> Void)? = nil,
         conversationLinkHost: ConversationLinkHost? = nil) {
        self.openTrackerItem = openTrackerItem
        self.openConversation = openConversation
        self.conversationLinkHost = conversationLinkHost
    }

    init(_ environment: EnvironmentValues) {
        self.init(openTrackerItem: environment.openTrackerItem,
                  openConversation: environment.openConversation,
                  conversationLinkHost: environment.conversationLinkHost)
    }
}

extension View {
    func timelineHostedEnvironment(_ environment: TimelineHostedEnvironment) -> some View {
        self.environment(\.openTrackerItem, environment.openTrackerItem)
            .environment(\.openConversation, environment.openConversation)
            .environment(\.conversationLinkHost, environment.conversationLinkHost)
    }
}

/// Mirror of `ChatView.swift`'s private `TimelineRowView` for the UIKit
/// timeline's hosted rows — same `TimelineItemView` wiring, closure for
/// closure — except the subtask card, which is a `Button` into
/// `actions.openSubChat`. Deleted together with the SwiftUI path.
struct HostedTimelineRow: View {
    let content: HostedRowContent
    let viewModel: ChatViewModel
    let actions: ChatTimelineActions

    var body: some View {
        switch content.row {
        case .separator(let date):
            DateSeparator(date: date)
        case .message(let item):
            if let child = content.subtaskChild {
                Button {
                    actions.openSubChat(child.id)
                } label: {
                    SubtaskLinkCard(title: child.title, isRunning: child.isRunning)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else {
                TimelineItemView(
                    item: item,
                    resolveImage: { viewModel.image(for: $0) },
                    onRetry: { id in viewModel.retrySend(itemID: id) },
                    onTapImage: actions.tapImage,
                    onTapFile: { mxc, filename in
                        Task {
                            if let url = await viewModel.writeTempFile(mxcURL: mxc, filename: filename) {
                                actions.previewFile(url, filename)
                            }
                        }
                    },
                    isDownloadingFile: { viewModel.isDownloadingFile($0) },
                    isMediaUnavailable: { viewModel.isMediaUnavailable($0) },
                    askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                    isPromptAnswered: { viewModel.isPromptAnswered($0) },
                    answerSummary: { viewModel.answerSummary(forPrompt: $0) },
                    agentChatState: { viewModel.agentChatState($0) },
                    onAnswerAgentChat: { eventID, request, approve in
                        Task {
                            await viewModel.answerAgentChat(eventID: eventID, request: request,
                                                            decision: approve ? .approve : .deny)
                        }
                    },
                    agentSpawnState: { viewModel.agentSpawnState($0, request: $1) },
                    onAnswerAgentSpawn: { eventID, request, approve in
                        Task {
                            try? await viewModel.answerAgentSpawn(eventID: eventID, request: request,
                                                                  decision: approve ? .approve : .deny)
                        }
                    },
                    onOpenSpawnRoom: actions.openSpawnRoom,
                    onOpenItem: actions.openItem,
                    onOpenMission: actions.openMission,
                    convoID: viewModel.roomID,
                    hasMultipleSenders: content.hasMultipleSenders
                )
            }
        }
    }
}

/// Builds every hosted SwiftUI view the timeline shows or measures — one
/// source for both, so a measured height is the rendered height.
@MainActor
struct HostedRowFactory {
    let viewModel: ChatViewModel
    var actions: ChatTimelineActions
    var environment: TimelineHostedEnvironment

    var router: TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: environment.openTrackerItem,
                           openConversation: environment.openConversation)
    }

    func row(_ content: HostedRowContent) -> AnyView {
        AnyView(HostedTimelineRow(content: content, viewModel: viewModel, actions: actions)
            .timelineHostedEnvironment(environment))
    }

    func piece(_ piece: HostedPiece) -> AnyView {
        switch piece {
        case .pills(let text):
            return AnyView(ConversationLinkPillRow(refs: text.pills, style: text.isOwn ? .me : .bot,
                                                   hasAvatar: text.avatarSender != nil)
                .timelineHostedEnvironment(environment))
        case .table(let table):
            return AnyView(MarkdownTableGrid(table: table, router: router))
        }
    }

    func footer(label: String) -> AnyView {
        AnyView(ActivityIndicatorRow(label: label))
    }
}
```

The closures above are `TimelineRowView`'s (`ChatView.swift` lines 1650–1693) verbatim, except `onTapImage`, `onTapFile` and `onOpenSubChat`, which route through `ChatTimelineActions`.

`Matron/Features/Chat/Timeline/HostedSizer.swift`:

```swift
import SwiftUI
import UIKit

/// Measures SwiftUI content off-screen with one reused hosting controller —
/// the height it would take in the SwiftUI timeline's `VStack` (a nil
/// vertical proposal, i.e. `fixedSize(vertical:)`), at the current Dynamic
/// Type size. Main thread only; results are cached by the caller.
@MainActor
final class HostedSizer {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        host.sizingOptions = []
        host.view.backgroundColor = .clear
    }

    func height<V: View>(of view: V, width: CGFloat, sizeCategory: UIContentSizeCategory) -> CGFloat {
        if host.traitOverrides.preferredContentSizeCategory != sizeCategory {
            host.traitOverrides.preferredContentSizeCategory = sizeCategory
        }
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}
```

`Matron/Features/Chat/Timeline/TimelineMeasurer.swift`:

```swift
import SwiftUI
import UIKit

/// The production `TimelineRowMeasuring`: text rows through `TextRowRenderer`
/// (off-main when they hold no hosted piece), hosted rows / pieces / the
/// activity footer through `HostedSizer` with the SAME views the cells host.
final class TimelineMeasurer: TimelineRowMeasuring, @unchecked Sendable {
    @MainActor var factory: HostedRowFactory
    @MainActor private let sizer: HostedSizer

    @MainActor
    init(factory: HostedRowFactory) {
        self.factory = factory
        self.sizer = HostedSizer()
    }

    func backgroundTextRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender? {
        TextRowRenderer.backgroundRender(content, width: width, style: style)
    }

    @MainActor
    func measure(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement {
        switch content {
        case .text(let text):
            return .text(TextRowRenderer.render(text, width: width, style: style) { piece, pieceWidth in
                self.sizer.height(of: self.factory.piece(piece), width: pieceWidth, sizeCategory: style.sizeCategory)
            })
        case .hosted(let hosted):
            return .hosted(sizer.height(of: factory.row(hosted), width: width, sizeCategory: style.sizeCategory))
        }
    }

    @MainActor
    func footerHeight(label: String, width: CGFloat, style: TimelineTextStyle) -> CGFloat {
        sizer.height(of: factory.footer(label: label), width: width, sizeCategory: style.sizeCategory)
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineMeasurerTests MatronTests/TimelineHeightProviderTests`

Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/HostedTimelineRow.swift Matron/Features/Chat/Timeline/HostedSizer.swift Matron/Features/Chat/Timeline/TimelineMeasurer.swift MatronTests/TimelineTestFixtures.swift MatronTests/TimelineMeasurerTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: hosted timeline rows, HostedSizer and the production measurer" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase 4: Cells

### Task 17: `TextMessageCell`

**Ruling on the spec:** the spec asks for two things that compete for the same long-press:
- partial text selection that "works natively", and
- Copy through `collectionView(_:contextMenuConfigurationForItemsAt:)`.

A `UITextView` must also stay selectable for its links to be tappable at all. So presses on the text belong to the text view: native selection, with an edit menu that gains a "Copy Message" item. Presses anywhere else in the row (bubble padding, time, pills gap) get the collection view's context menu with Copy. Task 26 wires that split.

For VoiceOver, the text view is the accessibility element and its label is the sender ("Me", "matron"). Links then stay individually reachable, which the SwiftUI path's `.combine` label could not offer.

**Files:**
- Create: `Matron/Features/Chat/Timeline/TextMessageCell.swift`
- Modify: `MatronShared/Sources/DesignSystem/MatronPalette.swift` (append an iOS-only `UIColor` extension)
- Test: `MatronTests/TextMessageCellTests.swift`

**Interfaces:**
- Consumes: `TextRowRender`, `TextRowLayout`, `HostedRowFactory`, `CodeBlockSegmentView`, `SenderAvatarView`, `SendStateView`, `TimelineTextViewFactory`, `TimelineLinkRouter`.
- Produces:
  - `final class TextMessageCell: UICollectionViewCell, UITextViewDelegate` with:
    - `configure(render:factory:onRetry:)`
    - `private(set) var render`
    - `enum LinkDecision { case system, inApp }` and `static func linkDecision(for:) -> LinkDecision`
    - test seams `segmentViewsForTesting`, `bubbleForTesting`, `sendStateForTesting`
  - `UIColor.matronBubbleBot`, `.matronBubbleMe` and `.matronBubbleShadow` (public, iOS only)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
import UIKit
import MatronModels
import MatronDesignSystem
@testable import Matron

@MainActor
final class TextMessageCellTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    private func factory() -> HostedRowFactory {
        HostedRowFactory(viewModel: TimelineFixtures.viewModel(LiveTimelineFixture()), actions: .inert,
                         environment: TimelineHostedEnvironment())
    }

    private func content(_ body: String, own: Bool = false, state: TimelineSendState = .sent,
                         avatar: String? = nil, pills: [ConversationLinkRef] = []) -> TextRowContent {
        TextRowContent(itemID: "1", body: body, isOwn: own, sendState: state, timestamp: TimelineFixtures.base,
                       avatarSender: avatar, senderLabel: own ? "Me" : (avatar ?? "matron"), pills: pills)
    }

    private func cell(_ content: TextRowContent, width: CGFloat = 393) -> TextMessageCell {
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(.text(content), width: width,
                                                                                  style: style) else {
            fatalError("text rows measure as renders")
        }
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: render.layout.rowHeight))
        cell.configure(render: render, factory: factory, onRetry: { _ in })
        cell.layoutIfNeeded()
        return cell
    }

    func test_configure_buildsOneViewPerSegment_inTheLayoutFrames() {
        let cell = cell(content("Intro.\n\n```swift\nlet x = 1\n```\n\nOutro."))
        XCTAssertEqual(cell.segmentViewsForTesting.count, 3)
        XCTAssertTrue(cell.segmentViewsForTesting[0] is UITextView)
        XCTAssertTrue(cell.segmentViewsForTesting[1] is CodeBlockSegmentView)
        XCTAssertEqual(cell.segmentViewsForTesting.map(\.frame), cell.render?.layout.segmentFrames)
        XCTAssertEqual(cell.bubbleForTesting.frame, cell.render?.layout.bubbleFrame)
    }

    func test_reconfigure_reusesSegmentViews_whenTheKindsMatch() {
        let cell = cell(content("first body"))
        let before = cell.segmentViewsForTesting.map(ObjectIdentifier.init)
        let factory = factory()
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
            .text(content("second, longer body that wraps")), width: 393, style: style) else { return XCTFail() }
        cell.configure(render: render, factory: factory, onRetry: { _ in })
        XCTAssertEqual(cell.segmentViewsForTesting.map(ObjectIdentifier.init), before,
                       "the streaming row reconfigures in place — no view churn per frame")
        XCTAssertEqual((cell.segmentViewsForTesting[0] as? UITextView)?.text, "second, longer body that wraps")
    }

    func test_ownSendingRow_dimsTheBubble_andShowsTheSendState() {
        let cell = cell(content("On my way", own: true, state: .sending))
        XCTAssertEqual(cell.bubbleForTesting.alpha, 0.7)
        XCTAssertFalse(cell.sendStateForTesting.isHidden)
        XCTAssertEqual(cell.sendStateForTesting.frame, cell.render?.layout.sendStateFrame)
    }

    func test_linkDecision_systemLinksUseUIKitsDefault() {
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "https://example.com")!), .system)
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "matron://item/5")!), .inApp)
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "matron://convo/c-1")!), .inApp)
        XCTAssertEqual(TextMessageCell.linkDecision(for: URL(string: "matrix:r/x:s")!), .inApp,
                       "swallowed links route through the router, which consumes them")
    }

    func test_textView_isLabelledWithTheSender() {
        XCTAssertEqual((cell(content("hi", own: true)).segmentViewsForTesting[0] as? UITextView)?.accessibilityLabel, "Me")
        XCTAssertEqual((cell(content("hi", avatar: "dev-2")).segmentViewsForTesting[0] as? UITextView)?.accessibilityLabel,
                       "dev-2")
    }

    func test_palette_matchesTheSwiftUIColors() {
        func rgba(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a]
        }
        for (uiColor, color) in [(UIColor.matronBubbleMe, Color.matronBubbleMe), (.matronBubbleBot, .matronBubbleBot)] {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: appearance)
                let lhs = rgba(uiColor.resolvedColor(with: traits))
                let rhs = rgba(UIColor(color).resolvedColor(with: traits))
                for (a, b) in zip(lhs, rhs) { XCTAssertEqual(a, b, accuracy: 0.002) }
            }
        }
    }

    func test_snapshots() {
        let cases: [(String, TextRowContent)] = [
            ("bot-plain", content("Found it. The mock server binds a fixed port, so parallel runs race for it.")),
            ("own", content("Can you take a look at the flaky upload test?", own: true)),
            ("avatar", content("Nightly run finished: one flaky failure.", avatar: "dev-2")),
            ("code", content("Run:\n\n```sh\nswift test --filter UploadQueueTests\n```")),
            ("table", content("| Case | Result |\n|:--|--:|\n| retry | ok |\n| timeout | **failed** |")),
            ("pills", content("See [Auth refactor](matron://convo/auth-1).",
                              pills: [ConversationLinkRef(id: "auth-1", text: "Auth refactor")])),
            ("failed", content("This one failed", own: true, state: .failed(reason: "offline"))),
        ]
        for (name, content) in cases {
            let cell = cell(content)
            assertTimelineSnapshot(cell, size: cell.bounds.size, named: "text-cell-\(name)")
        }
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TextMessageCellTests`

Expected: the build fails with `cannot find 'TextMessageCell' in scope`.

- [ ] **Step 3: Add the UIKit palette**

Append this to `MatronShared/Sources/DesignSystem/MatronPalette.swift`:

```swift
#if canImport(UIKit) && !os(macOS)
/// UIKit twins of the bubble palette for the UIKit chat timeline — the same
/// components as the `Color` statics above (`TextMessageCellTests` pins it).
public extension UIColor {
    static let matronBubbleBot = matronAdaptive(light: (255, 255, 255), dark: (38, 36, 33))
    static let matronBubbleMe = matronAdaptive(light: (196, 245, 251), dark: (18, 58, 65))
    /// `rgb(18,16,14 / 0.08)` — warm near-black at 8%.
    static let matronBubbleShadow = UIColor(red: 18 / 255, green: 16 / 255, blue: 14 / 255, alpha: 0.08)

    private static func matronAdaptive(light: (CGFloat, CGFloat, CGFloat),
                                       dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        }
    }
}
#endif
```

- [ ] **Step 4: Implement the cell**

`Matron/Features/Chat/Timeline/TextMessageCell.swift`:

```swift
import UIKit
import SwiftUI
import MatronDesignSystem

/// A text message row: bubble chrome, one view per markdown segment
/// (TextKit 2 text / code block / hosted table), the time in UIKit, the
/// sender avatar, the pill row (hosted) and the own-message send state —
/// all placed at the frames `TextRowRenderer` measured, never self-sized.
final class TextMessageCell: UICollectionViewCell, UITextViewDelegate {
    private enum SegmentKind: Equatable { case text, code, table }

    private let bubble = UIView()
    private let timestampLabel = UILabel()
    private let avatarView = SenderAvatarView()
    private let sendStateView = SendStateView()
    private var segmentViews: [UIView] = []
    private var segmentKinds: [SegmentKind] = []
    /// The exact string instance each text view shows — a reconfigure with
    /// the same (memoised) string skips the TextKit relayout.
    private var appliedTexts: [NSAttributedString?] = []
    private var pillsView: (UIView & UIContentView)?
    private(set) var render: TextRowRender?
    private var router = TimelineLinkRouter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = TextBubbleGeometry.cornerRadius
        bubble.layer.shadowColor = UIColor.matronBubbleShadow.cgColor
        bubble.layer.shadowOpacity = 1
        bubble.layer.shadowRadius = 1
        bubble.layer.shadowOffset = CGSize(width: 0, height: 1)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.lineBreakMode = .byClipping
        timestampLabel.isAccessibilityElement = false
        bubble.addSubview(timestampLabel)
        contentView.addSubview(avatarView)
        contentView.addSubview(bubble)
        contentView.addSubview(sendStateView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(render: TextRowRender, factory: HostedRowFactory, onRetry: @escaping (String) -> Void) {
        self.render = render
        router = factory.router
        let content = render.content
        bubble.backgroundColor = content.isOwn ? .matronBubbleMe : .matronBubbleBot

        let kinds = render.segments.map(Self.kind)
        if kinds != segmentKinds { rebuildSegmentViews(kinds) }
        for (index, segment) in render.segments.enumerated() {
            switch segment {
            case .text(let text):
                guard let textView = segmentViews[index] as? UITextView else { continue }
                if appliedTexts[index] !== text {
                    textView.attributedText = text
                    appliedTexts[index] = text
                }
                textView.accessibilityLabel = content.senderLabel
            case .code(let language, let code):
                (segmentViews[index] as? CodeBlockSegmentView)?.configure(language: language, code: code,
                                                                           style: render.style)
            case .table(let table):
                (segmentViews[index] as? (UIView & UIContentView))?.configuration =
                    UIHostingConfiguration { factory.piece(.table(table)) }.margins(.all, 0)
            }
        }

        timestampLabel.font = render.style.timestampFont
        timestampLabel.text = render.timestampText
        // `.opacity(0.7)` on the whole rendered body while sending.
        let alpha: CGFloat = content.sendState == .sending ? 0.7 : 1
        bubble.alpha = alpha
        if let sender = content.avatarSender, !content.isOwn { avatarView.configure(name: sender) }
        sendStateView.configure(state: SendStateGlyph.from(content.sendState), font: render.style.timestampFont) {
            onRetry(content.itemID)
        }

        if content.pills.isEmpty {
            pillsView?.isHidden = true
        } else {
            let configuration = UIHostingConfiguration { factory.piece(.pills(content)) }.margins(.all, 0)
            if let pillsView {
                pillsView.configuration = configuration
            } else {
                let view = configuration.makeContentView()
                contentView.addSubview(view)
                pillsView = view
            }
            pillsView?.isHidden = false
            pillsView?.alpha = alpha
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout = render?.layout else { return }
        bubble.frame = layout.bubbleFrame
        bubble.layer.shadowPath = UIBezierPath(roundedRect: bubble.bounds,
                                               cornerRadius: TextBubbleGeometry.cornerRadius).cgPath
        for (view, frame) in zip(segmentViews, layout.segmentFrames) { view.frame = frame }
        timestampLabel.frame = layout.timestampFrame
        avatarView.isHidden = layout.avatarFrame == nil
        if let frame = layout.avatarFrame { avatarView.frame = frame }
        if let frame = layout.pillsFrame { pillsView?.frame = frame }
        if let frame = layout.sendStateFrame { sendStateView.frame = frame }
    }

    private static func kind(_ segment: MarkdownSegment) -> SegmentKind {
        switch segment {
        case .text: return .text
        case .code: return .code
        case .table: return .table
        }
    }

    private func rebuildSegmentViews(_ kinds: [SegmentKind]) {
        segmentViews.forEach { $0.removeFromSuperview() }
        segmentViews = kinds.map { kind -> UIView in
            switch kind {
            case .text:
                let view = TimelineTextViewFactory.make()
                view.delegate = self
                return view
            case .code:
                return CodeBlockSegmentView()
            case .table:
                return UIHostingConfiguration { EmptyView() }.margins(.all, 0).makeContentView()
            }
        }
        segmentViews.forEach { bubble.addSubview($0) }
        segmentKinds = kinds
        appliedTexts = Array(repeating: nil, count: kinds.count)
    }

    // MARK: Links

    enum LinkDecision: Equatable {
        /// http(s) and other OS-handled schemes: UIKit's default action.
        case system
        /// Item / conversation links (in-app) and swallowed links.
        case inApp
    }

    static func linkDecision(for url: URL) -> LinkDecision {
        TimelineLinkRouter.isSystemLink(url) ? .system : .inApp
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        switch Self.linkDecision(for: url) {
        case .system:
            return defaultAction
        case .inApp:
            let router = router
            return UIAction { _ in router.route(url) }
        }
    }

    // MARK: Test seams

    var segmentViewsForTesting: [UIView] { segmentViews }
    var bubbleForTesting: UIView { bubble }
    var sendStateForTesting: SendStateView { sendStateView }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TextMessageCellTests`

Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 6: Record and review the snapshots**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && MATRON_SKIP_SNAPSHOT_TESTS=0 MATRON_RECORD_SNAPSHOTS=1 scripts/ios-test.sh MatronTests/TextMessageCellTests/test_snapshots; MATRON_SKIP_SNAPSHOT_TESTS=0 scripts/ios-test.sh MatronTests/TextMessageCellTests/test_snapshots`

Expected: 14 PNGs are recorded, then `Executed 1 test, with 0 failures`.

This is the spec's main risk, so do a parity review. Open each PNG next to the same body rendered by the SwiftUI path on the simulator (flag off), and check that the fonts, bubble sizes, time placement, code block and table read the same. Note any differences in the commit message for Dan's try-build. Run `xcodegen generate`.

- [ ] **Step 7: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TextMessageCell.swift MatronShared/Sources/DesignSystem/MatronPalette.swift MatronTests/TextMessageCellTests.swift MatronTests/__Snapshots__/TextMessageCellTests
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TextMessageCell — TextKit 2 segments in measured frames, UIKit bubble chrome" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 18: `HostedRowCell` and the footer view

**Files:**
- Create: `Matron/Features/Chat/Timeline/HostedRowCell.swift`
- Modify: `MatronTests/TimelineTestFixtures.swift` (append `waitUntil`)
- Test: `MatronTests/HostedRowCellTests.swift`

**Interfaces:**
- Produces:
  - `final class HostedRowCell: UICollectionViewCell` with `configure(rowID:expectedHeight:content:)` and `var onHeightChange: ((String, CGFloat) -> Void)?`. It reports asynchronously on main when the hosted content's ideal height differs from `expectedHeight` by more than 0.5 pt.
  - `final class TimelineFooterView: UICollectionReusableView` with `configure(content:)`
  - `@MainActor func waitUntil(timeout:file:line:_:) async throws`

- [ ] **Step 1: Add the wait helper**

Append this to `MatronTests/TimelineTestFixtures.swift`:

```swift
/// Spins the main run loop (display links, dispatch) until `condition`.
@MainActor
func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import SwiftUI
import UIKit
@testable import Matron

/// Hosted rows keep cached sizes but re-report when their SwiftUI content
/// changes size on its own (an ask card answered, an image landing, a live
/// output tile growing) — the controller re-lays out that row only.
@MainActor
final class HostedRowCellTests: XCTestCase {
    @Observable final class HeightBox { var height: CGFloat = 40 }

    struct Probe: View {
        let box: HeightBox
        var body: some View { Color.red.frame(height: box.height) }
    }

    private func mount(_ view: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 400))
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return window
    }

    func test_reportsAHeightChange_whenHostedContentGrows() async throws {
        let box = HeightBox()
        let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
        var reports: [(String, CGFloat)] = []
        cell.onHeightChange = { reports.append(($0, $1)) }
        cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Probe(box: box)))
        let window = mount(cell)
        box.height = 90
        try await waitUntil { !reports.isEmpty }
        XCTAssertEqual(reports.last?.0, "row-1")
        XCTAssertEqual(reports.last?.1, 90)
        _ = window
    }

    func test_doesNotReportWhenTheHeightMatches() async throws {
        let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
        var reports = 0
        cell.onHeightChange = { _, _ in reports += 1 }
        cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Probe(box: HeightBox())))
        let window = mount(cell)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reports, 0)
        _ = window
    }

    func test_footerView_hostsItsContentEdgeToEdge() {
        let footer = TimelineFooterView(frame: CGRect(x: 0, y: 0, width: 393, height: 30))
        footer.configure(content: AnyView(Text("Thinking…")))
        footer.layoutIfNeeded()
        XCTAssertEqual(footer.subviews.count, 1)
        XCTAssertEqual(footer.subviews.first?.frame, footer.bounds)
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/HostedRowCellTests`

Expected: the build fails with `cannot find 'HostedRowCell' in scope`.

- [ ] **Step 4: Implement**

`Matron/Features/Chat/Timeline/HostedRowCell.swift`:

```swift
import UIKit
import SwiftUI

/// A timeline row rendered by existing SwiftUI views (`HostedTimelineRow`)
/// through `UIHostingConfiguration`, at the frame the layout gives it. The
/// content lays out at its ideal height (`fixedSize(vertical:)` — what the
/// measurement used) pinned to the top; when that height changes on its own
/// the cell reports it once, off the layout pass, and the controller
/// re-measures only this row.
final class HostedRowCell: UICollectionViewCell {
    private(set) var rowID: String?
    private var expectedHeight: CGFloat = 0
    var onHeightChange: ((String, CGFloat) -> Void)?

    func configure(rowID: String, expectedHeight: CGFloat, content: AnyView) {
        self.rowID = rowID
        self.expectedHeight = expectedHeight
        contentConfiguration = UIHostingConfiguration {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { [weak self] height in
                    self?.report(height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .margins(.all, 0)
    }

    private func report(_ height: CGFloat) {
        let rounded = ceil(height)
        guard let rowID, abs(rounded - expectedHeight) > 0.5 else { return }
        expectedHeight = rounded
        // Never re-enter the collection view's layout pass from inside it.
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(rowID, rounded)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowID = nil
        onHeightChange = nil
    }
}

/// The activity indicator ("Thinking…", tool use) — a supplementary view
/// outside the row/anchor space, exactly as the SwiftUI path keeps it a
/// sibling of the scroll-target layout.
final class TimelineFooterView: UICollectionReusableView {
    private var hosted: (UIView & UIContentView)?

    func configure(content: AnyView) {
        let configuration = UIHostingConfiguration { content }.margins(.all, 0)
        if let hosted {
            hosted.configuration = configuration
        } else {
            let view = configuration.makeContentView()
            addSubview(view)
            hosted = view
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}
```

- [ ] **Step 5: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/HostedRowCellTests`

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/HostedRowCell.swift MatronTests/TimelineTestFixtures.swift MatronTests/HostedRowCellTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: HostedRowCell with self-reported size changes, activity footer view" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 5: Layout, controller, integration

### Task 19: `TimelineLayout`

**Ruling on the spec:** the spec puts "`contentOffsetAdjustment` in its invalidation contexts" on the layout. This plan keeps the offset decision in `TimelineScrollModel` and has one writer:
- The controller sets `contentOffset` immediately after each invalidation, in the same run-loop turn.
- The layout's `targetContentOffset(forProposedContentOffset:)` returns the same model value, so UIKit's own post-update adjustment agrees with it.

A prepend therefore never shows a frame at the wrong position, and ownership never splits between two writers.

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelineLayout.swift`
- Test: `MatronTests/TimelineLayoutTests.swift`

**Interfaces:**
- Consumes: `TimelineScrollModel`.
- Produces:
  - `@MainActor protocol TimelineLayoutSource: AnyObject { var scrollModel: TimelineScrollModel { get } }`
  - `final class TimelineLayout: UICollectionViewLayout` with `weak var source`, `static let footerKind` and `static let footerIndexPath`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import UIKit
@testable import Matron

@MainActor
final class TimelineLayoutTests: XCTestCase {
    final class Source: NSObject, TimelineLayoutSource, UICollectionViewDataSource {
        var scrollModel = TimelineScrollModel()
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            scrollModel.rows.count
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "footer", for: indexPath)
        }
    }

    private func make(rows: [TimelineScrollModel.Row], footer: CGFloat = 0, viewport: CGFloat = 300)
        -> (UICollectionView, TimelineLayout, Source) {
        let source = Source()
        source.scrollModel.setViewportHeight(viewport)
        source.scrollModel.replaceRows(rows, footerHeight: footer)
        let layout = TimelineLayout()
        layout.source = source
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 393, height: viewport), collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.register(UICollectionReusableView.self, forSupplementaryViewOfKind: TimelineLayout.footerKind,
                      withReuseIdentifier: "footer")
        view.dataSource = source
        view.layoutIfNeeded()
        return (view, layout, source)
    }

    func test_cellFrames_comeFromTheModel() {
        let (_, layout, source) = make(rows: [.init(id: "a", height: 100), .init(id: "b", height: 50)])
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
                       CGRect(x: 0, y: source.scrollModel.rowMinY(at: 0), width: 393, height: 100))
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame,
                       CGRect(x: 0, y: source.scrollModel.rowMinY(at: 1), width: 393, height: 50))
    }

    func test_contentSize_isTheModelsContentHeight() {
        let (view, _, source) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        XCTAssertEqual(view.contentSize, CGSize(width: 393, height: source.scrollModel.contentHeight))
    }

    func test_footer_isASupplementaryBelowTheRows() {
        let (_, layout, source) = make(rows: [.init(id: "a", height: 100)], footer: 40)
        let footer = layout.layoutAttributesForSupplementaryView(ofKind: TimelineLayout.footerKind,
                                                                 at: TimelineLayout.footerIndexPath)
        XCTAssertEqual(footer?.frame, CGRect(x: 0, y: source.scrollModel.footerMinY, width: 393, height: 40))
    }

    func test_targetContentOffset_isTheModelsDecision() {
        let (_, layout, source) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        XCTAssertEqual(layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 0, y: 3)),
                       CGPoint(x: 0, y: source.scrollModel.contentOffsetY))
    }

    func test_elementsInRect_filtersByIntersection() {
        let (_, layout, _) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        let items = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 393, height: 200)) ?? []
        XCTAssertEqual(items.map(\.indexPath.item), [0, 1])
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineLayoutTests`

Expected: the build fails with `cannot find 'TimelineLayout' in scope`.

- [ ] **Step 3: Implement**

`Matron/Features/Chat/Timeline/TimelineLayout.swift`:

```swift
import UIKit

@MainActor
protocol TimelineLayoutSource: AnyObject {
    var scrollModel: TimelineScrollModel { get }
}

/// A read-only projection of `TimelineScrollModel`: exact frames, exact
/// content size, no estimates, no self-sizing. The activity footer is a
/// section-footer supplementary outside the row space.
final class TimelineLayout: UICollectionViewLayout {
    static let footerKind = UICollectionView.elementKindSectionFooter
    static let footerIndexPath = IndexPath(item: 0, section: 0)

    weak var source: TimelineLayoutSource?

    private var cellAttributes: [UICollectionViewLayoutAttributes] = []
    private var footerAttributes: UICollectionViewLayoutAttributes?
    private var contentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        guard let collectionView, let model = source?.scrollModel else {
            cellAttributes = []
            footerAttributes = nil
            contentSize = .zero
            return
        }
        let width = collectionView.bounds.width
        cellAttributes = model.rows.indices.map { index in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: 0, y: model.rowMinY(at: index), width: width, height: model.rows[index].height)
            return attributes
        }
        if model.footerHeight > 0 {
            let footer = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.footerKind,
                                                          with: Self.footerIndexPath)
            footer.frame = CGRect(x: 0, y: model.footerMinY, width: width, height: model.footerHeight)
            footerAttributes = footer
        } else {
            footerAttributes = nil
        }
        contentSize = CGSize(width: width, height: model.contentHeight)
    }

    override var collectionViewContentSize: CGSize { contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result = cellAttributes.filter { $0.frame.intersects(rect) }
        if let footerAttributes, footerAttributes.frame.intersects(rect) { result.append(footerAttributes) }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cellAttributes.indices.contains(indexPath.item) ? cellAttributes[indexPath.item] : nil
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                       at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        elementKind == Self.footerKind ? footerAttributes : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    /// UIKit asks this after batch updates; the answer is the model's.
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let model = source?.scrollModel else { return proposedContentOffset }
        return CGPoint(x: 0, y: model.contentOffsetY)
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineLayoutTests`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelineLayout.swift MatronTests/TimelineLayoutTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: TimelineLayout — exact frames and content size from the scroll model" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 20: `ChatTimelineController` core

**Files:**
- Create: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`
- Modify: `MatronTests/TimelineTestFixtures.swift` (append `TimelineHarness`)
- Test: `MatronTests/ChatTimelineControllerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 7–19, and `ChatViewModel`'s `windowedRows`, `activityLabel`, `hasMultipleSenders`, `windowTailAnchorID`, `windowContainsTail`, `pendingFocusID`, `lastRenderableItemID`, `lastRenderableItemIsOwn`, `imagePixelSize(for:)`, `resetHistoryWindow()` and `retrySend(itemID:)`, plus `SubChatStripViewModel.children`.
- Produces:
  - `let timelineLogger: Logger` (module-internal)
  - `@MainActor final class FrameCoalescer` with `request()`, `invalidate()` and `isPending`
  - `@Observable @MainActor final class ChatTimelineBridge` with `isFollowingTail`, `weak var controller`, `setFollowing(_:)` and `jumpToBottom()`
  - `@MainActor final class ChatTimelineController` with:
    - `init(viewModel:stripViewModel:bridge:actions:environment:)`
    - `update(actions:environment:)`, `tearDown()` and `sync()`
    - `jumpToBottom()`
    - `scrollModel`, `collectionView`, `appliedRowIDs` and `hasPendingWork`
    - the `UIScrollViewDelegate` methods

- [ ] **Step 1: Add the harness**

Append this to `MatronTests/TimelineTestFixtures.swift`:

```swift
/// A `ChatTimelineController` in a real window over a real `ChatViewModel`
/// fed by `LiveTimelineFixture`.
@MainActor
final class TimelineHarness {
    let service = LiveTimelineFixture()
    let viewModel: ChatViewModel
    let strip: SubChatStripViewModel
    let bridge = ChatTimelineBridge()
    private(set) var controller: ChatTimelineController
    let window: UIWindow

    init(roomID: String = "!timeline-\(UUID().uuidString):test",
         size: CGSize = CGSize(width: 393, height: 700), attach: Bool = true) {
        viewModel = TimelineFixtures.viewModel(service, roomID: roomID)
        strip = SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: roomID)
        controller = ChatTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                            actions: .inert, environment: TimelineHostedEnvironment())
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if attach { self.attach() }
    }

    func attach() {
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// Room reopen: a fresh controller over the same (cached) view model.
    func remount() {
        controller.tearDown()
        controller = ChatTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                            actions: .inert, environment: TimelineHostedEnvironment())
        attach()
    }

    func start(with items: [TimelineItem]) async throws {
        service.emit(items)
        _ = await viewModel.start()
        try await settle()
    }

    func emit(_ items: [TimelineItem]) async throws {
        service.emit(items)
        try await waitUntil { self.viewModel.items == items }
        try await settle()
    }

    /// Until the controller shows exactly the view model's current window.
    func settle(timeout: TimeInterval = 3) async throws {
        try await waitUntil(timeout: timeout) {
            var seen = Set<String>()
            let expected = self.viewModel.windowedRows.map(TimelineRowContentBuilder.anchorID(for:))
                .filter { seen.insert($0).inserted }
            return self.controller.appliedRowIDs == expected && !self.controller.hasPendingWork
        }
    }

    var collectionView: UICollectionView { controller.collectionView }
    var maxOffset: CGFloat { max(0, collectionView.contentSize.height - collectionView.bounds.height) }

    /// A user drag to `y` that settles there.
    func drag(to y: CGFloat) {
        controller.scrollViewWillBeginDragging(collectionView)
        collectionView.contentOffset = CGPoint(x: 0, y: y)
        controller.scrollViewDidEndDecelerating(collectionView)
    }

    /// A row's top edge relative to the viewport's top edge.
    func onScreenY(_ id: String) -> CGFloat? {
        guard let index = controller.scrollModel.index(of: id) else { return nil }
        return controller.scrollModel.rowMinY(at: index) - collectionView.contentOffset.y
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import UIKit
import MatronChat
import MatronViewModels
@testable import Matron

/// Spec §2: opens at the bottom; stays pinned through streaming; content
/// never moves under a reader; own send returns to the tail; the activity
/// indicator is a footer outside the anchor space.
@MainActor
final class ChatTimelineControllerTests: XCTestCase {
    func test_opensAtTheBottom() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        let last = IndexPath(item: h.controller.appliedRowIDs.count - 1, section: 0)
        XCTAssertTrue(h.collectionView.indexPathsForVisibleItems.contains(last))
        XCTAssertTrue(h.bridge.isFollowingTail)
    }

    func test_streamingReplyStaysPinned() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(40)
        try await h.start(with: items)
        var body = "Streaming"
        items.append(TimelineFixtures.streaming("r1", body: body))
        for step in 0..<5 {
            body += " step \(step) " + String(repeating: "growing words ", count: 12)
            items[items.count - 1] = TimelineFixtures.streaming("r1", body: body)
            try await h.emit(items)
            XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5, "step \(step)")
        }
    }

    func test_newMessageWhileReadingHistoryDoesNotMoveContent() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(60)
        try await h.start(with: items)
        h.drag(to: 400)
        let anchor = h.controller.scrollModel.topAnchor()
        items.append(TimelineFixtures.text(61))
        try await h.emit(items)
        XCTAssertEqual(h.collectionView.contentOffset.y, 400, accuracy: 0.5)
        XCTAssertEqual(h.controller.scrollModel.topAnchor(), anchor)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_ownSendReturnsToTheTail() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(60)
        try await h.start(with: items)
        h.drag(to: 300)
        items.append(TimelineFixtures.text(61, own: true))
        try await h.emit(items)
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
    }

    func test_activityFooterPinsWhileFollowing_andIsNotARow() async throws {
        let h = TimelineHarness()
        let items = TimelineFixtures.conversation(30)
        try await h.start(with: items)
        try await h.emit(items + [TimelineFixtures.activity("Thinking…")])
        XCTAssertGreaterThan(h.controller.scrollModel.footerHeight, 0)
        XCTAssertFalse(h.controller.appliedRowIDs.contains("activity"))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertNotNil(h.collectionView.supplementaryView(forElementKind: TimelineLayout.footerKind,
                                                          at: TimelineLayout.footerIndexPath))
    }

    func test_streamingRowRetiringBelowTheViewportDoesNotMoveTheReader() async throws {
        let h = TimelineHarness()
        let body = "Final answer. " + String(repeating: "Detail. ", count: 40)
        let history = TimelineFixtures.conversation(60)
        try await h.start(with: history + [TimelineFixtures.streaming("r1", body: body)])
        h.drag(to: 300)
        let anchor = h.controller.scrollModel.topAnchor()
        try await h.emit(history + [TimelineFixtures.text(61, body: body)])
        XCTAssertEqual(h.collectionView.contentOffset.y, 300, accuracy: 0.5)
        XCTAssertEqual(h.controller.scrollModel.topAnchor(), anchor)
    }

    func test_duplicateItemIDsRenderOnce() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(20) + [TimelineFixtures.text(20)])
        XCTAssertEqual(h.controller.appliedRowIDs.filter { $0 == "20" }.count, 1)
    }

    func test_shortConversationHugsTheComposer() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(2))
        let model = h.controller.scrollModel
        let last = model.rows.count - 1
        XCTAssertEqual(model.rowMinY(at: last) + model.rows[last].height + 16, h.collectionView.bounds.height,
                       accuracy: 0.5)
        XCTAssertEqual(h.collectionView.contentOffset.y, 0)
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/ChatTimelineControllerTests`

Expected: the build fails with `cannot find 'ChatTimelineController' in scope`.

- [ ] **Step 4: Implement the controller**

`Matron/Features/Chat/Timeline/ChatTimelineController.swift`:

```swift
import UIKit
import SwiftUI
import os
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Un-gated breadcrumbs for the UIKit timeline — same subsystem as the
/// SwiftUI path's `ios-chat-view`, so field traces read as one story.
let timelineLogger = Logger(subsystem: "chat.matron", category: "ios-chat-timeline")

/// Runs `action` once on the next display frame however often it was
/// requested since — the spec's "coalesced to one update per display frame".
@MainActor
final class FrameCoalescer {
    @MainActor
    private final class Target: NSObject {
        weak var owner: FrameCoalescer?
        @objc func tick() { owner?.fire() }
    }

    private var link: CADisplayLink?
    private let target = Target()
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        target.owner = self
    }

    var isPending: Bool { link.map { !$0.isPaused } ?? false }

    func request() {
        if link == nil {
            let link = CADisplayLink(target: target, selector: #selector(Target.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    fileprivate func fire() {
        link?.isPaused = true
        action()
    }
}

/// The controller's state and commands for the SwiftUI chrome around it
/// (jump button, top-trailing controls, `onDisappear`).
@Observable
@MainActor
final class ChatTimelineBridge {
    private(set) var isFollowingTail = true
    @ObservationIgnored weak var controller: ChatTimelineController?

    func setFollowing(_ following: Bool) {
        if isFollowingTail != following { isFollowingTail = following }
    }

    func jumpToBottom() { controller?.jumpToBottom() }
}

/// The UIKit chat timeline (spec 2026-09-26). Reads the unchanged
/// `ChatViewModel` API through Observation, measures every row exactly
/// before applying it, and is the ONLY writer of the collection view's
/// `contentOffset` — always the value `TimelineScrollModel` decided.
@MainActor
final class ChatTimelineController: UIViewController, UICollectionViewDelegate, TimelineLayoutSource {
    /// Up to this many unmeasured text rows are measured on the spot (a new
    /// message, the streaming row); more wait for the background precompute
    /// (window growth, a prepend, a first open).
    static let synchronousMeasureLimit = 8

    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: ChatTimelineBridge

    private(set) var scrollModel = TimelineScrollModel()
    private(set) var collectionView: UICollectionView!
    private let layout = TimelineLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var factory: HostedRowFactory
    private let measurer: TimelineMeasurer
    private let heights: TimelineHeightProvider
    private lazy var coalescer = FrameCoalescer { [weak self] in self?.sync() }

    private var contents: [String: TimelineRowContent] = [:]
    private var measurements: [String: TimelineMeasurement] = [:]
    private var mainThreadOnlyIDs = Set<String>()
    private var footerHeights: [String: CGFloat] = [:]
    private var width: CGFloat = 0
    private var style = TimelineTextStyle(sizeCategory: .large)
    private var isApplyingLayout = false
    private var forceSynchronousMeasure = false
    private var precomputeTask: Task<Void, Never>?
    private var lastTailID: String?

    init(viewModel: ChatViewModel, stripViewModel: SubChatStripViewModel, bridge: ChatTimelineBridge,
         actions: ChatTimelineActions, environment: TimelineHostedEnvironment) {
        self.viewModel = viewModel
        self.stripViewModel = stripViewModel
        self.bridge = bridge
        let factory = HostedRowFactory(viewModel: viewModel, actions: actions, environment: environment)
        let measurer = TimelineMeasurer(factory: factory)
        self.factory = factory
        self.measurer = measurer
        self.heights = TimelineHeightProvider(roomID: viewModel.roomID, cache: .shared, measurer: measurer)
        super.init(nibName: nil, bundle: nil)
        bridge.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    func update(actions: ChatTimelineActions, environment: TimelineHostedEnvironment) {
        factory.actions = actions
        factory.environment = environment
        measurer.factory = factory
    }

    /// Called by the representable when SwiftUI removes this timeline.
    func tearDown() {
        coalescer.invalidate()
        precomputeTask?.cancel()
    }

    var appliedRowIDs: [String] { scrollModel.rows.map(\.id) }
    var hasPendingWork: Bool { precomputeTask != nil || coalescer.isPending }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout.source = self
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // ChatKeyboardAvoidance resizes our frame; no automatic insets.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.accessibilityIdentifier = "chat.timeline"
        collectionView.delegate = self
        view.addSubview(collectionView)
        self.collectionView = collectionView
        configureDataSource()
        style = TimelineTextStyle(sizeCategory: traitCollection.preferredContentSizeCategory)
        timelineLogger.breadcrumb("uikit timeline load room=\(viewModel.roomID) rows=\(viewModel.windowedRows.count)")
        coalescer.request()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if size.height != scrollModel.viewportHeight {
            performLayoutUpdate { scrollModel.setViewportHeight(size.height) }
        }
        if size.width != width {
            let hadWidth = width > 0
            width = size.width
            footerHeights.removeAll()
            if hadWidth { resyncSynchronously() } else { sync() }
        }
    }

    // MARK: Data source

    private func configureDataSource() {
        let textRegistration = UICollectionView.CellRegistration<TextMessageCell, String> { [weak self] cell, _, id in
            guard let self, case .text(let render)? = self.measurements[id] else { return }
            cell.configure(render: render, factory: self.factory) { [weak self] itemID in
                self?.viewModel.retrySend(itemID: itemID)
            }
        }
        let hostedRegistration = UICollectionView.CellRegistration<HostedRowCell, String> { [weak self] cell, _, id in
            guard let self, case .hosted(let content)? = self.contents[id] else { return }
            cell.onHeightChange = { [weak self] rowID, height in self?.hostedHeightChanged(rowID, to: height) }
            cell.configure(rowID: id, expectedHeight: self.measurements[id]?.height ?? 0,
                           content: self.factory.row(content))
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<TimelineFooterView>(
            elementKind: TimelineLayout.footerKind
        ) { [weak self] footer, _, _ in
            guard let self, let label = self.viewModel.activityLabel else { return }
            footer.configure(content: self.factory.footer(label: label))
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, indexPath, id in
            if case .text? = self?.contents[id] {
                return view.dequeueConfiguredReusableCell(using: textRegistration, for: indexPath, item: id)
            }
            return view.dequeueConfiguredReusableCell(using: hostedRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    // MARK: Observation → apply

    private func observeViewModel() {
        withObservationTracking { [viewModel, stripViewModel] in
            _ = viewModel.windowedRows
            _ = viewModel.activityLabel
            _ = viewModel.hasMultipleSenders
            _ = viewModel.windowTailAnchorID
            _ = viewModel.pendingFocusID
            _ = viewModel.lastRenderableItemID
            _ = stripViewModel.children
            for case .message(let item) in viewModel.windowedRows {
                if case .image(let url?, _, _, _) = item.kind { _ = viewModel.imagePixelSize(for: url) }
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.coalescer.request() }
        }
    }

    /// One pass: re-arm observation, build row contents, measure (or defer
    /// to the precompute), apply, then the post-apply position rules.
    func sync() {
        observeViewModel()
        guard width > 0 else { return }
        let built = TimelineRowContentBuilder.build(TimelineRowSource(
            rows: viewModel.windowedRows,
            hasMultipleSenders: viewModel.hasMultipleSenders,
            children: stripViewModel.children,
            imagePixelSize: { [viewModel] url in viewModel.imagePixelSize(for: url) }))
        if !built.droppedDuplicates.isEmpty {
            timelineLogger.breadcrumb("timeline dropped duplicate row ids \(built.droppedDuplicates.prefix(5).joined(separator: ","))")
        }
        let missing = heights.missingText(in: built.contents, width: width, style: style, excluding: mainThreadOnlyIDs)
        if missing.count > Self.synchronousMeasureLimit, !forceSynchronousMeasure {
            schedulePrecompute(missing)
            return
        }
        apply(built.contents)
        afterApply()
    }

    private func resyncSynchronously() {
        forceSynchronousMeasure = true
        defer { forceSynchronousMeasure = false }
        sync()
    }

    private func schedulePrecompute(_ texts: [TextRowContent]) {
        guard precomputeTask == nil else { return }
        let width = width, style = style
        precomputeTask = Task { [weak self] in
            guard let self else { return }
            let needsMain = await self.heights.precompute(texts, width: width, style: style)
            self.mainThreadOnlyIDs.formUnion(needsMain)
            self.precomputeTask = nil
            self.coalescer.request()
        }
    }

    private func apply(_ newContents: [TimelineRowContent]) {
        var rows: [TimelineScrollModel.Row] = []
        rows.reserveCapacity(newContents.count)
        var changed: [String] = []
        var nextContents: [String: TimelineRowContent] = [:]
        var nextMeasurements: [String: TimelineMeasurement] = [:]
        for content in newContents {
            let id = content.anchorID
            if let old = contents[id], old != content { changed.append(id) }
            let measurement = heights.measurement(content, width: width, style: style)
            nextContents[id] = content
            nextMeasurements[id] = measurement
            rows.append(.init(id: id, height: measurement.height))
        }
        contents = nextContents
        measurements = nextMeasurements

        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        let reconfigure = forceSynchronousMeasure ? rows.map(\.id) : changed
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        snapshot.reconfigureItems(reconfigure.filter(previousIDs.contains))
        performLayoutUpdate {
            scrollModel.windowContainsTail = viewModel.windowContainsTail
            scrollModel.replaceRows(rows, footerHeight: currentFooterHeight())
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        reconfigureFooter()
        if let rescue = scrollModel.lastRescue {
            timelineLogger.breadcrumb("timeline anchor \(rescue.lostRowID) vanished → \(rescue.survivorID ?? "bottom")")
        }
    }

    private func afterApply() {
        handleTailChange()
    }

    /// The single `contentOffset` write path: mutate the model, invalidate,
    /// write the model's offset, lay out — all inside one guard so UIKit's
    /// intermediate scroll callbacks can't feed back into the model.
    private func performLayoutUpdate(_ changes: () -> Void) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        changes()
        layout.invalidateLayout()
        let target = scrollModel.contentOffsetY
        if abs(collectionView.contentOffset.y - target) > 0.25 {
            collectionView.contentOffset = CGPoint(x: 0, y: target)
        }
        collectionView.layoutIfNeeded()
        bridge.setFollowing(scrollModel.isFollowingTail)
    }

    private func currentFooterHeight() -> CGFloat {
        guard let label = viewModel.activityLabel else { return 0 }
        if let height = footerHeights[label] { return height }
        let height = measurer.footerHeight(label: label, width: width, style: style)
        footerHeights[label] = height
        return height
    }

    private func reconfigureFooter() {
        guard let label = viewModel.activityLabel,
              let footer = collectionView.supplementaryView(forElementKind: TimelineLayout.footerKind,
                                                            at: TimelineLayout.footerIndexPath) as? TimelineFooterView
        else { return }
        footer.configure(content: factory.footer(label: label))
    }

    // MARK: Position rules

    /// Your own outgoing message always returns you to the bottom.
    private func handleTailChange() {
        let tail = viewModel.lastRenderableItemID
        defer { lastTailID = tail }
        guard let tail, let previous = lastTailID, tail != previous,
              viewModel.lastRenderableItemIsOwn, !scrollModel.isFollowingTail else { return }
        timelineLogger.breadcrumb("follow-tail ON (own send)")
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
        performLayoutUpdate { scrollModel.followTail() }
    }

    private func hostedHeightChanged(_ id: String, to height: CGFloat) {
        guard let content = contents[id], let current = measurements[id]?.height, abs(current - height) > 0.5 else {
            return
        }
        heights.storeHostedHeight(height, for: content, width: width, style: style)
        measurements[id] = .hosted(height)
        performLayoutUpdate { scrollModel.updateHeight(ofRow: id, to: height) }
    }

    /// The jump-to-latest button.
    func jumpToBottom() {
        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
        killMomentum()
        timelineLogger.breadcrumb("follow-tail ON (jump button)")
        performLayoutUpdate { scrollModel.followTail() }
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
    }

    /// Zero-delta non-animated write: the canonical deceleration kill.
    private func killMomentum() {
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingLayout else { return }
        scrollModel.noteUserOffset(scrollView.contentOffset.y)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollModel.beginUserDrag() {
            timelineLogger.breadcrumb("follow-tail OFF (user drag)")
            bridge.setFollowing(false)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleAfterScroll() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleAfterScroll()
    }

    private func settleAfterScroll() {
        scrollModel.windowContainsTail = viewModel.windowContainsTail
        if scrollModel.endUserScroll() {
            timelineLogger.breadcrumb("follow-tail ON (settled at tail)")
            bridge.setFollowing(true)
        }
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/ChatTimelineControllerTests`

Expected: `Executed 8 tests, with 0 failures`.

If `test_newMessageWhileReadingHistoryDoesNotMoveContent` fails, UIKit adjusted the offset during the diffable batch update. Check that `TimelineLayout.targetContentOffset(forProposedContentOffset:)` is being consulted by setting a breakpoint. Do not add a second corrective write.

- [ ] **Step 6: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/ChatTimelineController.swift MatronTests/TimelineTestFixtures.swift MatronTests/ChatTimelineControllerTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: ChatTimelineController — observed VM, measured apply, single offset writer, follow-tail" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 21: Representable and `ChatView` integration

**Files:**
- Create: `Matron/Features/Chat/Timeline/ChatTimelineView.swift`
- Modify: `Matron/Features/Chat/ChatView.swift`, in three places:
  - properties after `@State private var nativeScroll = NativeScrollViewBox()` (line 98)
  - the branch at `chatPage` line 624
  - a new `uikitTimeline` property after `chatPage`
- Test: `MatronTests/ChatTimelineIntegrationTests.swift`

**Interfaces:**
- Consumes: `ChatTimelineController`, `ChatTimelineBridge`, `ChatTimelineActions`, `TimelineHostedEnvironment(_:)`.
- Produces: `struct ChatTimelineView: UIViewControllerRepresentable`. `ChatView` renders it when `@AppStorage(ChatTimelineFlag.key)` is true.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import SwiftUI
import UIKit
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Spec §3: the flag picks the timeline; the SwiftUI path stays untouched.
@MainActor
final class ChatTimelineIntegrationTests: XCTestCase {
    private func host(flag: Bool) async throws -> (UIWindow, ChatViewModel) {
        UserDefaults.standard.set(flag, forKey: ChatTimelineFlag.key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: ChatTimelineFlag.key) }
        let service = LiveTimelineFixture()
        service.emit(TimelineFixtures.conversation(12))
        let viewModel = TimelineFixtures.viewModel(service)
        let view = ChatView(
            viewModel: viewModel,
            composerVM: ComposerViewModel(roomID: viewModel.roomID, timeline: service, commands: []),
            stripViewModel: SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: viewModel.roomID),
            chatTitle: "Integration")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: NavigationStack { view })
        window.makeKeyAndVisible()
        try await waitUntil(timeout: 5) { !viewModel.rows.isEmpty }
        return (window, viewModel)
    }

    private func timeline(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView, collection.accessibilityIdentifier == "chat.timeline" {
            return collection
        }
        for subview in view.subviews {
            if let found = timeline(in: subview) { return found }
        }
        return nil
    }

    func test_flagOn_mountsTheUIKitTimeline() async throws {
        let (window, _) = try await host(flag: true)
        try await waitUntil(timeout: 5) { self.timeline(in: window) != nil }
        XCTAssertNotNil(timeline(in: window))
    }

    func test_flagOff_keepsTheSwiftUITimeline() async throws {
        let (window, _) = try await host(flag: false)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(timeline(in: window))
    }

    /// Source pin: the SwiftUI branch is still there, untouched, behind the flag.
    func test_swiftUIBranch_isUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let branch = try XCTUnwrap(source.range(of: "} else if usesUIKitTimeline {"))
        let reader = try XCTUnwrap(source.range(of: "ScrollViewReader { proxy in"))
        XCTAssertLessThan(branch.lowerBound, reader.lowerBound)
        XCTAssertTrue(source.contains(".defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)"))
        XCTAssertTrue(source.contains("@AppStorage(ChatTimelineFlag.key) private var usesUIKitTimeline"))
    }

    func test_hostedEnvironment_carriesTheLinkHandlers() {
        var environment = EnvironmentValues()
        environment.openTrackerItem = { _ in }
        environment.openConversation = { _ in }
        let hosted = TimelineHostedEnvironment(environment)
        XCTAssertNotNil(hosted.openTrackerItem)
        XCTAssertNotNil(hosted.openConversation)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/ChatTimelineIntegrationTests`

Expected: `test_flagOn_mountsTheUIKitTimeline` and `test_swiftUIBranch_isUnchanged` fail. The summary reads `Executed 4 tests, with 2 failures`.

- [ ] **Step 3: Implement the representable**

`Matron/Features/Chat/Timeline/ChatTimelineView.swift`:

```swift
import SwiftUI
import MatronViewModels

/// Hosts `ChatTimelineController` in `ChatView` in place of the
/// `ScrollViewReader`/`ScrollView` block (spec §2 Structure).
struct ChatTimelineView: UIViewControllerRepresentable {
    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: ChatTimelineBridge
    let actions: ChatTimelineActions

    func makeUIViewController(context: Context) -> ChatTimelineController {
        ChatTimelineController(viewModel: viewModel, stripViewModel: stripViewModel, bridge: bridge,
                               actions: actions, environment: TimelineHostedEnvironment(context.environment))
    }

    func updateUIViewController(_ controller: ChatTimelineController, context: Context) {
        controller.update(actions: actions, environment: TimelineHostedEnvironment(context.environment))
    }

    static func dismantleUIViewController(_ controller: ChatTimelineController, coordinator: ()) {
        controller.tearDown()
    }
}
```

- [ ] **Step 4: Wire `ChatView`**

In `Matron/Features/Chat/ChatView.swift`, add this after `@State private var nativeScroll = NativeScrollViewBox()`:

```swift
    /// `chat.timeline.uikit` (spec 2026-09-26 §3): the UIKit timeline
    /// (`uikitTimeline`) instead of the SwiftUI one below, which stays
    /// byte-for-byte as it was for the flag-off path.
    @AppStorage(ChatTimelineFlag.key) private var usesUIKitTimeline = ChatTimelineFlag.defaultValue
    /// The UIKit timeline's follow state + commands for the SwiftUI chrome.
    @State private var timelineBridge = ChatTimelineBridge()
```

In `chatPage`, change

```swift
            } else {
            ScrollViewReader { proxy in
```

to

```swift
            } else if usesUIKitTimeline {
                uikitTimeline
            } else {
            ScrollViewReader { proxy in
```

Add this property directly after the closing brace of `private var chatPage: some View { … }`:

```swift
    /// The UIKit timeline (spec 2026-09-26). `ChatTimelineController` owns
    /// scrolling; the overlays are the SwiftUI branch's own controls, driven
    /// by `timelineBridge` instead of `isFollowingTail`.
    private var uikitTimeline: some View {
        ChatTimelineView(
            viewModel: viewModel,
            stripViewModel: stripViewModel,
            bridge: timelineBridge,
            actions: ChatTimelineActions(
                openSubChat: { id in navigationPath?.wrappedValue.append(id) },
                openSpawnRoom: openSpawnedRoom,
                openItem: openItem,
                openMission: openMission,
                previewFile: { url, filename in attachmentPreview = .file(url, filename: filename) },
                tapImage: { url, image in
                    attachmentPreview = .image(ImageGalleries.conversation(
                        tapped: url, image: image, chatViewModel: viewModel, deps: deps, session: session))
                }
            )
        )
        // Same answer persistence the SwiftUI branch hangs off its stack.
        .onChange(of: viewModel.items) { _, _ in
            viewModel.persistVisibleAnswers()
        }
        .overlay {
            if viewModel.rows.isEmpty { TimelineLoadingIndicator() }
        }
        .overlay(alignment: .top) {
            MinDisplayDuration(while: viewModel.isPaginatingBackward) { visible in
                if visible {
                    PaginatingHeader()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: viewModel.isPaginatingBackward)
        }
        .overlay(alignment: .bottomTrailing) {
            if !timelineBridge.isFollowingTail {
                JumpToBottomButton { timelineBridge.jumpToBottom() }
            }
        }
        .overlay(alignment: .topTrailing) {
            MinDisplayDuration(while: viewModel.isTurnRunning || viewModel.activityLabel != nil) { stopVisible in
                ChatTopTrailingControls(
                    showsStop: stopVisible,
                    showsJump: ChatTopTrailingControls.showsJump(
                        isFollowingTail: timelineBridge.isFollowingTail,
                        isTasksPage: pager.page == .tasks
                    ),
                    onStop: { Task { await viewModel.sendCommand("!esc") } },
                    onJump: { Task { await viewModel.jumpToLastOwnMessage() } }
                )
            }
        }
    }
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/ChatTimelineIntegrationTests MatronTests/ChatViewBindingTests MatronTests/ChatKeyboardAvoidanceTests MatronTests/ChatPagerTests`

Expected: `Executed N tests, with 0 failures`, where N is 4 plus the existing counts of the three classes. Record N.

- [ ] **Step 6: Smoke-run on the simulator**

Build and run the app on an iPhone 17 simulator (Debug, so the flag defaults on). Open a conversation and check:
- It opens at the bottom.
- Scrolling up leaves the tail and shows the jump button.
- The jump button returns to the tail.
- Sending a message pins to the tail.

Then turn the flag off in Settings ▸ Advanced, reopen the chat, and confirm the SwiftUI timeline is back.

- [ ] **Step 7: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/ChatTimelineView.swift Matron/Features/Chat/ChatView.swift MatronTests/ChatTimelineIntegrationTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: ChatView renders the UIKit timeline behind chat.timeline.uikit" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase 6: Behaviours

### Task 22: Pagination and the detached window

**Files:**
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`
- Test: `MatronTests/TimelinePaginationTests.swift`

**Interfaces:**
- Consumes: `ChatViewModel.extendHistoryWindow()`, `revealNewerHistory()`, `isExtendingWindow`, `isPaginatingBackward`, `windowContainsTail`, and `TimelineScrollModel.isNearTop` / `isNearBottom`.
- Produces: `private(set) var extendRequestCount: Int` (a test seam). Edge triggers fire from `scrollViewDidScroll` and after each apply.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
@testable import Matron

/// Spec §2 Pagination: within 1.5 screens of the top, reveal older rows;
/// the prepend keeps the anchor exactly (no pins, no retries).
@MainActor
final class TimelinePaginationTests: XCTestCase {
    func test_scrollingNearTheTopRevealsOlderRowsWithoutMovingContent() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(300))
        let before = h.controller.appliedRowIDs.count
        h.drag(to: 200)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        let y = try XCTUnwrap(h.onScreenY(anchor.rowID))
        try await waitUntil(timeout: 5) { h.controller.appliedRowIDs.count > before && !h.controller.hasPendingWork }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(anchor.rowID)), y, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_exhaustedHistory_doesNotRetrigger() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(30))
        h.drag(to: 10)
        try await waitUntil { h.controller.extendRequestCount == 1 && !h.viewModel.isExtendingWindow
            && !h.viewModel.isPaginatingBackward }
        try await Task.sleep(nanoseconds: 100_000_000)
        for y in [4.0, 12.0, 6.0, 20.0] as [CGFloat] { h.collectionView.contentOffset = CGPoint(x: 0, y: y) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.controller.extendRequestCount, 1, "no new rows came back — don't spin")
    }

    func test_detachedWindow_revealsNewerRowsNearTheBottom_keepingTheAnchor() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(600))
        h.viewModel.ensureWindowContains("100")
        try await h.settle()
        // `ensureWindowContains` holds `isExtendingWindow` for 150ms, which
        // (correctly) blocks reveals; start reading after it drops.
        try await waitUntil { !h.viewModel.isExtendingWindow }
        XCTAssertFalse(h.viewModel.windowContainsTail)
        let anchorBefore = h.viewModel.windowTailAnchorID
        h.drag(to: h.maxOffset - 40)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        let y = try XCTUnwrap(h.onScreenY(anchor.rowID))
        try await waitUntil(timeout: 5) { h.viewModel.windowTailAnchorID != anchorBefore }
        try await h.settle()
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(anchor.rowID)), y, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail, "a detached window's bottom never re-arms follow")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelinePaginationTests`

Expected: the build fails with `value of type 'ChatTimelineController' has no member 'extendRequestCount'`.

- [ ] **Step 3: Implement**

In `ChatTimelineController`, add these properties next to `lastTailID`:

```swift
    private var extendInFlight = false
    /// The window head an extend last came back with unchanged: history is
    /// exhausted there, so near-top stops asking until the head moves.
    private var exhaustedHeadID: String?
    private(set) var extendRequestCount = 0
```

Replace `scrollViewDidScroll` with:

```swift
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingLayout else { return }
        scrollModel.noteUserOffset(scrollView.contentOffset.y)
        evaluateEdgeTriggers()
    }
```

Replace `afterApply` with:

```swift
    private func afterApply() {
        handleTailChange()
        // A prepend that lands while the reader is still near the top keeps
        // revealing; a detached window's bottom keeps sliding.
        if !scrollModel.isFollowingTail { evaluateEdgeTriggers() }
    }
```

Then add:

```swift
    // MARK: Pagination

    /// Spec §2 Pagination. Older: not following and within 1.5 screens of
    /// the top → `extendHistoryWindow()` (local growth first, network when
    /// the window already shows everything). Newer: a window detached from
    /// the tail, viewport near its bottom → `revealNewerHistory()`. Both
    /// prepends and slides keep the viewport by anchor — no pin, no retry.
    private func evaluateEdgeTriggers() {
        if !scrollModel.isFollowingTail, scrollModel.isNearTop { requestOlderHistory() }
        if !viewModel.windowContainsTail, scrollModel.isNearBottom,
           !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward {
            timelineLogger.breadcrumb("reveal newer (window detached, tail anchor \(viewModel.windowTailAnchorID ?? "nil"))")
            viewModel.revealNewerHistory()
        }
    }

    private func requestOlderHistory() {
        let head = scrollModel.rows.first { !$0.id.hasPrefix("sep:") }?.id
        guard !extendInFlight, !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward,
              head != exhaustedHeadID else { return }
        extendInFlight = true
        extendRequestCount += 1
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.extendHistoryWindow()
            let newHead = self.viewModel.windowedRows.lazy.compactMap { row -> String? in
                if case .message(let item) = row { return item.id }
                return nil
            }.first
            self.exhaustedHeadID = (newHead == head) ? head : nil
            self.extendInFlight = false
            timelineLogger.diag("history reveal → head \(newHead ?? "nil") (was \(head ?? "nil"))")
        }
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelinePaginationTests MatronTests/ChatTimelineControllerTests`

Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/ChatTimelineController.swift MatronTests/TimelinePaginationTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline paginates by anchor — older near the top, newer in a detached window" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 23: Jumps (sequence, search, milestone, own requests)

**Files:**
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`
- Test: `MatronTests/TimelineJumpTests.swift`

**Interfaces:**
- Consumes: `ChatViewModel.pendingFocusID`, `clearPendingFocus()`, `ensureWindowContains(_:)` and `rowAnchorIDs`, and `TimelineScrollModel.jumpOffset(toRow:)`.
- Produces: jump handling after every apply, and a flash on the target cell (`accessibilityIdentifier` `"chat.timeline.flash"`).

Every jump entry point (search results, the in-chat search bar, milestone cards, the summaries TOC, "Your requests", "jump to my last message") already reaches the view as `pendingFocusID`, set by `ChatViewModel.focus(seq:)` after it has run `ensureWindowContains`. The controller needs only this one path.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
@testable import Matron

/// Spec §2 Jumps: pendingFocusID → ensureWindowContains → apply → exact
/// frame → stop deceleration → row top at the viewport top → flash.
@MainActor
final class TimelineJumpTests: XCTestCase {
    func test_focusLandsTheRowAtTheTop_andFlashesIt() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        await h.viewModel.focus(seq: 150)
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("150")), 0, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "150"))
        let cell = try XCTUnwrap(h.collectionView.cellForItem(at: IndexPath(item: index, section: 0)))
        XCTAssertTrue(cell.subviews.contains { $0.accessibilityIdentifier == "chat.timeline.flash" })
    }

    func test_focusOutsideTheWindow_widensThenLands() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        XCTAssertNil(h.controller.scrollModel.index(of: "30"), "starts outside the 120-row window")
        await h.viewModel.focus(seq: 30)
        try await waitUntil(timeout: 5) { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("30")), 0, accuracy: 0.5)
    }

    func test_focusSetBeforeTheTimelineMounts_isHonoured() async throws {
        let h = TimelineHarness(attach: false)
        h.service.emit(TimelineFixtures.conversation(200))
        _ = await h.viewModel.start()
        await h.viewModel.focus(seq: 90)
        h.attach()
        try await waitUntil(timeout: 5) { h.viewModel.pendingFocusID == nil && !h.controller.hasPendingWork }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("90")), 0, accuracy: 0.5)
    }

    func test_jumpToBottom_followsAgain_andForgetsTheRememberedPosition() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(80))
        h.drag(to: 300)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "10")
        h.bridge.jumpToBottom()
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: h.viewModel.roomID))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineJumpTests`

Expected: the first three tests time out in `waitUntil`, or fail on `onScreenY`. The summary reads `Executed 4 tests, with 3 failures`.

- [ ] **Step 3: Implement**

Replace `afterApply` with:

```swift
    private func afterApply() {
        handlePendingFocus()
        handleTailChange()
        if !scrollModel.isFollowingTail { evaluateEdgeTriggers() }
    }
```

Then add:

```swift
    // MARK: Jumps

    /// Spec §2 Jumps. `focus(seq:)` has already widened the window; if our
    /// apply of that window is still pending (precompute), the next sync
    /// lands it. A target the view model no longer has at all is dropped.
    private func handlePendingFocus() {
        guard let target = viewModel.pendingFocusID else { return }
        guard scrollModel.index(of: target) != nil else {
            if !viewModel.rowAnchorIDs.contains(target) {
                timelineLogger.breadcrumb("jump target \(target) not loaded — dropped")
                viewModel.clearPendingFocus()
            } else if !viewModel.windowedRows.contains(where: { TimelineRowContentBuilder.anchorID(for: $0) == target }) {
                viewModel.ensureWindowContains(target)
            }
            return
        }
        viewModel.clearPendingFocus()
        killMomentum()
        performLayoutUpdate { _ = scrollModel.jumpOffset(toRow: target) }
        timelineLogger.breadcrumb("jump → \(target) (offset \(Int(scrollModel.contentOffsetY)))")
        flashRow(target)
    }

    private func flashRow(_ id: String) {
        guard let index = scrollModel.index(of: id),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) else { return }
        let flash = UIView(frame: cell.bounds)
        flash.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        flash.isUserInteractionEnabled = false
        flash.accessibilityIdentifier = "chat.timeline.flash"
        cell.addSubview(flash)
        UIView.animate(withDuration: 0.6, delay: 0.4, options: [.curveEaseOut]) {
            flash.alpha = 0
        } completion: { _ in
            flash.removeFromSuperview()
        }
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineJumpTests MatronTests/TimelinePaginationTests MatronTests/ChatTimelineControllerTests`

Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/ChatTimelineController.swift MatronTests/TimelineJumpTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline jumps land the row at the top exactly, with a flash" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 24: Scroll restoration with an in-row offset

**Ruling on the spec:** "restore to (id, offset) if the id is still in the window, else to the bottom" keeps today's semantics:
- If the id is anywhere in the loaded rows (`rowAnchorIDs`), the window widens (`ensureWindowContains`) and the position is restored.
- Otherwise the entry is forgotten and the chat opens at the tail.

Entries written by the SwiftUI path carry no offset. They are bottom-anchored ids, so the UIKit path restores them with the row's bottom at the viewport's bottom.

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ChatScrollPositionMemory.swift`
- Modify: `MatronShared/Tests/ViewModelTests/ChatScrollPositionMemoryTests.swift`
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`
- Modify: `Matron/Features/Chat/ChatView.swift` (the scroll-memory block in `.onDisappear`)
- Test: `MatronTests/TimelineRestoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct ChatScrollPosition: Equatable, Sendable { itemID: String; offsetInRow: Double? }`
  - `ChatScrollPositionMemory.store(roomID:itemID:offsetInRow:)` and `ChatScrollPositionMemory.retrievePosition(roomID:)`. `store(roomID:itemID:)`, `retrieve(roomID:)` and `forget(roomID:)` behave exactly as before.
  - `ChatTimelineController.storeScrollPosition()`, `hasPendingRestore` and `ChatTimelineBridge.storeScrollPosition()`

- [ ] **Step 1: Write the failing shared tests**

Append to `ChatScrollPositionMemoryTests`:

```swift
    @MainActor
    func test_storeWithOffset_roundTripsThePosition() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev1", offsetInRow: 42.5)
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: "!a:s"),
                       ChatScrollPosition(itemID: "$ev1", offsetInRow: 42.5))
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!a:s"), "$ev1",
                       "the SwiftUI path's id-only read is unchanged")
    }

    @MainActor
    func test_idOnlyStore_hasNoOffset() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev1")
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: "!a:s"),
                       ChatScrollPosition(itemID: "$ev1", offsetInRow: nil))
    }

    @MainActor
    func test_storeWithOffset_rejectsTransientIDs() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev1", offsetInRow: 3)
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "eph:r1", offsetInRow: 3)
        XCTAssertNil(ChatScrollPositionMemory.retrievePosition(roomID: "!a:s"))
    }
```

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ChatScrollPositionMemoryTests 2>&1 | tail -5`

Expected: the build fails with `cannot find 'ChatScrollPosition' in scope`.

- [ ] **Step 2: Implement the memory change**

Replace the body of `ChatScrollPositionMemory` in `ChatScrollPositionMemory.swift` with the following. The doc comments above `store(roomID:itemID:)`, `isTransient`, `retrieve`, `forget` and `_resetForTesting` stay as they are.

```swift
    private static var positions: [String: ChatScrollPosition] = [:]

    public static func store(roomID: String, itemID: String?) {
        if let itemID, !isTransient(itemID) {
            positions[roomID] = ChatScrollPosition(itemID: itemID, offsetInRow: nil)
        } else {
            positions.removeValue(forKey: roomID)
        }
    }

    /// The UIKit timeline's entry: the TOP visible row and how far the
    /// viewport's top edge sat below that row's top. Same transient-id rule.
    public static func store(roomID: String, itemID: String, offsetInRow: Double) {
        if isTransient(itemID) {
            positions.removeValue(forKey: roomID)
        } else {
            positions[roomID] = ChatScrollPosition(itemID: itemID, offsetInRow: offsetInRow)
        }
    }

    private static func isTransient(_ id: String) -> Bool {
        id == "activity" || id.hasPrefix("echo:") || id.hasPrefix("eph:")
    }

    public static func retrieve(roomID: String) -> String? {
        positions[roomID]?.itemID
    }

    /// The full entry — the UIKit timeline reads the offset too.
    public static func retrievePosition(roomID: String) -> ChatScrollPosition? {
        positions[roomID]
    }

    public static func forget(roomID: String) {
        positions.removeValue(forKey: roomID)
    }

    public static func _resetForTesting() {
        positions.removeAll()
    }
```

Add this above the enum:

```swift
/// A remembered per-room scroll position. `offsetInRow` is set only by the
/// UIKit timeline (viewport top below the row's top); the SwiftUI timeline's
/// entries are bottom-anchored ids with no offset.
public struct ChatScrollPosition: Equatable, Sendable {
    public let itemID: String
    public let offsetInRow: Double?

    public init(itemID: String, offsetInRow: Double?) {
        self.itemID = itemID
        self.offsetInRow = offsetInRow
    }
}
```

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter ChatScrollPositionMemoryTests 2>&1 | tail -3`

Expected: `Executed 10 tests, with 0 failures`, which is the 7 existing tests plus 3 new ones.

- [ ] **Step 3: Write the failing controller tests**

```swift
import XCTest
import UIKit
import MatronViewModels
@testable import Matron

/// Spec §2 Scroll restoration.
@MainActor
final class TimelineRestoreTests: XCTestCase {
    func test_leavingAndReopening_restoresTheExactPosition() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(100))
        h.drag(to: 1500)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        h.bridge.storeScrollPosition()
        h.remount()
        try await h.settle()
        try await waitUntil { !h.controller.hasPendingRestore }
        let restored = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        XCTAssertEqual(restored.rowID, anchor.rowID)
        XCTAssertEqual(restored.offsetInRow, anchor.offsetInRow, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_swiftUIPathEntry_restoresBottomAligned() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60")
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(100))
        try await waitUntil { !h.controller.hasPendingRestore }
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "60"))
        let bottom = h.controller.scrollModel.rowMinY(at: index) + h.controller.scrollModel.rows[index].height
            - h.collectionView.contentOffset.y
        XCTAssertEqual(bottom, h.collectionView.bounds.height, accuracy: 0.5)
    }

    func test_goneRow_fallsBackToTheTail_andForgets() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "9999", offsetInRow: 10)
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(40))
        try await waitUntil { !h.controller.hasPendingRestore }
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: h.viewModel.roomID))
    }

    func test_leavingWhileFollowing_forgetsTheMemory() async throws {
        let h = TimelineHarness()
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "3")
        try await h.start(with: TimelineFixtures.conversation(40))
        h.bridge.jumpToBottom()
        h.bridge.storeScrollPosition()
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: h.viewModel.roomID))
    }
}
```

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineRestoreTests`

Expected: the build fails with `value of type 'ChatTimelineBridge' has no member 'storeScrollPosition'`.

- [ ] **Step 4: Implement in the controller, the bridge and `ChatView`**

Add to `ChatTimelineBridge`:

```swift
    func storeScrollPosition() { controller?.storeScrollPosition() }
```

In `ChatTimelineController`, add these properties next to `lastTailID`:

```swift
    private var pendingRestore: ChatScrollPosition?
    private var restoreWidened = false
    var hasPendingRestore: Bool { pendingRestore != nil }
```

In `viewDidLoad`, directly before the final `coalescer.request()`, add the lines below. They go there, not in `init`, because the memory is read when the timeline mounts (a controller can be built before its room's position is stored, as `TimelineHarness(attach: false)` does):

```swift
        pendingRestore = ChatScrollPositionMemory.retrievePosition(roomID: viewModel.roomID)
        if pendingRestore != nil {
            // Same as the SwiftUI path: a remembered position opens released.
            scrollModel.stopFollowing()
            bridge.setFollowing(false)
        }
```

Replace `afterApply` with:

```swift
    private func afterApply() {
        handlePendingRestore()
        handlePendingFocus()
        handleTailChange()
        if !scrollModel.isFollowingTail { evaluateEdgeTriggers() }
    }
```

Then add:

```swift
    // MARK: Restoration

    /// Spec §2 Scroll restoration: exact (id, offset) when the row is here;
    /// widen once when it is loaded but outside the window; otherwise the
    /// entry is gone — forget it and open at the tail. A pending jump wins.
    private func handlePendingRestore() {
        guard let position = pendingRestore, !scrollModel.rows.isEmpty else { return }
        if viewModel.pendingFocusID != nil {
            pendingRestore = nil
            return
        }
        if scrollModel.index(of: position.itemID) != nil {
            pendingRestore = nil
            performLayoutUpdate {
                if let offset = position.offsetInRow {
                    _ = scrollModel.restore(.init(rowID: position.itemID, offsetInRow: CGFloat(offset)))
                } else {
                    _ = scrollModel.restoreBottomAligned(rowID: position.itemID)
                }
            }
            timelineLogger.breadcrumb("restore → \(position.itemID) +\(position.offsetInRow.map { Int($0) } ?? -1)")
        } else if viewModel.rowAnchorIDs.contains(position.itemID) {
            guard !restoreWidened else { return }
            restoreWidened = true
            viewModel.ensureWindowContains(position.itemID)
        } else {
            pendingRestore = nil
            ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            timelineLogger.breadcrumb("restore target \(position.itemID) gone → tail")
            performLayoutUpdate { scrollModel.followTail() }
        }
    }

    /// Leaving the room: remember the top anchor, or nothing while following.
    func storeScrollPosition() {
        guard pendingRestore == nil else { return }   // never overwrite an unapplied entry
        guard !scrollModel.isFollowingTail, let anchor = scrollModel.topAnchor() else {
            ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            return
        }
        ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: anchor.rowID,
                                       offsetInRow: Double(anchor.offsetInRow))
    }
```

In `ChatView.swift` `.onDisappear`, replace

```swift
            if !isFollowingTail, let id = visibleRows.bottomID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
```

with

```swift
            if usesUIKitTimeline {
                timelineBridge.storeScrollPosition()
            } else if !isFollowingTail, let id = visibleRows.bottomID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
```

This must run before `viewModel.resetHistoryWindow(ifGeneration:)`, which is already true because the scroll-memory block comes first in `onDisappear`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelineRestoreTests MatronTests/TimelineJumpTests MatronTests/ChatTimelineControllerTests`

Expected: `Executed 16 tests, with 0 failures`.

Then run the Mac-side memory users to prove nothing changed there:

`cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'ChatScrollPositionMemory|ChatViewModel' 2>&1 | tail -3`

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add MatronShared/Sources/ViewModels/ChatScrollPositionMemory.swift MatronShared/Tests/ViewModelTests/ChatScrollPositionMemoryTests.swift Matron/Features/Chat/Timeline/ChatTimelineController.swift Matron/Features/Chat/ChatView.swift MatronTests/TimelineRestoreTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline restores (row, in-row offset); scroll memory gains an optional offset" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 25: Keyboard, rotation and Dynamic Type

**Files:**
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`
- Test: `MatronTests/TimelineResizeTests.swift`

**Interfaces:**
- Consumes: `TimelineScrollModel.setViewportHeight(_:)`, `bottomAnchor()` and `topAnchor()`; `ChatKeyboardAvoidance`, which stays the only keyboard mechanism and resizes the representable's frame.
- Produces: re-measurement on a Dynamic Type change that keeps the reader's place.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
@testable import Matron

/// Spec §2 Keyboard + Review Focus 4: resizes and re-measures never move
/// the message the reader is looking at.
@MainActor
final class TimelineResizeTests: XCTestCase {
    private func resize(_ h: TimelineHarness, to size: CGSize) {
        h.window.frame = CGRect(origin: .zero, size: size)
        h.window.layoutIfNeeded()
        h.controller.view.layoutIfNeeded()
    }

    func test_keyboardResize_whilePinned_staysAtTheBottom() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        resize(h, to: CGSize(width: 393, height: 400))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        resize(h, to: CGSize(width: 393, height: 700))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
    }

    func test_keyboardResize_whileReading_keepsTheBottomRowFixed() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let bottom = try XCTUnwrap(h.controller.scrollModel.bottomAnchor())
        let before = try XCTUnwrap(h.onScreenY(bottom.rowID))
        resize(h, to: CGSize(width: 393, height: 400))
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(bottom.rowID)), before - 300, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_widthChangeWhileReading_keepsTheTopMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let top = try XCTUnwrap(h.controller.scrollModel.topAnchor()).rowID
        resize(h, to: CGSize(width: 700, height: 700))
        try await h.settle()
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, top)
    }

    func test_dynamicTypeChangeWhileReading_keepsTheTopMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let top = try XCTUnwrap(h.controller.scrollModel.topAnchor()).rowID
        let heightBefore = try XCTUnwrap(h.controller.scrollModel.height(of: "30"))
        h.controller.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        try await waitUntil(timeout: 5) { (h.controller.scrollModel.height(of: "30") ?? 0) > heightBefore }
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, top)
    }

    func test_collectionView_isConfiguredForTheGuideComposer() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        XCTAssertEqual(h.collectionView.keyboardDismissMode, .interactive)
        XCTAssertEqual(h.collectionView.contentInsetAdjustmentBehavior, .never)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineResizeTests`

Expected: `test_dynamicTypeChangeWhileReading_keepsTheTopMessage` times out, because no trait handler exists yet. The summary reads `Executed 5 tests, with 1 failure`.

The width and keyboard tests already pass on Task 20's `viewDidLayoutSubviews` logic, and this task pins them.

- [ ] **Step 3: Implement the Dynamic Type handler**

In `viewDidLoad`, after `style = TimelineTextStyle(…)`, add:

```swift
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: ChatTimelineController, _: UITraitCollection) in
            controller.contentSizeCategoryChanged()
        }
```

Then add:

```swift
    /// Dynamic Type changed: every row re-measures (the style is half of
    /// every cache key) synchronously, so the top anchor survives exactly.
    private func contentSizeCategoryChanged() {
        let category = traitCollection.preferredContentSizeCategory
        guard category != style.sizeCategory else { return }
        style = TimelineTextStyle(sizeCategory: category)
        footerHeights.removeAll()
        mainThreadOnlyIDs.removeAll()
        timelineLogger.breadcrumb("timeline Dynamic Type → \(category.rawValue)")
        resyncSynchronously()
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineResizeTests`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/ChatTimelineController.swift MatronTests/TimelineResizeTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline keeps the reader's place through keyboard, rotation and Dynamic Type" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 26: Copy menus and text selection

**Files:**
- Modify: `Matron/Features/Chat/Timeline/TextMessageCell.swift` (add `isTextHit(_:)` and the edit-menu delegate)
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift` (add the context-menu delegate and `copyText(forRowID:)`)
- Test: `MatronTests/TimelineMenuTests.swift`

**Interfaces:**
- Produces:
  - `TextMessageCell.isTextHit(_ pointInCell: CGPoint) -> Bool`
  - `textView(_:editMenuForTextIn:suggestedActions:)`, which adds "Copy Message"
  - `ChatTimelineController.collectionView(_:contextMenuConfigurationForItemsAt:point:)`
  - `ChatTimelineController.copyText(forRowID:) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
@testable import Matron

/// Spec §2: Copy via the collection view's context menu; native partial
/// selection inside the text (Task 17 ruling on who owns which press).
@MainActor
final class TimelineMenuTests: XCTestCase {
    private func firstTextCell(_ h: TimelineHarness) throws -> (IndexPath, TextMessageCell) {
        for indexPath in h.collectionView.indexPathsForVisibleItems.sorted() {
            if let cell = h.collectionView.cellForItem(at: indexPath) as? TextMessageCell { return (indexPath, cell) }
        }
        throw XCTSkip("no text cell on screen")
    }

    func test_contextMenu_outsideTheText_offersCopyOfTheWholeBody() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let (indexPath, cell) = try firstTextCell(h)
        let outside = CGPoint(x: cell.bounds.maxX - 2, y: cell.bounds.midY)
        XCTAssertFalse(cell.isTextHit(outside))
        let point = h.collectionView.convert(outside, from: cell)
        XCTAssertNotNil(h.controller.collectionView(h.collectionView, contextMenuConfigurationForItemsAt: [indexPath],
                                                    point: point))
        let id = h.controller.appliedRowIDs[indexPath.item]
        XCTAssertEqual(h.controller.copyText(forRowID: id), cell.render?.content.body)
    }

    func test_contextMenu_onTheText_yieldsToTextSelection() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let (indexPath, cell) = try firstTextCell(h)
        let textView = try XCTUnwrap(cell.segmentViewsForTesting.first)
        let inside = cell.convert(CGPoint(x: textView.bounds.midX, y: textView.bounds.midY), from: textView)
        XCTAssertTrue(cell.isTextHit(inside))
        XCTAssertNil(h.controller.collectionView(h.collectionView, contextMenuConfigurationForItemsAt: [indexPath],
                                                 point: h.collectionView.convert(inside, from: cell)))
    }

    func test_editMenu_addsCopyMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let (_, cell) = try firstTextCell(h)
        let textView = try XCTUnwrap(cell.segmentViewsForTesting.first as? UITextView)
        let menu = cell.textView(textView, editMenuForTextIn: NSRange(location: 0, length: 3), suggestedActions: [])
        XCTAssertEqual(menu?.children.compactMap { ($0 as? UIAction)?.title }, ["Copy Message"])
    }

    func test_contextMenu_hostedRowsHaveNone() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let separator = try XCTUnwrap(h.controller.appliedRowIDs.firstIndex { $0.hasPrefix("sep:") })
        XCTAssertNil(h.controller.collectionView(h.collectionView,
                                                 contextMenuConfigurationForItemsAt: [IndexPath(item: separator, section: 0)],
                                                 point: .zero))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineMenuTests`

Expected: the build fails with `value of type 'TextMessageCell' has no member 'isTextHit'`.

- [ ] **Step 3: Implement**

In `TextMessageCell`, add:

```swift
    // MARK: Menus

    /// Whether a press at `pointInCell` lands on message text — those
    /// presses belong to the text view (selection, links, its edit menu).
    func isTextHit(_ pointInCell: CGPoint) -> Bool {
        segmentViews.contains { view in
            view is UITextView && view.convert(view.bounds, to: self).contains(pointInCell)
        }
    }

    /// Selection's edit menu gains a whole-message copy of the markdown
    /// source — what the SwiftUI path's Copy menu put on the pasteboard.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let body = render?.content.body else { return nil }
        let copyMessage = UIAction(title: "Copy Message", image: UIImage(systemName: "doc.on.doc")) { _ in
            Pasteboard.copy(body)
        }
        return UIMenu(children: suggestedActions + [copyMessage])
    }
```

In `ChatTimelineController`, add:

```swift
    // MARK: Context menu

    /// The markdown source a text row's Copy puts on the pasteboard.
    func copyText(forRowID id: String) -> String? {
        guard case .text(let text)? = contents[id] else { return nil }
        return text.body
    }

    /// Copy for presses outside the text (bubble padding, time, pills gap);
    /// presses on the text belong to the text view. Hosted rows: no menu,
    /// as on the SwiftUI path.
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath), let body = copyText(forRowID: id) else { return nil }
        if let cell = collectionView.cellForItem(at: indexPath) as? TextMessageCell,
           cell.isTextHit(collectionView.convert(point, to: cell)) {
            return nil
        }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                Pasteboard.copy(body)
            }])
        }
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineMenuTests MatronTests/TextMessageCellTests`

Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Check the gestures on the simulator by hand**

On an iPhone 17 simulator, open a chat with the flag on and check each of these:

1. Long-pressing a word selects it. The edit menu shows Copy, Select All and Copy Message.
2. Drag the selection handles across lines, then Copy. Paste the result into the composer: it is a partial copy.
3. Long-pressing the bubble's time shows the context menu with Copy. Paste gives the full markdown.
4. Tapping a `matron://convo` link opens the conversation, and tapping an http link opens Safari.

If step 3 never shows the menu, UIKit's text-selection long-press is winning over the context-menu gesture. File that as a finding on the tracker and do not work around it silently.

- [ ] **Step 6: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TextMessageCell.swift Matron/Features/Chat/Timeline/ChatTimelineController.swift MatronTests/TimelineMenuTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline copy — context menu outside the text, Copy Message in selection's menu" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 27: Breadcrumbs, signposts and the blank-chat invariant

**Files:**
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`
- Test: `MatronTests/TimelineInvariantTests.swift`

**Interfaces:**
- Produces:
  - `func verifyVisibleRows()`, the invariant, run after every apply
  - `private(set) var invariantSnapCount`
  - `OSSignposter` intervals `timeline.apply` and `timeline.precompute` under `chat.matron` / `timeline`, so the device pass can see them in Instruments

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UIKit
@testable import Matron

/// Spec §2: "Invariant check after each apply: if there are rows but no
/// visible cells, log a breadcrumb and snap to the bottom."
@MainActor
final class TimelineInvariantTests: XCTestCase {
    func test_rowsButNoVisibleCells_snapsToTheBottom() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(40))
        h.drag(to: 100_000)
        h.collectionView.layoutIfNeeded()
        XCTAssertTrue(h.collectionView.indexPathsForVisibleItems.isEmpty)
        h.controller.verifyVisibleRows()
        XCTAssertEqual(h.controller.invariantSnapCount, 1)
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertFalse(h.collectionView.indexPathsForVisibleItems.isEmpty)
    }

    /// Source pin: the forensic breadcrumbs field traces rely on.
    func test_lifecycleBreadcrumbsExist() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Chat/Timeline/ChatTimelineController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for crumb in ["follow-tail OFF (user drag)", "follow-tail ON (settled at tail)", "follow-tail ON (own send)",
                      "follow-tail ON (jump button)", "jump → ", "restore → ", "INVARIANT rows=",
                      "timeline anchor ", "timeline dropped duplicate row ids"] {
            XCTAssertTrue(source.contains(crumb), crumb)
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineInvariantTests`

Expected: the build fails with `value of type 'ChatTimelineController' has no member 'verifyVisibleRows'`.

- [ ] **Step 3: Implement**

Add at file scope, below `timelineLogger`:

```swift
/// Instruments intervals for the device pass (spec §4 performance gate).
let timelineSignposter = OSSignposter(subsystem: "chat.matron", category: "timeline")
```

In `ChatTimelineController`, add the property `private(set) var invariantSnapCount = 0`.

Wrap the body of `apply(_:)` in a signpost interval. Its first line is `let signpost = timelineSignposter.beginInterval("timeline.apply", id: timelineSignposter.makeSignpostID())`, and its first `defer` is `defer { timelineSignposter.endInterval("timeline.apply", signpost) }`.

At the end of `apply(_:)`, after the rescue breadcrumb, add:

```swift
        timelineLogger.diag("timeline apply rows=\(rows.count) changed=\(changed.count) following=\(scrollModel.isFollowingTail) offset=\(Int(scrollModel.contentOffsetY)) contentH=\(Int(scrollModel.contentHeight))")
        verifyVisibleRows()
```

In `schedulePrecompute`, wrap the `await self.heights.precompute(…)` call:

```swift
            let signpost = timelineSignposter.beginInterval("timeline.precompute", id: timelineSignposter.makeSignpostID(),
                                                            "\(texts.count) rows")
            let needsMain = await self.heights.precompute(texts, width: width, style: style)
            timelineSignposter.endInterval("timeline.precompute", signpost)
```

Then add:

```swift
    // MARK: Invariant

    /// The blank-chat tripwire: rows exist but no cell is on screen. With
    /// exact heights and one offset writer this should never fire; if it
    /// does, leave a full breadcrumb and put the reader somewhere real.
    func verifyVisibleRows() {
        guard !scrollModel.rows.isEmpty, view.window != nil else { return }
        collectionView.layoutIfNeeded()
        guard collectionView.indexPathsForVisibleItems.isEmpty else { return }
        invariantSnapCount += 1
        timelineLogger.breadcrumb("INVARIANT rows=\(scrollModel.rows.count) visible=0 offset=\(Int(collectionView.contentOffset.y)) contentH=\(Int(scrollModel.contentHeight)) viewport=\(Int(scrollModel.viewportHeight)) following=\(scrollModel.isFollowingTail) → snap to bottom")
        performLayoutUpdate { scrollModel.followTail() }
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelineInvariantTests MatronTests/ChatTimelineControllerTests`

Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Run the whole iOS suite**

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests`

Expected: `Executed N tests, with 0 failures`, where N is the pre-branch `MatronTests` count plus every test added in Tasks 1–27. Record N.

- [ ] **Step 6: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/ChatTimelineController.swift MatronTests/TimelineInvariantTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline signposts, apply diag and the rows-but-no-cells invariant" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Phase 7: Verification

### Task 28: Rig seed and UI tests

**Files:**
- Create: `MatronUITests/rig/seed-timeline.mjs`
- Modify: `MatronUITests/rig/rebuild-rig.sh`:
  - the UDID becomes overridable
  - the timeline seed becomes opt-in
  - `perf-timeline` is added to the back-dating plan
- Modify: `MatronUITests/rig/README.md` (add a "Timeline rig" section)
- Modify: `Matron/Features/Chat/Composer/ComposerView.swift`: `.accessibilityIdentifier("composer.field")` on the `TextField("Message…", …)` and `.accessibilityIdentifier("composer.send")` on the send `Button`. These are identifiers only, so neither path changes behaviour.
- Create: `MatronUITests/RigAgent.swift`
- Test: `MatronUITests/ChatTimelineUITests.swift`

**Interfaces:**
- Consumes:
  - the local journal rig (`127.0.0.1:9810`) and the agent ops `stream` and `finalize` (journal `docs/protocol.md`)
  - the accessibility ids `chat.timeline`, `chat.jumpToBottom`, `chat.jumpToLastOwnMessage`, `composer.field` and `composer.send`
- Produces:
  - 9 UI tests covering spec §4's list. They skip when the rig is down, and the streaming test also skips when `RIG_AGENT_TOKEN` is unset.

- [ ] **Step 1: Write the timeline seed**

`MatronUITests/rig/seed-timeline.mjs`:

```js
// Timeline rig — seeds `perf-timeline` ("Timeline perf rig"): 220 long
// markdown messages (links, lists, code, tables, quotes), own messages at
// 060 and 180, a conversation link at 215 and an item link at 216. It is
// the spec §1 workload for the UIKit timeline's UI tests and perf gate.
// Markers PERF-001…PERF-220 let tests find rows.
//
// Run by rebuild-rig.sh when RIG_TIMELINE=1 (after seed.mjs). Needs the
// same ./node_modules providing 'ws' as seed.mjs.
import WebSocket from 'ws';
import fs from 'node:fs';

const URL_WS = 'ws://127.0.0.1:9810/ws';
const CONVO = 'perf-timeline';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const client = JSON.parse(fs.readFileSync('/tmp/matron-demo/login-client.json', 'utf8'));
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL_WS);
    ws.on('open', () => ws.send(JSON.stringify({ op: 'hello', token, cursor: null })));
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.op === 'hello_ok') resolve(ws);
      else if (msg.op === 'error') console.error('error:', msg);
    });
    ws.on('error', reject);
  });
}

const mac = await connect(macToken);
const app = await connect(client.token);
let n = 0;
async function frame(ws, obj) {
  ws.send(JSON.stringify(obj));
  n++;
  await sleep(60); // local server: receipt order == append order across sockets
}

function body(i) {
  const item = (i % 40) + 1;
  let s = `PERF-${String(i).padStart(3, '0')} **Step ${i}** — reviewing [the upload queue](https://example.com/upload/${i}) and [#${item}](matron://item/${item}).\n\n`;
  s += `- first point about retries and backoff for request ${i}\n`;
  s += '- second point with `inline code` and a [doc link](https://developer.apple.com/documentation/uikit)\n';
  s += '- third point that wraps across several lines on a phone because it keeps going with more detail than fits\n\n';
  if (i % 5 === 0) s += '```swift\nlet queue = UploadQueue(maxRetries: 3)\nqueue.start()\n```\n\n';
  if (i % 5 === 1) s += '| Case | Result |\n|:--|--:|\n| retry | ok |\n| timeout | **failed** |\n\n';
  if (i % 5 === 2) s += '> A quoted note that spans a couple of lines to exercise the quote styling in the timeline.\n\n';
  s += `Closing paragraph for message ${i} with one more [link](https://example.com/${i}).`;
  return s;
}

await frame(mac, { op: 'convo_upsert', convo_id: CONVO, title: 'Timeline perf rig', session_state: 'done' });
for (let i = 1; i <= 220; i++) {
  const marker = `PERF-${String(i).padStart(3, '0')}`;
  if (i === 60 || i === 180) {
    await frame(app, { op: 'send', convo_id: CONVO, type: 'text',
                       payload: { body: `${marker} (own) Can you check the retry numbers on step ${i}?` },
                       local_id: `timeline-${i}` });
  } else if (i === 215) {
    await frame(mac, { op: 'publish', convo_id: CONVO, type: 'text',
                       payload: { body: `${marker} Related work lives in [Dark mode](matron://convo/demo-dark-mode).` },
                       idem_key: `timeline-${i}` });
  } else if (i === 216) {
    await frame(mac, { op: 'publish', convo_id: CONVO, type: 'text',
                       payload: { body: `${marker} Tracked as [#1](matron://item/1).` }, idem_key: `timeline-${i}` });
  } else {
    await frame(mac, { op: 'publish', convo_id: CONVO, type: 'text', payload: { body: body(i) },
                       idem_key: `timeline-${i}` });
  }
}
await frame(app, { op: 'read_marker', convo_id: CONVO, up_to_seq: null });
console.log(`seeded ${n} timeline frames`);
mac.close(); app.close();
```

- [ ] **Step 2: Wire the seed into the rig**

In `MatronUITests/rig/rebuild-rig.sh`:
- Change `UDID=E55664EB-2F33-4238-B360-38C616A43EE8` to `UDID="${RIG_UDID:-E55664EB-2F33-4238-B360-38C616A43EE8}"`.
- Directly after the line `HOMELAB_DEVICE_ID="$HOMELAB_DEVICE_ID" node seed.mjs`, add:
  ```bash
  # UIKit timeline UI tests + perf gate (docs/superpowers/plans/2026-09-26-ios-uikit-timeline.md).
  # Opt-in: the extra conversation would otherwise appear in marketing shots.
  if [[ "${RIG_TIMELINE:-0}" == "1" ]]; then
    node seed-timeline.mjs
  fi
  ```
- In the Python back-dating `plan` dict, add `'perf-timeline': now - 1*MIN,` as its first entry. It is a no-op when the conversation doesn't exist.

In `MatronUITests/rig/README.md`, append:

````markdown
## Timeline rig (UIKit timeline UI tests + perf gate)

```bash
cp seed-timeline.mjs perf-gate.sh /tmp/matron-demo/
RIG_UDID=$(xcrun simctl list devices available | grep -m1 -E '^ +iPhone 17 \(' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl boot "$RIG_UDID" || true
xcodebuild build-for-testing -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd CODE_SIGNING_ALLOWED=NO
RIG_TIMELINE=1 RIG_UDID=$RIG_UDID /tmp/matron-demo/rebuild-rig.sh
```

Rebuild before every UI-test run: the tests send messages and stream
replies, and the jump test assumes message 180 is the newest own message.
````

- [ ] **Step 3: Add the composer identifiers**

In `ComposerView.swift`:
- Add `.accessibilityIdentifier("composer.field")` after `.lineLimit(1...8)` on the `TextField("Message…", …)`.
- In the send `Button` (the `else` branch that calls `viewModel.send()`), add `.accessibilityIdentifier("composer.send")` after `.disabled(!isSendable || viewModel.isSending)`.

- [ ] **Step 4: Write the rig agent**

`MatronUITests/RigAgent.swift`:

```swift
import Foundation

/// Speaks the journal agent protocol to the local rig as mac-studio, so a UI
/// test can stream a reply into `perf-timeline` (`stream` ephemerals, then
/// `finalize`). Token from `RIG_AGENT_TOKEN`, passed to the runner as
/// `TEST_RUNNER_RIG_AGENT_TOKEN`.
final class RigAgent: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let token: String

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let token = environment["RIG_AGENT_TOKEN"], !token.isEmpty else { return nil }
        self.token = token
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:9810/ws")!)
    }

    func connect() async throws {
        task.resume()
        try await send(["op": "hello", "token": token, "cursor": NSNull()])
        while true {
            if case .string(let text) = try await task.receive(), text.contains("\"hello_ok\"") { return }
        }
    }

    func send(_ frame: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func streamReply(convo: String, ref: String, chunks: [String], interval: UInt64 = 200_000_000) async throws {
        for chunk in chunks {
            try await send(["op": "stream", "convo_id": convo, "message_ref": ref, "text": chunk])
            try await Task.sleep(nanoseconds: interval)
        }
    }

    func finalize(convo: String, ref: String, body: String) async throws {
        try await send(["op": "finalize", "convo_id": convo, "message_ref": ref, "type": "text",
                        "payload": ["body": body, "message_ref": ref]])
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
```

- [ ] **Step 5: Write the UI tests**

`MatronUITests/ChatTimelineUITests.swift`:

```swift
import XCTest

/// Spec §4 UI tests for the UIKit timeline, against the local rig seeded
/// with `perf-timeline` (see rig/README.md "Timeline rig"). Skips when the
/// rig isn't running, so normal scheme runs are unaffected.
final class ChatTimelineUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("timeline rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launchArguments += ["-chat.timeline.uikit", "YES"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    // MARK: Helpers

    private var timeline: XCUIElement { app.collectionViews["chat.timeline"] }

    private func openChat(titled title: String) {
        let tab = app.tabBars.buttons["Conversations"]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chat titled \(title)")
        row.tap()
    }

    private func openPerfChat() {
        openChat(titled: "Timeline perf rig")
        XCTAssertTrue(timeline.waitForExistence(timeout: 10), "UIKit timeline not mounted — flag argument ignored?")
    }

    private func message(_ marker: String) -> XCUIElement {
        timeline.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
    }

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        element.exists && timeline.frame.intersects(element.frame)
    }

    /// PERF numbers of the message text views intersecting the timeline.
    private func visibleMarkers() -> [Int] {
        timeline.textViews.allElementsBoundByIndex.compactMap { element -> Int? in
            guard element.exists, timeline.frame.intersects(element.frame),
                  let value = element.value as? String,
                  let range = value.range(of: #"PERF-\d{3}"#, options: .regularExpression) else { return nil }
            return Int(value[range].dropFirst(5))
        }
    }

    // MARK: Tests

    func test_opensAtTheBottom() {
        openPerfChat()
        let last = message("PERF-220")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertTrue(isOnScreen(last))
        XCTAssertFalse(app.buttons["chat.jumpToBottom"].exists)
    }

    func test_sendKeepsTheTailVisible() {
        openPerfChat()
        timeline.swipeDown()
        XCTAssertTrue(app.buttons["chat.jumpToBottom"].waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        let text = "uitest-\(UUID().uuidString.prefix(8))"
        field.typeText(text)
        app.buttons["composer.send"].tap()
        let sent = message(text)
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertTrue(isOnScreen(sent), "your own send returns to the tail")
    }

    func test_streamingReplyStaysPinned() throws {
        guard let agent = RigAgent() else { throw XCTSkip("RIG_AGENT_TOKEN not set") }
        openPerfChat()
        let ref = "uitest-\(UUID().uuidString.prefix(8))"
        let chunks = (1...12).map { " STREAM-\(String(format: "%02d", $0)) " + String(repeating: "more words ", count: 8) }
        let done = expectation(description: "streamed")
        Task.detached {
            do {
                try await agent.connect()
                try await agent.streamReply(convo: "perf-timeline", ref: ref, chunks: chunks)
                try await agent.finalize(convo: "perf-timeline", ref: ref, body: chunks.joined())
                agent.close()
            } catch {
                XCTFail("rig agent: \(error)")
            }
            done.fulfill()
        }
        for index in [4, 8, 12] {
            let marker = message(String(format: "STREAM-%02d", index))
            XCTAssertTrue(marker.waitForExistence(timeout: 10), "chunk \(index) never rendered")
            XCTAssertTrue(isOnScreen(marker), "chunk \(index) streamed below the fold — follow-tail lost")
        }
        wait(for: [done], timeout: 30)
        XCTAssertFalse(app.buttons["chat.jumpToBottom"].exists)
    }

    func test_scrollingToTheTopPagesInWithoutAJump() {
        openPerfChat()
        var lowest = Int.max
        for _ in 0..<60 {
            if isOnScreen(message("PERF-001")) { break }
            timeline.swipeDown(velocity: .fast)
            guard let low = visibleMarkers().min() else { continue }
            XCTAssertLessThanOrEqual(low, lowest, "the timeline jumped forward (\(lowest) → \(low))")
            lowest = low
            XCTAssertTrue(app.buttons["chat.jumpToBottom"].exists, "reading history must never re-pin the tail")
        }
        XCTAssertTrue(isOnScreen(message("PERF-001")), "never reached the first message")
    }

    func test_jumpToMyLastMessageLandsTheRowAtTheTop() {
        openPerfChat()
        timeline.swipeDown()
        let jump = app.buttons["chat.jumpToLastOwnMessage"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        let own = message("PERF-180")
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        let landed = expectation(for: NSPredicate { _, _ in
            abs(own.frame.minY - self.timeline.frame.minY) < 24
        }, evaluatedWith: nil)
        wait(for: [landed], timeout: 5)
    }

    func test_keyboardUpAndDownKeepsTheConversationVisible() {
        openPerfChat()
        let last = message("PERF-220")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(isOnScreen(last), "the tail stays visible above the keyboard")
        XCTAssertLessThanOrEqual(last.frame.maxY, field.frame.minY + 1)
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6)))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [gone], timeout: 5)
        XCTAssertFalse(visibleMarkers().isEmpty, "the timeline must not go blank when the keyboard leaves")
    }

    func test_roomSwitchRestoresPosition() throws {
        openPerfChat()
        for _ in 0..<6 { timeline.swipeDown() }
        sleep(1)
        let marker = try XCTUnwrap(visibleMarkers().min())
        app.navigationBars.buttons.firstMatch.tap()
        openChat(titled: "Fix the flaky upload test")
        app.navigationBars.buttons.firstMatch.tap()
        openPerfChat()
        let restored = message(String(format: "PERF-%03d", marker))
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue(isOnScreen(restored))
    }

    func test_conversationLinkOpensTheConversation() {
        openPerfChat()
        let link = message("PERF-215").links["Dark mode"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let title = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Dark mode for settings screen"))
        XCTAssertTrue(title.firstMatch.waitForExistence(timeout: 10))
    }

    func test_itemLinkReachesTheItemHandler() {
        openPerfChat()
        let link = message("PERF-216").links["#1"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        // The rig has no tracker item #1: the shared resolver explains the
        // miss in the Tracker alert — proof the tap went in-app, not to iOS.
        XCTAssertTrue(app.alerts["Tracker"].waitForExistence(timeout: 10))
        app.alerts["Tracker"].buttons["OK"].tap()
    }
}
```

- [ ] **Step 6: Run the UI tests against the rig**

First rebuild the rig per `MatronUITests/rig/README.md` "Timeline rig", with `RIG_TIMELINE=1`. Then run:

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate
export TEST_RUNNER_RIG_AGENT_TOKEN=$(sed -n 's/.*token: *\([^ ]*\).*/\1/p' /tmp/matron-demo/agent-mac-studio.txt | head -1)
IOS_TEST_DESTINATION="id=$RIG_UDID" scripts/ios-test.sh MatronUITests/ChatTimelineUITests
```

Expected: `Executed 9 tests, with 0 failures`.

Also run the same command with the rig stopped (`pkill -f 'node src/server.js'`). Expected: `Executed 9 tests, with 0 failures`, with all 9 skipped. This proves CI stays green.

- [ ] **Step 7: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add MatronUITests/rig/seed-timeline.mjs MatronUITests/rig/rebuild-rig.sh MatronUITests/rig/README.md MatronUITests/RigAgent.swift MatronUITests/ChatTimelineUITests.swift Matron/Features/Chat/Composer/ComposerView.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline UI tests on the rig (open, send, stream, page, jump, keyboard, restore, links)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 29: Performance gate

This is the spec §1 rig, made repeatable:
- An iPhone 17 simulator (60 Hz), and a Release (`-O`) build with the probe compiled in.
- The `perf-timeline` conversation: 220 long markdown messages full of links.
- A `CADisplayLink` auto-scroll for 15 s. The app measures its own CPU seconds with `getrusage` and its hitches with a display-link frame counter, 3 runs each at 25 and 150 pt/frame, while the host runs `sample` for main-thread busy time.

The targets from spec §4:
- At 25 pt/frame: ≤ 1.0 s CPU and 0 hitches.
- At 150 pt/frame: ≤ 1 hitch per second.

**Files:**
- Create: `Matron/Features/Chat/Timeline/TimelinePerfProbe.swift`
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift` (`viewDidAppear` hook, compiled only with `#if DEBUG || MATRON_PERF_PROBE`)
- Modify: `Matron/App/AppShellView.swift` (`MATRON_PERF_OPEN_CONVO` hook, `#if DEBUG || MATRON_PERF_PROBE`)
- Create: `MatronUITests/rig/perf-gate.sh`
- Test: `MatronTests/TimelinePerfProbeTests.swift`

**Interfaces:**
- Produces:
  - `struct HitchCounter` with `frame(at:duration:)`, `frames`, `hitches` and `hitchSeconds`
  - `TimelinePerfProbe` with `Config.fromEnvironment(_:)` and `Report` (Codable)
  - the files `tmp/timeline-perf.started` and `tmp/timeline-perf.json` in the app's data container
  - `perf-gate.sh`, which exits 0 only when the gate passes

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Matron

final class TimelinePerfProbeTests: XCTestCase {
    func test_steadyFrames_haveNoHitches() {
        var counter = HitchCounter()
        for frame in 0..<60 { counter.frame(at: Double(frame) / 60, duration: 1.0 / 60) }
        XCTAssertEqual(counter.frames, 59)
        XCTAssertEqual(counter.hitches, 0)
    }

    func test_aDroppedFrameGap_isOneHitch_ofTheLateTime() {
        var counter = HitchCounter()
        counter.frame(at: 0, duration: 1.0 / 60)
        counter.frame(at: 1.0 / 60, duration: 1.0 / 60)
        counter.frame(at: 4.0 / 60, duration: 1.0 / 60)
        XCTAssertEqual(counter.hitches, 1)
        XCTAssertEqual(counter.hitchSeconds, 2.0 / 60, accuracy: 1e-9)
    }

    func test_config_readsTheLaunchEnvironment() {
        XCTAssertEqual(TimelinePerfProbe.Config.fromEnvironment(["MATRON_PERF_AUTOSCROLL_PT": "25"]),
                       .init(pointsPerFrame: 25, duration: 15))
        XCTAssertEqual(TimelinePerfProbe.Config.fromEnvironment(["MATRON_PERF_AUTOSCROLL_PT": "150",
                                                                 "MATRON_PERF_DURATION_S": "5"]),
                       .init(pointsPerFrame: 150, duration: 5))
        XCTAssertNil(TimelinePerfProbe.Config.fromEnvironment([:]))
    }
}
```

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && scripts/ios-test.sh MatronTests/TimelinePerfProbeTests`

Expected: the build fails with `cannot find 'HitchCounter' in scope`.

- [ ] **Step 2: Implement the probe**

`Matron/Features/Chat/Timeline/TimelinePerfProbe.swift`:

```swift
#if DEBUG || MATRON_PERF_PROBE
import UIKit
import Darwin

/// Frame-pacing accounting for the perf gate: a frame arriving more than
/// 1.5 frame-durations after the previous one is a hitch, and the time it
/// was late is hitch time.
struct HitchCounter: Equatable {
    private(set) var frames = 0
    private(set) var hitches = 0
    private(set) var hitchSeconds: Double = 0
    private var last: CFTimeInterval?

    mutating func frame(at timestamp: CFTimeInterval, duration: CFTimeInterval) {
        defer { last = timestamp }
        guard let last else { return }
        frames += 1
        let interval = timestamp - last
        if interval > duration * 1.5 {
            hitches += 1
            hitchSeconds += interval - duration
        }
    }
}

/// Spec §1/§4 rig: auto-scrolls the timeline for `duration` seconds,
/// bouncing between the ends at `pointsPerFrame`, and writes CPU seconds
/// (getrusage, this process) + hitches to `tmp/timeline-perf.json`.
/// Enabled only by `MATRON_PERF_AUTOSCROLL_PT` in a DEBUG or
/// `MATRON_PERF_PROBE` build.
@MainActor
final class TimelinePerfProbe: NSObject {
    struct Config: Equatable {
        let pointsPerFrame: CGFloat
        let duration: TimeInterval

        static func fromEnvironment(_ environment: [String: String]) -> Config? {
            guard let raw = environment["MATRON_PERF_AUTOSCROLL_PT"], let points = Double(raw), points > 0 else {
                return nil
            }
            return Config(pointsPerFrame: CGFloat(points),
                          duration: environment["MATRON_PERF_DURATION_S"].flatMap(Double.init) ?? 15)
        }
    }

    struct Report: Codable, Equatable {
        let pointsPerFrame: Double
        let seconds: Double
        let cpuSeconds: Double
        let frames: Int
        let hitches: Int
        let hitchMilliseconds: Double
    }

    private weak var scrollView: UIScrollView?
    private let config: Config
    private let onStart: () -> Void
    private var link: CADisplayLink?
    private var counter = HitchCounter()
    private var direction: CGFloat = -1
    private var startTimestamp: CFTimeInterval?
    private var startCPU: Double = 0

    init(scrollView: UIScrollView, config: Config, onStart: @escaping () -> Void) {
        self.scrollView = scrollView
        self.config = config
        self.onStart = onStart
    }

    func start() {
        onStart()
        startCPU = Self.cpuSeconds()
        try? Data().write(to: Self.url("timeline-perf.started"))
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        counter.frame(at: link.timestamp, duration: link.duration)
        if startTimestamp == nil { startTimestamp = link.timestamp }
        guard let scrollView else { return finish(elapsed: 0) }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        var y = scrollView.contentOffset.y + direction * config.pointsPerFrame
        if y <= 0 {
            y = 0
            direction = 1
        } else if y >= maxY {
            y = maxY
            direction = -1
        }
        scrollView.contentOffset = CGPoint(x: 0, y: y)
        let elapsed = link.timestamp - (startTimestamp ?? link.timestamp)
        if elapsed >= config.duration { finish(elapsed: elapsed) }
    }

    private func finish(elapsed: CFTimeInterval) {
        link?.invalidate()
        link = nil
        let report = Report(pointsPerFrame: Double(config.pointsPerFrame), seconds: elapsed,
                            cpuSeconds: Self.cpuSeconds() - startCPU, frames: counter.frames,
                            hitches: counter.hitches, hitchMilliseconds: counter.hitchSeconds * 1000)
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: Self.url("timeline-perf.json")) }
        timelineLogger.breadcrumb("perf probe done \(report)")
    }

    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
```

In `ChatTimelineController`, add inside the class:

```swift
    #if DEBUG || MATRON_PERF_PROBE
    private var perfProbe: TimelinePerfProbe?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard perfProbe == nil,
              let config = TimelinePerfProbe.Config.fromEnvironment(ProcessInfo.processInfo.environment) else { return }
        let probe = TimelinePerfProbe(scrollView: collectionView, config: config) { [weak self] in
            // The auto-scroll is a "user" reading history: release follow-tail.
            guard let self, self.scrollModel.beginUserDrag() else { return }
            self.bridge.setFollowing(false)
        }
        perfProbe = probe
        // Let the open (entry window → steady window → paginate) settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { probe.start() }
    }
    #endif
```

In `Matron/App/AppShellView.swift`, add this modifier directly after the `.onReceive(NotificationDelegate.shared.tappedRoomID) { … }` modifier:

```swift
        #if DEBUG || MATRON_PERF_PROBE
        // Perf gate (UIKit timeline plan, Task 29): open a conversation
        // straight from the launch environment — no UI automation needed.
        .task {
            guard let convo = ProcessInfo.processInfo.environment["MATRON_PERF_OPEN_CONVO"] else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            nav.openChat(convo)
        }
        #endif
```

Run: `cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests/TimelinePerfProbeTests`

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 3: Write the gate script**

`MatronUITests/rig/perf-gate.sh`:

```bash
#!/usr/bin/env bash
# UIKit timeline performance gate (spec 2026-09-26 §4; plan Task 29).
# Prereq: the rig rebuilt with RIG_TIMELINE=1 on $RIG_UDID (booted iPhone 17).
# Builds Release with MATRON_PERF_PROBE, installs over the rig's app (data
# kept), runs 3 × 15 s auto-scrolls at 25 and at 150 pt/frame with `sample`
# on the host, and checks the targets:
#   25 pt/frame  → mean app CPU ≤ 1.0 s and 0 hitches
#   150 pt/frame → mean ≤ 1 hitch per second
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
UDID="${RIG_UDID:?set RIG_UDID to the rig's iPhone 17 simulator udid}"
DD=/tmp/matron-perf-dd
OUT=/tmp/matron-perf
rm -rf "$OUT" && mkdir -p "$OUT"

xcodebuild build -project "$REPO/Matron.xcodeproj" -scheme Matron -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=MATRON_PERF_PROBE > "$OUT/build.log" 2>&1
xcrun simctl install "$UDID" "$DD/Build/Products/Release-iphonesimulator/Matron.app"
DATA=$(xcrun simctl get_app_container "$UDID" chat.matron.app data)

run() {
  local pt=$1 i=$2
  rm -f "$DATA/tmp/timeline-perf.json" "$DATA/tmp/timeline-perf.started"
  SIMCTL_CHILD_MATRON_PERF_AUTOSCROLL_PT="$pt" SIMCTL_CHILD_MATRON_PERF_DURATION_S=15 \
  SIMCTL_CHILD_MATRON_PERF_OPEN_CONVO=perf-timeline \
    xcrun simctl launch --terminate-running-process "$UDID" chat.matron.app -chat.timeline.uikit YES > /dev/null
  for _ in $(seq 1 160); do [ -f "$DATA/tmp/timeline-perf.started" ] && break; sleep 0.25; done
  [ -f "$DATA/tmp/timeline-perf.started" ] || { echo "probe never started (pt=$pt run=$i)"; exit 1; }
  local pid; pid=$(pgrep -n -x Matron)
  sample "$pid" 15 -file "$OUT/sample-$pt-$i.txt" > /dev/null 2>&1 &
  for _ in $(seq 1 120); do [ -f "$DATA/tmp/timeline-perf.json" ] && break; sleep 0.25; done
  wait
  [ -f "$DATA/tmp/timeline-perf.json" ] || { echo "probe never finished (pt=$pt run=$i)"; exit 1; }
  cp "$DATA/tmp/timeline-perf.json" "$OUT/run-$pt-$i.json"
  echo "pt=$pt run=$i $(cat "$OUT/run-$pt-$i.json")"
}

for pt in 25 150; do for i in 1 2 3; do run "$pt" "$i"; done; done

python3 - "$OUT" <<'PYEOF'
import glob, json, os, sys
out = sys.argv[1]
def runs(pt):
    return [json.load(open(p)) for p in sorted(glob.glob(os.path.join(out, f"run-{pt}-*.json")))]
slow, fast = runs(25), runs(150)
cpu = sum(r["cpuSeconds"] for r in slow) / len(slow)
slow_hitches = sum(r["hitches"] for r in slow) / len(slow)
fast_rate = sum(r["hitches"] / r["seconds"] for r in fast) / len(fast)
fast_cpu = sum(r["cpuSeconds"] for r in fast) / len(fast)
print(f"25 pt/frame : mean CPU {cpu:.2f} s (target ≤ 1.00), mean hitches {slow_hitches:.2f} (target 0)")
print(f"150 pt/frame: mean {fast_rate:.2f} hitches/s (target ≤ 1.00), mean CPU {fast_cpu:.2f} s")
print(f"main-thread samples: {out}/sample-*.txt")
ok = cpu <= 1.0 and slow_hitches == 0 and fast_rate <= 1.0
print("PERF GATE", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PYEOF
```

Run: `chmod +x /Users/danbarker/Dev/matron-apple-uikittimeline/MatronUITests/rig/perf-gate.sh`

- [ ] **Step 4: Run the gate**

Rebuild the rig with `RIG_TIMELINE=1` (Task 28 Step 6 prerequisites), then:

Run: `cp /Users/danbarker/Dev/matron-apple-uikittimeline/MatronUITests/rig/perf-gate.sh /tmp/matron-demo/ && RIG_UDID=$RIG_UDID /Users/danbarker/Dev/matron-apple-uikittimeline/MatronUITests/rig/perf-gate.sh`

Expected: the final line is `PERF GATE PASS`.

Record the six JSON lines and the two summary lines. For each 25 pt run, also record the main-thread busy time from `sample-25-*.txt`: the call-graph count under `Thread_… DispatchQueue_1: com.apple.main-thread`, times 1 ms.

On `FAIL`, open `sample-150-*.txt` and profile before changing anything. The spec's expected remaining cost is first-time TextKit layout as cells come on screen. Record the numbers in the Task 30 tracker item either way.

- [ ] **Step 5: Commit**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git add Matron/Features/Chat/Timeline/TimelinePerfProbe.swift Matron/Features/Chat/Timeline/ChatTimelineController.swift Matron/App/AppShellView.swift MatronUITests/rig/perf-gate.sh MatronTests/TimelinePerfProbeTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "ios: UIKit timeline perf probe + perf-gate.sh (spec §4 targets)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 30: Full verification, device try-build, Dan's gate

Nothing merges until Dan has tried it on his iPhone and approved.

**Files:** none change, unless the checks below find something.

- [ ] **Step 1: Run all automated suites**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline && xcodegen generate && scripts/ios-test.sh MatronTests
cd /Users/danbarker/Dev/matron-apple-uikittimeline/MatronShared && set -o pipefail && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
cd /Users/danbarker/Dev/matron-apple-uikittimeline && mkdir -p /tmp/matron-mac-test-home && env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-mac-test-home TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -3
```

Expected:
- The iOS run shows `Executed N tests, with 0 failures`.
- The shared package run shows 0 failures.
- The Mac run shows the Task 2 baseline `Executed` count, with 0 failures.

Then confirm the diff touches nothing under `MatronMac/`:

```bash
git diff --stat origin/main -- MatronMac MatronMacTests MatronMacUITests
```

Expected: empty output.

- [ ] **Step 2: Build and install on Dan's iPhone (Release)**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
xcodebuild -project Matron.xcodeproj -scheme Matron -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/matron-device-dd -allowProvisioningUpdates build 2>&1 | tail -3
xcrun devicectl list devices
```

Take Dan's iPhone identifier from the `xcrun devicectl list devices` output, then install:

```bash
xcrun devicectl device install app --device "$IPHONE_ID" /tmp/matron-device-dd/Build/Products/Release-iphoneos/Matron.app
```

Error 12040 means the phone is locked: retry once it is unlocked. Error 4000 is a transient tunnel failure: retry.

A dev-signed Release build counts as the App Store channel, so the flag defaults off. Dan turns it on in Settings ▸ Advanced ▸ New chat timeline.

- [ ] **Step 3: Record hitches on the device (120 Hz)**

With the flag on and Dan scrolling a long markdown chat:

```bash
xcrun xctrace record --template 'Animation Hitches' --device "$IPHONE_ID" --attach Matron --time-limit 30s \
  --output /tmp/matron-uikit-timeline-hitches.trace
```

Open the trace. Check the hitch count, and that the `timeline.apply` and `timeline.precompute` signpost intervals (subsystem `chat.matron`, category `timeline`) sit outside the scroll bursts.

- [ ] **Step 4: File Dan's gate on the tracker**

Create one tracker question item (kind `question`, actions `["Merge", "Needs changes"]`) titled "iOS UIKit timeline try-build is on your phone — OK to merge?". Its body must contain:
- the perf-gate numbers from Task 29 (all six runs, the means, PASS/FAIL, the 25 pt main-thread busy time)
- the device hitch trace summary from Step 3
- the snapshot parity notes from Task 17 Step 6
- the Task 26 Step 5 gesture findings
- this checklist for Dan:
  1. Open long markdown chats; scroll fast and slowly. It should be smooth at 120 Hz and never blank.
  2. Watch a live turn stream while pinned. Scroll up mid-turn: the text you're reading doesn't move.
  3. Send while scrolled up: it returns to the bottom.
  4. Use search, a milestone card, "Your requests" and "jump to my last message": each lands the row at the top, with a flash.
  5. Leave a chat mid-history and come back: you're in the same place.
  6. Keyboard up and down, and the interactive swipe-down dismissal.
  7. Links: an item, a conversation, a pill and an http link. Long-press to select part of a message. Long-press the bubble edge to Copy.
  8. Rotate, and change Dynamic Type mid-chat.
  9. Blank-chat soak: use it daily for a few days. If a chat ever looks empty, pull the breadcrumb log:
     ```bash
     xcrun devicectl device copy from --device "$IPHONE_ID" --domain-type appDataContainer --domain-identifier chat.matron.app --source Documents/matron-diag.log --destination /tmp/matron-diag.log
     ```
     Then grep it for `INVARIANT`, `ios-chat-timeline` crumbs, `anchor … vanished`.

Link the item to the draft PR from Step 5.

- [ ] **Step 5: Push the branch and open a draft PR (do not merge)**

```bash
cd /Users/danbarker/Dev/matron-apple-uikittimeline
git push -u origin feat/ios-uikit-timeline
gh pr create --draft --base main --head feat/ios-uikit-timeline \
  --title "iOS: UIKit chat timeline behind chat.timeline.uikit" \
  --body "Implements docs/superpowers/specs/2026-09-26-ios-uikit-timeline-design.md per docs/superpowers/plans/2026-09-26-ios-uikit-timeline.md. Flag on by default in Debug/TestFlight, off for the App Store; SwiftUI path and Mac untouched. Perf gate + device numbers in the tracker item. Draft until Dan has tried the device build.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

The PR stays a draft until Dan answers "Merge" on the tracker item. Only then run `gh pr ready`, wait for CI and the reviews, and merge (merge commit, not squash).

---

## Out of scope (follow-ups, not in this plan)

- **Spec Phase 2:** raising `ChatViewModel.maxWindowSize` (for example to 1000) once the flag has soaked.
- **`SubChatView`** (the read-only subagent viewer) still renders through the SwiftUI `TimelineListContent`. The spec names only `ChatView`'s block. Porting the viewer is a small follow-up that reuses `ChatTimelineController` with no composer.
- **Deleting the SwiftUI iOS path**, `TimelineRowView` and its `HostedTimelineRow` mirror note: two releases after the flag flips on (spec §3).
