# Mac timeline: render markdown tables properly

**Date:** 2026-08-11
**Status:** Approved (Dan, 2026-08-11 — "sure")

## Problem

Pipe tables in chat messages render properly on iOS (MarkdownUI draws real
tables) but not on the Mac timeline. The Mac renders message bodies through
`MarkdownAttributed` — Apple's `AttributedString(markdown:)` mapped onto a
flat `NSAttributedString` inside a single selectable `NSTextView`
(`SelectableMessageText`) — and that converter has no table case. Apple's
parser fully parses GFM pipe tables (verified: runs carry `tableCell N`,
`tableRow N` / `tableHeaderRow`, and `table [columns with alignments]`
presentation-intent components), but `BlockKind.init` falls through to
`.paragraph`, so each cell renders as its own block-separated line — a
vertical spill of cell text.

## Approach

Render real tables **inside the same flat attributed string** using TextKit's
`NSTextTable` / `NSTextTableBlock`. This keeps the single-`NSTextView`
architecture (whole-message drag selection, deterministic height measurement)
intact — no view interleaving, no timeline layout changes.

Spike-verified: an `NSTextTable`-backed attributed string lays out in the
existing standalone TextKit-1 measurement stack (`NSLayoutManager` +
`ensureLayout` + `usedRect`) and measures deterministically across repeated
calls at multiple widths. Also spike-verified: the live `NSTextView`
(TextKit 2 by default) will fall back to TextKit 1 on its own when its
storage contains table blocks — `textLayoutManager` becomes nil — and the
rendered height then matches the TK1 measurement exactly (132.0 == 132.0 in
the spike). That automatic fallback is background behaviour only, not the
path taken: it fires just once the view is in a window, and the re-layout it
triggers keeps the view's top edge, shifting the view's origin off the frame
SwiftUI gave it. `SelectableMessageText` therefore opts in explicitly, before
first layout (see Scope). Messages containing a table render wholly via
TextKit 1; messages without tables keep today's TextKit 2 path.

Rejected alternatives: interleaving SwiftUI grids between text segments
(breaks single-drag selection — the reason this renderer exists — and
reintroduces multi-view height churn); rendering tables as aligned monospaced
text (still "not properly").

## Scope

Mac-only, all in `MatronShared`:

- `Sources/DesignSystem/MarkdownAttributed.swift` — table conversion + styling
- `Sources/DesignSystem/MarkdownReconstruction.swift` — copy-time pipe-table rebuild
- `Sources/DesignSystem/SelectableMessageText.swift` — selects TextKit 1 for
  table-bearing messages (`useTextKit1IfTabled`, called before the attributed
  string is assigned in both `makeNSView` and `updateNSView`)
- `Tests/DesignSystemSnapshotTests/` — unit + snapshot coverage

No iOS, bridge, journal, or timeline-view changes. `MacTimelineItemView` is
untouched.

## Design

### Block classification

`BlockKind` gains one case:

```swift
case tableCell(row: Int, column: Int, isHeader: Bool,
               columnCount: Int, alignments: [TableAlignment])
```

with a small supporting enum:

```swift
enum TableAlignment: Hashable { case left, center, right }
```

- `row` is 0-based with the header row as row 0 (Apple reports
  `tableHeaderRow` for the header and `tableRow N` (1-based) for body rows —
  map header → 0, body → N).
- `column` is the 0-based `tableCell` index.
- `columnCount` and `alignments` are read from the `table` component's
  columns array (alignment defaults to `.left` when unspecified). They ride
  on every cell so copy-time reconstruction can rebuild the delimiter row
  from any selected cell without out-of-band state.
- `BlockKind.init` checks for `tableCell`/`tableHeaderRow`/`tableRow`/`table`
  components before the list checks. A run with table components but no
  usable cell/row info (defensive) stays `.paragraph`.

Derived properties: `fontSize` = base; `isBold` = true for header cells;
`foreground` = label; `marker` = nil; `isCodeBlock` = false.

### Conversion (`build(from:)`)

Table cells flow through the existing run loop — each cell is a distinct
`presentationIntent` identity, so the existing block-boundary logic already
separates cells and bumps `blockIdentity` per cell. Table-specific handling:

- **One `NSTextTable` per markdown table.** A table is "the maximal run of
  consecutive `tableCell` blocks"; a new table starts when a `tableCell`
  block follows a non-table block. `numberOfColumns` from `columnCount`,
  `layoutAlgorithm = .automaticLayoutAlgorithm`, content width 100%.
- **One `NSTextTableBlock` per cell** (`startingRow: row, rowSpan: 1,
  startingColumn: column, columnSpan: 1`), attached via the cell paragraph
  style's `textBlocks`. All runs of the same cell share one block instance.
- **Cell paragraphs must be newline-terminated** — TextKit requires it. The
  block-boundary separator already appends `"\n"` between blocks; the
  separator between two cells must carry the *previous cell's* paragraph
  style (with its `textBlocks`) in addition to the existing semantics-only
  attributes, or the cell's paragraph isn't bound to its table block. The
  final trailing-newline trim at the end of `build` must NOT trim into a
  table: when the last block is a `tableCell`, leave exactly one trailing
  newline (the cell terminator) in place.
- **Cell alignment:** paragraph style `alignment` from the cell's column
  alignment (left/center/right).
- **Inline content inside cells** (bold, italic, code, links) reuses
  `runAttributes` unchanged — table cells only add the paragraph-style
  table block, alignment, and header-bold on top.

### Styling

- Header row: bold, `NSColor.controlBackgroundColor` cell background
  (via `NSTextTableBlock.setBackgroundColor` so it fills the cell, not just
  the glyph runs).
- All cells: 0.5pt border in `NSColor.separatorColor`, 4pt padding on all
  edges, via the table block's `setWidth(_:type:for:)` / `setBorderColor`.
- Cell text: body size (`baseFontSize`), no paragraph spacing inside cells
  (`paragraphSpacing = 0` — row height comes from padding).
- The table as a whole reads as one block: the block *after* a table gets
  the normal `"\n"` separator, and the gap below the table comes from an
  8pt bottom **margin on the last row's cell blocks** (`setWidth(8, ...,
  for: .margin, edge: .maxY)`). Spike-verified: a margin set on the
  `NSTextTable` itself is ignored by layout; last-row cell margins measure
  correctly (+8pt); cell `paragraphSpacing` only grows the cell interior. A bubble containing a table spans the
  available width (tables fill their container, like GitHub); that is
  accepted behaviour, not a bug.

### Copy-time reconstruction

`MarkdownRunSemantics` carries the new `BlockKind` case automatically (it
stores a `BlockKind`). `MarkdownReconstruction` gains a table pass:

- Consecutive `tableCell` blocks are grouped; cells with the same `row` join
  as `| a | b | c |` (cell text rendered through the existing
  `inlineMarkdown` so bold/links survive).
- After a row with `isHeader == true`, emit the delimiter row from
  `alignments` (`---`, `:---:`, `---:`).
- Rows join with `"\n"`; the table joins to neighbouring blocks with the
  standard blank line.
- Partial selections stay best-effort (matching the file's contract): the
  selected cells of a row still join with pipes; a selection that misses the
  header simply produces a table without a delimiter row. No attempt to pad
  columns or fill unselected cells.
- Full-message copy is unaffected — `MessageCopyTextView` already copies the
  original source verbatim.

### Sizing & caching

No changes to `size(for:source:width:)`, the size cache, or the conversion
cache — conversion stays a pure function of source. Streaming messages
re-convert per delta as today; a half-streamed table renders as paragraphs
until the header + delimiter lines have arrived, then snaps into a table
(same class of reflow as any streaming markdown).

## Testing

All in `MatronShared/Tests/DesignSystemSnapshotTests` (existing target):

- `MarkdownAttributedTests`: table source → cells carry `NSTextTableBlock`s
  with correct row/column/columnCount; header cells bold, body cells not;
  column alignments map to paragraph alignment; message ending in a table
  keeps the terminating newline (and one ending in a paragraph still trims);
  inline bold/link inside a cell keeps its attributes; `size` for a table
  source is deterministic across repeated calls.
- `MarkdownCopyTests`: reconstruction of a full table selection round-trips
  to a pipe table with delimiter row and alignment colons; partial selection
  (subset of rows) produces pipe rows without crashing; inline styling
  inside cells survives.
- `SelectableMessageTextSnapshotTests` (or sibling): one snapshot pinning a
  rendered table (header + 2 rows, mixed alignment, an inline-bold and a
  link cell) at a fixed width. Snapshot runs need
  `MATRON_APP_SUPPORT_OVERRIDE` discipline per repo test docs.
