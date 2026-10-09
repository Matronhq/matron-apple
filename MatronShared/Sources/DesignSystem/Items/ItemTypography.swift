import SwiftUI
import MarkdownUI

/// Type and measure for the tracker item reading surface (`ItemDetailView`
/// and `ItemCommentComposer`). One place for the numbers so the body card,
/// the comment cards, the pending rows and the composer cannot drift apart.
///
/// The item thread is a reading surface, not a chat: a filed question is
/// often several paragraphs, read once on a wide Mac window. So it gets a
/// size a step above the chat message scale, more generous leading, and a
/// capped, centred column instead of stretching across the window.
public enum ItemTypography {
    #if os(macOS)
    /// ×1.25 ⇒ ≈16pt on macOS (13pt base). A step above the Mac chat
    /// timeline's 14.3pt (`MarkdownAttributed.baseFontSize`) — the chat
    /// scale was walked down for a stream of short turns; a thread of
    /// paragraphs wants a reading face. (×1.40 ≈ 18pt was tried on
    /// 2026-09-14 once the theme actually rendered; it read as too
    /// big, so this is the settled size.)
    static let bodyScale: CGFloat = 1.25
    /// Extra leading between wrapped lines, on top of the font's own.
    public static let lineSpacing: CGFloat = 4
    /// The item title, a step above the body: 22pt semibold on the Mac.
    public static let titleFont: Font = .title.weight(.semibold)
    /// Author / date captions on a card — 12pt/11pt, so they don't read
    /// as footnotes beside a 16pt body.
    public static let captionFont: Font = .callout
    public static let captionDetailFont: Font = .subheadline
    #else
    /// ≈18pt on iOS/iPad — see `phoneBodyScale`.
    static let bodyScale: CGFloat = phoneBodyScale
    public static let lineSpacing: CGFloat = 3
    public static let titleFont: Font = .title2.weight(.semibold)
    public static let captionFont: Font = .caption
    public static let captionDetailFont: Font = .caption2
    #endif

    /// ×1.06 ⇒ ≈18pt on iOS/iPad (17pt base), Dynamic-Type scaled like
    /// the rest of the body (`ItemDetailView.scaledBodySize`,
    /// `Theme.matronItem`). Chat bodies there stay at the 17pt system size
    /// by decision; the item thread is the one surface that
    /// reads a step above it. It was ×1.18 ≈ 20pt (the old iOS chat
    /// multiplier, reused) until 20pt read as "a bit big"
    /// on the iPhone, so it came down one notch.
    ///
    /// Declared on every platform so the Mac-hosted SPM suite can pin it
    /// (`ItemTypographyScaleTests`); only the iOS branch of `bodyScale`
    /// reads it.
    static let phoneBodyScale: CGFloat = 1.06

    /// Gap after each markdown paragraph inside a body — a real paragraph
    /// break, not just a wrapped line, so multi-paragraph items read as
    /// prose rather than a wall.
    static let paragraphSpacing: CGFloat = 14

    /// Widest a markdown table cell grows before its text wraps. Columns
    /// otherwise size to their content, and a table wider than the card
    /// scrolls sideways (`Theme.matronItem`'s `.table`) — so a long cell
    /// wraps into a readable block instead of stretching into one line.
    static let tableCellMaxWidth: CGFloat = 280

    /// Maximum width of the thread column. At ≈16pt this is roughly
    /// 70–75 characters per line (the classic 65–75 measure); wider than
    /// this the eye loses the line start on the way back. The column is
    /// centred in the detail view when there is more room than this.
    public static let measure: CGFloat = 640

    /// Vertical gap between thread rows (header, body card, comments).
    static let threadSpacing: CGFloat = 18
    /// Inner padding of a body/comment card.
    static let cardPadding: CGFloat = 14

    /// MarkdownUI's base body size — `FontProperties.defaultSize`, the
    /// point size its `.em` font sizes resolve against before Dynamic
    /// Type scaling. Plain `Text` beside a markdown body must start from
    /// the same base (and scale the same way, via `@ScaledMetric
    /// (relativeTo: .body)` on the view) or the two drift apart at any
    /// non-default text size.
    static let baseSize: CGFloat = {
        #if os(macOS)
        return 13
        #else
        return 17
        #endif
    }()
}

public extension Theme {
    /// Item-thread variant of `.matron`: the `ItemTypography` body size
    /// plus a real paragraph gap. Pair with `ItemTypography.lineSpacing`
    /// on `MarkdownText` for the leading.
    ///
    /// The size is given in POINTS, never `.em`. MarkdownUI 2.x applies
    /// `theme.text` on the outside and then re-applies its own base size
    /// as an absolute `FontSize` just inside it (`ScaledFontSizeModifier`,
    /// `Markdown.body`), and an absolute `FontSize` resets the relative
    /// `scale` to 1 — so `FontSize(.em(x))` in a theme's `.text` style is
    /// silently ignored. (That is why `Theme.matronMessage`'s `.em` scale
    /// never took effect either.) An absolute size survives: the modifier
    /// reads it back and re-applies it through a `@ScaledMetric
    /// (relativeTo: .body)`, so Dynamic Type still scales it on iOS.
    /// `ItemTypographyRenderTests` pins that the rendered text is
    /// actually larger than the base.
    static let matronItem: Theme = matron
        .text {
            FontFamily(.system(.default))
            ForegroundColor(.primary)
            FontSize(ItemTypography.baseSize * ItemTypography.bodyScale)
        }
        // Symmetric on purpose: MarkdownUI spaces neighbouring blocks by
        // the larger of the two facing margins, and no other block style
        // in `.matron` sets one, so a bottom-only margin would leave a
        // paragraph flush against the code fence or list above it while
        // gapped from the one below. `max` means paragraph→paragraph is
        // still one gap, not two.
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: ItemTypography.paragraphSpacing, bottom: ItemTypography.paragraphSpacing)
        }
        // GFM tables. MarkdownUI's default is a bare grid squeezed into the
        // card width: no inner rules, no cell padding, and on a phone four
        // columns broke their words mid-word ("snapshotte / d") — it read
        // as broken ASCII. Columns now size to their content (capped per
        // cell, see `ItemTableCellWidth`) and a table wider than the card
        // scrolls sideways. Chrome matches the iOS chat table
        // (`MarkdownTableGrid`): a hairline border on every cell and a 5%
        // tint on the header row.
        //
        // The grid is our own (`ItemTableGrid`), built from the table's
        // markdown, and MarkdownUI's (`configuration.label`) is never put
        // on screen. Its table has every cell publish an anchor and
        // resolves all of them in two geometry readers, for its borders and
        // row backgrounds, and they are resolved again whenever the table
        // moves: each scroll frame of a thread re-measured every cell of
        // every table in it, on screen or not. `ItemTableScrollCostTests`.
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                ItemTableGrid(table: ItemTable.parsed(forTableMarkdown: configuration.content.renderMarkdown()))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .markdownMargin(top: ItemTypography.paragraphSpacing, bottom: ItemTypography.paragraphSpacing)
        }
}

/// A GFM table as a grid of `ItemTableCell`s, with no rules or backgrounds
/// of its own: each cell draws its border and tint.
struct ItemTableGrid: View {
    let table: ItemTable.Parsed

    var body: some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(table.cells.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.cells[row].indices, id: \.self) { column in
                        ItemTableCell(content: table.cells[row][column], isHeader: row == 0,
                                      alignment: table.alignments[column])
                    }
                }
            }
        }
        .padding(Self.gap)
    }

    /// Between neighbouring cells' borders and round the table, as
    /// MarkdownUI's grid leaves for its own (here undrawn) rules.
    static let gap: CGFloat = 1
}

/// One `Theme.matronItem` table cell: natural width capped at
/// `ItemTypography.tableCellMaxWidth`, header row semibold and tinted, a
/// hairline border, and the text placed by its column's GFM alignment
/// (`:---` leading, `:---:` centre, `---:` trailing) at the top of the row.
/// The text is the cell's own markdown through the enclosing theme, so its
/// code, links and emphasis look as they do in the paragraphs round it.
struct ItemTableCell: View {
    let content: MarkdownContent
    let isHeader: Bool
    let alignment: ItemTableColumnAlignment

    var body: some View {
        ItemTableCellWidth(maxWidth: ItemTypography.tableCellMaxWidth) {
            Markdown(content)
                .markdownTextStyle {
                    if isHeader { FontWeight(.semibold) }
                }
                .multilineTextAlignment(alignment.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        // Fill the grid cell so a short cell sits at the top of a row a
        // wrapped neighbour made tall (not floating in its middle), and its
        // border and tint cover the whole cell.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
        .background(isHeader ? Color.primary.opacity(0.05) : Color.clear)
        .border(Color.primary.opacity(0.18), width: 0.5)
    }
}

/// A GFM table read back from its markdown (MarkdownUI's `renderMarkdown()`
/// of the table block): the header row, then the body rows, every row with
/// one cell per column.
struct ItemTable: Equatable {
    var alignments: [ItemTableColumnAlignment]
    var rows: [[String]]

    init(tableMarkdown markdown: String) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var alignments = ItemTableColumnAlignment.columns(ofTableMarkdown: markdown)
        var rows = lines.enumerated().filter { $0.offset != 1 || alignments.isEmpty }.map { Self.cells(ofRow: $0.element) }
        // No delimiter row (not a table's markdown after all): every line
        // is a row, every column leading.
        let columns = alignments.isEmpty ? (rows.map(\.count).max() ?? 0) : alignments.count
        if alignments.isEmpty { alignments = Array(repeating: .leading, count: columns) }
        rows = rows.map { Array(($0 + Array(repeating: "", count: max(0, columns - $0.count))).prefix(columns)) }
        self.alignments = alignments
        self.rows = rows
    }

    /// The cells of one `| a | b |` row. A pipe inside a cell is written
    /// `\|` and comes back as a plain pipe.
    static func cells(ofRow line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                // Only `\|` is the table's escape; any other backslash pair
                // belongs to the cell's own markdown.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        // The row's own leading and trailing pipes bound it; they are not
        // empty cells.
        if cells.count > 1, cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.count > 1, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A cell's markdown, safe to parse on its own. In a table a cell is
    /// only ever inline text, but alone, a cell that starts like a block
    /// (`# of rows`, `- none`, `1. first`, `> 5`, `---`) would parse as a
    /// heading, a list, a quote or a rule. Escaping the marker keeps it
    /// the text it was. An empty cell keeps a line's height.
    static func inlineMarkdown(ofCell cell: String) -> String {
        guard let first = cell.first else { return "\u{00A0}" }
        let rest = cell.dropFirst()
        let endsMarker = rest.isEmpty || rest.first?.isWhitespace == true
        let escapedFirst = "\\" + cell
        switch first {
        case ">":
            return escapedFirst
        case "#":
            let afterHashes = cell.drop { $0 == "#" }
            return afterHashes.isEmpty || afterHashes.first?.isWhitespace == true ? escapedFirst : cell
        case "-", "+", "*", "_":
            let isRule = first != "+" && cell.allSatisfy { $0 == first || $0.isWhitespace }
                && cell.filter { $0 == first }.count >= 3
            return (first != "_" && endsMarker) || isRule ? escapedFirst : cell
        case "~":
            return cell.hasPrefix("~~~") ? escapedFirst : cell
        case "`":
            // A fence opens only when no backtick follows the run.
            let afterTicks = cell.drop { $0 == "`" }
            return cell.hasPrefix("```") && !afterTicks.contains("`") ? escapedFirst : cell
        case "[":
            // `[label]: text` alone on a line is a link reference
            // definition and renders as nothing.
            if let close = cell.firstIndex(of: "]"), cell[cell.index(after: close)...].hasPrefix(":") { return escapedFirst }
            return cell
        default:
            // `1. first` / `2) second`: an ordered list.
            let digits = cell.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return cell }
            let after = cell.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return cell }
            let tail = after.dropFirst()
            guard tail.isEmpty || tail.first?.isWhitespace == true else { return cell }
            return digits + "\\" + after
        }
    }

    /// A table ready to draw: every cell parsed.
    final class Parsed {
        let alignments: [ItemTableColumnAlignment]
        let cells: [[MarkdownContent]]

        init(_ table: ItemTable) {
            alignments = table.alignments
            cells = table.rows.map { $0.map { MarkdownContent(ItemTable.inlineMarkdown(ofCell: $0)) } }
        }
    }

    /// Parsed once per table: a thread's bodies are immutable, and its
    /// theme closure runs again whenever the card above it is rebuilt.
    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 300
        return cache
    }()

    static func parsed(forTableMarkdown markdown: String) -> Parsed {
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let parsed = Parsed(ItemTable(tableMarkdown: markdown))
        cache.setObject(parsed, forKey: key)
        return parsed
    }
}

/// A GFM table column's alignment, from its delimiter row.
enum ItemTableColumnAlignment: Equatable {
    case leading, center, trailing

    var frame: Alignment {
        switch self {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Column alignments of a single GFM table's markdown — its delimiter
    /// row (the second line: `| :-- | :-: | --: |`). Empty when there is
    /// none, which leaves every column leading.
    static func columns(ofTableMarkdown markdown: String) -> [ItemTableColumnAlignment] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return [] }
        var row = lines[1].trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        let cells = row.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty, cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) else {
            return []
        }
        return cells.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }
}

/// Lays a table cell out at its natural width, capped at `maxWidth`.
///
/// Inside the table's horizontal `ScrollView` the grid proposes no width,
/// so a plain `Text` would lay every cell out on one line however long it
/// is; `.frame(maxWidth:)` does not help, because it forwards the
/// unspecified proposal and only clamps the frame around an overflowing
/// child. This asks the cell for its ideal width and wraps it at
/// `min(ideal, maxWidth)` (or the grid's column width, when it proposes
/// one), so short cells hug and long ones wrap.
struct ItemTableCellWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let cell = subviews.first else { return .zero }
        let width = min(cell.sizeThatFits(.unspecified).width, maxWidth, proposal.width ?? .infinity)
        return cell.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
