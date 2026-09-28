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
  - Text rows: `TextBubbleGeometry.layout`, with `Rendered.size(width:)` for the body and a new memoised `Rendered.lastBaseline(width:)` for the timestamp's baseline alignment.
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
  - **Off:** `willStartLiveScrollNotification`, or any phase-less mouse-wheel event (the scroll view subclass overrides `scrollWheel`), calls `beginUserDrag`.
  - **On:** `didEndLiveScroll` calls `endUserScroll`, which re-arms it only at the true tail. It also comes back on your own send and on the jump button.
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
  - Frames: at widths 420, 700 and 1100, for the fingerprint corpus plus avatar, own-message, pill and send-state cases, the `MacTextRowView` bubble, text origin and timestamp frames match the SwiftUI `MacTimelineItemView` row within 1 pt.
  - Snapshots: light and dark bitmaps of both, compared.
  - Renderer: the fingerprint fixture unchanged.
- **Selection:**
  - The existing `MessageCopyTextView*` tests pass unchanged.
  - New controller tests cover register-applies-span, provider fallback for unmounted rows, and a transcript across rows that were never mounted.
- **Links:** the existing coordinator link-policy tests move onto `MessageLinkRouter` and run against both hosts.
- **Perf gate:** the §1 rig, interleaved A/B in one binary (flag off/on), ≥3 pairs, against the §2 targets.
- **Manual pass for Dan** (added to `manual-tests.md`):
  - drag-select across messages, with autoscroll
  - code copy button
  - right-click "Open Item"
  - streaming reply while reading history, and while pinned
  - jump button
  - window resize while reading

### Results (2026-09-28)

**Run.** Branch `feat/mac-appkit-timeline` at `c91554b4` plus a DEBUG-only coalescer breadcrumb. One binary, flag off/on interleaved, 3 pairs, against the §1 rig store (a `.backup` of the live store made that evening):

```
zsh MatronMacUITests/rig/mac-perf.sh build ~/Dev/matron-apple-mactable /tmp/mactable/app-new
caffeinate -d -u -t 3600 &      # the display link doesn't tick on a sleeping display
RUN_TIMEOUT_TICKS=240 zsh MatronMacUITests/rig/mac-perf.sh ab /tmp/mactable/app-new 3
```

The flag was switched with the `-chat.timeline.appkit YES|NO` launch argument. Before this run, `launch` used `defaults write`, which never reached the rig app, so all earlier "off" runs were really "on" (see the rig README). The unified log confirms the switch: 15 `mac timeline controller init` lines in the three ON runs (launch plus four opens each), none in the OFF runs.

**Load.** `uptime`: 31 / 49 / 49 before, 14 / 22 / 33 after; per-result `load` was 12–44. That is far lighter than the §1 baseline (330–780), so flag-off absolutes are lower than §1's (e.g. 12 s against 28–37 s for the 25 pt scroll). Only the ratios count. Idle noise floor in both arms: a median of 16.5 hitches per 5 s.

Hitch % is the share of frames that hitched. "Worst" is the worst frame gap. Footprint for a scroll row is the value at the end of that scroll. Every value is the median of 3 pairs, apart from Open, which is the median of 12 switches (4 per run).

| Workload | Metric | OFF | ON | ON/OFF | Target | Result |
|---|---|---|---|---|---|---|
| Scroll 900 × 25 pt | CPU s | 12.52 | 4.48 | **0.36** (0.45, 0.36, 0.36) | ≤ 0.25 | **MISS** |
| | hitch % | 37.9 | **3.6** (9.2, 3.1, 3.6) | 0.09 | ≤ 10% | pass |
| | worst ms | 356 | 98 | 0.28 | — | |
| | footprint MB | 232 | 123 | 0.53 | ≤ OFF | pass |
| Scroll 300 × 150 pt | CPU s | 10.02 | 3.85 | **0.38** (0.58, 0.31, 0.42) | ≤ 0.35 | **MISS** (marginal; see note) |
| | hitch % | 71.6 | 51.5 | 0.72 | — | |
| | worst ms | 595 | 90 | 0.15 | — | |
| | footprint MB | 266 | 152 | 0.57 | ≤ OFF | pass |
| Stream 150 @ 10 Hz | CPU s | 5.32 | 3.01 | **0.57** (1.22, 0.56, 0.59) | ≤ 0.30 | **MISS** |
| | worst ms (pinned) | 470 | **161** (161, 116, 466) | 0.34 | < 100 | **MISS** |
| | hitch % | 6.3 | 10.0 | 1.58 | — | worse than OFF |
| | footprint MB | 235 | 160 | 0.68 | — | |
| Open (switch) | first frame ms | 353 | 181 | 0.51 | ≤ OFF | pass (cold 731→637, warm 313→165) |
| | hitch ms, next 5 s | 416 | 278 | **0.67** | ≤ 0.5 | **MISS** (cold 0.45 pass, warm 349→271 = 0.78) |
| | CPU s | 0.82 | 0.51 | 0.62 | — | |
| | footprint MB | 152 | 110 | 0.72 | — | |

Per-pair raw values (OFF / ON):

| Pair | Scroll 25: CPU, hitch %, worst | Scroll 150: CPU, hitch %, worst, travelled pt | Stream: CPU, hitch %, worst | Open first-frame ms ×4 | Open hitch ms ×4 |
|---|---|---|---|---|---|
| 1 OFF | 12.81, 32.9, 507 | 10.02, 67.2, 595, 53 677 | 5.32, 6.3, 470 | 731, 339, 374, 313 | 1185, 468, 1436, 417 |
| 1 ON | 5.72, 9.2, 224 | 5.86, 51.8, 239, 85 273 | 6.48, 12.5, 161 | 637, 165, 280, 185 | 588, 393, 549, 383 |
| 2 OFF | 12.52, 40.2, 356 | 11.69, 76.9, 704, 53 642 | 5.40, 6.3, 552 | 891, 292, 369, 300 | 646, 196, 414, 224 |
| 2 ON | 4.48, 3.1, 98 | 3.66, 51.5, 89, 84 694 | 3.01, 7.1, 116 | 979, 158, 158, 195 | 290, 159, 271, 200 |
| 3 OFF | 11.83, 37.9, 319 | 9.13, 71.6, 397, 44 910 | 4.85, 6.8, 454 | 629, 287, 367, 284 | 459, 295, 349, 187 |
| 3 ON | 4.31, 3.6, 72 | 3.85, 49.8, 90, 85 092 | 2.87, 10.0, 466 | 532, 128, 160, 176 | 235, 150, 60, 284 |

Notes:
- **Scroll 300 × 150 pt did more work with the flag on.** It is fixed by step count, but ON travelled 85 k pt against OFF's 45–54 k, so the SwiftUI timeline clamps or stalls part of each run. Per point travelled, ON cost about 0.22 of OFF. The target is still reported as missed on its own definition.
- **Pair 1 is noisy.** Its first ON stream took more CPU than OFF (6.48 against 5.32). The next two pairs agree with each other (0.56, 0.59).
- **Where the flag-on time goes**, from `sample` of the flag-on process (`/tmp/mactable/sample-on-*.txt`):
  - *Scroll 25 pt:* the main thread is 58% busy. Of that busy time (overlapping, inclusive):
    - about 23% is `NSHostingView.layout` of hosted (SwiftUI) rows as they mount. About 15% of it is `MacHostedRowView`'s `hostContentMayHaveResized`, which calls `fittingSize` after every host layout pass, and `fittingSize` builds a constraint engine each time;
    - about 13% is `NSTableView` row-view preparation (`prepareContentInRect`);
    - about 10% is `NSTextView` TextKit 2 viewport layout;
    - about 5% is the controller's `sync`.
    No single small fix closes the gap to 25%. The `fittingSize` re-check, the hosted rows' SwiftUI layout and the table's row mounting are the follow-ups.
  - *Stream:* the main thread is only about 14% busy. Of that, 26% is the coalesced `sync` (including re-rendering the growing reply's markdown), 35% is the window layout pass (the streaming row's `NSTextView` re-layout, `MessageBodyView.codeBlockFrames`, hosted views) and 6% is the view model's snapshot path. The worst-frame spikes (116–466 ms) were not reproduced under `sample`, because sampling adds its own stalls.
  - *Open:* each flag-on open logged `mac timeline precompute landed with 39–92 rows still missing — measuring on main` (13 times across the three ON runs). When the window grows from 41 to 121 rows during an open, the rows added after the background batch was scheduled get measured on main. This is the likely reason warm-switch hitch time only fell to 0.78 of OFF, and it is the first follow-up for Open.
- **Coalescer.** In every flag-on process the display link ticked (`mac timeline coalescer: display link ticked`). The 50 ms fallback timer fired once per process, at mount, before the window was on screen.
- **No `REENTRANT-GUARD`** in any run. The AppKit warning "reentrant operation in its NSTableView delegate" appears once per launch in both arms (7 of 7 launches), so it comes from the sidebar, as §7 says. There were no invariant or rescue breadcrumbs ("rows ≠ model → reload", "dropped duplicate row ids", "no text measurement").

**Verdict.** Every hitch, worst-frame, first-frame and footprint number improved, most of them 2–10×. Four targets were met: the 25 pt scroll's hitch %, open first frame, and both footprints. Five were missed:
- 25 pt scroll CPU: 0.36 against 0.25
- 150 pt scroll CPU: 0.38 against 0.35
- stream CPU: 0.57 against 0.30
- stream worst frame: 161 ms against 100 ms
- open hitch time: 0.67 against 0.5
The stream's hitch % was also higher with the flag on (10.0% against 6.3%).

## 7. Risks

- **Parity of hand-laid-out text rows with SwiftUI's `lastTextBaseline` HStack.** Mitigation: the frame-parity tests, plus the hosted fallback — any row kind can be switched to hosted with a one-line change while a mismatch is fixed.
- **Recycled `MessageCopyTextView`s.** An id change already unregisters and drops stale highlights (`selectionItemID` willSet/didSet). The row view also clears `selectedRange` and cancels a code-button flash on reuse, and a press in progress captures its id at press time, as today.
- **NSTableView reentrancy.** Never call `noteHeightOfRows`/`insertRows` from inside a delegate callback; everything goes through the coalescer. (The existing "reentrant operation in its NSTableView delegate" warning in the rig log comes from the sidebar and predates this work.)
- **Hosted rows costing a SwiftUI graph each.** They are the minority. The iOS prototype showed hosting is the expensive cell type, which is why text rows are native.
