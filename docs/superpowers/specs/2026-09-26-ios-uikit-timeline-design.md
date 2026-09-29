# #3199 — iOS chat scroll lag: measured cause and UICollectionView timeline design

## 1. Measured cause

The rig: iPhone 17 simulator (60 Hz), Release (-O) build of main 3900414d plus throwaway probe flags. The Coordinator chat is seeded with 220 long markdown messages full of links. A CADisplayLink auto-scroll runs for 15 s. Metric: app CPU seconds (mean of 3 runs), plus hitch ms/s.

| Variant (150 pt/frame fling) | CPU s | Hitch ms/s |
|---|---|---|
| **Baseline** (eager VStack, 120 rows, MarkdownUI) | **3.30** | ~0–3 |
| No text selection / no shadow / no context menu / no scrollTargetLayout | 3.17–3.46 | ~0 |
| Plain `Text(AttributedString)` instead of MarkdownUI | 2.22 | 0 |
| Window 40 rows instead of 120 | **0.91** | 0 |
| LazyVStack | 4.70 | **125** |

- **Release vs Debug makes no difference.** The cost is inside SwiftUI, not our code.
- **Where the main thread goes** (`sample` of the baseline):
  - 44% in the update cycle.
  - `GraphHost.runTransaction` 34%, of which AttributeGraph `Subgraph::update` is 21% and `propagate_dirty` 13%.
  - `ScrollViewCommitMutation.apply` 12.5%.
  - `_UIHostingView` render 12%.
  - Our code is about 0%: no body re-evaluations, and CoreText is not near the top.
- **Diagnosis:** every scroll frame runs a SwiftUI transaction whose cost grows with the number of mounted views. MarkdownUI turns each message into dozens of views (paragraphs, list items, link runs).
  - Shadows, selection, context menus and geometry modifiers are noise.
  - The eager 120-row window cannot be tuned away: shrinking it brings back the blank-chat estimation risk, and going lazy is worse.

### Prototype: UICollectionView with reuse (probe-only)

| 15 s run | 150 pt/frame CPU / hitch | 25 pt/frame (reading) CPU / hitch | Main-thread busy (sampled) |
|---|---|---|---|
| Baseline SwiftUI | 3.30 / ~0 | 4.02 / 0 | 2300 ms |
| Cells with `UIHostingConfiguration(TimelineItemView)` | 4.0 / **130** | 2.74 / **101** | 1163 ms |
| Cells with TextKit 2 `UITextView` + cached attributed string | **2.28** / 44 | **2.12** / 40 | **814 ms** |
| Hosting cells, unlimited window | 6.17 / 208 | — | — |

What cells must avoid:
- **MarkdownUI inside hosting cells.** Each new cell spends about 30 ms in `UIHostingContentView.systemLayoutSizeFitting`, which shows up as the hitches.
- **Auto Layout self-sizing on the scroll path.** The TextKit cell's remaining hitches are all first-time `systemLayoutSizeFitting` and TextKit layout when a cell comes on screen.

Therefore the design uses TextKit text cells with heights measured ahead of time and cached, manual layout, and no estimated heights.

## 2. Design

**Choice: UICollectionView with a custom `TimelineLayout`, not UITableView.**
- The custom layout owns exact content height and `contentOffsetAdjustment` in its invalidation contexts, so a prepend doesn't move the content on screen.
- Diffable data source plus `reconfigureItems` updates the streaming row in place.
- Table views estimate row heights by design, and estimated content height is the root of the blank-chat history.

**Structure**
- `ChatTimelineController` is a UIViewController hosted by `UIViewControllerRepresentable` in `ChatView`, in place of the `ScrollViewReader`/`ScrollView` block.
- It reads the unchanged `ChatViewModel` API (`windowedRows`, `pendingFocusID`, `extendHistoryWindow`, `revealNewerHistory`, `activityLabel`) through `withObservationTracking`.
- **Pure-logic core: `TimelineScrollModel`**, a struct with no UIKit. It covers the height cache, anchor math and the follow-tail state, so it can be unit-tested.

**Cell content**
- **`TextMessageCell`** (text, the dominant kind):
  - A TextKit 2 `UITextView`, selectable and not editable.
  - The attributed string comes from a UIKit port of `MarkdownAttributed`, which the Mac already uses. It will share one source via platform font/color typealiases.
  - Code blocks and tables become block segments: code uses its own monospaced text view with a copy button; tables use a small hosted grid.
  - The conversation pill row (`ConversationLinkPillRow`) is a hosted segment whose height is measured once.
  - Timestamp and send state are drawn in UIKit.
  - Link taps use `textView(_:primaryActionFor:defaultAction:)` and route through the existing `MarkdownText.handle` / `MatronItemLink` policy (items, convos, http).
  - Copy goes through `collectionView(_:contextMenuConfigurationForItemsAt:)`.
  - Partial text selection works natively, which is better than SwiftUI's `textSelection`.
- **`HostedRowCell`** covers the rarer kinds, all with cached sizes:
  - Tool calls, diffs, ask-user cards, agent-chat/agent-spawn cards, item/milestone markers, date separators and subtask cards.
  - These use `UIHostingConfiguration` with the existing SwiftUI views.
  - Size is measured once per row value and width, then cached.
- **Images:** height comes from `imagePixelSize` or a placeholder aspect ratio. When the image resolves, only that row is invalidated, with an anchor-preserving offset adjustment.

**Self-sizing and height cache**
- Heights are computed by `TimelineMeasurer`: TextKit layout of the cached attributed string at the column width.
- The cache key is (row id, content hash, width, Dynamic Type size).
- Precompute runs off the main thread when the window changes and synchronously on a miss, never through Auto Layout.
- The layout always knows exact content height, which is the property that made the eager VStack cure the blank chat.

**Bottom anchoring and new messages**
- `isFollowingTail` works as today:
  - Set false on `scrollViewWillBeginDragging`.
  - Set true on settling within 100 pt of the bottom, on your own send, and on the jump button.
- While following, every layout pass that changes content height ends with `contentOffset = maxOffset`, inside `prepare()`/invalidation, not animated and not deferred.
- When not following, the anchor is (first visible row id, offset within it), re-applied after every snapshot apply.

**Streaming last message**
- The `eph:` row is reconfigured in place and re-measured, coalesced to one update per display frame.
- If following, it stays pinned in the same pass.
- The activity indicator stays a footer outside the anchor space (lesson from round 5).

**Jumps (seq, search, milestone)**
- Sequence: `pendingFocusID` → `ensureWindowContains` → apply → read the exact frame from the layout → stop deceleration (zero-delta `setContentOffset`) → set the offset to the row top → flash-highlight the cell.
- No retry timers are needed because nothing is estimated.

**Pagination and window**
- When not following and within 1.5 screens of the top, call `extendHistoryWindow()`. The prepend preserves the anchor through `contentOffsetAdjustment`.
- Mounted cost is now proportional to visible rows, so the 120/360 window becomes a memory and measurement bound only.
- Phase 1 keeps today's window values so the view model behaves identically. Phase 2 raises the cap (for example 1000) once the flag has soaked.

**Scroll restoration**
- `ChatScrollPositionMemory` gains an optional in-row offset.
- On open: restore to (id, offset) if the id is still in the window, else to the bottom. The existing transient-id rejection is kept.

**Keyboard (#241 guide composer)**
- `ChatKeyboardAvoidance` stays the only keyboard mechanism: the controller's frame shrinks as the composer rides the guide.
- In `viewDidLayoutSubviews`, a bounds-height change keeps the bottom pinned while following. Otherwise it keeps the bottom-visible row fixed, the way Messages does.
- `keyboardDismissMode = .interactive` and `contentInsetAdjustmentBehavior = .never`.

**Why the blank-chat bug can't come back**
- Its causes were:
  - The `.scrollPosition` write-back clobber.
  - Animated `scrollTo` over estimated layout.
  - Lazy estimated content height swinging from 41K to 494K pt.
- In the new design:
  - There are no SwiftUI scroll APIs, no estimates and no animated programmatic scrolls.
  - One owner writes `contentOffset`.
  - Anchors resolve by row id against the current snapshot, with the existing nearest-survivor rescue.
- Invariant check after each apply: if there are rows but no visible cells, log a breadcrumb and snap to the bottom.

## 3. Feature flag

- `@AppStorage("chat.timeline.uikit")`, with a Settings ▸ Advanced toggle.
  - On by default in every build, App Store included (Dan, 2026-09-28, tracker #3954). The first plan kept App Store builds off for one release.
  - Off is the current SwiftUI path, untouched; it is deleted two releases later.
- Both paths consume the same view model. The Mac is untouched.

## 4. Test plan

- **Unit tests (`TimelineScrollModel`, fake measurer):**
  - prepend keeps the anchor exactly
  - follow-tail pin on growth
  - unpinned growth above the viewport doesn't move content
  - jump offset math
  - keyboard resize while pinned or unpinned
  - vanished-anchor rescue
  - cache invalidation on width or Dynamic Type change
- **Renderer tests:** UIKit markdown parity with Mac `MarkdownAttributed` (headings, lists, quotes, code, tables, `[label]:` escape), plus link-policy routing.
- **Snapshot tests** for `TextMessageCell` and pills, in light and dark.
- **UI tests:**
  - opens at the bottom
  - send keeps the tail visible
  - streaming reply stays pinned
  - scrolling up to the top pages in without a jump
  - search/milestone jump lands the row at the top
  - keyboard up/down with the composer
  - room switch restores position
  - a link tap opens an item or conversation
- **Performance gate (this rig):**
  - Targets: ≤1.0 s CPU and 0 hitches at 25 pt/frame, and at most one hitch per second at 150 pt/frame.
  - Then a device pass on Dan's iPhone (120 Hz) with signposts, and a blank-chat soak with the `chat.matron` breadcrumbs.

## 5. Tasks (rough sizes)

1. UIKit port of `MarkdownAttributed` (shared source) plus block segments for code and tables — **L, 3–4 d**
2. `TimelineMeasurer` and height cache, with background precompute — **M, 2 d**
3. `TimelineLayout` and `TimelineScrollModel` (anchor, follow-tail, prepend) with unit tests — **L, 3 d**
4. Controller, representable, diffable bridge and streaming reconfigure — **M, 2 d**
5. `TextMessageCell` (links, selection, context menu, send state, pills) — **L, 3 d**; `HostedRowCell` with cached sizing — **M, 1.5 d**
6. Jumps, search, milestones, pagination, restore and keyboard wiring — **M, 2–3 d**
7. Flag, Settings toggle, breadcrumbs and invariant — **S, 0.5 d**
8. UI tests, performance gate and device soak — **M, 2–3 d**

**Total ≈ 3.5–4 weeks.**

**Main risk:** rendering parity between TextKit and MarkdownUI. The Mac renderer already solved most of it, but tables need their own segment on iOS because there is no `NSTextTable`.
