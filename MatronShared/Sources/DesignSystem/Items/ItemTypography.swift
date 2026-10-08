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
        // tint on the header row. The borders are per cell rather than
        // MarkdownUI's table-border overlay, which drew only the top rule
        // once the table overflowed the scroll view (measured).
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: .clear, width: 0))
                    // Each cell fills its grid cell (for the rules and the
                    // tint), which defeats the grid's own column alignment;
                    // the cells place their text by the GFM delimiter row's
                    // alignment instead. MarkdownUI hands a cell only its
                    // row and column, so the table reads the alignments off
                    // its own markdown and passes them down.
                    .environment(\.itemTableColumnAlignments,
                                 ItemTableColumnAlignment.columns(ofTableMarkdown: configuration.content.renderMarkdown()))
            }
            .markdownMargin(top: ItemTypography.paragraphSpacing, bottom: ItemTypography.paragraphSpacing)
        }
        .tableCell { configuration in
            ItemTableCell(configuration: configuration)
        }
}

/// One `Theme.matronItem` table cell: natural width capped at
/// `ItemTypography.tableCellMaxWidth`, header row semibold and tinted, a
/// hairline border, and the text placed by its column's GFM alignment
/// (`:---` leading, `:---:` centre, `---:` trailing) at the top of the row.
struct ItemTableCell: View {
    let configuration: TableCellConfiguration
    @Environment(\.itemTableColumnAlignments) private var alignments

    var body: some View {
        let alignment = configuration.column < alignments.count ? alignments[configuration.column] : .leading
        ItemTableCellWidth(maxWidth: ItemTypography.tableCellMaxWidth) {
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
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
        .background(configuration.row == 0 ? Color.primary.opacity(0.05) : Color.clear)
        .border(Color.primary.opacity(0.18), width: 0.5)
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

extension EnvironmentValues {
    /// The enclosing `Theme.matronItem` table's column alignments.
    @Entry var itemTableColumnAlignments: [ItemTableColumnAlignment] = []
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
