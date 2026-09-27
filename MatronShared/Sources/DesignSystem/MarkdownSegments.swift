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
#endif
