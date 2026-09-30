# Mac chat timeline: measured cause and a virtualised AppKit (NSTableView) design

Mission: Dan, 28 Sep — "it seems better on ios already and mac is slow". The iOS timeline moved to UIKit in #3199 (spec `2026-09-26-ios-uikit-timeline-design.md`, merged `b30c9f35` behind `chat.timeline.uikit`). This spec does the same for the Mac: a virtualised `NSTableView` timeline behind a flag, with the current SwiftUI timeline kept as the fallback.

## 1. Measured cause

**Rig.** Release `-O` build of main `678c4e49` plus DEBUG-only probe hooks (`MatronMac/App/MacTimelinePerfProbe.swift`), built with the Debug entitlements (no sandbox). It runs offline against a `.backup` copy of Dan's live store with `homeserverURL` pointed at `127.0.0.1:9`, so it never talks to the journal.

The probe drives three workloads:
- **Scroll:** a synthetic trackpad scroll. Phased scroll-wheel events go straight to the timeline's `NSScrollView`; nothing is posted to the system.
- **Streaming:** a growing `eph:` reply, fed through the view model's real snapshot path, coalescer included.
- **Open:** a conversation switch.

Metrics: app CPU seconds (getrusage), display-link hitches (a frame later than 1.5 × the 8.3 ms frame), worst frame gap, and physical footprint.

Setup:
- **Occlusion:** the rig window floats at 2% opacity and ignores the mouse. It stays un-occluded, so its display link runs at 120 Hz, without getting in the way on a Mac Dan is using. Idle noise floor: about 4 hitches in 5 s.
- **Chats:** `3a258fa0` (7,142 text events), with `5ee1ed62` (4,446) as the switch partner. The row window grows to its 361-row cap while scrolling.

| Workload (fixed amount of work) | CPU s | Frames that hitch | Worst frame |
|---|---|---|---|
| Scroll 900 steps × 25 pt | **28–37** | 76–96% | 1.2–2.8 s |
| Scroll 300 steps × 150 pt | 15–17 | 97% | 1.8–2.2 s |
| Stream 150 deltas at 10 Hz | 4.6–10 | 8–25% | 1.2–1.7 s |
| Open (switch between the two chats) | 0.7–1.5 | 0.3–1.2 s hitch time in the next 5 s; 290–880 ms to first frame with rows | — |

Footprint was 160–275 MB.

**Caveat.** The machine's load average was 330–780 during these runs (other builds and VMs), so absolute numbers are inflated. The before/after in §6 is therefore interleaved A/B in one binary, flag off vs on.

**Where the main thread goes** (`sample` during the 25 pt scroll):
- 100% under `GraphHost.flushTransactions` / `AG::Subgraph::update`.
- **87% in `StackLayout`**, the eager `VStack` of up to 361 rows being re-laid out as the window extends and the scroll geometry changes.
- 35% in `MarkdownAttributed.build` for rows mounted by the extension.

Our per-row code is otherwise negligible. This is the iOS diagnosis again: the cost scales with the number of mounted SwiftUI rows. The eager stack cannot be made lazy, because that brings back the blank-chat history.

**Conclusion.** Mount only the visible rows, with exact, cached heights and one owner of the scroll offset. Keep every Mac behaviour by reusing the AppKit pieces the Mac already has.

## 2. Goal and success criteria

The flag-on timeline, measured interleaved against flag-off in the same binary (≥3 pairs), must meet:

| Workload | Target |
|---|---|
| Scroll 900 × 25 pt | ≤ 25% of flag-off CPU; ≤ 10% of frames hitch |
| Scroll 300 × 150 pt | ≤ 35% of flag-off CPU |
| Stream 150 deltas | ≤ 30% of flag-off CPU; worst frame < 100 ms while pinned |
| Open | First frame with rows ≤ flag-off; hitch time halved |
| Footprint | Not above flag-off after the scroll |

Every behaviour in §4 works with the flag on. With the flag off, nothing changes.

## 3. Design

**Choice: a view-based `NSTableView`.** One column, no header, `usesAutomaticRowHeights = false`, and heights returned from a cache through `tableView(_:heightOfRow:)`. `NSCollectionView` with a custom layout would mirror iOS more closely, but the table gives several things for free:
- row-view recycling
- `noteHeightOfRows(withIndexesChanged:)` for one-row updates
- accessibility rows
- autoscroll during text drags, because the text views sit inside its clip view

The one thing the table does not do — keep the viewport steady across a prepend — is owned by the shared scroll model, as on iOS.

### Structure

- **`MacTimelineController`** (`NSViewController`) owns an `NSScrollView` subclass (`MacTimelineScrollView`) and the table.
  - `MacTimelineView: NSViewControllerRepresentable` hosts it in `MacChatView.chatColumn`, in place of the `ScrollViewReader { ScrollView { MacTimelineListContent } }` block, when the flag is on.
  - The SwiftUI chrome stays SwiftUI, around the representable: the loading indicator, the "Loading earlier messages…" pill, the jump button, Stop / jump-to-my-message, the drop overlay and the banners.
  - A small `@Observable` **`MacTimelineBridge`** carries `isFollowingTail` out and `jumpToBottom()` in, mirroring iOS `ChatTimelineBridge`.
- The controller reads the **unchanged** `ChatViewModel` API through `withObservationTracking`:
  - `windowedRows`, `hasMultipleSenders`, `pendingFocusID`, `activityLabel`, `windowContainsTail`, `isPaginatingBackward`, `lastRenderableItemID`/`lastRenderableItemIsOwn`
  - `extendHistoryWindow`, `revealNewerHistory`, `ensureWindowContains`, `resetHistoryWindow`
  - `stripViewModel.children`, for subtask cards
- **One writer of the scroll offset.** Only the controller sets the clip view's bounds origin, always from `TimelineScrollModel.contentOffsetY`, and always in the same run-loop turn as the table change, with implicit animation off. The user's own scrolling is recorded with `noteUserOffset`.

### Shared with iOS

Pure, platform-free files move from `Matron/Features/Chat/Timeline/` to a new `Shared/ChatTimeline/` folder that `project.yml` compiles into both app targets. iOS behaviour stays byte-identical, and its existing tests keep passing:
- **`TimelineScrollModel`**, unchanged: exact heights, anchors, follow-tail, prepend and rescue maths, jump and restore offsets.
- **`TimelineRowContent` and `TimelineRowContentBuilder`:** the row-content value types, duplicate-id guard and subtask resolution. `avatarSender` and `displayName` (identical today in `TimelineItemView` and `MacTimelineItemView`) move into a shared `TimelineSenderLabels` enum, which both item views call.
- **`TextBubbleGeometry`:** the bubble, timestamp, avatar, pill and send-state frames that mirror `MessageBubble`. Both platforms already share `MessageBubble`, so the geometry is the same.

Already shared and reused as they are:
- `MarkdownAttributed.Rendered` (the Mac renderer iOS was ported from), with its memoised `size(width:)`/`codeBlockFrames(width:)`, lock-protected and so measurable off the main thread.
- The **fingerprint fixture** (`MarkdownAttributedFingerprintTests`), which guards that nothing here changes the renderer's output.
- `MatronPalette` bubble colours and shadow.
- `MessageCopyTextView` and `MessageSelectionController`.
- `MatronItemLink`, `ChatScrollPositionMemory` (with its in-row offset) and `MainThreadStallMonitor`.

Not shared: the iOS segment renderer. The Mac keeps one `NSTextView` per message with `NSTextTable` tables, because cross-message selection and markdown-faithful copy depend on a message being one text storage.

### Rows

- **`MacTextRowView`**, for text messages and the streaming `eph:` row (most rows). It is a manual-layout `NSView` laid out from `TextBubbleGeometry`:
  - **Bubble:** a layer-backed view with corner radius 8, `matronBubbleMe`/`matronBubbleBot`, and the 1 pt shadow.
  - **Body:** the existing `MessageCopyTextView`, configured exactly as `SelectableTextViewRepresentable.makeNSView` does today. That logic moves into a shared `MessageTextViewConfigurator` that both call.
  - **Timestamp:** an `NSTextField` in `caption2`, secondary colour.
  - **Avatar and send state:** small hosted SwiftUI views (`SenderAvatar`, `SendStateIndicator`), measured once.
  - **Code-block copy buttons:** `NSButton`s placed from `Rendered.codeBlockFrames(width:)` at the same positions as today's overlay, with the same checkmark flash.
  - **Conversation pill row:** a hosted `ConversationLinkPillRow`, measured once per content and width.
  - **Links:** the link-click policy moves from `SelectableTextViewRepresentable.Coordinator` into a shared `MessageLinkRouter` (`NSTextViewDelegate`). The SwiftUI path and the table use the same object, so item, convo, http and matrix routing, and the right-click "Open Item #N" rewrite, cannot drift. `openTrackerItem` and `openConversation` come from the representable's environment.
  - **Context menu:** "Copy" (the raw body) plus "Copy N Messages" when a cross-message selection exists. The text view keeps its own AppKit menu, as today.
  - **Reuse identifiers:** tabled messages use a separate identifier (`text.tk1`), because a text view switched to TextKit 1 for `NSTextTable` cannot go back to TextKit 2.
  - **Accessibility:** the "Me: …" / "Name: …" label, as today.
- **`MacHostedRowView`**, for every other kind: separators, tool calls, diffs, live output, tool streams, ask-user and agent cards, spawn outcomes, item/milestone/mission/coordinator markers, images, files, subtask cards and unknown events.
  - It wraps an `NSHostingView` of the existing `MacTimelineRowView` content, so these rows render exactly as today.
  - Height is `fittingSize` at the row width, cached by (room, row id, width) with content equality.
  - A hosted view whose intrinsic size changes (an ask-user card answered, an image resolving, a tool card expanded) re-measures only its own row.
- **Activity indicator:** a footer row outside the anchor space, as on iOS (`setFooterHeight`).

### Measuring and caching

- **`MacTimelineMeasurer`.**
  - Text rows: `TextBubbleGeometry.layout`, with `Rendered.size(width:)` for the body. The timestamp aligns to the body's BOTTOM, not its last line's baseline: SwiftUI reports no text baseline for the `SelectableMessageText` representable, so `MessageBubble`'s `.lastTextBaseline` HStack falls back to the view's bottom (measured in Task 6; a `Rendered.lastBaseline(width:)` was added for this and removed unused in the final fix wave).
  - Hosted rows: `fittingSize` on a sizing host, main thread only.
- **`MacTimelineMeasureCache`**, the same shape as iOS `TimelineMeasureCache`: an `NSCache`, keyed by (room, row id, width), hit only when the stored content `==` the row's current content.
- **Precompute.** Text heights are computed off the main thread when the window or the width changes. A visible-row miss is measured synchronously; nothing is ever estimated.

### Updates

- **Coalescing.** One apply per display frame (an `NSView.displayLink` coalescer), however many snapshots arrive.
- **Apply.** Contents are built with the shared builder and diffed by anchor id:
  - Removed and inserted rows go through `removeRows`/`insertRows` with no animation, or `reloadData` when most rows changed.
  - A row whose content changed but whose id didn't is reconfigured in place if it's visible, followed by `noteHeightOfRows` for that index.
  - Then `model.replaceRows`, then the clip origin is set from the model, all in the same turn.
- **Streaming.** The `eph:` row is the in-place case above:
  - The storage is swapped only when the `Rendered` instance changes (the same pointer test `updateNSView` uses today).
  - The cross-selection span is re-applied with `force: true`.
  - Only that row is re-measured.
  - The rest of the window is never re-evaluated. This is the property the SwiftUI path cannot have.

### Scrolling behaviour

- **Follow-tail.** `TimelineScrollModel.isFollowingTail`:
  - **Off:** `willStartLiveScrollNotification`, a wheel `phase.began`, or any phase-less mouse-wheel event (the scroll view subclass overrides `scrollWheel`), calls `beginUserDrag`. So does any user clip move with no gesture around it (momentum, Page Up / Home / space in a text view, drag-select autoscroll) that leaves the near-bottom threshold while following — the controller checks the geometry in its `userScrolled` handler.
  - **On:** the end of the user's scroll calls `endUserScroll`, which re-arms it only at the tail. The end is `didEndLiveScroll` (posted after any momentum), a `momentumPhase.ended`, or a finger lift (`phase.ended`) that no momentum follows within two frames — never the lift itself, because AppKit gives no forward signal that momentum will follow. A non-gesture move that arrives at the tail re-arms too. It also comes back on your own send and on the jump button.
  - While following, every height change ends with the offset at `maxOffsetY`.
- **History edges.**
  - Not following and within 1.5 screens of the top: `extendHistoryWindow()`. The prepend keeps the anchor exactly (model).
  - Near the bottom of a detached window: `revealNewerHistory()`.
- **Jumps.** Search, Find in Chat, milestone/TOC and "jump to my last message" all arrive as `pendingFocusID`. The sequence is `ensureWindowContains` → apply → `model.jumpOffset` → set the origin → flash the row. No retry timers are needed, because heights are exact.
- **Restore.**
  - On leave, `ChatScrollPositionMemory.store(roomID:itemID:offsetInRow:)` records the top anchor.
  - On open, the table restores it; a SwiftUI-path entry goes through `restoreBottomAligned`.
  - Transient ids are still rejected. Leaving while following forgets the position, as today.
- **Resize.**
  - A width change keeps the top anchor.
  - During live resize, visible rows are re-measured synchronously and the rest in the background.
  - `noteHeightOfRows` for everything runs once resize ends.
  - A height-only change keeps the bottom pinned while following.

### Cross-message selection with virtualised rows

Today every windowed row has a live text view, and `MessageSelectionController` reads lengths and markdown from them. With only visible rows mounted, two small, backwards-compatible additions cover this:
1. **`register(_:)` re-applies the active span** to a target that registers mid-selection. A row scrolled into view by drag-autoscroll shows its highlight at once.
2. **A `contentProvider: (id) -> (attributed: NSAttributedString, source: String)?` fallback**, used when an id in the span has no live target:
   - `storageLength` becomes `attributed.length`.
   - `crossSelectionMarkdown` becomes `MarkdownReconstruction.markdown(from:in:)` on the rendered string, or the verbatim source for a full span.
   - So a drag from message 3 to message 40 copies all 38 messages even though 30 were never mounted.

The provider is installed by the table controller only; the SwiftUI path has a view for every row and is unaffected. `orderedIDs` is still fed from `windowedRows`. The press takeover, autoscroll, escalation and clear-monitor logic in `MessageCopyTextView` is reused unchanged.

### Out of scope

- **The sub-chat pane (`MacSubChatPane`)** keeps its SwiftUI timeline. It can adopt the controller once the flag has soaked.
- **Raising the 120/360 row-window caps.** Mounted cost is now proportional to visible rows, so a later change can lift them. Phase 1 keeps today's values so the view model behaves identically.

## 4. Behaviours that must survive (flag on)

- Cross-message drag selection: press in one message, drag into another, including autoscroll past the viewport edge. Plus "Copy N Messages", ⌘C and Edit ▸ Copy producing the `[date, time] Name: text` transcript.
- Markdown-faithful copy: a full message copies its source; a partial selection is reconstructed; a selection inside one code block copies bare code; RTF goes alongside.
- Code-block copy buttons, with the checkmark flash.
- Links: `matron://item/N` opens the item; `matron://convo/<id>` opens the conversation; http(s) goes to the browser; matrix/mxc links are swallowed; right-click shows "Open Item #N" / "Open Conversation".
- Streaming updates without rebuilding the whole window; the tail stays pinned while following.
- Scroll-to-bottom pinning: open at the bottom, your own send returns to the bottom, the jump button, and follow re-arms on settling at the tail.
- History paging up and down without jumps; search, Find in Chat and TOC jumps landing the row at the top; per-room restore.
- Ask-user answering, agent-chat/spawn approval, item/milestone/mission cards, subtask cards opening the pane, image preview and file open — all through the hosted rows.
- Dragging and dropping attachments anywhere on the column; the header accessory, banners and composer unaffected.

## 5. Flag

- `@AppStorage("chat.timeline.appkit")`, as `MacTimelineFlag` (mirrors `ChatTimelineFlag`). A toggle in Settings ▸ Device ▸ Advanced reads "Faster chat timeline (AppKit)".
- It's read when a chat opens, so a flip takes effect on the next open.
- Off gives the current SwiftUI timeline, byte for byte.
- Default: **on in Debug builds, off in Release** until Dan has used it. Flipping the default and deleting the SwiftUI path are later, separate PRs. Question to Dan in the approval item.

## 6. Test plan

The `MatronMacTests` host is always run with `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport`, and the "Executed N tests" count is asserted.

- **Model:** iOS `TimelineScrollModel` tests keep running from the shared file. Mac-specific cases: prepend keeps the anchor; stream growth stays pinned; unpinned growth above the viewport doesn't move content; jump offset; restore; resize keeping the top anchor; vanished-anchor rescue.
- **Controller** (real `ChatViewModel` over the shared fake timeline service, in a real window):
  - Asserted after every apply: the table's `rect(ofRow:)` equals the model's row frames, and the clip origin equals `contentOffsetY`.
  - Only visible rows have views.
  - A stream delta re-measures one row.
  - Own send pins.
  - A jump lands the row at the top.
- **Parity:**
  - Frames: at widths 420, 700 and 1100, for the measurer corpus, own and not-own, with and without the avatar, the `TextRowLayout` bubble frame, text origin and timestamp frame match the SwiftUI `MacTimelineItemView` row within 1 pt (`MacTimelineMeasurerTests.test_textRowFramesMatchSwiftUIRow`).
  - Heights: the same corpus plus pill and send-state cases match the SwiftUI row's height within 1 pt.
  - Visual: the perf rig's open snapshot of the table timeline against the SwiftUI one (Task 11). Light/dark bitmap snapshots of the two row implementations were dropped by controller ruling: the Mac snapshot harness has a known appearance chore, and the frame + height parity plus the rig snapshot cover the intent. A visual mismatch would surface in Dan's manual pass instead of CI.
  - Renderer: the fingerprint fixture unchanged.
- **Selection:**
  - The existing `MessageCopyTextView*` tests pass unchanged.
  - New controller tests cover register-applies-span, provider fallback for unmounted rows, and a transcript across rows that were never mounted.
- **Links:** the existing coordinator link-policy tests move onto `MessageLinkRouter` and run against both hosts.
- **Perf gate:** the §1 rig, interleaved A/B in one binary (flag off/on), ≥3 pairs, against the §2 targets.
- **Manual pass for Dan:** the "Mac AppKit timeline" checklist in `manual-tests.md`, which covers every §4 behaviour (selection and copy, links, streaming, follow-tail including trackpad flicks and keyboard scrolling, jumps, restore across pane toggles, the hosted-row cards, drag-and-drop, chrome) plus the flag toggle and the flag-off path.

### Results (2026-09-28)

**Run.** Branch `feat/mac-appkit-timeline` at `3c341042`. This is after one targeted fix round: hosted rows no longer re-measure on every layout pass, and an open measures only on-screen rows on main. One binary, flag off/on interleaved, 3 pairs, against the §1 rig store (a `.backup` of the live store made that evening):

```
zsh MatronMacUITests/rig/mac-perf.sh build ~/Dev/matron-apple-mactable /tmp/mactable/app-new
caffeinate -d -u -t 3600 &      # the display link doesn't tick on a sleeping display
RUN_TIMEOUT_TICKS=240 zsh MatronMacUITests/rig/mac-perf.sh ab /tmp/mactable/app-new 3
```

**Flag switch.** The flag was set with the `-chat.timeline.appkit YES|NO` launch argument. Before this, `launch` used `defaults write`, which never reached the rig app, so every earlier "off" run was really "on" (see the rig README). The unified log confirms the switch worked: the three ON runs have 15 `mac timeline controller init` lines (launch plus four opens each), and the OFF runs have none.

**Load.** `uptime` read 44 / 28 / 27 before and 17 / 19 / 26 after. The `load` field on individual results ranged from 13 to 29. That is far lighter than the §1 baseline (330–780), so flag-off absolutes are lower than §1's; only the ratios count. Idle noise floor, both arms: 0–24 hitches per 5 s.

**Statistic.** ON/OFF is the **median of the three per-pair ratios**: each ON run divided by the OFF run just before it. Every pair ran OFF first, so any drift within a pair (thermal, background load, caches warmed by the OFF run) lands on the ON side; the order was not alternated. The OFF and ON columns are plain medians of the three runs. For Open, each run's value is the mean of its 4 switches. "Worst" is the worst frame gap. Footprint is taken at the end of that workload.

| Workload | Metric | OFF | ON | ON/OFF (per-pair ratios) | Target | Result |
|---|---|---|---|---|---|---|
| Scroll 900 × 25 pt | CPU s | 13.88 | 4.19 | **0.30** (0.30, 0.27, 0.31) | ≤ 0.25 | **MISS** |
| | hitch % | 45.3 | **2.9** (2.8, 3.2, 2.9) | 0.07 | ≤ 10% | pass |
| | worst ms | 484 | 65 | 0.13 (0.13, 0.45, 0.13) | — | |
| | footprint MB | 244 | 123 | 0.50 | ≤ OFF | pass |
| Scroll 300 × 150 pt | CPU s | 11.32 | 3.60 | **0.33** (0.33, 0.33, 0.28) | ≤ 0.35 | pass |
| | hitch % | 76.3 | 51.5 | 0.68 | — | |
| | worst ms | 414 | 87 | 0.21 | — | |
| | footprint MB | 282 | 151 | 0.54 | ≤ OFF | pass |
| Stream 150 @ 10 Hz | CPU s | 5.87 | 3.30 | **0.56** (0.56, 0.57, 0.39) | ≤ 0.30 | **MISS** |
| | worst ms (pinned) | 480 | **268** (59, 305, 268) | 0.56 | < 100 | **MISS** |
| | hitch % | 6.5 | 9.4 | 1.39 (1.64, 1.39, 0.78) | — | worse than OFF |
| | footprint MB | 253 | 155 | 0.60 | — | |
| Open (switch) | first frame ms | 436 | 288 | 0.66 (0.66, 0.71, 0.39) | ≤ OFF | pass |
| | hitch ms, next 5 s | 571 | 375 | **0.66** (0.52, 0.91, 0.66) | ≤ 0.5 | **MISS** |
| | CPU s | 0.96 | 0.54 | 0.55 | — | |
| | footprint MB | 155 | 108 | 0.70 | — | |

**Before the fix round** (same statistic; first run of the evening, at `c91554b4`):
- Scroll 25 CPU: 0.36, hitch 3.6%
- Scroll 150 CPU: 0.42
- Stream CPU: 0.59, worst 161 ms, hitch ratio 1.47
- Open first frame: 0.72, hitch ms 0.57

**Per-pair raw values, OFF / ON.**

| Pair | Scroll 25: CPU, hitch %, worst | Scroll 150: CPU, hitch %, worst | Stream: CPU, hitch %, worst | Open first-frame ms ×4 | Open hitch ms ×4 |
|---|---|---|---|---|---|
| 1 OFF | 13.5, 41.3, 484 | 11.3, 77.6, 465 | 5.9, 5.9, 480 | 723, 338, 378, 304 | 1039, 525, 683, 315 |
| 1 ON | 4.1, 2.8, 62 | 3.7, 51.5, 81 | 3.3, 9.6, 59 | 660, 147, 182, 165 | 380, 39, 285, 633 |
| 2 OFF | 15.3, 45.3, 370 | 10.9, 72.6, 402 | 5.9, 6.7, 493 | 742, 257, 420, 301 | 551, 512, 484, 377 |
| 2 ON | 4.2, 3.2, 168 | 3.6, 50.8, 89 | 3.3, 9.4, 305 | 696, 169, 190, 168 | 396, 164, 530, 656 |
| 3 OFF | 13.9, 47.1, 487 | 12.6, 76.3, 414 | 5.7, 6.5, 477 | 942, 311, 378, 1132 | 872, 473, 601, 337 |
| 3 ON | 4.2, 2.9, 65 | 3.6, 52.2, 87 | 2.2, 5.1, 268 | 534, 188, 199, 157 | 407, 228, 336, 529 |

**Notes.**
- **Unexplained travel difference.** For the same 300 wheel steps of 150 pt, ON's `travelledPt` was about 85k and OFF's 42–50k. For the 25 pt scroll, ON was always 40.2k and OFF 23–49k. `travelledPt` sums |Δ `bounds.origin.y`|, and that includes the origin shifts from prepends and anchor compensation, which the two timelines handle differently. So the metric can't be compared across arms, and the CPU ratios aren't normalised by it. Whether the table timeline really scrolls farther per wheel event is a manual-checklist item.
- **What the fix round moved.**
  - Scroll CPU improved: 25 pt went from 0.36 to 0.30, and 150 pt from 0.42 to 0.33, which now meets its target.
  - Stream CPU didn't move (0.59 → 0.56).
  - The open-precompute split never fired in this run. No `landed short` breadcrumb was logged, and neither was the old `landed with … rows still missing — measuring on main`, which appeared 13 times in the earlier run. The timing that produced the short landings didn't recur, so this run doesn't test that change. Open hitch time (0.57 → 0.66) is within the pair-to-pair spread (0.52–0.91).
- **What remains, and why it wasn't chased.**
  - *25 pt scroll CPU (0.30 vs 0.25).* The rest of the cost is SwiftUI layout of hosted rows as they mount, `NSTableView` row-view preparation, and TextKit 2 viewport layout of text rows (`/tmp/mactable/sample-on-scroll25.txt`, before the fix). Closing it means cheaper hosted rows or reusing text views. That is structural work, not a small fix.
  - *Stream CPU (0.56) and worst frame (59–305 ms vs < 100).* Each coalesced delta re-renders the growing reply's markdown (`MarkdownAttributed.rendered`) and re-lays out its `NSTextView`, code-block frames and hosted pieces (`/tmp/mactable/sample-on-stream.txt`). This is the same per-delta work the SwiftUI path does, just without the stack re-layout. An incremental render for the streaming row is the follow-up.
  - *Open hitch time (0.66 vs 0.5).* The first frame is already faster. The remaining hitch time falls in the 5 s after an open, during history reveal and mounting hosted rows. It needs its own sample.
- **Coalescer.** The display link ticked in every flag-on process (`mac timeline coalescer: display link ticked`). The 50 ms fallback timer fired once per process, at mount, before the window was on screen.
- **Diagnostics.** No `REENTRANT-GUARD` in any run. The AppKit "reentrant operation in its NSTableView delegate" warning appears once per launch in both arms, so it comes from the sidebar (§7). There were no invariant or rescue breadcrumbs.

**Verdict.**
- Every scroll and open hitch, worst-frame, first-frame and footprint number improved, most scroll ones by 2–15×. The exception is streaming: its worst frame improved (0.56) but its hitch % got worse (below).
- Met (5): the 25 pt scroll's hitch %, 150 pt scroll CPU, open first frame, and both footprints.
- Missed (4): 25 pt scroll CPU (0.30 vs 0.25), stream CPU (0.56 vs 0.30), stream worst frame (268 ms vs 100), and open hitch time (0.66 vs 0.5).
- Stream hitch % was also higher with the flag on (9.4% vs 6.5%).

### Results after the follow-ups (2026-09-29)

**Run.** `4d43d1c4`, after the follow-ups cycle (`docs/superpowers/specs/2026-09-29-mac-appkit-timeline-perf-followups.md`: D0 diagnostics, S1–S6, X1, R1, R2, O1 plus review fixes). Same rig, store, statistic and command as above (`ab … 3`, OFF first). Load fell from 60 to 24 (1-min) across the run, the quietest of the cycle; no `xcodebuild` ran and no simulator was active. Full report: `.superpowers/sdd/2026-09-29-mac-appkit-followups/final-gate.md` (local).

| Target | Before follow-ups | After (per-pair ratios) | Result |
|---|---|---|---|
| Scroll 25 pt CPU ≤ 0.25 | 0.30 | **0.34** (0.24, 0.34, 0.41) | **MISS** |
| Scroll 25 pt hitch % ≤ 10 | 2.9 | 3.2 / 2.8 / 5.2 | pass |
| Scroll 150 pt CPU ≤ 0.35 | 0.33 | **0.30** (0.30, 0.31, 0.27) | pass |
| Stream CPU ≤ 0.30 | 0.56 | **0.38** (0.43, 0.37, 0.38) | **MISS** |
| Stream worst frame < 100 ms | 268 ms | **80 / 67 / 81 ms**; 0 gaps over 100 ms | pass |
| Stream hitch % vs OFF | 9.4 vs 6.5 | 8.9 / 6.8 / 6.3 vs 6.0 / 7.3 / 7.2 (ratio 0.93) | about parity |
| Open first frame ≤ OFF | 0.66 | 0.70 (0.70, 0.63, 0.77) | pass |
| Open hitch ms ≤ 0.5 | 0.66 | **0.39** (0.58, 0.39, 0.40) | pass |
| Footprint ≤ OFF | 0.50 / 0.54 / 0.60 / 0.70 | 0.51 / 0.51 / 0.52 / 0.72 | pass |

**Notes.**
- **Two of the four misses are fixed:** the stream worst frame and the open hitch time. Stream CPU fell by a third but still misses.
- **Scroll 25 pt CPU tracks load.** Its per-pair ratio rose from 0.24 to 0.41 as the load fell from 60 to 24, with identical row counts in both arms. OFF's CPU fell (18.2 → 10.9 s) while ON's held (4.4 → 4.5 s). So earlier readings under load were flattered by contention, and the quiet-machine ratio is nearer 0.4 than 0.3. The direction checks at load 300–700 during the cycle (0.27–0.44) are not comparable.
- **The ON arm's own scroll CPU is flat across the cycle** (4.2 s before, 4.4 s now); the stream ON CPU fell from 3.3 s to 2.2 s.
- **Not done, by design gate:** S7 (move the streaming render off main) is CPU-neutral and the worst-frame target it served is met. S8 (block-split incremental markdown render, shared with iOS, high risk) is estimated at ~6% of stream busy time, which would not reach 0.30 on its own.

## 7. Risks

- **Parity of hand-laid-out text rows with SwiftUI's `lastTextBaseline` HStack.** Mitigation: the frame-parity tests, plus the hosted fallback — any row kind can be switched to hosted with a one-line change while a mismatch is fixed.
- **Recycled `MessageCopyTextView`s.** An id change already unregisters and drops stale highlights (`selectionItemID` willSet/didSet). The row view also clears `selectedRange` and cancels a code-button flash on reuse, and a press in progress captures its id at press time, as today.
- **NSTableView reentrancy.** Never call `noteHeightOfRows`/`insertRows` from inside a delegate callback; everything goes through the coalescer. (The existing "reentrant operation in its NSTableView delegate" warning in the rig log comes from the sidebar and predates this work.)
- **Hosted rows costing a SwiftUI graph each.** They are the minority. The iOS prototype showed hosting is the expensive cell type, which is why text rows are native.
