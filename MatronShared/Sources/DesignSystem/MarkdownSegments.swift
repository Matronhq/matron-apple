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
