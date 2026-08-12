#if os(macOS)
import AppKit

/// Rebuilds markdown source from a range of a `MarkdownAttributed`-rendered
/// string, driven by the `MarkdownRunSemantics` annotations laid down at build
/// time. Pure and deterministic: (attributed string, range) → markdown.
///
/// Best-effort by design: a partial selection inside a styled run wraps the
/// fragment; nesting/indentation flattened by rendering stays flat. The
/// full-selection case is handled upstream by `MessageCopyTextView`, which
/// copies the original source verbatim instead of calling this.
enum MarkdownReconstruction {

    static func markdown(from attributed: NSAttributedString, in range: NSRange) -> String {
        var blocks: [Block] = []

        attributed.enumerateAttribute(MarkdownAttributed.semanticsKey, in: range) { value, subrange, _ in
            let text = (attributed.string as NSString).substring(with: subrange)
            guard let semantics = value as? MarkdownRunSemantics else {
                // Unannotated text (parse-failure fallback) passes through
                // verbatim as its own pseudo-block.
                if blocks.last?.identity == Block.verbatimIdentity {
                    blocks[blocks.count - 1].segments.append(Segment(text: text, inline: [], link: nil))
                } else {
                    blocks.append(Block(
                        kind: .paragraph,
                        identity: Block.verbatimIdentity,
                        segments: [Segment(text: text, inline: [], link: nil)]
                    ))
                }
                return
            }
            let segment = Segment(text: text, inline: semantics.inline, link: semantics.link)
            if blocks.last?.identity == semantics.blockIdentity {
                blocks[blocks.count - 1].segments.append(segment)
            } else {
                blocks.append(Block(kind: semantics.block, identity: semantics.blockIdentity, segments: [segment]))
            }
        }

        var output = ""
        // `previous` tracks the last block of the previous unit, so the
        // separator rules keep working across a table (whose cells render as
        // one unit, not one block each).
        var previous: Block?
        for unit in units(from: blocks) {
            switch unit {
            case .single(let block):
                if let previous {
                    output += separator(from: previous, to: block)
                }
                output += render(block)
                previous = block
            case .table(let cells):
                guard let first = cells.first else { continue }
                if let previous {
                    output += separator(from: previous, to: first)
                }
                output += renderTable(cells)
                previous = cells.last
            }
        }
        return output
    }

    // MARK: - Model

    private struct Segment {
        let text: String
        let inline: MarkdownInlineFlags
        let link: URL?
    }

    private struct Block {
        /// Identity for coalescing unannotated pass-through text.
        static let verbatimIdentity = Int.min
        let kind: BlockKind
        let identity: Int
        var segments: [Segment]
    }

    /// A table's cells render together (they rebuild one pipe table), so
    /// blocks are grouped before rendering.
    private enum RenderUnit {
        case single(Block)
        /// One table's `tableCell` blocks, in document order.
        case table([Block])
    }

    /// Groups cells into tables on `BlockKind.tableCellContinues` — the same
    /// rule the renderer uses to open a new `NSTextTable`. Adjacent tables
    /// carry no separating block between them (the boundary newline is
    /// annotated as the previous cell's), so consecutive-cell grouping alone
    /// would fuse two rendered tables into one on copy.
    private static func units(from blocks: [Block]) -> [RenderUnit] {
        var units: [RenderUnit] = []
        var previousCell: (row: Int, column: Int)?
        for block in blocks {
            guard case .tableCell(let row, let column, _, _, _) = block.kind else {
                units.append(.single(block))
                previousCell = nil
                continue
            }
            if case .table(var cells)? = units.last,
               BlockKind.tableCellContinues((row, column), after: previousCell) {
                cells.append(block)
                units[units.count - 1] = .table(cells)
            } else {
                units.append(.table([block]))
            }
            previousCell = (row, column)
        }
        return units
    }

    // MARK: - Block rendering

    /// Consecutive list items are separated by a single newline (a blank line
    /// would split the markdown list); everything else gets a blank line.
    /// Verbatim pass-through blocks keep the newlines they carried, so they
    /// join with nothing.
    private static func separator(from previous: Block, to next: Block) -> String {
        if previous.identity == Block.verbatimIdentity || next.identity == Block.verbatimIdentity {
            return ""
        }
        if case .listItem = previous.kind, case .listItem = next.kind { return "\n" }
        return "\n\n"
    }

    private static func render(_ block: Block) -> String {
        if block.identity == Block.verbatimIdentity {
            return block.segments.map(\.text).joined()
        }

        // Code blocks reproduce their text verbatim inside fences — inline
        // flags never apply there (the mono font is block presentation).
        if case .codeBlock(let language) = block.kind {
            let body = trimTrailingNewlines(block.segments.map(\.text).joined())
            return "```\(language ?? "")\n\(body)\n```"
        }

        var text = trimTrailingNewlines(inlineMarkdown(block.segments))

        switch block.kind {
        case .header(let level):
            text = String(repeating: "#", count: level) + " " + text
        case .blockQuote:
            text = text
                .components(separatedBy: "\n")
                .map { "> " + $0 }
                .joined(separator: "\n")
        case .listItem:
            // The rendered marker is part of the text ("• " / "N. ").
            // Translate the bullet; ordered markers are already markdown. A
            // partial selection that missed the marker stays markerless.
            if text.hasPrefix("\u{2022} ") {
                text = "- " + text.dropFirst(2)
            }
        case .paragraph, .codeBlock, .tableCell:
            // Cells are re-joined into pipe rows by `renderTable`; a cell that
            // reaches here on its own renders as its bare text.
            break
        }
        return text
    }

    /// Pipe-table markdown from one table's cell blocks. Cells join by `row`;
    /// a header row is followed by a delimiter row rebuilt from the alignments
    /// carried by the header cells that were actually emitted (left is
    /// markdown's default and stays plain `---`).
    /// Best-effort like the rest of this file: a selection that misses the
    /// header just has no delimiter row, and missing cells are simply absent.
    private static func renderTable(_ cells: [Block]) -> String {
        var lines: [String] = []
        var currentRow: Int?
        var currentCells: [String] = []
        var headerAlignments: [TableAlignment]?

        func flushRow() {
            guard !currentCells.isEmpty else { return }
            lines.append("| " + currentCells.joined(separator: " | ") + " |")
            if let alignments = headerAlignments {
                let delimiters = alignments.map { alignment -> String in
                    switch alignment {
                    case .left: return "---"
                    case .center: return ":---:"
                    case .right: return "---:"
                    }
                }
                lines.append("| " + delimiters.joined(separator: " | ") + " |")
                headerAlignments = nil
            }
            currentCells = []
        }

        for cell in cells {
            guard case .tableCell(let row, let column, let isHeader, _, let alignments) = cell.kind else { continue }
            if row != currentRow {
                flushRow()
                currentRow = row
            }
            // A cell's segments include its terminator newline (same block
            // identity as the cell's text), so the trims here are what keep
            // cell text on one line.
            currentCells.append(
                trimTrailingNewlines(inlineMarkdown(cell.segments))
                    .trimmingCharacters(in: .whitespaces)
            )
            // One delimiter per EMITTED header cell, not one per table column:
            // a selection that clips the header row would otherwise produce a
            // delimiter row wider than the header row it delimits. Out-of-range
            // columns fall back to left, as the renderer does.
            if isHeader {
                let alignment = column < alignments.count ? alignments[column] : .left
                headerAlignments = (headerAlignments ?? []) + [alignment]
            }
        }
        flushRow()
        return lines.joined(separator: "\n")
    }

    private static func trimTrailingNewlines(_ text: String) -> String {
        var text = text
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: - Inline rendering

    /// Delimiter emission order: outermost first. Closing happens in reverse.
    private static let delimiterOrder: [(flag: MarkdownInlineFlags, delimiter: String)] = [
        (.bold, "**"),
        (.italic, "*"),
        (.strikethrough, "~~"),
        (.code, "`"),
    ]

    /// Streams segments through an open-delimiter stack so nested styles emit
    /// properly nested markdown (`**bold *both* bold**`) instead of broken
    /// adjacent pairs (`**bold ***both*** bold**`). Whitespace at style edges
    /// is shifted outside the delimiters — `** bold**` doesn't parse.
    private static func inlineMarkdown(_ segments: [Segment]) -> String {
        var output = ""
        var open: [MarkdownInlineFlags] = []

        func close(downTo keep: Int) {
            while open.count > keep {
                let flag = open.removeLast()
                let delimiter = delimiterOrder.first { $0.flag == flag }!.delimiter
                // Shift trailing spaces/tabs outside the closing delimiter.
                var trailing = ""
                while let last = output.last, last == " " || last == "\t" {
                    trailing = String(output.removeLast()) + trailing
                }
                output += delimiter + trailing
            }
        }

        for segment in segments {
            if let link = segment.link {
                // A link renders as its own unit; close everything first so
                // the bracket never splits an emphasis span.
                close(downTo: 0)
                output += "[\(segment.text)](\(link.absoluteString))"
                continue
            }

            let target = delimiterOrder.map(\.flag).filter { segment.inline.contains($0) }
            let common = zip(open, target).prefix { $0 == $1 }.count
            close(downTo: common)

            var text = segment.text
            for flag in target.dropFirst(open.count) {
                // Shift leading whitespace outside the opening delimiter.
                while let first = text.first, first == " " || first == "\t" {
                    output += String(text.removeFirst())
                }
                output += delimiterOrder.first { $0.flag == flag }!.delimiter
                open.append(flag)
            }
            output += text
        }
        close(downTo: 0)
        return output
    }
}
#endif
