# Mac Markdown Tables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render GFM pipe tables as real tables in the Mac timeline's selectable message renderer, with copy-time pipe-table reconstruction.

**Architecture:** Extend `MarkdownAttributed` (Apple markdown parse → flat `NSAttributedString` in one `NSTextView`) with a `tableCell` block kind that emits TextKit `NSTextTable`/`NSTextTableBlock` paragraphs; extend `MarkdownReconstruction` to rebuild pipe tables from the new semantics. No view or timeline changes — the live `NSTextView` auto-falls-back to TextKit 1 for table-bearing strings and then matches the TK1 measurement exactly (spike-verified).

**Tech Stack:** Swift / AppKit (TextKit 1 tables), XCTest + SnapshotTesting, SwiftPM (`MatronShared`).

**Spec:** `docs/superpowers/specs/2026-08-11-mac-markdown-tables-design.md` — read it first; it records the spike results this plan relies on.

## Global Constraints

- All code is Mac-only, inside existing `#if os(macOS)` files in `MatronShared/Sources/DesignSystem/`; tests in `MatronShared/Tests/DesignSystemSnapshotTests/`.
- Conversion must stay a pure, deterministic function of the markdown source — no `Date()`, no randomness, no dependence on view state. Any mutation of style/block objects must complete before `build(from:)` returns.
- The `account`-style omit conventions of other repos do NOT apply here; but the file's existing conventions DO: match the comment density and style of `MarkdownAttributed.swift` (constraint-explaining comments, not narration).
- Run unit tests with:
  `cd MatronShared && swift test --filter 'MarkdownAttributedTests|MarkdownCopyTests'`
- Run the full package suite before the final commit:
  `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`
  (snapshot baselines for other suites are appearance-sensitive on dev machines; the new snapshot test is exercised separately in Task 4).
- Never touch `~/Dev/matron-apple` (main clone) — all work happens in this worktree.

---

### Task 1: `tableCell` block classification

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift` (the `BlockKind` enum, ~line 397, and its `init`)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedTests.swift`

**Interfaces:**
- Produces: `BlockKind.tableCell(row: Int, column: Int, isHeader: Bool, columnCount: Int, alignments: [TableAlignment])` and `enum TableAlignment: Hashable { case left, center, right }` — Task 2 renders it, Task 3 reconstructs from it.

- [x] **Step 1: Write the failing tests** (semantics annotations are the observable surface for classification):

```swift
// MARK: - Tables

private let tableSource = """
| Repo | PR |
| :--- | ---: |
| bridge | **215** |
| apple | 133 |
"""

func test_tableCell_classifiedWithRowColumnHeader() {
    let attributed = convert(tableSource)
    let headAttrs = attributes(of: attributed, atFirst: "Repo")
    let headSemantics = headAttrs[MarkdownAttributed.semanticsKey] as? MarkdownRunSemantics
    guard case .tableCell(let row, let column, let isHeader, let columnCount, let alignments) = headSemantics?.block else {
        return XCTFail("header cell not classified as tableCell: \(String(describing: headSemantics?.block))")
    }
    XCTAssertEqual(row, 0)
    XCTAssertEqual(column, 0)
    XCTAssertTrue(isHeader)
    XCTAssertEqual(columnCount, 2)
    XCTAssertEqual(alignments, [.left, .right])

    let bodyAttrs = attributes(of: attributed, atFirst: "133")
    let bodySemantics = bodyAttrs[MarkdownAttributed.semanticsKey] as? MarkdownRunSemantics
    guard case .tableCell(let bRow, let bColumn, let bHeader, _, _) = bodySemantics?.block else {
        return XCTFail("body cell not classified as tableCell")
    }
    XCTAssertEqual(bRow, 2)
    XCTAssertEqual(bColumn, 1)
    XCTAssertFalse(bHeader)
}
```

- [x] **Step 2: Run to verify failure**

Run: `cd MatronShared && swift test --filter MarkdownAttributedTests/test_tableCell_classifiedWithRowColumnHeader`
Expected: FAIL — cells currently classify as `.paragraph`.

- [x] **Step 3: Implement.** Add to `MarkdownAttributed.swift`, near `BlockKind`:

```swift
/// Column alignment of a parsed table, mirrored from
/// `PresentationIntent.TableColumn.Alignment` so `BlockKind` stays
/// self-contained (and Hashable) for copy-time semantics.
enum TableAlignment: Hashable {
    case left, center, right

    init(_ column: PresentationIntent.TableColumn) {
        switch column.alignment {
        case .center: self = .center
        case .right: self = .right
        default: self = .left
        }
    }
}
```

Add the case to `BlockKind`:

```swift
/// One table cell. `row` is 0-based with the header row as row 0 (Apple
/// reports `tableHeaderRow` for the header and 1-based `tableRow` for
/// body rows, so the numbering lines up naturally). `columnCount` and
/// `alignments` ride on every cell so copy-time reconstruction can
/// rebuild the delimiter row from any selected cell.
case tableCell(row: Int, column: Int, isHeader: Bool,
               columnCount: Int, alignments: [TableAlignment])
```

In `BlockKind.init`, accumulate table components alongside the list vars and resolve them BEFORE the list fallback (a cell's components arrive as `tableCell` + `tableHeaderRow`/`tableRow` + `table`):

```swift
var cellColumn: Int?
var cellRow: Int?
var isHeaderRow = false
var tableColumns: [PresentationIntent.TableColumn]?
```

inside the component loop (new cases, no early return — the row/cell/table components arrive as siblings):

```swift
case .tableCell(let columnIndex):
    cellColumn = columnIndex
case .tableHeaderRow:
    cellRow = 0
    isHeaderRow = true
case .tableRow(let rowIndex):
    cellRow = rowIndex
case .table(let columns):
    tableColumns = columns
```

after the loop, before the `sawListItem` check:

```swift
if let cellColumn, let cellRow, let tableColumns {
    self = .tableCell(
        row: cellRow, column: cellColumn, isHeader: isHeaderRow,
        columnCount: tableColumns.count,
        alignments: tableColumns.map(TableAlignment.init)
    )
    return
}
```

Update the derived properties so the switch stays exhaustive and header cells render bold:

- `isBold`: `if case .tableCell(_, _, let isHeader, _, _) = self { return isHeader }` alongside the header case.
- `fontSize`, `foreground`, `marker`, `isCodeBlock`: fall into the existing defaults (base size, label, nil, false) — verify no `switch` without a default breaks.
- `paragraphStyle(for:)` in `MarkdownAttributed`: add a `.tableCell` case with `style.paragraphSpacing = 0` (the real cell style with `textBlocks` is built in Task 2; this keeps the function total).

- [x] **Step 4: Run the target tests**

Run: `cd MatronShared && swift test --filter 'MarkdownAttributedTests|MarkdownCopyTests'`
Expected: new test PASSES; all existing tests still pass (table sources previously fell to `.paragraph` — nothing else asserted on them).

- [x] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/MarkdownAttributed.swift MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedTests.swift
git commit -m "feat(mac): classify markdown table cells in MarkdownAttributed"
```

---

### Task 2: Emit `NSTextTable` blocks in the converter

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/MarkdownAttributed.swift` (`build(from:)`, ~line 158–274; styling constants ~line 29)
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedTests.swift`

**Interfaces:**
- Consumes: `BlockKind.tableCell` from Task 1.
- Produces: rendered strings where every table-cell character's `.paragraphStyle` has `textBlocks == [NSTextTableBlock]` with correct geometry; header cells bold with cell background; the string for a table-terminated message ends in exactly one `"\n"`.

- [x] **Step 1: Write the failing tests:**

```swift
private func tableBlock(
    _ attrs: [NSAttributedString.Key: Any],
    file: StaticString = #filePath, line: UInt = #line
) -> NSTextTableBlock? {
    let style = attrs[.paragraphStyle] as? NSParagraphStyle
    let block = style?.textBlocks.first as? NSTextTableBlock
    if block == nil { XCTFail("no NSTextTableBlock on run", file: file, line: line) }
    return block
}

func test_table_cellsCarryTableBlocks() {
    let attributed = convert(tableSource)

    guard let head = tableBlock(attributes(of: attributed, atFirst: "Repo")),
          let body = tableBlock(attributes(of: attributed, atFirst: "133")) else { return }

    XCTAssertEqual(head.table.numberOfColumns, 2)
    XCTAssertEqual(head.startingRow, 0)
    XCTAssertEqual(head.startingColumn, 0)
    XCTAssertEqual(body.startingRow, 2)
    XCTAssertEqual(body.startingColumn, 1)
    // Same NSTextTable instance spans the whole table.
    XCTAssertTrue(head.table === body.table)

    // Header row: bold + cell background. Body row: neither.
    let headFont = font(attributes(of: attributed, atFirst: "Repo"))
    XCTAssertTrue(headFont.fontDescriptor.symbolicTraits.contains(.bold))
    XCTAssertNotNil(head.backgroundColor)
    let bodyFont = font(attributes(of: attributed, atFirst: "apple"))
    XCTAssertFalse(bodyFont.fontDescriptor.symbolicTraits.contains(.bold))
    XCTAssertNil(body.backgroundColor)
}

func test_table_columnAlignmentMapsToParagraphAlignment() {
    let attributed = convert(tableSource) // columns are :--- and ---:
    let left = attributes(of: attributed, atFirst: "bridge")[.paragraphStyle] as? NSParagraphStyle
    let right = attributes(of: attributed, atFirst: "133")[.paragraphStyle] as? NSParagraphStyle
    XCTAssertEqual(left?.alignment, .left)
    XCTAssertEqual(right?.alignment, .right)
}

func test_table_lastRowCellsGetBottomMargin() {
    let attributed = convert(tableSource + "\n\nAfter.")
    guard let lastRow = tableBlock(attributes(of: attributed, atFirst: "apple")),
          let firstRow = tableBlock(attributes(of: attributed, atFirst: "bridge")) else { return }
    XCTAssertEqual(lastRow.width(for: .margin, edge: .maxY), 8)
    XCTAssertEqual(firstRow.width(for: .margin, edge: .maxY), 0)
}

func test_messageEndingInTable_keepsSingleTerminatorNewline() {
    let attributed = convert("Intro.\n\n" + tableSource)
    XCTAssertTrue(attributed.string.hasSuffix("133\n"),
                  "table cell terminator must survive the trailing trim: \(attributed.string.debugDescription)")
    XCTAssertFalse(attributed.string.hasSuffix("\n\n"))
    // The terminator itself is bound to the cell's table block.
    let terminatorAttrs = attributed.attributes(at: attributed.length - 1, effectiveRange: nil)
    XCTAssertNotNil((terminatorAttrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first)
}

func test_twoAdjacentTables_getSeparateTextTables() {
    let two = tableSource + "\n\n" + "| X |\n| --- |\n| y |"
    let attributed = convert(two)
    guard let first = tableBlock(attributes(of: attributed, atFirst: "bridge")),
          let second = tableBlock(attributes(of: attributed, atFirst: "y")) else { return }
    XCTAssertFalse(first.table === second.table)
    XCTAssertEqual(second.table.numberOfColumns, 1)
}

func test_inlineStylesInsideCells_keepAttributes() {
    let attributed = convert(tableSource)
    let bold = font(attributes(of: attributed, atFirst: "215"))
    XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
    // And still inside the table:
    XCTAssertNotNil(tableBlock(attributes(of: attributed, atFirst: "215")))
}

func test_size_tableSource_deterministicAndFillsWidth() {
    let attributed = convert(tableSource)
    let a = MarkdownAttributed.size(for: attributed, source: tableSource, width: 400)
    let b = MarkdownAttributed.size(for: attributed, source: tableSource, width: 400)
    XCTAssertEqual(a, b)
    XCTAssertGreaterThan(a.height, 0)
}
```

- [x] **Step 2: Run to verify failure**

Run: `cd MatronShared && swift test --filter MarkdownAttributedTests`
Expected: the new table tests FAIL (no textBlocks emitted yet); Task 1's classification test still passes.

- [x] **Step 3: Implement the table path in `build(from:)`.**

Add styling constants next to the existing ones:

```swift
/// Table chrome: hairline cell borders, compact padding, and the bottom
/// margin the LAST row carries so the table clears the following block
/// (a margin on the NSTextTable itself is ignored by layout — spike,
/// 2026-08-11).
private static let tableBorderWidth: CGFloat = 0.5
private static let tableCellPadding: CGFloat = 4
private static let tableBottomMargin: CGFloat = 8
```

Add mutable state before the run loop:

```swift
// In-progress table state. One NSTextTable spans consecutive tableCell
// blocks; a row/column that steps BACKWARD means a new markdown table
// started back-to-back with the previous one. `rowBlocks` remembers each
// row's cell blocks so the final row can get its bottom margin once the
// table's extent is known (cells stream through in order; the last row
// isn't knowable up front).
var currentTable: NSTextTable?
var currentRowBlocks: [Int: [NSTextTableBlock]] = [:]
var currentCellStyle: NSMutableParagraphStyle?
var previousCell: (row: Int, column: Int)?
```

Add two private helpers:

```swift
/// Closes the in-progress table: gives the last row's cells their bottom
/// margin. Must run before any non-table block is appended and at end of
/// input. Mutating the blocks after their runs were appended is safe —
/// paragraph styles reference the block objects, and layout reads them
/// after `build` returns.
func endTable() {
    guard !currentRowBlocks.isEmpty, let lastRow = currentRowBlocks.keys.max() else {
        currentTable = nil
        return
    }
    for block in currentRowBlocks[lastRow] ?? [] {
        block.setWidth(tableBottomMargin, type: .absoluteValueType, for: .margin, edge: .maxY)
    }
    currentTable = nil
    currentRowBlocks = [:]
    currentCellStyle = nil
    previousCell = nil
}
```

(Implement as a nested closure or private static func taking the state `inout` — match the file's style; a nested func over `var`s in `build` is simplest.)

```swift
/// NSTextAlignment for a parsed column alignment.
private static func nsAlignment(_ alignment: TableAlignment) -> NSTextAlignment {
    switch alignment {
    case .left: return .left
    case .center: return .center
    case .right: return .right
    }
}
```

Wire into the run loop:

1. **Block boundary (existing `intent != previousIntent` branch):** when the separator `"\n"` is appended and the PREVIOUS block was a `tableCell`, the newline is that cell's paragraph terminator — give it the cell's paragraph style and base font on top of the existing semantics-only attrs:

```swift
if case .tableCell = previousSemantics?.block ?? .paragraph, let currentCellStyle {
    separatorAttrs[.paragraphStyle] = currentCellStyle
    separatorAttrs[.font] = font(size: baseFontSize)
}
```

(Place before the `output.append` of the separator; keep the existing semantics assignment untouched.)

2. **On entering a new block** (right after the boundary handling, where `marker` is handled): if the new block is NOT a `tableCell` and a table is open, call `endTable()`. If it IS a `tableCell(row:column:isHeader:columnCount:alignments:)`:

```swift
// New table when none is open, or when the cell coordinates step
// backward (two tables back-to-back parse as adjacent cell runs).
if currentTable == nil
    || (previousCell.map { row < $0.row || (row == $0.row && column <= $0.column) } ?? false) {
    endTable()
    let table = NSTextTable()
    table.numberOfColumns = columnCount
    table.layoutAlgorithm = .automaticLayoutAlgorithm
    table.setContentWidth(100, type: .percentageValueType)
    currentTable = table
}
let block = NSTextTableBlock(
    table: currentTable!, startingRow: row, rowSpan: 1,
    startingColumn: column, columnSpan: 1
)
block.setWidth(tableBorderWidth, type: .absoluteValueType, for: .border)
block.setBorderColor(.separatorColor)
block.setWidth(tableCellPadding, type: .absoluteValueType, for: .padding)
if isHeader { block.backgroundColor = .controlBackgroundColor }
currentRowBlocks[row, default: []].append(block)
previousCell = (row, column)

let style = NSMutableParagraphStyle()
style.textBlocks = [block]
style.paragraphSpacing = 0
if column < alignments.count {
    style.alignment = Self.nsAlignment(alignments[column])
}
currentCellStyle = style
```

Guard: this "entering a new block" work must run once per block (on `intent != previousIntent`), not once per run — a cell with inline styling has several runs sharing one block.

3. **Appending cell runs:** after `runAttributes(...)` builds `attrs`, override the paragraph style for table cells:

```swift
if case .tableCell = block, let currentCellStyle {
    attrs[.paragraphStyle] = currentCellStyle
}
```

4. **After the run loop:** if the last block was a `tableCell`, append the terminating `"\n"` (cell style + base font + the last cell's semantics with `inline: []`, mirroring the separator convention), then call `endTable()`.

5. **Trailing trim:** the existing `while ... hasSuffix("\n")` loop must not eat a table terminator — stop when the final character's paragraph style has non-empty `textBlocks`:

```swift
while output.length > 0, output.string.hasSuffix("\n") {
    let attrs = output.attributes(at: output.length - 1, effectiveRange: nil)
    if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textBlocks.isEmpty {
        break // table-cell terminator — structural, not dead space
    }
    output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
}
```

- [x] **Step 4: Run the target tests**

Run: `cd MatronShared && swift test --filter 'MarkdownAttributedTests|MarkdownCopyTests'`
Expected: ALL pass, including `test_output_neverEndsWithNewline` (non-table sources still trim fully) and the existing size tests.

- [x] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/MarkdownAttributed.swift MatronShared/Tests/DesignSystemSnapshotTests/MarkdownAttributedTests.swift
git commit -m "feat(mac): render markdown tables as NSTextTable in the timeline"
```

---

### Task 3: Copy-time pipe-table reconstruction

**Files:**
- Modify: `MatronShared/Sources/DesignSystem/MarkdownReconstruction.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift`

**Interfaces:**
- Consumes: `BlockKind.tableCell` semantics laid down by Tasks 1–2.
- Produces: `MarkdownReconstruction.markdown(from:in:)` emits pipe tables for table selections.

- [x] **Step 1: Write the failing tests** (match the file's existing reconstruction-test style — build via `MarkdownAttributed.attributedString(for:)`, reconstruct the full range or a `range(of:)`-derived subrange):

```swift
func test_reconstruct_fullTable_roundTripsPipesAndAlignment() {
    let source = """
    | Repo | PR |
    | :--- | ---: |
    | bridge | **215** |
    | apple | 133 |
    """
    let attributed = MarkdownAttributed.attributedString(for: source)
    let rebuilt = MarkdownReconstruction.markdown(
        from: attributed, in: NSRange(location: 0, length: attributed.length))
    XCTAssertEqual(rebuilt, """
    | Repo | PR |
    | --- | ---: |
    | bridge | **215** |
    | apple | 133 |
    """)
}

func test_reconstruct_tableBetweenParagraphs_blankLineSeparated() {
    let source = "Before.\n\n| A | B |\n| --- | --- |\n| c | d |\n\nAfter."
    let attributed = MarkdownAttributed.attributedString(for: source)
    let rebuilt = MarkdownReconstruction.markdown(
        from: attributed, in: NSRange(location: 0, length: attributed.length))
    XCTAssertEqual(rebuilt, "Before.\n\n| A | B |\n| --- | --- |\n| c | d |\n\nAfter.")
}

func test_reconstruct_partialTableSelection_bestEffortRows() {
    let source = "| A | B |\n| --- | --- |\n| cc | dd |\n| ee | ff |"
    let attributed = MarkdownAttributed.attributedString(for: source)
    // Select from "cc" to the end — body rows only, no header.
    let start = (attributed.string as NSString).range(of: "cc").location
    let rebuilt = MarkdownReconstruction.markdown(
        from: attributed, in: NSRange(location: start, length: attributed.length - start))
    XCTAssertEqual(rebuilt, "| cc | dd |\n| ee | ff |")
}
```

Alignment note for the first test: a `:---` (left) column reconstructs as plain `---` — left is the default; only `center`/`right` carry colons. The expected string above encodes that choice.

- [x] **Step 2: Run to verify failure**

Run: `cd MatronShared && swift test --filter MarkdownCopyTests`
Expected: new tests FAIL (cells currently render as bare paragraphs).

- [x] **Step 3: Implement.** In `MarkdownReconstruction.markdown(from:in:)`, group the collected `blocks` into render units before the output loop:

```swift
private enum RenderUnit {
    case single(Block)
    case table([Block]) // consecutive tableCell blocks, in order
}

private static func units(from blocks: [Block]) -> [RenderUnit] {
    var units: [RenderUnit] = []
    for block in blocks {
        if case .tableCell = block.kind {
            if case .table(var cells)? = units.last {
                cells.append(block)
                units[units.count - 1] = .table(cells)
            } else {
                units.append(.table([block]))
            }
        } else {
            units.append(.single(block))
        }
    }
    return units
}
```

Render a table unit:

```swift
/// Pipe-table markdown from consecutive cell blocks. Cells join by `row`;
/// a header row is followed by the delimiter row rebuilt from the cells'
/// carried alignments (left is markdown's default and stays plain `---`).
/// Best-effort like the rest of this file: a selection that misses the
/// header just has no delimiter row; missing cells in a row are simply
/// absent.
private static func renderTable(_ cells: [Block]) -> String {
    var lines: [String] = []
    var currentRow: Int?
    var currentCells: [String] = []
    var headerInfo: [TableAlignment]?

    func flushRow() {
        guard !currentCells.isEmpty else { return }
        lines.append("| " + currentCells.joined(separator: " | ") + " |")
        if let alignments = headerInfo {
            let delimiters = alignments.map { alignment -> String in
                switch alignment {
                case .left: return "---"
                case .center: return ":---:"
                case .right: return "---:"
                }
            }
            lines.append("| " + delimiters.joined(separator: " | ") + " |")
            headerInfo = nil
        }
        currentCells = []
    }

    for cell in cells {
        guard case .tableCell(let row, _, let isHeader, _, let alignments) = cell.kind else { continue }
        if row != currentRow {
            flushRow()
            currentRow = row
        }
        currentCells.append(trimTrailingNewlines(inlineMarkdown(cell.segments))
            .trimmingCharacters(in: .whitespaces))
        if isHeader { headerInfo = alignments }
    }
    flushRow()
    return lines.joined(separator: "\n")
}
```

Rework the output loop to walk units: `.single` renders via the existing `render(_:)`/`separator(from:to:)`; `.table` renders via `renderTable` and joins to neighbouring units with `"\n\n"` (verbatim-adjacent units keep the existing `""` join). Adjust `separator` handling so it works on units — simplest: compute the separator from the LAST block of the previous unit and the FIRST block of the next, treating any table unit's boundary blocks as non-list, non-verbatim (i.e. blank line).

Also: the table-cell terminator newline runs (separator `"\n"`s carrying `tableCell` semantics with `inline: []`) arrive as segments of their cell's block — `trimTrailingNewlines` + `.trimmingCharacters(in: .whitespaces)` in `renderTable` strips them from cell text, which is why cell text needs no other newline handling.

- [x] **Step 4: Run the target tests**

Run: `cd MatronShared && swift test --filter 'MarkdownCopyTests|MarkdownAttributedTests'`
Expected: ALL pass (existing reconstruction tests unaffected — non-table sources produce only `.single` units and take the old path).

- [x] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/MarkdownReconstruction.swift MatronShared/Tests/DesignSystemSnapshotTests/MarkdownCopyTests.swift
git commit -m "feat(mac): reconstruct pipe tables on copy from the timeline"
```

---

### Task 4: Snapshot pin + full-suite verification

**Files:**
- Modify: `MatronShared/Tests/DesignSystemSnapshotTests/SelectableMessageTextSnapshotTests.swift`
- Create: committed baseline PNGs under `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/SelectableMessageTextSnapshotTests/`

**Interfaces:**
- Consumes: everything above via the public `SelectableMessageText`.

- [ ] **Step 1: Add the snapshot test** (mirror `test_richMessage`'s use of `assertVariants(of:named:)`):

```swift
func test_tableMessage() {
    let view = SelectableMessageText("""
    Release status:

    | Repo | PR | State |
    | :--- | :---: | ---: |
    | bridge | [#215](https://example.com) | **merged** |
    | apple | #133 | open |

    Merge order doesn't matter.
    """)
    .frame(width: 420)
    .padding()
    assertVariants(of: view, named: "tableMessage")
}
```

- [ ] **Step 2: Record the baseline** — run WITHOUT the skip flag so the new test records, then re-run to verify it passes against its own baseline:

Run: `cd MatronShared && swift test --filter SelectableMessageTextSnapshotTests/test_tableMessage`
Expected: first run records (fails with "recorded"), second run PASSES. Inspect the recorded PNG (open it) — it must show a bordered 3-column table with a shaded bold header row, a centered middle column, a right-aligned third column, a styled link, and normal paragraphs above and below. If the render is visibly wrong (e.g. no borders, cells stacked vertically), STOP and report — do not commit a wrong-looking baseline.

- [ ] **Step 3: Full-suite verification**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test`
Expected: 0 failures, and the log's executed-test count is at or above the pre-change count (do NOT let a grep pipeline mask a build failure — read the tail of the output).

- [ ] **Step 4: Commit**

```bash
git add MatronShared/Tests/DesignSystemSnapshotTests
git commit -m "test(mac): pin rendered markdown table snapshot"
```
