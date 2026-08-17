# New Chat sheet: adaptive size + usage columns (Mac) — design

**Date:** 2026-08-12
**Status:** Approved (Dan: "yes sounds good")

## Goal

The Mac New Chat chooser (#133) stacks sessions + usage-limit lines under
each box name, in a sheet hard-coded to 480pt wide — with a dozen boxes it
reads as one long list. Two changes:

1. The sheet grows with the window when space is available.
2. Usage renders as aligned columns, one row per machine.

iOS keeps its stacked layout — right for narrow screens. Out of scope.

## 1. Adaptive sheet size

Mac sheets adopt only a rigid content frame (flexible frames collapse —
image-viewer lesson, 2026-08-12). So the sheet computes a rigid layout once,
from the presenting window's size, captured at presentation time:

- Call site (`MacChatListView`'s `.sheet`) passes
  `NSApp.keyWindow?.contentLayoutRect.size` into `MacNewChatSheet` — at that
  moment the key window is the window whose New Chat control was clicked.
  `nil` (no window, previews, tests) → today's exact dimensions.
- `MacNewChatSheet.layout(for windowSize: CGSize?) -> Layout` — pure static,
  unit-tested. `Layout` carries:
  - `width` = 70% of window width, clamped to 480…880; nil → 480.
  - `listMaxHeight` = 60% of window height, clamped to 300…650; nil → 360.
- The agent list uses `.frame(minHeight: 200, maxHeight: layout.listMaxHeight)`
  (today: max 360). The folder list grows too:
  `.frame(minHeight: 160, maxHeight: layout.listMaxHeight)` (today: fixed 160)
  — a widened sheet with a 160pt folder list would look vestigial.
- No live resize tracking: the size is frozen at open. Reopening adapts.

## 2. Usage columns

### Column model

- `LimitColumn: Equatable, Sendable, Identifiable { id: String, label: String }`
  in `MatronModels` next to `BoxCapacity`.
- `BoxCapacity.limitColumns(across capacities: [BoxCapacity]) -> [LimitColumn]`
  — union of `limitLines` ids in first-encounter order (caller passes
  capacities in the sorted-agents order, so the result is deterministic);
  label taken from the first line seen with that id. Pure, unit-tested.
- The Mac sheet computes columns from the connected agents' capacities in
  list order. Fleet-wide, so every row aligns to the same columns.

### Row layout (`MacAgentPickerRow`)

Fixed-width trailing cells inside the existing `List` rows — rows stay
whole-row buttons with native hover/scroll. (A SwiftUI `Grid` can't align
across separate `List` rows, and `Table`'s selection model fights the
button flow; fixed widths are the pragmatic Mac answer.)

- Box cell (flexible, as today): icon, name + account email, connection
  caption. The stacked `AgentCapacityRowContent` block is REMOVED from the
  Mac row (it stays for iOS).
- `Sessions` cell, 64pt: the live-session count (`liveSessions`), or `—`.
- One 108pt cell per `LimitColumn`: the percent in the shared threshold
  colour (`UsageMetersFormat.barColor`, green < 50 / orange < 80 / red ≥ 80,
  medium weight, monospaced digits), with the `BoxCapacity.resetText`
  caption beneath in `.caption2`/tertiary. A box lacking that line: `—`.
- Pending (fan-out in flight): `…` in every data cell, tertiary.
- Offline row: `—` in every data cell; name/last-seen caption unchanged.
- Chevron stays trailing on connected rows.
- Accessibility: each data cell gets a combined label
  ("<column label>, <percent> percent used, resets …" — same copy the
  stacked block used).

### Header row

Above the `List` (outside it, so it never scrolls away): `Machine` over the
flexible column, `Sessions`, then each column's `label`, `.caption2`
secondary, wrapped to at most 2 lines, widths matching the cells.

Shown only when there is anything to head: some capacity arrived or a
fan-out is pending. A fleet of old bridges (no capacity blocks at all)
renders exactly today's plain picker, headerless.

## Testing

- Unit: `layout(for:)` — nil, small (900×600 → 630×360), large
  (2000×1200 → 880 clamped, 650 clamped), tiny (500×400 → 480, 300 floors).
- Unit: `limitColumns(across:)` — union, first-encounter order, label from
  first occurrence, duplicate ids within one box not duplicated, empty in →
  empty out.
- Snapshot: re-record `NewChatSheetCapacitySnapshotTests` (row signature
  and layout change) — states: full capacity, second box missing one
  column's line, pending, old-bridge, offline — rendered with the header at
  a representative 700pt width.
- Full `swift test` (MatronShared) + Mac unit tests
  (`-only-testing:MatronMacTests`, `MATRON_APP_SUPPORT_OVERRIDE` set, per
  standing rule).

## Out of scope (YAGNI)

- iOS chooser changes.
- Sortable `Table`, column resizing, user column preferences.
- Live sheet resize while open; re-fan-out on resize.
- Any view-model / wire changes — `capacities`, `capacityPending`, and
  `BoxCapacity.parse` are untouched.
