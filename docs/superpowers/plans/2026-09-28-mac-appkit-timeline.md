# Mac AppKit (NSTableView) Chat Timeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Mac chat timeline's eager SwiftUI `VStack` with a virtualised `NSTableView`, behind `chat.timeline.appkit`, keeping every Mac timeline behaviour. It reuses the iOS UIKit timeline's shared pieces and measures clearly faster on long chats.

**Architecture:**
- The iOS timeline's platform-neutral parts move into `Shared/ChatTimeline/`, compiled into both apps:
  - the scroll model, row-content builder and bubble geometry;
  - a new `TimelineSession` policy core, extracted from `ChatTimelineController`, that owns follow-tail, restore, jumps, paging edges and the invariant.
- The iOS controller and a new `MacTimelineController` each implement a small `TimelineSurface` protocol for their view: a collection view on iOS, a table view on Mac.
- **Mac rows:**
  - Text rows are native AppKit: a bubble, the existing `MessageCopyTextView` and a timestamp, laid out by the shared geometry.
  - Every other row kind is an `NSHostingView` of today's SwiftUI row view, with a cached height.

**Tech Stack:** Swift 6, AppKit (`NSTableView`, TextKit 2 `NSTextView`), SwiftUI (`NSViewControllerRepresentable`, `NSHostingView`), Observation, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-28-mac-appkit-timeline-design.md` — read it first. §1 has the measured cause and §4 has the behaviours list this plan must keep.

## Global Constraints

- Flag key `chat.timeline.appkit`; default ON in Debug builds, OFF in Release (spec §5). The flag-off path is the current SwiftUI timeline byte for byte.
- iOS behaviour must not change. Every existing `MatronTests` timeline test passes unchanged after the extraction (Tasks 1–2).
- The Mac renderer's output must not change: `MarkdownAttributedFingerprintTests` stays green with no re-record.
- The view model API is consumed as it is. No `ChatViewModel` changes apart from the DEBUG-only perf hooks in Task 0.
- One writer of the scroll offset per surface, and only from `TimelineSession`'s model. No estimated heights, no animated programmatic scrolls.
- Never call `noteHeightOfRows`/`insertRows`/`removeRows` from inside an `NSTableView` delegate callback; go through the coalescer.
- **Mac tests:** run `MatronMacTests` ONLY as `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport xcodebuild test …`. The env var must be real, not a trailing `KEY=value` argument. After each run:
  - Check `/tmp/matron-test-appsupport/journal-store/` exists.
  - Assert the "Executed N tests" count; `-only-testing:` on a class xcodegen hasn't picked up runs 0 tests and reports success.
- Run `xcodegen generate` after adding or moving any file or folder.
- **Disk:** this Mac is low on disk.
  - Use one DerivedData per purpose: `/tmp/mactable/dd` (rig), `/tmp/mactable/dd-test` (Mac tests), `/tmp/mactable/dd-ios` (iOS tests).
  - Add `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` to every Mac build.
  - Check `df -h /` before each build; delete all three at the end (Task 12).
- **Commits:** use `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit …`; never `git config` inside the worktree. End every message with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer.
- Worktree: `~/Dev/matron-apple-mactable`, branch `feat/mac-appkit-timeline`, off `origin/main` `678c4e49`.

## Review Focus

1. **A cross-message drag that autoscrolls past rows that were never mounted.** The copied transcript must still include every message between the ends, and the highlight must appear on rows as they scroll in. Tested in Task 5 (controller, provider fallback) and Task 10 (table-level integration).
2. **A streaming reply growing while the reader sits mid-history** (not following). The rows on screen must not move. While following, the tail stays pinned, frame by frame. Tested in Task 9.
3. **A window resize while reading history.** The top message stays the top message, and heights are re-measured at the new width with no clipped bubbles. Tested in Task 10.
4. **A recycled text row view that was showing a selection or a code-button checkmark.** Neither may leak onto the message it's reused for. Tested in Task 7.
5. **Tabled messages (TextKit 1) and plain messages sharing the table.** A reused view must never flip TextKit version; tables render as tables. Tested in Task 7.

---

## File map

```
Shared/ChatTimeline/                         (compiled into Matron AND MatronMac)
  TimelineScrollModel.swift                  moved from Matron/Features/Chat/Timeline, unchanged
  TimelineRowContent.swift                   moved; calls TimelineSenderLabels
  TimelineSenderLabels.swift                 NEW — avatarSender / displayName (shared statics)
  TextBubbleGeometry.swift                   moved (incl. TextRowLayout), unchanged
  TimelineSession.swift                      NEW — policy core extracted from ChatTimelineController
  TimelineSurface.swift                      NEW — protocol the platform controllers implement
Shared/ChatTimelineTestSupport/              (compiled into MatronTests AND MatronMacTests)
  TimelineServiceFixtures.swift              LiveTimelineFixture, NoMediaFixture, NoChildrenChatFixture,
                                             TimelineFixtures.viewModel/.text — moved out of TimelineTestFixtures.swift
Matron/Features/Chat/Timeline/ChatTimelineController.swift   now a TimelineSurface driving TimelineSession
MatronShared/Sources/DesignSystem/
  MessageLinkRouter.swift                    NEW — link policy (from SelectableTextViewRepresentable.Coordinator)
  MessageBodyView.swift                      NEW — public AppKit body: MessageCopyTextView + code-copy buttons
  SelectableMessageText.swift                uses MessageLinkRouter + MessageBodyView.configure(...)
  MarkdownAttributed.swift                   + Rendered.lastBaseline(width:)
  MessageSelectionController.swift           + register re-applies span, + contentProvider fallback
MatronMac/Features/Chat/Timeline/
  MacTimelineFlag.swift                      NEW
  MacTimelineRowContentView.swift            MacTimelineRowView moved out of MacChatView.swift (internal)
  MacTimelineMeasurer.swift                  NEW — text via TextBubbleGeometry, hosted via fittingSize; cache
  MacTextRowView.swift                       NEW — native text row
  MacHostedRowView.swift                     NEW — NSHostingView row with size-change callback
  MacTimelineScrollView.swift                NEW — NSScrollView subclass: user-scroll detection
  MacTimelineController.swift                NEW — NSViewController + NSTableView, TimelineSurface
  MacTimelineView.swift                      NEW — representable + MacTimelineBridge
MatronMac/Features/Chat/MacChatView.swift    flag branch in chatColumn
MatronMac/Features/Settings/MacDeviceSettingsView.swift   Advanced toggle
MatronMac/App/MacTimelinePerfProbe.swift     (Task 0, exists) rig probe
MatronMacUITests/rig/mac-perf.sh             NEW — build / launch / run / A-B script
MatronMacTests/MacTimeline*Tests.swift       NEW
```

---

### Task 0: Commit the perf rig (already built for the baseline)

**Files:**
- Exists: `MatronMac/App/MacTimelinePerfProbe.swift`; DEBUG hooks in `MatronShared/Sources/ViewModels/ChatViewModel.swift` (`debugReceiveStreamingText`, `debugEndStreaming`), `MatronMac/App/MatronMacApp.swift`, `MatronMac/Features/Chat/MacChatView.swift` (probe registration and `noteRowsPresented`), and `MatronMac/Features/ChatList/MacChatListView.swift` (the `.matronPerfOpenConversation` receiver).
- Create: `MatronMacUITests/rig/mac-perf.sh`, `MatronMacUITests/rig/README.md`.

- [ ] **Step 1: Write `mac-perf.sh`.** It folds together the `/tmp/mactable/{build,launch,run}.sh` scripts used for the baseline:

```zsh
#!/bin/zsh
# Mac timeline perf rig (spec 2026-09-28 §1). Offline copy of the live store,
# Release -O + DEBUG hooks, no sandbox. Never a second live client: the copied
# session's homeserverURL points at 127.0.0.1:9.
#   mac-perf.sh store              — back up the live store into $RIG/store
#   mac-perf.sh build <worktree> <appdir>
#   mac-perf.sh launch <appdir> [convo] [flag on|off]
#   mac-perf.sh run "<cmd>" ...    — one probe command per arg, prints each result
#   mac-perf.sh ab <appdir> <pairs> — interleaved flag off/on suite
set -e
RIG=${RIG:-/tmp/mactable}
LIVE="$HOME/Library/Containers/chat.matron.app/Data/Library/Application Support/chat.matron.app"
LONG=${LONG:-3a258fa0-ee0a-43e2-9f01-a30db5695e39}
OTHER=${OTHER:-5ee1ed62-1b55-4968-b788-a089ff0b0e28}
case $1 in
store)
  mkdir -p $RIG/store/journal-store $RIG/store/sessions
  sqlite3 "$LIVE/journal-store/dan.sqlite" ".backup $RIG/store/journal-store/dan.sqlite"
  sqlite3 "$LIVE/matron-search.sqlite" ".backup $RIG/store/matron-search.sqlite"
  jq '.homeserverURL="https://127.0.0.1:9/"' "$LIVE/sessions/matron.journal.session.json" > $RIG/store/sessions/matron.journal.session.json ;;
build)
  cd $2 && xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Release \
    -derivedDataPath $RIG/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    OTHER_SWIFT_FLAGS='$(inherited) -DDEBUG' CODE_SIGN_ENTITLEMENTS=MatronMac/App/MatronMac.Debug.entitlements \
    build > $RIG/build.log 2>&1 || { grep -E ' error: ' $RIG/build.log | head; exit 1; }
  mkdir -p $3 && rm -rf $3/MatronMac.app && ditto $RIG/dd/Build/Products/Release/MatronMac.app $3/MatronMac.app ;;
launch)
  pkill -f "$RIG/.*/MatronMac.app/Contents/MacOS/MatronMac" || true; sleep 1; rm -f $RIG/cmd
  if [ "$4" = on ]; then defaults write chat.matron.app chat.timeline.appkit -bool YES
  else defaults write chat.matron.app chat.timeline.appkit -bool NO; fi
  env MATRON_APP_SUPPORT_OVERRIDE=$RIG/store MATRON_PERF_CMD_FILE=$RIG/cmd MATRON_PERF_OUT=$RIG/perf.jsonl \
    MATRON_DEBUG_OPEN_CONVO=${3:-$LONG} $2/MatronMac.app/Contents/MacOS/MatronMac \
    -MatronDebug YES -NSAppSleepDisabled YES > $RIG/app.log 2>&1 &
  sleep 20; $0 run "float on" ;;
run)
  shift; touch $RIG/perf.jsonl
  for c in "$@"; do
    n=$(wc -l < $RIG/perf.jsonl); echo "$c" > $RIG/cmd
    for i in {1..600}; do [ $(wc -l < $RIG/perf.jsonl) -gt $n ] && break; sleep 0.5; done
    tail -1 $RIG/perf.jsonl; sleep 2
  done ;;
ab)
  for p in $(seq 1 $3); do for flag in off on; do
    echo "== pair $p flag $flag"; $0 launch $2 $LONG $flag
    $0 run "idle 5" "open $OTHER" "open $LONG" "open $OTHER" "open $LONG" \
      "bottom" "scroll 25 900" "bottom" "scroll 150 300" "bottom" "stream 150 10" "idle 5"
  done; done ;;
esac
```

  The rig is unsandboxed, so it reads `~/Library/Preferences/chat.matron.app.plist`, never the live app's container.

- [ ] **Step 2: Write `README.md`.** Copy the recipe and caveats from spec §1: occlusion and `float`, the load-average caveat, and "interleaved A/B only".

- [ ] **Step 3: Verify.** Run `zsh MatronMacUITests/rig/mac-perf.sh build ~/Dev/matron-apple-mactable /tmp/mactable/app-base`. Expected: exit 0, and `/tmp/mactable/app-base/MatronMac.app` exists.

- [ ] **Step 4: Commit.**

```bash
git add MatronMac/App/MacTimelinePerfProbe.swift MatronMac/App/MatronMacApp.swift MatronMac/Features/Chat/MacChatView.swift \
  MatronMac/Features/ChatList/MacChatListView.swift MatronShared/Sources/ViewModels/ChatViewModel.swift MatronMacUITests/rig docs/superpowers
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "mac: timeline perf rig — scroll, stream, open probes (DEBUG only)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 1: Move the pure iOS timeline pieces to `Shared/ChatTimeline`

**Files:**
- Move: `Matron/Features/Chat/Timeline/{TimelineScrollModel,TimelineRowContent,TextBubbleGeometry}.swift` → `Shared/ChatTimeline/`.
- Create: `Shared/ChatTimeline/TimelineSenderLabels.swift`.
- Modify:
  - `Matron/Features/Chat/Rendering/TimelineItemView.swift:548-561`
  - `MatronMac/Features/Chat/MacTimelineItemView.swift` (`avatarSender`, `displayName`)
  - `project.yml`: add `- path: Shared/ChatTimeline` to the `sources` of both `Matron` and `MatronMac`.
- Move: the UIKit-free fixtures in `MatronTests/TimelineTestFixtures.swift` (`LiveTimelineFixture`, `NoMediaFixture`, `NoChildrenChatFixture`, and any `TimelineFixtures` helpers that don't touch UIKit) → `Shared/ChatTimelineTestSupport/TimelineServiceFixtures.swift`. Add that path to the `sources` of both `MatronTests` and `MatronMacTests`.
- Test: `MatronMacTests/TimelineSharedSourcesTests.swift`.

**Interfaces:**
- Produces:
  - `enum TimelineSenderLabels { static func avatarSender(for: TimelineItem, hasMultipleSenders: Bool) -> String?; static func displayName(for senderID: String) -> String }`
  - `TimelineScrollModel`, `TimelineRowContent`, `TextRowContent`, `HostedRowContent`, `TimelineRowContentBuilder`, `TimelineRowSource`, `BuiltRows`, `TextBubbleGeometry`, `TextRowLayout` — unchanged API, now available in `MatronMac`.

- [ ] **Step 1: Write the failing Mac test** (it cannot compile until the move lands):

```swift
import XCTest
import MatronChat
import MatronModels
@testable import MatronMac

/// The shared timeline sources compile into the Mac app and behave as on iOS.
final class TimelineSharedSourcesTests: XCTestCase {
    func test_scrollModelPinsToBottomWhileFollowing() {
        var model = TimelineScrollModel()
        model.setViewportHeight(500)
        model.replaceRows((0..<20).map { .init(id: "r\($0)", height: 100) }, footerHeight: 0)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY, accuracy: 0.01)
    }

    func test_senderLabelsMatchBothItemViews() {
        XCTAssertEqual(TimelineSenderLabels.displayName(for: "@bot:server.com"), "bot")
        XCTAssertEqual(MacTimelineItemView.displayName(for: "@bot:server.com"), "bot")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails to compile.**

```bash
cd ~/Dev/matron-apple-mactable && xcodegen generate
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport xcodebuild test -project Matron.xcodeproj -scheme MatronMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/mactable/dd-test ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -only-testing:MatronMacTests/TimelineSharedSourcesTests 2>&1 | grep -E 'error:|Executed' | head
```

  Expected: `cannot find 'TimelineScrollModel' in scope`.

- [ ] **Step 3: Do the move.** Use `git mv` for the three files, then create `TimelineSenderLabels.swift`:

```swift
import MatronChat

/// Sender presentation shared by both timelines (iOS `TimelineItemView`, Mac
/// `MacTimelineItemView` and both table/collection timelines).
enum TimelineSenderLabels {
    /// Non-nil only in multi-sender rooms, never for own rows or the
    /// streaming placeholder.
    static func avatarSender(for item: TimelineItem, hasMultipleSenders: Bool) -> String? {
        guard !item.isOwn, hasMultipleSenders, !item.isEphemeralStreamingPlaceholder else { return nil }
        return item.sender
    }

    /// Local part of a Matrix-style id without the `@` sigil.
    static func displayName(for senderID: String) -> String {
        let withoutSigil = senderID.hasPrefix("@") ? String(senderID.dropFirst()) : senderID
        return withoutSigil.split(separator: ":").first.map(String.init) ?? senderID
    }
}
```

  Then:
  - Replace the bodies of `TimelineItemView.avatarSender/displayName` and `MacTimelineItemView.avatarSender/displayName` with `TimelineSenderLabels.…` forwards. Keep the statics: tests and other call sites use them.
  - In `Shared/ChatTimeline/TimelineRowContent.swift`, replace `TimelineItemView.avatarSender(` with `TimelineSenderLabels.avatarSender(`, and `TimelineItemView.displayName(` with `TimelineSenderLabels.displayName(`.
  - Move the fixtures file. Keep `TimelineHarness` (UIKit) in `MatronTests/TimelineTestFixtures.swift`. Change the moved file's `@testable import Matron` to plain imports of `MatronChat`, `MatronModels` and `MatronViewModels`. If a `TimelineFixtures` helper needs an app-target type, leave that helper in the iOS file.
  - Run `xcodegen generate`.

- [ ] **Step 4: Run the Mac test, then the iOS timeline suite.**
  - Mac: the Step 2 command. Expected: `Executed 2 tests, with 0 failures`.
  - iOS:

```bash
xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/mactable/dd-ios -only-testing:MatronTests 2>&1 | grep -E 'error:|Executed .* tests' | tail -3
```

  Expected: the same executed count as on `main` (record it before the move by running the same command on a clean checkout), and 0 failures.

- [ ] **Step 5: Commit** with the message `timeline: shared pure pieces (scroll model, row content, bubble geometry) compile into both apps`, plus the trailer.

---

### Task 2: Extract `TimelineSession` (policy core) from `ChatTimelineController`

The iOS controller mixes UIKit plumbing with platform-neutral rules. The rules move into a shared class; iOS keeps behaving identically and the Mac drives the same class.

**Files:**
- Create: `Shared/ChatTimeline/TimelineSurface.swift`, `Shared/ChatTimeline/TimelineSession.swift`.
- Modify: `Matron/Features/Chat/Timeline/ChatTimelineController.swift`.
- Test: `MatronMacTests/TimelineSessionTests.swift`, which uses a fake surface. It runs on the Mac target, so it also proves the session is UIKit-free.

**Interfaces:**
- Produces:

```swift
/// What a platform timeline view must do for `TimelineSession`.
@MainActor protocol TimelineSurface: AnyObject {
    /// Replace the displayed rows (ids in order) with no animation; rows in
    /// `reconfigure` keep their view and re-render; rows in `reload` get a
    /// fresh view (their kind changed). Called inside `performLayoutUpdate`.
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String])
    /// Write `offsetY` to the scroll view (content space, top-down) and lay out.
    func setContentOffset(_ offsetY: CGFloat)
    /// Stop any in-flight deceleration/momentum.
    func killMomentum()
    /// True when at least one row view is on screen (the blank-chat tripwire).
    func hasVisibleRows() -> Bool
    /// Briefly highlight the row (jump landing).
    func flashRow(_ id: String)
    /// A precompute is in flight or a sync is already scheduled.
    var hasPendingWork: Bool { get }
    /// Schedule one coalesced `sync` on the next frame.
    func requestSync()
    /// The follow state changed (drives the jump button).
    func followingChanged(_ following: Bool)
}
```

```swift
@MainActor final class TimelineSession {
    init(viewModel: ChatViewModel, surface: TimelineSurface)
    private(set) var scrollModel: TimelineScrollModel
    private(set) var contents: [String: TimelineRowContent]
    var hasPendingRestore: Bool { get }
    private(set) var isSuspended: Bool
    private(set) var isTornDown: Bool
    private(set) var exhaustedHeadID: String?        // test seam, as today
    private(set) var extendRequestCount: Int          // test seam, as today
    private(set) var invariantSnapCount: Int          // test seam, as today

    // Content
    func apply(_ contents: [TimelineRowContent], heights: [String: CGFloat], footerHeight: CGFloat,
               forceReconfigure: Bool)
    func afterApply()
    func updateHeight(ofRow id: String, to height: CGFloat)   // hosted self-report / stream re-measure
    func setFooterHeight(_ height: CGFloat)
    // Geometry
    func setViewportHeight(_ height: CGFloat, widthChanging: Bool)
    // User scrolling
    func userScrolled(toOffset y: CGFloat)
    func userDragBegan()
    func userScrollSettled()
    func userScrolledToTop()           // iOS status-bar tap
    // Commands
    func jumpToBottom()
    func storeScrollPosition()
    func mount()                       // viewDidLoad's restore read + first request
    func suspend()
    func resume()
    func tearDown()
    func verifyVisibleRows()
    func performLayoutUpdate(_ changes: (inout TimelineScrollModel) -> Void)
}
```

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import MatronMac

@MainActor final class FakeSurface: TimelineSurface {
    var applied: [[String]] = []
    var offsets: [CGFloat] = []
    var flashed: [String] = []
    var visible = true
    var hasPendingWork = false
    var syncRequests = 0
    var following: [Bool] = []
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String]) { applied.append(ids) }
    func setContentOffset(_ offsetY: CGFloat) { offsets.append(offsetY) }
    func killMomentum() {}
    func hasVisibleRows() -> Bool { visible }
    func flashRow(_ id: String) { flashed.append(id) }
    func requestSync() { syncRequests += 1 }
    func followingChanged(_ following: Bool) { self.following.append(following) }
}

@MainActor final class TimelineSessionTests: XCTestCase {
    private func texts(_ n: Int) -> [TimelineRowContent] {
        (0..<n).map { .text(TextRowContent(itemID: "m\($0)", body: "b\($0)", isOwn: false, sendState: .sent,
                                           timestamp: Date(timeIntervalSince1970: 0), avatarSender: nil,
                                           senderLabel: "bot", pills: [])) }
    }

    private func makeSession() async -> (TimelineSession, FakeSurface) {
        let service = LiveTimelineFixture()
        let viewModel = TimelineFixtures.viewModel(service, roomID: "!s-\(UUID().uuidString):t")
        let surface = FakeSurface()
        let session = TimelineSession(viewModel: viewModel, surface: surface)
        session.setViewportHeight(500, widthChanging: false)
        return (session, surface)
    }

    func test_applyWhileFollowingPinsToBottom() async {
        let (session, surface) = await makeSession()
        let rows = texts(20)
        session.apply(rows, heights: Dictionary(uniqueKeysWithValues: rows.map { ($0.anchorID, 100) }),
                      footerHeight: 0, forceReconfigure: false)
        XCTAssertEqual(surface.applied.last?.count, 20)
        XCTAssertEqual(surface.offsets.last ?? -1, session.scrollModel.maxOffsetY, accuracy: 0.01)
    }

    func test_userDragReleasesFollowAndPrependKeepsAnchor() async {
        let (session, surface) = await makeSession()
        var rows = texts(20)
        var heights = Dictionary(uniqueKeysWithValues: rows.map { ($0.anchorID, CGFloat(100)) })
        session.apply(rows, heights: heights, footerHeight: 0, forceReconfigure: false)
        session.userDragBegan()
        session.userScrolled(toOffset: 600)
        let anchor = session.scrollModel.topAnchor()
        let older: [TimelineRowContent] = (0..<5).map { .text(TextRowContent(itemID: "o\($0)", body: "o", isOwn: false,
            sendState: .sent, timestamp: Date(timeIntervalSince1970: 0), avatarSender: nil, senderLabel: "bot", pills: [])) }
        rows = older + rows
        for row in older { heights[row.anchorID] = 80 }
        session.apply(rows, heights: heights, footerHeight: 0, forceReconfigure: false)
        XCTAssertEqual(session.scrollModel.topAnchor(), anchor)
        XCTAssertEqual(surface.offsets.last ?? -1, 600 + 5 * 80 + 5 * session.scrollModel.metrics.rowSpacing, accuracy: 0.5)
        XCTAssertEqual(surface.following.last, false)
    }

    func test_invariantSnapsWhenRowsButNothingVisible() async {
        let (session, surface) = await makeSession()
        let rows = texts(3)
        session.apply(rows, heights: Dictionary(uniqueKeysWithValues: rows.map { ($0.anchorID, 100) }),
                      footerHeight: 0, forceReconfigure: false)
        surface.visible = false
        session.verifyVisibleRows()
        XCTAssertEqual(session.invariantSnapCount, 1)
    }
}
```

  `verifyVisibleRows` on iOS also requires `view.window != nil`. In the session that check becomes part of `hasVisibleRows()`: a surface with no window returns `true`, so it never trips.

- [ ] **Step 2: Run and confirm failure.** Use the Task 1 Step 2 command with `-only-testing:MatronMacTests/TimelineSessionTests`. Expected: `cannot find 'TimelineSession'`.

- [ ] **Step 3: Implement `TimelineSurface.swift` and `TimelineSession.swift`.** Move these members from `ChatTimelineController` verbatim into `TimelineSession`, keeping every comment:
  - Properties: `scrollModel`, `contents`, `lastTailID`, `extendInFlight`, `exhaustedHeadID`, `extendRequestCount`, `suppressEdgeTriggersUntilScroll`, `landedAnchorHoldsTop`, `pendingRestore`, `restoreWidened`, `storedSinceLastMove`, `isSuspended`, `isTornDown`, `invariantSnapCount`, `isApplyingLayout`.
  - Methods: `afterApply`, `handleTailChange`, `jumpToBottom`, `settleAfterScroll` (→ `userScrollSettled`), `handlePendingRestore`, `cancelPendingRestore`, `storeScrollPosition`, `handlePendingFocus`, `evaluateEdgeTriggers`, `requestOlderHistory`, `verifyVisibleRows`, `suspend`, `resume`.

  Apply these substitutions (and nothing else) in the moved code:

  | iOS controller | `TimelineSession` |
  |---|---|
  | `performLayoutUpdate { … scrollModel.x() … }` | `performLayoutUpdate { model in model.x() }` — body mutates `inout` model; after `changes`, `surface.setContentOffset(scrollModel.contentOffsetY)` if it differs by >0.25, then `surface.followingChanged(scrollModel.isFollowingTail)` |
  | `killMomentum()` | `surface.killMomentum()` |
  | `flashRow(target)` | `surface.flashRow(target)` |
  | `hasPendingWork` | `surface.hasPendingWork` |
  | `coalescer.request()` | `surface.requestSync()` |
  | `bridge.setFollowing(x)` | `surface.followingChanged(x)` |
  | `collectionView.indexPathsForVisibleItems.isEmpty` + `view.window != nil` | `!surface.hasVisibleRows()` |
  | `dataSource.apply(snapshot…)` inside `apply` | `surface.applyRows(ids, reconfigure:, reload:)` |
  | `timelineLogger` | a `Logger(subsystem: "chat.matron", category: "timeline")` in `TimelineSession.swift` with the same `breadcrumb`/`diag` helpers — use whatever `timelineLogger` is today; `grep -n "timelineLogger" Matron` and move its declaration into `Shared/ChatTimeline` if it's defined in the iOS target |

  `apply(_:heights:footerHeight:forceReconfigure:)` is the iOS `apply(_:)` loop:
  - `forceReconfigure` replaces `forceSynchronousMeasure`.
  - Heights come from the argument instead of `heights.measurement(...)`; a missing height is a programming error — `assertionFailure` and use 0.
  - `isText` classifies reconfigure vs reload as today.
  - Then `performLayoutUpdate { model in model.windowContainsTail = viewModel.windowContainsTail; model.replaceRows(rows, footerHeight: footerHeight, holdingBottom: pendingRestore != nil); surface.applyRows(...) }`.
  - The rescue breadcrumb and `verifyVisibleRows()` stay as they are.

  `mount()` is the tail of iOS `viewDidLoad` (pendingRestore read, `stopFollowing`, `requestSync`). `tearDown()` is iOS `tearDown()` minus the coalescer and precompute, which stay in the controller.

  Two user-scroll methods need care:
  - `userDragBegan()` is the body of `scrollViewWillBeginDragging`.
  - `userScrolled(toOffset:)` is `scrollViewDidScroll`, guarded by `isApplyingLayout`, plus `noteUserOffset` and `evaluateEdgeTriggers`.

- [ ] **Step 4: Make `ChatTimelineController` a `TimelineSurface`.**
  - It owns `let session: TimelineSession`, created in `init` with `surface: self`, since `bridge.controller = self` stays.
  - It keeps: collection view, data source, factory, measurer, heights, coalescer, precompute, `width`/`style`, footer, context menu and Dynamic Type.
  - `sync()` computes `measurements` exactly as today, then calls `session.apply(built.contents, heights: measurements.mapValues(\.height), footerHeight: currentFooterHeight(), forceReconfigure: forceSynchronousMeasure)`, then `session.afterApply()`.
  - Every former direct use of `scrollModel` reads `session.scrollModel`.
  - `TimelineLayoutSource` reads `session.scrollModel`.
  - The scroll delegate methods call the session's `user*` methods.
  - `viewDidLayoutSubviews` calls `session.setViewportHeight(size.height, widthChanging:)`. In the session this is `performLayoutUpdate { $0.setViewportHeight(height, keepingTop: landedAnchorHoldsTop || widthChanging) }`, then `if pendingRestore != nil { handlePendingRestore() }`.
  - Keep forwarding properties the iOS tests read (`scrollModel`, `appliedRowIDs`, `exhaustedHeadID`, `extendRequestCount`, `invariantSnapCount`, `hasPendingRestore`, `isSuspended`, `flashRow`, `verifyVisibleRows`, `storeScrollPosition`, `suspend`, `resume`, `jumpToBottom`) as one-line forwards, so no iOS test changes.

- [ ] **Step 5: Run both suites.**
  - Mac `TimelineSessionTests`: expect `Executed 3 tests, with 0 failures`.
  - The full iOS `MatronTests` command from Task 1: expect the recorded count and 0 failures. Any iOS failure means the move changed behaviour. Diff the moved method against `git show origin/main:Matron/Features/Chat/Timeline/ChatTimelineController.swift`; do not edit the tests.

- [ ] **Step 6: Commit** with the message `timeline: extract TimelineSession policy core; iOS controller becomes a TimelineSurface`.

---

### Task 3: Mac flag and Settings toggle

**Files:**
- Create: `MatronMac/Features/Chat/Timeline/MacTimelineFlag.swift`.
- Modify: `MatronMac/Features/Settings/MacDeviceSettingsView.swift`.
- Test: `MatronMacTests/MacTimelineFlagTests.swift`.

**Interfaces:** Produces `enum MacTimelineFlag { static let key = "chat.timeline.appkit"; static func defaultValue(isDebugBuild: Bool) -> Bool; static var defaultValue: Bool }`.

- [ ] **Step 1: Test.**

```swift
import XCTest
@testable import MatronMac

final class MacTimelineFlagTests: XCTestCase {
    func test_defaultsOnInDebugOffInRelease() {
        XCTAssertTrue(MacTimelineFlag.defaultValue(isDebugBuild: true))
        XCTAssertFalse(MacTimelineFlag.defaultValue(isDebugBuild: false))
        XCTAssertEqual(MacTimelineFlag.key, "chat.timeline.appkit")
    }
}
```

- [ ] **Step 2: Run it (Task 1 command, `-only-testing:MatronMacTests/MacTimelineFlagTests`).** Expected: compile failure.

- [ ] **Step 3: Implement.**

```swift
import Foundation

/// `chat.timeline.appkit` (spec 2026-09-28 §5): which Mac chat timeline
/// renders. `true` → `MacTimelineController` (NSTableView); `false` → the
/// SwiftUI `ScrollViewReader` timeline, byte-for-byte as before. Read when a
/// chat opens.
enum MacTimelineFlag {
    static let key = "chat.timeline.appkit"

    /// On in Debug builds, off in Release until Dan has used it (spec §5).
    static func defaultValue(isDebugBuild: Bool) -> Bool { isDebugBuild }

    static var defaultValue: Bool {
        #if DEBUG
        return defaultValue(isDebugBuild: true)
        #else
        return defaultValue(isDebugBuild: false)
        #endif
    }
}
```

  In `MacDeviceSettingsView`, add `@AppStorage(MacTimelineFlag.key) private var usesAppKitTimeline = MacTimelineFlag.defaultValue` and a new last `Section("Advanced")`:

```swift
Section("Advanced") {
    Toggle("Faster chat timeline (AppKit)", isOn: $usesAppKitTimeline)
    Text("Takes effect the next time you open a chat.")
        .font(.caption).foregroundStyle(.secondary)
}
```

  Match the view's existing `Section`/`Form` idiom. If it doesn't use `Section(_:)` with a title string, copy whatever the other sections use.

- [ ] **Step 4: Run.** Expected: `Executed 1 test, with 0 failures`.
- [ ] **Step 5: Commit** with the message `mac: chat.timeline.appkit flag + Settings toggle`.

---

### Task 4: Design-system pieces — link router, public message body view, last baseline

**Files:**
- Create: `MatronShared/Sources/DesignSystem/MessageLinkRouter.swift`, `MatronShared/Sources/DesignSystem/MessageBodyView.swift`.
- Modify:
  - `MatronShared/Sources/DesignSystem/SelectableMessageText.swift`: `Coordinator` becomes a `MessageLinkRouter` subclass or holder; `makeNSView`'s configuration moves into `MessageBodyView.configureTextView`.
  - `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift`: add `Rendered.lastBaseline(width:)`.
- Test:
  - Move the existing link-policy tests. Find them with `grep -rln "clickedOnLink" MatronShared/Tests` and point them at `MessageLinkRouter`.
  - New: `MatronShared/Tests/DesignSystemSnapshotTests/MessageBodyViewTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/RenderedBaselineTests.swift`.

**Interfaces:**
- Produces:

```swift
public final class MessageLinkRouter: NSObject, NSTextViewDelegate {
    public var openTrackerItem: ((Int) -> Void)?
    public var openConversation: ((String) -> Void)?
    public var openExternally: (URL) -> Void            // default NSWorkspace.shared.open
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool
}

/// AppKit twin of `SelectableMessageText`: the message body text view plus its
/// code-block copy buttons, for hosts that lay out manually (the table timeline).
public final class MessageBodyView: NSView {
    public init()
    public let router: MessageLinkRouter
    public private(set) var itemID: String?
    /// Sets content; no-op storage write when `rendered` is the instance
    /// already shown (streaming re-emits). Re-applies a live cross-selection.
    public func configure(source: String, rendered: MarkdownAttributed.Rendered,
                          itemID: String?, selectionController: MessageSelectionController?)
    /// Reuse: clears text selection, cancels a code-copy checkmark, drops the id.
    public func prepareForReuse()
    /// For hit tests and menus.
    public var textView: NSTextView { get }
    /// Same text-view configuration SelectableMessageText uses — one source.
    static func configureTextView(_ textView: MessageCopyTextView, router: MessageLinkRouter)
}

extension MarkdownAttributed.Rendered {
    /// Distance from the top of the laid-out text to the LAST line's baseline,
    /// at `width` (memoised per width, like `size(width:)`).
    public func lastBaseline(width: CGFloat) -> CGFloat
}
```

- [ ] **Step 1: Write the failing tests.**

```swift
#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

final class RenderedBaselineTests: XCTestCase {
    func test_lastBaselineIsInsideTheLastLineAndGrowsWithLines() {
        let one = MarkdownAttributed.rendered(for: "Hello", style: .chat)
        let three = MarkdownAttributed.rendered(for: "Hello\n\nSecond\n\nThird", style: .chat)
        let b1 = one.lastBaseline(width: 400), b3 = three.lastBaseline(width: 400)
        XCTAssertGreaterThan(b1, 0)
        XCTAssertLessThanOrEqual(b1, one.size(width: 400).height)
        XCTAssertGreaterThan(b3, b1 * 2)
        XCTAssertEqual(three.lastBaseline(width: 400), b3)   // memo stable
    }
}

@MainActor final class MessageBodyViewTests: XCTestCase {
    func test_codeButtonsSitAtCodeBlockFrames() {
        let source = "Before\n\n```\nmake test\n```\n\nAfter"
        let rendered = MarkdownAttributed.rendered(for: source, style: .chat)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: rendered.size(width: 400).height)
        view.configure(source: source, rendered: rendered, itemID: "m1", selectionController: nil)
        view.layoutSubtreeIfNeeded()
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        let frames = rendered.codeBlockFrames(width: 400)
        XCTAssertEqual(buttons.count, frames.count)
        // Same centre rule as the SwiftUI overlay: x = min(maxX + 12, width - 12), y = minY + 12.
        XCTAssertEqual(buttons[0].frame.midX, min(frames[0].rect.maxX + 12, 400 - 12), accuracy: 0.5)
        XCTAssertEqual(buttons[0].frame.midY, frames[0].rect.minY + 12, accuracy: 0.5)
    }

    func test_reconfigureWithSameRenderedDoesNotRewriteStorage() {
        let rendered = MarkdownAttributed.rendered(for: "Hi", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "Hi", rendered: rendered, itemID: "m1", selectionController: nil)
        let storage = view.textView.textStorage
        view.textView.setSelectedRange(NSRange(location: 0, length: 1))
        view.configure(source: "Hi", rendered: rendered, itemID: "m1", selectionController: nil)
        XCTAssertTrue(view.textView.textStorage === storage)
        XCTAssertEqual(view.textView.selectedRange().length, 1)
    }

    func test_prepareForReuseClearsSelectionAndId() {
        let rendered = MarkdownAttributed.rendered(for: "Hello there", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "Hello there", rendered: rendered, itemID: "m1", selectionController: nil)
        view.textView.setSelectedRange(NSRange(location: 0, length: 5))
        view.prepareForReuse()
        XCTAssertEqual(view.textView.selectedRange().length, 0)
        XCTAssertNil(view.itemID)
    }
}
#endif
```

  `MessageBodyView` must be flipped (`override var isFlipped: Bool { true }`), because the code frames are top-left origin.

- [ ] **Step 2: Run and confirm failure.**

```bash
cd ~/Dev/matron-apple-mactable/MatronShared && swift test --filter 'RenderedBaselineTests|MessageBodyViewTests' 2>&1 | tail -5
```

  Expected: compile errors for the missing members.

- [ ] **Step 3: Implement.**
  - **`lastBaseline(width:)`:**
    - Use the same standalone TextKit 1 stack `codeBlockFrames` builds, at the hugged width `size(width:).width`.
    - Take the glyph range of the last character, then `lineFragmentRect(forGlyphAt:)` for the line's `minY`, plus `layoutManager.typesetter.baselineOffset(in:glyphIndex:)`, or `location(forGlyphAt:).y` (the baseline within its fragment).
    - Memoise in a `[CGFloat: CGFloat]` under `lock`, like `sizes`.
    - An empty string returns 0.
  - **`MessageLinkRouter`:** move `Coordinator.textView(_:clickedOnLink:at:)` and its properties unchanged. `Coordinator` keeps `lastApplied` and subclasses `MessageLinkRouter`, so the existing tests still see a `Coordinator`.
  - **`MessageBodyView`:**
    - It owns one `MessageCopyTextView`, configured by `configureTextView` from `makeNSView`'s body: `isEditable = false`, `isSelectable = true`, `drawsBackground = false`, `textContainerInset = .zero`, `lineFragmentPadding = 0`, `widthTracksTextView = true`, `isVerticallyResizable = true`, `isHorizontallyResizable = false`, `delegate = router`, `isAutomaticLinkDetectionEnabled = false`, `displaysLinkToolTips = true`.
    - `useTextKit1IfTabled` moves here as a static `useTextKit1IfTabled(_:rendered:)`, called from `configure` before the storage write.
    - The `lastApplied` pointer test and the cross-selection `force: true` re-apply are copied from `updateNSView`.
    - Code buttons: an `NSButton` per frame, 20×20 (12 pt glyph + 4 pt padding each side), `bezelStyle = .accessoryBarAction`, image `doc.on.doc`, then `checkmark` + `systemGreen` for 1.2 s after a click (a `DispatchWorkItem` cancelled on re-click and in `prepareForReuse`), `toolTip = "Copy code"`, `setAccessibilityLabel("Copy code")`. The click writes the bare code to `NSPasteboard.general`, as `CodeBlockCopyButton` does.
    - `layout()` places the text view at `bounds`, and each button centred at `(min(frame.rect.maxX + 12, bounds.width - 12), frame.rect.minY + 12)`, using `codeBlockFrames(width: bounds.width)`.
  - **`SelectableTextViewRepresentable`:** `makeNSView` calls `MessageBodyView.configureTextView(textView, router: context.coordinator)`. The SwiftUI overlay stays. The SwiftUI path must render exactly as before; the fingerprint test and `MessageCopyTextView*` tests prove it.

- [ ] **Step 4: Run the design-system suite.**

```bash
cd ~/Dev/matron-apple-mactable/MatronShared && swift test --filter 'DesignSystemSnapshotTests' 2>&1 | grep -E 'Executed|error|failed' | tail -3
```

  Expected: 0 failures, and `MarkdownAttributedFingerprintTests` passing. With `MATRON_SKIP_SNAPSHOT_TESTS=1` set locally, the snapshot-image tests skip; the fingerprint test is not an image test.

- [ ] **Step 5: Commit** with the message `design: MessageLinkRouter + public MessageBodyView + Rendered.lastBaseline for AppKit hosts`.

---

### Task 5: Cross-message selection for virtualised rows

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/MessageSelectionController.swift`.
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MessageSelectionVirtualisedTests.swift`.

**Interfaces:**
- Produces:
  - `public var contentProvider: ((String) -> (attributed: NSAttributedString, source: String)?)?` (`@ObservationIgnored`).
  - `register(_:)` now pushes the active span to the new target.
  - `selectedSpans()` falls back to the provider for ids without a live target.

- [ ] **Step 1: Test.** Use a minimal fake target; the existing selection tests may already define one (`grep -n "CrossSelectionTarget" MatronShared/Tests`), so reuse it if so.

```swift
#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

@MainActor final class MessageSelectionVirtualisedTests: XCTestCase {
    final class Target: CrossSelectionTarget {
        let selectionItemID: String?
        let storageLength: Int
        var frameInWindow: NSRect
        var range: NSRange?
        init(_ id: String, length: Int, y: CGFloat) { selectionItemID = id; storageLength = length; frameInWindow = NSRect(x: 0, y: y, width: 100, height: 20) }
        func characterIndex(atWindowPoint point: NSPoint) -> Int { 2 }
        func setCrossSelection(_ range: NSRange?) { self.range = range }
        func crossSelectionMarkdown() -> String { "live-\(selectionItemID!)" }
    }

    private func controller() -> MessageSelectionController {
        let c = MessageSelectionController()
        c.orderedIDs = ["a", "b", "c", "d"]
        c.contentProvider = { id in (NSAttributedString(string: "text-\(id)"), "src-\(id)") }
        return c
    }

    func test_unmountedMiddleRowsCopyFromProvider() {
        let c = controller()
        let a = Target("a", length: 6, y: 100), d = Target("d", length: 6, y: 0)
        c.register(a); c.register(d)
        XCTAssertTrue(c.beginCrossMessage(anchorID: "a", charIndex: 2))
        c.hitTester = { _, _ in d }
        c.extend(toWindowPoint: .zero, window: nil)
        let spans = c.selectedSpans()
        XCTAssertEqual(spans.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(spans[1].text, "src-b")          // full span of an unmounted row = verbatim source
        XCTAssertEqual(spans[2].text, "src-c")
        XCTAssertEqual(spans[0].text, "live-a")
    }

    func test_registeringMidSelectionReceivesItsSpan() {
        let c = controller()
        let a = Target("a", length: 6, y: 100), d = Target("d", length: 6, y: 0)
        c.register(a); c.register(d)
        c.beginCrossMessage(anchorID: "a", charIndex: 2)
        c.hitTester = { _, _ in d }
        c.extend(toWindowPoint: .zero, window: nil)
        let b = Target("b", length: 9, y: 60)
        c.register(b)                                    // scrolled into view by autoscroll
        XCTAssertEqual(b.range, NSRange(location: 0, length: 9))
    }

    func test_partialSpanOfUnmountedEndReconstructsMarkdown() {
        let c = controller()
        let d = Target("d", length: 6, y: 0)
        c.register(d)
        c.beginCrossMessage(anchorID: "d", charIndex: 0)
        let a = Target("a", length: 6, y: 100)
        c.register(a)
        c.hitTester = { _, _ in a }
        c.extend(toWindowPoint: .zero, window: nil)
        c.unregister(d)                                  // anchor scrolled away
        XCTAssertEqual(c.selectedSpans().last?.text, "src-d")   // anchor at 0, dragging up → full row
    }
}
#endif
```

- [ ] **Step 2: Run** `swift test --filter MessageSelectionVirtualisedTests`. Expected: FAIL (no `contentProvider`).

- [ ] **Step 3: Implement.**
  - Add a private helper `length(of id:) -> Int?`: `target(for:)?.storageLength ?? contentProvider?(id)?.attributed.length`.
  - `applySpans()` uses `length(of:)` in place of `target.storageLength` and keeps a range for every id with a length, in a new `@ObservationIgnored private var spans: [String: NSRange]`. It still pushes only to live targets. `highlighted` stays live-only.
  - `register(_:)`: after storing, `if let range = spans[id] { target.setCrossSelection(range) }`.
  - `clear()` also empties `spans`.
  - `selectedSpans()`: `target(for: id)?.crossSelectionMarkdown()` first; otherwise, with `(attributed, source) = contentProvider?(id)` and `range = spans[id]`:
    - range is the full string: `source`;
    - range length > 0: `MarkdownReconstruction.markdown(from: attributed, in: range)`;
    - otherwise: `nil`.
  - The ordinary SwiftUI path installs no provider and has a target for every row, so its behaviour is unchanged.

- [ ] **Step 4: Run** the new tests and the existing selection tests: `swift test --filter 'MessageSelection|MessageCopyTextView'`. Expected: all pass.
- [ ] **Step 5: Commit** with the message `selection: spans survive virtualised rows (register re-applies, provider fallback)`.

---

### Task 6: `MacTimelineMeasurer` and cache

**Files:**
- Create: `MatronMac/Features/Chat/Timeline/MacTimelineMeasurer.swift`, and `MatronMac/Features/Chat/Timeline/MacTimelineRowContentView.swift` (move `MacTimelineRowView` out of `MacChatView.swift`; `private` becomes internal, otherwise unchanged).
- Test: `MatronMacTests/MacTimelineMeasurerTests.swift`.

**Interfaces:**
- Produces:

```swift
struct MacTextRowRender {                       // everything a text row view draws
    let content: TextRowContent
    let rendered: MarkdownAttributed.Rendered
    let layout: TextRowLayout                    // row coordinates; segmentFrames[0] = body frame in the bubble
    let timestampText: String                    // `Date.FormatStyle.dateTime.hour().minute()` as SwiftUI renders it
}
enum MacRowMeasurement { case text(MacTextRowRender); case hosted(CGFloat)
    var height: CGFloat }
final class MacTimelineMeasureCache {            // NSCache keyed (roomID,rowID,width); hit iff content ==
    static let shared: MacTimelineMeasureCache
    func measurement(roomID: String, content: TimelineRowContent, width: CGFloat) -> MacRowMeasurement?
    func store(_ m: MacRowMeasurement, roomID: String, content: TimelineRowContent, width: CGFloat)
}
@MainActor final class MacTimelineMeasurer {
    init(hostedRow: @escaping (HostedRowContent) -> AnyView)
    /// Off-main safe (pure + Rendered's locks).
    nonisolated static func measureText(_ content: TextRowContent, width: CGFloat,
                                        pillsHeight: CGFloat?, sendStateHeight: CGFloat?) -> MacTextRowRender
    func measure(_ content: TimelineRowContent, width: CGFloat) -> MacRowMeasurement
    func pillsHeight(_ refs: [ConversationLinkRef], isOwn: Bool, hasAvatar: Bool, width: CGFloat) -> CGFloat
    func sendStateHeight(width: CGFloat) -> CGFloat
    func hostedHeight(_ content: HostedRowContent, width: CGFloat) -> CGFloat
}
```

- [ ] **Step 1: Test the height parity between the text measurement and the SwiftUI row.**

```swift
import XCTest
import SwiftUI
import MatronChat
import MatronModels
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineMeasurerTests: XCTestCase {
    static let corpus = [
        "Hi", "A longer message that will certainly wrap onto a second line at the narrow width we test with here.",
        "# Heading\n\nBody.\n\n- one\n- two", "Before\n\n```swift\nlet x = 1\n```\n\nAfter",
        "| A | B |\n|---|---|\n| 1 | 2 |", "Links: [#65](matron://item/65) and [room](matron://convo/abc-123).",
    ]

    private func item(_ body: String, own: Bool) -> TimelineItem {
        TimelineItem(id: "m-\(body.hashValue)", sender: own ? "@me:s" : "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                     kind: .text(body: body, formattedHTML: nil), isOwn: own, sendState: .sent)
    }

    /// The SwiftUI row's height at `width` — what the table row must equal.
    private func swiftUIHeight(_ item: TimelineItem, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: MacTimelineItemView(item: item).frame(width: width))
        return host.fittingSize.height
    }

    func test_textRowHeightMatchesSwiftUIRow() {
        for width in [420.0, 700.0, 1100.0] as [CGFloat] {
            for body in Self.corpus {
                for own in [false, true] {
                    let it = item(body, own: own)
                    let content = TextRowContent(itemID: it.id, body: body, isOwn: own, sendState: .sent,
                                                 timestamp: it.timestamp, avatarSender: nil,
                                                 senderLabel: own ? "Me" : "bot",
                                                 pills: ConversationLinkRefs.extract(from: body, cache: true))
                    let measurer = MacTimelineMeasurer(hostedRow: { _ in AnyView(EmptyView()) })
                    let m = measurer.measure(.text(content), width: width)
                    XCTAssertEqual(m.height, swiftUIHeight(it, width: width), accuracy: 1,
                                   "width \(width) own \(own) body \(body.prefix(20))")
                }
            }
        }
    }

    func test_cacheHitsOnlyForEqualContent() {
        let cache = MacTimelineMeasureCache(countLimit: 10)
        let a = TimelineRowContent.hosted(HostedRowContent(row: .separator(Date(timeIntervalSince1970: 0)),
                                                           subtaskChild: nil, hasMultipleSenders: false, imagePixelSize: nil))
        cache.store(.hosted(30), roomID: "r", content: a, width: 500)
        XCTAssertEqual(cache.measurement(roomID: "r", content: a, width: 500)?.height, 30)
        XCTAssertNil(cache.measurement(roomID: "r", content: a, width: 501))
    }
}
```

  If `MacTimelineItemView`'s memberwise init needs more arguments, pass the defaults; the struct's closure properties are all optional with defaults.

- [ ] **Step 2: Run** (Task 1 command, `-only-testing:MatronMacTests/MacTimelineMeasurerTests`). Expected: compile failure.

- [ ] **Step 3: Implement.**
  - **`measureText`:**
    - `rendered = MarkdownAttributed.rendered(for: body, style: .chat, cache: !content.isStreaming)`.
    - `timestamp`: measure `timestampText` with `NSFont.preferredFont(forTextStyle: .caption2)` via `NSAttributedString.size()`, with `ascent = font.ascender`.
    - Content measure closure `{ wrap in let s = rendered.size(width: wrap); return .init(size: s, lastBaseline: rendered.lastBaseline(width: wrap), segmentFrames: [CGRect(origin: .zero, size: s)]) }`.
    - Then `TextBubbleGeometry.layout(rowWidth: width, isOwn:, hasAvatar: content.avatarSender != nil, timestamp:, content:, pillsHeight: content.pills.isEmpty ? nil : { _ in pillsHeight! }, sendStateHeight: content.isOwn && content.sendState != .sent ? sendStateHeight : nil)`.
  - **`measure`:** a text case needing pills or a send-state height gets them from the main-thread hosted sizers:
    - `ConversationLinkPillRow(refs:style:hasAvatar:)` in an `NSHostingView` with `.frame(width:)`, taking `fittingSize.height`.
    - `SendStateIndicator` likewise, memoised per state.
  - **`hostedHeight`:** one reusable `NSHostingView<AnyView>`. Set `rootView = hostedRow(content)`, wrapped in `.frame(width: width)`, and read `fittingSize.height`.
  - **Separators and hosted rows:** `hostedRow` builds `MacTimelineRowView(row:subtaskChild:viewModel:…)` in the controller (Task 9). The measurer takes the closure so tests can inject.
  - **If the parity test fails for a case:** fix the geometry inputs (timestamp font, bubble padding, avatar), never the test tolerance. `TextBubbleGeometry` mirrors `MessageBubble`; the likely suspect is the `lastBaseline` definition, which must match SwiftUI's `.lastTextBaseline` for an `NSViewRepresentable` hosting an `NSTextView`. If SwiftUI treats the representable's last baseline as its bottom (no baseline reported), use `lastBaseline = size.height` and note it in a comment with the measured evidence.

- [ ] **Step 4: Run.** Expected: `Executed 2 tests, with 0 failures`.
- [ ] **Step 5: Commit** with the message `mac: timeline measurer — text rows via shared bubble geometry, parity with the SwiftUI row`.

---

### Task 7: `MacTextRowView` and `MacHostedRowView`

**Files:**
- Create: `MatronMac/Features/Chat/Timeline/MacTextRowView.swift`, `MatronMac/Features/Chat/Timeline/MacHostedRowView.swift`.
- Test: `MatronMacTests/MacTimelineRowViewTests.swift`.

**Interfaces:**
- Consumes: `MacTextRowRender`, `MessageBodyView`, `TextRowLayout`.
- Produces:

```swift
final class MacTextRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.text")
    static let tabledIdentifier = NSUserInterfaceItemIdentifier("timeline.text.tk1")
    let body: MessageBodyView
    func configure(render: MacTextRowRender, selectionController: MessageSelectionController?,
                   linkRouting: MacTimelineLinkRouting, onRetry: @escaping (String) -> Void,
                   pills: () -> AnyView?, sendState: () -> AnyView?)
    func flash()                                   // jump landing highlight, removed on reuse
}
struct MacTimelineLinkRouting { var openTrackerItem: ((Int) -> Void)?; var openConversation: ((String) -> Void)? }
final class MacHostedRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.hosted")
    var onHeightChange: ((String, CGFloat) -> Void)?
    func configure(rowID: String, expectedHeight: CGFloat, content: AnyView)
    func flash()
}
```

- [ ] **Step 1: Tests.** They cover frame layout, reuse hygiene (Review Focus 4) and the TextKit version (Review Focus 5).

```swift
import XCTest
import SwiftUI
import MatronChat
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineRowViewTests: XCTestCase {
    private func render(_ body: String, own: Bool = false, width: CGFloat = 700) -> MacTextRowRender {
        let content = TextRowContent(itemID: "m-\(body.hashValue)", body: body, isOwn: own, sendState: .sent,
                                     timestamp: Date(timeIntervalSince1970: 1_700_000_000), avatarSender: nil,
                                     senderLabel: "bot", pills: [])
        return MacTimelineMeasurer.measureText(content, width: width, pillsHeight: nil, sendStateHeight: nil)
    }

    private func row(_ r: MacTextRowRender, width: CGFloat = 700) -> MacTextRowView {
        let v = MacTextRowView(frame: NSRect(x: 0, y: 0, width: width, height: r.layout.rowHeight))
        v.configure(render: r, selectionController: nil, linkRouting: .init(), onRetry: { _ in },
                    pills: { nil }, sendState: { nil })
        v.layoutSubtreeIfNeeded()
        return v
    }

    func test_bubbleAndBodyFramesComeFromTheLayout() {
        let r = render("Hello there")
        let v = row(r)
        XCTAssertEqual(v.bubbleFrameForTesting, r.layout.bubbleFrame)
        XCTAssertEqual(v.body.frame, r.layout.segmentFrames[0].offsetBy(dx: r.layout.bubbleFrame.minX, dy: r.layout.bubbleFrame.minY))
    }

    func test_reuseDropsSelectionFlashAndCheckmark() {
        let v = row(render("First message with some words"))
        v.body.textView.setSelectedRange(NSRange(location: 0, length: 5))
        v.flash()
        v.prepareForReuse()
        v.configure(render: render("Second"), selectionController: nil, linkRouting: .init(), onRetry: { _ in },
                    pills: { nil }, sendState: { nil })
        XCTAssertEqual(v.body.textView.selectedRange().length, 0)
        XCTAssertFalse(v.hasFlashForTesting)
        XCTAssertEqual(v.body.textView.string, "Second")
    }

    func test_tabledMessagesUseTextKit1AndPlainUseTextKit2() {
        let plain = row(render("Plain"))
        XCTAssertNotNil(plain.body.textView.textLayoutManager)
        let tabled = row(render("| A |\n|---|\n| 1 |"))
        XCTAssertNil(tabled.body.textView.textLayoutManager)   // TK1 after the opt-out
    }
}
```

  The `…ForTesting` accessors are internal read-only properties on the views.

- [ ] **Step 2: Run** (`-only-testing:MatronMacTests/MacTimelineRowViewTests`). Expected: compile failure.

- [ ] **Step 3: Implement `MacTextRowView`.**
  - The view is flipped. In `init(frame:)`, add these subviews:
    - the `bubble` `NSView`: `wantsLayer`, `layer.cornerRadius = 8`, background `NSColor(Color.matronBubbleMe/Bot)`, shadow from `Color.matronBubbleShadow` (radius 1, offset (0, -1) in the flipped layer, opacity 1);
    - the `body` `MessageBodyView`, as a subview of `bubble`;
    - `timeLabel`, an `NSTextField(labelWithString:)` with the `caption2` font and `secondaryLabelColor`;
    - optional hosted `pillsHost`, `sendStateHost` and `avatarHost`, all `NSHostingView<AnyView>`.
  - `configure` stores the render, calls `body.configure(source: render.content.body, rendered: render.rendered, itemID: render.content.itemID, selectionController:)`, and sets `body.router.openTrackerItem/openConversation` from `linkRouting`.
  - `layout()` applies `render.layout`:
    - `bubble.frame = layout.bubbleFrame`;
    - `body.frame = layout.segmentFrames[0]` (bubble coordinates);
    - `timeLabel.frame = layout.timestampFrame`;
    - avatar, pills and send state at their frames (row coordinates).
  - Set `setAccessibilityLabel("\(senderLabel): \(body)")` and `setAccessibilityElement(true)` on the row, matching `MacTimelineItemView.accessibilityLabel`.
  - `menu(for:)` returns an `NSMenu` for clicks outside `body` (text-view clicks never reach the row):
    - `"Copy"`, copying `render.content.body` via `Pasteboard.copy`;
    - when `selectionController?.hasSelection == true` and there is a `finishedTranscript`, a leading `"Copy N Messages"` item with `representedObject = transcript.text`, sent to `body.textView` via `copyCrossSelection(_:)`. This mirrors `MessageCopyTextView.menu(for:)`.
  - `flash()` adds a subview tagged `0x6A_46_4C` with `controlAccentColor.withAlphaComponent(0.15)` and fades it over 0.6 s after 0.4 s using `NSAnimationContext`.
  - `prepareForReuse()` removes the flash, calls `body.prepareForReuse()`, and nils the hosted views' `rootView`s.
  - The controller chooses the reuse identifier: `tabledIdentifier` when `render.rendered.containsTable`, else `identifier`.

- [ ] **Step 4: Implement `MacHostedRowView`.** It is an `NSTableCellView` containing one `NSHostingView<AnyView>` pinned to its bounds, with `sizingOptions = [.intrinsicContentSize]`.
  - `configure` sets `rootView`.
  - Override `layout()`. After `super`, if `abs(host.fittingSize.height - expectedHeight) > 0.5`, call `onHeightChange?(rowID, host.fittingSize.height)` on the next main-queue turn, never inside layout (Global Constraints: no table mutations inside callbacks). Then update `expectedHeight` so it reports once per change.
  - `flash()` and `prepareForReuse()` work as in the text row.

- [ ] **Step 5: Run.** Expected: `Executed 3 tests, with 0 failures`.
- [ ] **Step 6: Commit** with the message `mac: native text row + hosted row views for the table timeline`.

---

### Task 8: `MacTimelineScrollView` — user-scroll detection

**Files:**
- Create: `MatronMac/Features/Chat/Timeline/MacTimelineScrollView.swift`.
- Test: `MatronMacTests/MacTimelineScrollViewTests.swift`.

**Interfaces:**
- Produces:

```swift
final class MacTimelineScrollView: NSScrollView {
    var onUserScrollBegan: (() -> Void)?
    var onUserScrollEnded: (() -> Void)?
    var onUserScrolled: ((CGFloat) -> Void)?       // clip origin.y after a user-driven move
    /// Set by the controller around its own origin writes.
    var isApplyingProgrammaticScroll = false
}
```

- [ ] **Step 1: Test.** Phased trackpad events call began/ended; a phase-less mouse wheel calls both; programmatic writes report nothing.

```swift
import XCTest
@testable import MatronMac

@MainActor final class MacTimelineScrollViewTests: XCTestCase {
    private func wheel(_ delta: Int32, phase: CGScrollPhase?) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        if let phase {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        return NSEvent(cgEvent: cg)!
    }

    private func makeView() -> MacTimelineScrollView {
        let sv = MacTimelineScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let doc = FlippedDocView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        sv.documentView = doc
        return sv
    }
    final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

    func test_phasedTrackpadScrollReportsBeganAndEnded() {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(0, phase: .began))
        sv.scrollWheel(with: wheel(-20, phase: .changed))
        sv.scrollWheel(with: wheel(0, phase: .ended))
        XCTAssertEqual(log.first, "began")
        XCTAssertEqual(log.last, "ended")
    }

    func test_mouseWheelTickIsBeganThenEnded() {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(-3, phase: nil))
        XCTAssertEqual(log, ["began", "ended"])
    }

    func test_programmaticScrollIsNotReportedAsUser() {
        let sv = makeView()
        var moves = 0
        sv.onUserScrolled = { _ in moves += 1 }
        sv.isApplyingProgrammaticScroll = true
        sv.contentView.scroll(to: NSPoint(x: 0, y: 500))
        sv.reflectScrolledClipView(sv.contentView)
        sv.isApplyingProgrammaticScroll = false
        XCTAssertEqual(moves, 0)
    }
}
```

- [ ] **Step 2: Run** (`-only-testing:MatronMacTests/MacTimelineScrollViewTests`). Expected: compile failure.

- [ ] **Step 3: Implement.**
  - Override `scrollWheel(with:)`:
    - `event.phase == .began` (or `.mayBegin` followed by changed): `onUserScrollBegan`.
    - `event.phase` is empty and `event.momentumPhase` is empty (a mouse wheel): `onUserScrollBegan` before `super`, then `onUserScrollEnded` after.
    - `event.momentumPhase == .ended`, or (`event.phase == .ended` with no momentum to follow — `event.momentumPhase == []` on the next event is not knowable, so treat `phase == .ended` as "ended", and `momentumPhase == .ended` as ended again): `onUserScrollEnded`.
    - Always call `super.scrollWheel(with:)`.
  - In `init`, observe `NSView.boundsDidChangeNotification` on `contentView` (`contentView.postsBoundsChangedNotifications = true`). When `!isApplyingProgrammaticScroll`, call `onUserScrolled?(contentView.bounds.origin.y)`.
  - Also observe `willStartLiveScrollNotification` → began and `didEndLiveScrollNotification` → ended, for scroller-knob drags. The session's `beginUserDrag`/`endUserScroll` are idempotent, so duplicate reports are harmless.

- [ ] **Step 4: Run.** Expected: `Executed 3 tests, with 0 failures`.
- [ ] **Step 5: Commit** with the message `mac: timeline scroll view reports user scrolls (trackpad, wheel, scroller)`.

---

### Task 9: `MacTimelineController` — the table surface

**Files:**
- Create: `MatronMac/Features/Chat/Timeline/MacTimelineController.swift`.
- Test: `MatronMacTests/MacTimelineControllerTests.swift`, plus a harness `MatronMacTests/MacTimelineHarness.swift`.

**Interfaces:**
- Consumes: `TimelineSession`, `TimelineSurface`, `TimelineRowContentBuilder`, `MacTimelineMeasurer`, `MacTimelineMeasureCache`, `MacTextRowView`, `MacHostedRowView`, `MacTimelineScrollView`, `MacTimelineRowView`.
- Produces:

```swift
struct MacTimelineActions {                    // what hosted rows and text rows call out to
    var onOpenSubChat: (String) -> Void
    var onOpenSpawnRoom: ((String) -> Void)?
    var onOpenItem: ((String) -> Void)?
    var onOpenMission: ((String) -> Void)?
    var onPreviewImage: (URL, Image) -> Void
    var linkRouting: MacTimelineLinkRouting
    static let inert: MacTimelineActions
}
@MainActor final class MacTimelineController: NSViewController, TimelineSurface, NSTableViewDataSource, NSTableViewDelegate {
    init(viewModel: ChatViewModel, stripViewModel: SubChatStripViewModel, bridge: MacTimelineBridge,
         selection: MessageSelectionController, actions: MacTimelineActions,
         cache: MacTimelineMeasureCache = .shared)
    let session: TimelineSession
    private(set) var tableView: NSTableView!
    private(set) var scrollView: MacTimelineScrollView!
    func update(actions: MacTimelineActions)
    func sync()                                   // coalesced entry; tests call directly
    func tearDown()
    var hasPendingWork: Bool { get }
}
@MainActor @Observable final class MacTimelineBridge {   // Task 11 file; declare here if needed first
    private(set) var isFollowingTail = true
    weak var controller: MacTimelineController?
    func setFollowing(_ following: Bool)
    func jumpToBottom()
    func storeScrollPosition()
}
```

- [ ] **Step 1: Write the harness and tests.** Real `ChatViewModel` over `LiveTimelineFixture`, in a real `NSWindow`:

```swift
import XCTest
import AppKit
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineHarness {
    let service = LiveTimelineFixture()
    let viewModel: ChatViewModel
    let strip: SubChatStripViewModel
    let bridge = MacTimelineBridge()
    let selection = MessageSelectionController()
    let controller: MacTimelineController
    let window: NSWindow

    init(size: CGSize = CGSize(width: 800, height: 600)) {
        let roomID = "!mac-timeline-\(UUID().uuidString):test"
        viewModel = TimelineFixtures.viewModel(service, roomID: roomID)
        strip = SubChatStripViewModel(chat: NoChildrenChatFixture(), parentConvoID: roomID)
        controller = MacTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: bridge,
                                           selection: selection, actions: .inert, cache: MacTimelineMeasureCache(countLimit: 4000))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderFront(nil)
    }

    /// First snapshot: `start()` returns after it (same as iOS `TimelineHarness.start(with:)`).
    func start(with items: [TimelineItem]) async throws {
        service.emit(items)
        _ = await viewModel.start()
        try await settle()
    }

    /// Later snapshots commit coalesced (≤ 250 ms).
    func emit(_ items: [TimelineItem]) async throws {
        service.emit(items)
        try await waitUntil { self.viewModel.items == items }
        try await settle()
    }

    /// Until the table shows exactly the view model's current window.
    func settle(timeout: TimeInterval = 3) async throws {
        try await waitUntil(timeout: timeout) {
            var seen = Set<String>()
            let expected = self.viewModel.windowedRows.map(TimelineRowContentBuilder.anchorID(for:))
                .filter { seen.insert($0).inserted }
            return self.controller.session.scrollModel.rows.map(\.id) == expected && !self.controller.hasPendingWork
        }
        controller.view.layoutSubtreeIfNeeded()
    }

    /// Ids are numeric strings (journal seqs) starting at 1, like `TimelineFixtures`, so `focus(seq:)` resolves them.
    func texts(_ n: Int, body: (Int) -> String = { "Message \($0) with a few words in it" }) -> [TimelineItem] {
        (1...n).map { TimelineItem(id: "\($0)", sender: "@bot:s",
                                   timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)),
                                   kind: .text(body: body($0), formattedHTML: nil), isOwn: false, sendState: .sent) }
    }

    var clipY: CGFloat { controller.scrollView.contentView.bounds.origin.y }
    var maxY: CGFloat { controller.session.scrollModel.maxOffsetY }
}

@MainActor final class MacTimelineControllerTests: XCTestCase {
    func test_tableRowRectsEqualTheModelAndOnlyVisibleRowsHaveViews() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(200))
        let model = h.controller.session.scrollModel
        for i in 0..<model.rows.count {
            // +1: table row 0 is the top spacer (see Step 3 geometry mapping).
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        var mounted = 0
        h.controller.tableView.enumerateAvailableRowViews { _, _ in mounted += 1 }
        XCTAssertLessThan(mounted, 40)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)          // opened at the bottom, following
    }

    func test_streamingGrowthPinnedWhileFollowingAndStillWhileReading() async throws {
        let h = MacTimelineHarness()
        var items = h.texts(100)
        try await h.start(with: items)
        // Following: the eph row grows, the viewport stays at the bottom.
        for n in stride(from: 50, through: 2000, by: 150) {
            let eph = JournalTimelineMapper.streamingItem(messageRef: "r", text: String(repeating: "word ", count: n / 5), convoTS: Date())
            try await h.emit(items + [eph])
            XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
        }
        // Reading: the user scrolls up; further growth must not move the rows on screen.
        h.controller.session.userDragBegan()
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: h.clipY - 1500))
        h.controller.session.userScrolled(toOffset: h.controller.scrollView.contentView.bounds.origin.y)
        let anchor = h.controller.session.scrollModel.topAnchor()
        let eph = JournalTimelineMapper.streamingItem(messageRef: "r", text: String(repeating: "word ", count: 900), convoTS: Date())
        items.append(eph)
        try await h.emit(items)
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor(), anchor)
    }

    func test_streamDeltaReconfiguresOneRowOnly() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(50)
        try await h.start(with: items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a", convoTS: Date())])
        h.controller.resetCountersForTesting()
        try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a b c", convoTS: Date())])
        XCTAssertEqual(h.controller.reconfiguredRowCountForTesting, 1)
        XCTAssertEqual(h.controller.reloadDataCountForTesting, 0)
    }

    func test_ownSendReturnsToBottom() async throws {
        let h = MacTimelineHarness()
        var items = h.texts(100)
        try await h.start(with: items)
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 0)
        items.append(TimelineItem(id: "own1", sender: "@me:s", timestamp: Date(), kind: .text(body: "mine", formattedHTML: nil),
                                  isOwn: true, sendState: .sent))
        try await h.emit(items)
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
    }
}
```

  `waitUntil` is the helper the iOS timeline tests use; move it into `Shared/ChatTimelineTestSupport/` in Task 1 if it lives in an iOS-only file (`grep -rn "func waitUntil" MatronTests`). Every test below that awaits `start`/`emit` is `async throws`; the first push in each test is `start(with:)`, later ones `emit`.

- [ ] **Step 2: Run** (`-only-testing:MatronMacTests/MacTimelineControllerTests`). Expected: compile failure.

- [ ] **Step 3: Implement.**
  - **`loadView`:**
    - `scrollView = MacTimelineScrollView()` with `hasVerticalScroller = true`, `drawsBackground = false`, `automaticallyAdjustsContentInsets = false`, `contentInsets = .init()`.
    - `tableView = NSTableView()` with one `NSTableColumn`, `headerView = nil`, `intercellSpacing = .zero`, `backgroundColor = .clear`, `selectionHighlightStyle = .none`, `usesAutomaticRowHeights = false`, `style = .plain`, `gridStyleMask = []`, `focusRingType = .none`, `setAccessibilityIdentifier("chat.timeline")`. The column auto-resizes to the table (`columnAutoresizingStyle = .uniformColumnAutoresizingStyle`). `scrollView.documentView = tableView`.
    - Wire `scrollView.onUserScrollBegan/Ended/Scrolled` to `session.userDragBegan()`/`userScrollSettled()`/`userScrolled(toOffset:)`. In `userDragBegan`, also cancel nothing selection-related: a drag-select autoscroll is not a user scroll, because `autoscroll(with:)` moves the clip programmatically, with no wheel events.
  - **Geometry mapping** (the table's rects must equal the model's):
    - Rows carry their spacing: build `rows` for the session with `height + metrics.rowSpacing` for all but the last row, and `TimelineScrollModel(metrics: .init(topInset: 16, bottomInset: 16, rowSpacing: 0, nearBottomThreshold: 100, nearTopScreens: 1.5))`. Row views draw content at the top of their row.
    - Table row 0 is a spacer of height `alignmentPad + topInset`, and the last table row is the footer (activity indicator) of height `bottomInset + footerHeight`. So table index = model index + 1, and every conversion goes through the helpers `tableRow(forModelIndex:)` and `modelIndex(forTableRow:)`.
    - Adjust the parity test in Step 1 accordingly: compare `rect(ofRow: i + 1).minY` with `rowMinY(at: i)`.
  - **`heightOfRow`:**
    - spacer: `session.scrollModel.alignmentPad + 16`;
    - footer: `16 + footerHeight`;
    - rows: `session.scrollModel.rows[i].height`.
  - **`viewFor`:** by content kind. Text uses `makeView(withIdentifier: containsTable ? tabledIdentifier : identifier)`, or a new one with that identifier, then `configure(render: measurements[id] as .text, selectionController: selection, linkRouting: actions.linkRouting, onRetry: { viewModel.retrySend(itemID: $0) }, pills: …, sendState: …)`. Hosted uses `configure(rowID:expectedHeight:content: hostedRow(content))`, with `onHeightChange` → `hostedHeightChanged`.
  - **`hostedRow(_:)`** builds `AnyView(MacTimelineRowView(row: content.row, subtaskChild: content.subtaskChild, viewModel: viewModel, onOpenSubChat: actions.onOpenSubChat, onOpenSpawnRoom: actions.onOpenSpawnRoom, onOpenItem: actions.onOpenItem, onOpenMission: actions.onOpenMission, onPreviewImage: actions.onPreviewImage))`, plus the environment the SwiftUI path has: `.environment(selection)`, `.environment(\.openTrackerItem, …)`, `.environment(\.openConversation, …)` from `actions.linkRouting`. Pass the same closure to `MacTimelineMeasurer(hostedRow:)`, so render equals measure.
  - **`sync()`** is iOS `sync()`:
    - build contents;
    - measure: cache hit → use; text misses ≤ 8 → `measureText` on main; more → a background `Task.detached` over `MacTimelineMeasurer.measureText` for each, storing into the cache, then `requestSync()`; hosted rows always on main;
    - `session.apply(contents, heights: …, footerHeight: …, forceReconfigure:)`;
    - `session.afterApply()`.
    - Observation re-arms at the top via `withObservationTracking`, reading the same properties as iOS `observeViewModel()`.
  - **`TimelineSurface`:**
    - `applyRows`: diff against the previously applied id list. Pure appends or prepends use `insertRows(at:withAnimation: [])`; removals use `removeRows`; anything else (reorder, more than half changed) uses `reloadData()`. For `reconfigure` ids, reconfigure the visible view in place if there is one (`view(atColumn:row:makeIfNecessary: false)`). Then call `noteHeightOfRows(withIndexesChanged:)` for the reconfigured indexes and the spacer. Count reconfigures and reloads for the test counters.
    - `setContentOffset(y)`: `scrollView.isApplyingProgrammaticScroll = true`, `contentView.scroll(to: NSPoint(x: 0, y: y))`, `reflectScrolledClipView`, `= false`.
    - `killMomentum()`: `scrollView.contentView.scroll(to: contentView.bounds.origin)`. A zero-delta write ends momentum on macOS 13+, as in `NativeScrollViewBox`.
    - `hasVisibleRows()`: `view.window == nil || tableView.rows(in: scrollView.contentView.bounds).length > 2` (spacer and footer excluded).
    - `flashRow(id)`: the visible view's `flash()`.
    - `followingChanged`: `bridge.setFollowing`.
    - `requestSync`: the coalescer, `view.displayLink(target:selector:)`, paused when idle — the same shape as iOS `FrameCoalescer`.
  - **Resize:** in `viewDidLayout`, a height change calls `session.setViewportHeight(h, widthChanging:)`. A width change sets `width`, re-measures synchronously for visible rows and in the background for the rest, then `resyncSynchronously()`. During live resize (`view.inLiveResize`), coalesce to one sync per frame. `viewDidEndLiveResize` forces a full synchronous resync.
  - **Selection wiring:** `selection.orderedIDs` is set from `viewModel.windowedRows` on every sync (message ids only, as `MacTimelineListContent` does). `selection.contentProvider = { [weak self] id in … }` returns the text row's `(rendered.attributed, body)` from `contents`, or nil.
  - **Lifecycle:** `viewDidAppear` → `session.resume()`; `viewDidDisappear` → `session.suspend()`; `tearDown()` → `session.tearDown()`, invalidate the coalescer, cancel the precompute. `init` calls `session.mount()`.

- [ ] **Step 4: Run.** Expected: `Executed 4 tests, with 0 failures`.
- [ ] **Step 5: Commit** with the message `mac: MacTimelineController — virtualised NSTableView surface over TimelineSession`.

---

### Task 10: Edges, jumps, restore, resize and selection integration

**Files:**
- Test: `MatronMacTests/MacTimelineBehaviourTests.swift`. Fix-ups go in `MacTimelineController.swift`.

- [ ] **Step 1: Tests.** One per behaviour, using `MacTimelineHarness`:

```swift
@MainActor final class MacTimelineBehaviourTests: XCTestCase {
    func test_nearTopExtendsHistoryAndKeepsTheReaderInPlace() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(300))            // VM window = entry size; more rows exist above
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 10)
        let anchor = h.controller.session.scrollModel.topAnchor()
        for _ in 0..<50 where h.viewModel.windowedRows.count <= 121 { try? await Task.sleep(nanoseconds: 20_000_000) }
        h.controller.sync()
        XCTAssertGreaterThan(h.viewModel.windowedRows.count, 121)
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor(), anchor)
    }

    func test_pendingFocusLandsRowAtTopAndFlashes() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        let target = "40"
        await h.viewModel.focus(seq: 40)       // harness ids are seqs
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        try await h.settle()
        let i = h.controller.session.scrollModel.index(of: target)!
        XCTAssertEqual(h.clipY, h.controller.session.scrollModel.rowMinY(at: i), accuracy: 0.5)
    }

    func test_restoreLandsTheStoredTopAnchor() async throws {
        var h: MacTimelineHarness? = MacTimelineHarness()
        try await h!.start(with: h!.texts(100))
        h!.controller.session.userDragBegan()
        h!.controller.session.userScrolled(toOffset: 2000)
        let anchor = h!.controller.session.scrollModel.topAnchor()!
        h!.controller.tearDown()
        let room = h!.viewModel.roomID
        h = nil
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: room)?.itemID, anchor.rowID)
    }

    func test_widthChangeKeepsTheTopMessage() async throws {
        let h = MacTimelineHarness(size: CGSize(width: 1100, height: 600))
        try await h.start(with: h.texts(100, body: { "Message \($0) " + String(repeating: "long words ", count: 30) }))
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 3000)
        let top = h.controller.session.scrollModel.topAnchor()?.rowID
        h.window.setContentSize(CGSize(width: 480, height: 600))
        h.controller.view.layoutSubtreeIfNeeded()
        h.controller.sync()
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor()?.rowID, top)
        // Heights were re-measured at the new width.
        let i = h.controller.session.scrollModel.index(of: top!)!
        XCTAssertGreaterThan(h.controller.session.scrollModel.rows[i].height, 100)
    }

    func test_crossSelectionAcrossNeverMountedRowsCopiesAll() async throws {
        let h = MacTimelineHarness(size: CGSize(width: 800, height: 400))
        try await h.start(with: h.texts(60))
        h.selection.orderedIDs = h.viewModel.windowedRows.compactMap { if case .message(let it) = $0 { return it.id } else { return nil } }
        XCTAssertTrue(h.selection.beginCrossMessage(anchorID: "5", charIndex: 0))
        // Head on a mounted row near the bottom; rows 6…50 were never mounted.
        let headID = "55"
        let i = h.controller.session.scrollModel.index(of: headID)!
        let view = h.controller.tableView.view(atColumn: 0, row: i + 1, makeIfNecessary: false) as! MacTextRowView
        h.selection.hitTester = { _, _ in view.body.textView as? CrossSelectionTarget }
        h.selection.extend(toWindowPoint: .zero, window: h.window)
        h.selection.finish()
        XCTAssertEqual(h.selection.finishedTranscript?.messageCount, 51)
    }
}
```

  The harness's `texts` ids are numeric strings (journal seqs), so `focus(seq: 40)` resolves `"40"` exactly as `TimelineJumpTests` does with `TimelineFixtures`. No new view-model API.

  For `finishedTranscript`, call `MacChatView.installTranscriptProvider(on: h.selection, viewModel: h.viewModel)` in the harness init.

- [ ] **Step 2: Run** (`-only-testing:MatronMacTests/MacTimelineBehaviourTests`). Fix the controller until all 5 pass. The rules live in the shared session, so failures here are nearly always the surface's index mapping (spacer offset), a missing `viewDidLayout` → `setViewportHeight`, or `userScrolled` firing during programmatic writes.
- [ ] **Step 3: Commit** with the message `mac: table timeline — history edges, jumps, restore, resize, cross-row selection`.

---

### Task 11: Wire into `MacChatView` behind the flag

**Files:**
- Create: `MatronMac/Features/Chat/Timeline/MacTimelineView.swift` (representable + `MacTimelineBridge`, if not already created in Task 9).
- Modify: `MatronMac/Features/Chat/MacChatView.swift` (`chatColumn`), `MatronMac/App/MacTimelinePerfProbe.swift` (registration from the controller).
- Test: `MatronMacTests/MacChatViewTimelineFlagTests.swift`.

- [ ] **Step 1: Test.** The flag chooses the path, and flag-off leaves the SwiftUI tree in place:

```swift
@MainActor final class MacChatViewTimelineFlagTests: XCTestCase {
    func test_flagSelectsTimeline() {
        XCTAssertTrue(MacChatView.usesAppKitTimeline(defaults: Self.defaults(true)))
        XCTAssertFalse(MacChatView.usesAppKitTimeline(defaults: Self.defaults(false)))
    }
    private static func defaults(_ on: Bool) -> UserDefaults {
        let d = UserDefaults(suiteName: "mac-timeline-flag-\(UUID().uuidString)")!
        d.set(on, forKey: MacTimelineFlag.key)
        return d
    }
}
```

- [ ] **Step 2: Implement.**
  - **Flag read:** `MacChatView` adds `@AppStorage(MacTimelineFlag.key) private var appKitTimelineSetting = MacTimelineFlag.defaultValue`, and `@State private var usesAppKitTimeline: Bool?`, set once in `.onAppear` from the setting (read at open, spec §5). The static `usesAppKitTimeline(defaults:)` is `defaults.object(forKey: key) as? Bool ?? MacTimelineFlag.defaultValue`.
  - **`chatColumn`:** replace the `ScrollViewReader { … }` block with `if usesAppKitTimeline == true { appKitTimeline } else { <the existing block, unchanged> }`.
  - **`appKitTimeline`:**

```swift
MacTimelineView(viewModel: viewModel, stripViewModel: stripViewModel, bridge: timelineBridge,
                selection: messageSelection, actions: timelineActions)
    .overlay { if viewModel.rows.isEmpty { TimelineLoadingIndicator() } }
    .overlay(alignment: .top) { /* the same MinDisplayDuration PaginatingHeader block as the SwiftUI path */ }
    .overlay(alignment: .bottomTrailing) {
        if !timelineBridge.isFollowingTail { JumpToBottomButton { timelineBridge.jumpToBottom() } }
    }
    .overlay(alignment: .topTrailing) { /* the same ChatTopTrailingControls block, isFollowingTail: timelineBridge.isFollowingTail */ }
    .onChange(of: viewModel.items) { _, _ in viewModel.persistVisibleAnswers() }
```

  - **Shared overlays:** move the two overlay bodies (paginating header, top-trailing controls) into small `private` helper views or `@ViewBuilder` funcs, so both branches call the same code and the SwiftUI branch's output is unchanged.
  - **Actions:** `timelineActions` builds `MacTimelineActions` from the closures `MacTimelineListContent` gets today (`onOpenSubChat`, `onOpenConversation`, `showItem`, `onOpenMission`, image preview), with `linkRouting` from `@Environment(\.openTrackerItem)`/`(\.openConversation)` read in `MacChatView`.
  - **Scroll memory:** `.onDisappear` in the AppKit branch calls `timelineBridge.storeScrollPosition()` instead of the `visibleRows` store.
  - **Representable:** `MacTimelineView: NSViewControllerRepresentable`. `make` creates the controller; `update` calls `controller.update(actions:)`; `static dismantleNSViewController` calls `controller.tearDown()`, mirroring iOS `ChatTimelineView`.
  - **Probe:** in `MacTimelineController.viewDidAppear`, `#if DEBUG`: `MacTimelinePerfProbe.shared.viewModel = viewModel; scrollViewProvider = { [weak self] in self?.scrollView }; jumpToBottom = { [weak self] in self?.session.jumpToBottom() }`. At the end of `sync()` after an apply: `MacTimelinePerfProbe.shared.noteRowsPresented(roomID:count:)`.
  - **Selection:** keep `MacChatView.installTranscriptProvider(on:viewModel:)` for both branches. The controller sets `contentProvider` (Task 9).
  - **Leave alone:** the sub-chat pane, drag-and-drop and the header accessory.

- [ ] **Step 3: Run the Mac suites together.**

```bash
cd ~/Dev/matron-apple-mactable && xcodegen generate
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport xcodebuild test -project Matron.xcodeproj -scheme MatronMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/mactable/dd-test ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -only-testing:MatronMacTests 2>&1 | grep -E 'error:|Executed .* tests' | tail -3
ls /tmp/matron-test-appsupport/journal-store >/dev/null && echo override-applied
```

  Expected: 0 failures, the executed count ≥ the `main` count plus the new tests, and `override-applied`.

- [ ] **Step 4: Smoke-test in the rig.**
  - `mac-perf.sh build … /tmp/mactable/app-new`
  - `mac-perf.sh launch /tmp/mactable/app-new "" on`
  - `mac-perf.sh run "snap /tmp/mactable/new-open.png"`
  - Read the PNG: bubbles, timestamps, code buttons and cards look like `base-open.png`.
- [ ] **Step 5: Commit** with the message `mac: chat.timeline.appkit switches the chat column to the NSTableView timeline`.

---

### Task 12: Before/after, manual pass list, cleanup, PR

**Files:**
- Modify: `manual-tests.md` (add a "Mac AppKit timeline" section), and spec §6 (append a results table).

- [ ] **Step 1: Interleaved A/B.** Run `zsh MatronMacUITests/rig/mac-perf.sh ab /tmp/mactable/app-new 3`, the same binary with flag off/on alternating. Collect `perf.jsonl` and tabulate per workload: median CPU s, hitch %, worst frame, first-frame ms and footprint for off vs on. Compare against spec §2's targets. If a target is missed:
  - `sample` the flag-on process during that workload to attribute the cost;
  - fix the cause in the owning task's file;
  - re-run the A/B.

  Report every miss honestly in the results table.
- [ ] **Step 2: Add the manual-test checklist** to `manual-tests.md` (spec §6: drag-select with autoscroll, code copy, right-click Open Item, streaming while reading and while pinned, jump button, resize while reading, Find in Chat jump, image preview, ask-user answer).
- [ ] **Step 3: Clean up the disk.**

```bash
rm -rf /tmp/mactable/dd /tmp/mactable/dd-test /tmp/mactable/dd-ios /tmp/mactable/app-base /tmp/mactable/store
df -h / | tail -1
```

  Keep `/tmp/mactable/app-new` only if Dan wants to try it; otherwise delete it too.
- [ ] **Step 4: Commit, push, and open a draft PR.** Title: `Mac: virtualised AppKit chat timeline behind chat.timeline.appkit`. The body carries the before/after table, the spec link, and "flag default off in Release". End it with the Claude Code line.

---

## Self-review notes (done while writing)

- **Spec coverage:**

  | Spec section | Task(s) |
  |---|---|
  | §3 Structure | 9, 11 |
  | Shared with iOS | 1, 2 |
  | Rows | 6, 7 |
  | Measuring | 6, 9 |
  | Updates / streaming | 9 |
  | Scrolling behaviour | 8, 9, 10 |
  | Cross-message selection | 5, 10 |
  | Flag | 3, 11 |
  | Tests | every task + 12 |
  | Perf gate | 0, 12 |
  | Risks | 7 (reuse, TK1), 9 (reentrancy via coalescer), 6 (parity) |

- **Review Focus → tests:** item 1 → Task 5 and Task 10 `test_crossSelectionAcrossNeverMountedRowsCopiesAll`; item 2 → Task 9 `test_streamingGrowthPinnedWhileFollowingAndStillWhileReading`; item 3 → Task 10 `test_widthChangeKeepsTheTopMessage`; item 4 → Task 7 `test_reuseDropsSelectionFlashAndCheckmark`; item 5 → Task 7 `test_tabledMessagesUseTextKit1AndPlainUseTextKit2`.
- **Geometry:** the Task 9 spacer/footer mapping changes the row-index relation, and Task 9 Step 3 says so explicitly, including adjusting its own parity assertion.
