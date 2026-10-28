import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels

/// Fonts and markdown metrics of the native item thread for one Dynamic
/// Type size: the item reading face (`ItemTypography`), scaled as
/// `Theme.matronItem` scales it. Half of every measurement's cache key.
struct ItemThreadTextStyle: Hashable {
    let sizeCategory: UIContentSizeCategory

    var bodySize: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: ItemTypography.baseSize * ItemTypography.phoneBodyScale,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: sizeCategory))
    }

    var markdown: MarkdownAttributed.Style { .phoneItem(bodySize: bodySize) }

    /// Code blocks are the chat timeline's own, at its metrics.
    var code: TimelineTextStyle { TimelineTextStyle(sizeCategory: sizeCategory) }
}

/// A SwiftUI piece the native thread hosts: part of the item view.
enum ItemHostedPiece {
    case detail(ItemDetailView.Piece)
}

/// One card, measured for a width: where its background and each of its
/// pieces go, in the row's own coordinates.
final class ItemCardRender {
    enum Kind {
        case text(NSAttributedString)
        case code(language: String?, code: String)
        case table(ItemTableLayout)
        case hosted(ItemHostedPiece)
    }

    struct Piece {
        let kind: Kind
        let frame: CGRect
    }

    let content: ItemCardContent
    let style: ItemThreadTextStyle
    let cardFrame: CGRect
    let pieces: [Piece]
    let height: CGFloat

    init(content: ItemCardContent, style: ItemThreadTextStyle, cardFrame: CGRect, pieces: [Piece], height: CGFloat) {
        self.content = content
        self.style = style
        self.cardFrame = cardFrame
        self.pieces = pieces
        self.height = height
    }
}

enum ItemCardRenderer {
    /// The gap between a card's caption, body parts and delivery line.
    static let partSpacing: CGFloat = 6

    /// The thread's column in a row `rowWidth` wide: `ItemTypography
    /// .measure` at most, centred, inside the thread's padding.
    static func column(rowWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let width = max(0, min(rowWidth - 2 * ItemTypography.threadPadding, ItemTypography.measure))
        return ((rowWidth - width) / 2, width)
    }

    /// Lays a card out as the SwiftUI card lays itself out: caption, parts
    /// and delivery line stacked `partSpacing` apart inside the card's
    /// padding, the card as wide as its widest piece, the comment's own
    /// buttons a thread gap below, a status note's line across the column
    /// above. `hosted` answers a SwiftUI piece's size at a width.
    static func render(_ content: ItemCardContent, rowWidth: CGFloat, style: ItemThreadTextStyle,
                       hosted: (ItemHostedPiece, CGFloat) -> CGSize) -> ItemCardRender {
        let column = column(rowWidth: rowWidth)
        let padding = ItemTypography.cardPadding
        let inner = max(0, column.width - 2 * padding)
        let x = column.x + padding
        var top: CGFloat = 0
        var widest: CGFloat = 0
        var pieces: [ItemCardRender.Piece] = []
        if content.hasStatusLine, case .comment(let id) = content.row {
            let piece = ItemHostedPiece.detail(.statusLine(commentID: id))
            let size = hosted(piece, column.width)
            pieces.append(.init(kind: .hosted(piece), frame: CGRect(x: column.x, y: 0, width: column.width, height: size.height)))
            top = size.height + ItemDetailView.statusNoteSpacing
        }
        var y = top + padding

        func place(_ kind: ItemCardRender.Kind, size: CGSize, fillsWidth: Bool) {
            let width = fillsWidth ? inner : size.width
            pieces.append(.init(kind: kind, frame: CGRect(x: x, y: y, width: width, height: size.height)))
            widest = max(widest, width)
            y += size.height
        }

        let caption = ItemHostedPiece.detail(.caption(content.row))
        let captionSize = hosted(caption, inner)
        // The caption keeps the card's full width, so a date that grows
        // ("5 min ago" → "12 min ago") has room; the card hugs what the
        // caption measured.
        pieces.append(.init(kind: .hosted(caption), frame: CGRect(x: x, y: y, width: inner, height: captionSize.height)))
        widest = max(widest, captionSize.width)
        y += captionSize.height

        for part in content.parts {
            y += partSpacing
            switch part {
            case .markdown(let markdown):
                let segments = MarkdownAttributed.rendered(for: markdown, style: style.markdown, cache: true,
                                                           trackerLinks: content.trackerLinks[markdown]).segments
                for (index, segment) in segments.enumerated() {
                    if index > 0 { y += ItemTypography.paragraphSpacing }
                    switch segment {
                    case .text(let text):
                        // In runs of whole paragraphs, each a piece: a
                        // long answer is then several small text views
                        // that come and go as it scrolls, not one that is
                        // laid out and drawn whole the moment its card
                        // shows a corner.
                        for (run, gapBefore) in ItemTextRuns.split(text) {
                            y += gapBefore
                            place(.text(run), size: TextKitMeasure.hugging(run, width: inner).size, fillsWidth: false)
                        }
                    case .code(let language, let code):
                        place(.code(language: language, code: code),
                              size: CGSize(width: inner, height: CodeBlockMetrics.height(code: code, style: style.code)),
                              fillsWidth: true)
                    case .table(let table):
                        // The table keeps the card's full width and
                        // scrolls sideways inside it when it is wider.
                        let layout = ItemTableLayout(table: table)
                        place(.table(layout), size: CGSize(width: inner, height: layout.size.height), fillsWidth: true)
                    }
                }
            case .attachment(let attachment):
                let piece = ItemHostedPiece.detail(.attachment(content.row, blobRef: attachment.blobRef))
                let size = hosted(piece, inner)
                // The attachment keeps the full width to draw in and the
                // card hugs what it measured.
                pieces.append(.init(kind: .hosted(piece), frame: CGRect(x: x, y: y, width: inner, height: size.height)))
                widest = max(widest, size.width)
                y += size.height
            }
        }
        if content.hasDelivery, case .comment(let id) = content.row {
            y += partSpacing
            let piece = ItemHostedPiece.detail(.delivery(commentID: id))
            place(.hosted(piece), size: hosted(piece, inner), fillsWidth: true)
        }
        y += padding
        let cardFrame = CGRect(x: column.x, y: top, width: min(widest, inner) + 2 * padding, height: y - top)

        if content.hasActions, case .comment(let id) = content.row {
            y += ItemTypography.threadSpacing
            let piece = ItemHostedPiece.detail(.commentActions(commentID: id))
            let size = hosted(piece, column.width)
            pieces.append(.init(kind: .hosted(piece), frame: CGRect(x: column.x, y: y, width: column.width, height: size.height)))
            y += size.height
        }
        return ItemCardRender(content: content, style: style, cardFrame: cardFrame, pieces: pieces, height: ceil(y))
    }
}

/// Splits a card's prose into runs of whole paragraphs.
enum ItemTextRuns {
    /// A run closes at the first paragraph end past this many characters.
    static let targetLength = 200

    /// `text` as runs, each with the gap that belongs above it: the
    /// paragraph spacing the text itself would have put between the two
    /// paragraphs the split falls between. Rejoined with those gaps, the
    /// runs take the height `text` took.
    static func split(_ text: NSAttributedString) -> [(run: NSAttributedString, gapBefore: CGFloat)] {
        let string = text.string as NSString
        guard string.length > targetLength else { return [(text, 0)] }
        var runs: [(NSAttributedString, CGFloat)] = []
        var start = 0
        var gap: CGFloat = 0
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let end = NSMaxRange(paragraph)
            if end - start >= targetLength || end == string.length {
                // Without the paragraph's line break: it would measure as
                // an empty last line.
                var contentEnd = end
                while contentEnd > start, let scalar = UnicodeScalar(string.character(at: contentEnd - 1)),
                      CharacterSet.newlines.contains(scalar) { contentEnd -= 1 }
                if contentEnd > start {
                    runs.append((text.attributedSubstring(from: NSRange(location: start, length: contentEnd - start)), gap))
                    gap = spacing(after: paragraph.location, before: end, in: text)
                }
                start = end
            }
            location = end
        }
        return runs
    }

    /// The space between the paragraph at `last` and the one at `next`.
    private static func spacing(after last: Int, before next: Int, in text: NSAttributedString) -> CGFloat {
        // A paragraph's leading also follows its last line when another
        // paragraph comes after it.
        let style = text.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle
        let after = (style?.paragraphSpacing ?? 0) + (style?.lineSpacing ?? 0)
        guard next < text.length else { return after }
        let before = (text.attribute(.paragraphStyle, at: next, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacingBefore ?? 0
        return after + before
    }
}

/// Where the thread's rows go: `ItemTypography.threadSpacing` apart, inside
/// the thread's padding, with the scrolling stack's one-point tail after
/// the last row. A pure function of the rows' heights.
struct ItemThreadFrames: Equatable {
    private(set) var minYs: [CGFloat] = []
    private(set) var heights: [CGFloat] = []
    private(set) var contentHeight: CGFloat = 0

    init(heights: [CGFloat]) {
        self.heights = heights
        var y = ItemTypography.threadPadding
        for height in heights {
            minYs.append(y)
            y += height + ItemTypography.threadSpacing
        }
        // The stack ends in a one-point anchor row, a gap after the last
        // real row, and then the padding.
        contentHeight = y + 1 + ItemTypography.threadPadding
    }

    func frame(at index: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: minYs[index], width: width, height: heights[index])
    }

    /// The first row any part of which is at or below `y`.
    func firstRow(endingAfter y: CGFloat) -> Int? {
        minYs.indices.first { minYs[$0] + heights[$0] > y }
    }
}
