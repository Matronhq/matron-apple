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
        case body(ItemCardBody)
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

        if !content.parts.isEmpty {
            y += partSpacing
            let body = ItemCardBody.make(content, width: inner, style: style, hosted: hosted)
            // The text view takes the whole width when blocks sit on its
            // lines, as they do in it; prose alone hugs its text.
            pieces.append(.init(kind: .body(body), frame: CGRect(x: x, y: y, width: body.viewWidth, height: body.height)))
            for block in body.blockPieces {
                pieces.append(.init(kind: block.kind, frame: block.frame.offsetBy(dx: x, dy: y)))
            }
            widest = max(widest, body.usedWidth)
            y += body.height
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

/// A card's text, code blocks, tables and attachments as ONE selectable
/// string (`TextRowBody`), as the chat lays out a message: a selection
/// then runs from any paragraph of the card to any other. Each block is a
/// placeholder line exactly as tall as the block, whose own view is drawn
/// at that line. A card several screens tall is then one text view, laid
/// out whole once it shows, as a long chat message is.
struct ItemCardBody {
    struct BlockPiece {
        let kind: ItemCardRender.Kind
        /// In the body's coordinates.
        let frame: CGRect
    }

    let body: TextRowBody
    /// The blocks' views, in `body.blocks` order.
    let blockPieces: [BlockPiece]
    /// How wide the text view is: the text container's width.
    let viewWidth: CGFloat
    /// How wide what it draws is: the card hugs this.
    let usedWidth: CGFloat
    let height: CGFloat

    /// The blocks' frames in the text view's coordinates.
    var blockFrames: [CGRect] { blockPieces.map(\.frame) }

    static func make(_ content: ItemCardContent, width: CGFloat, style: ItemThreadTextStyle,
                     hosted: (ItemHostedPiece, CGFloat) -> CGSize) -> ItemCardBody {
        var elements: [TextRowBody.Element] = []
        var kinds: [Int: ItemCardRender.Kind] = [:]
        func add(_ kind: TextRowBody.Element.Kind, spacing: CGFloat, block: ItemCardRender.Kind? = nil) {
            if let block { kinds[elements.count] = block }
            elements.append(.init(kind: kind, spacingBefore: elements.isEmpty ? 0 : spacing))
        }
        for part in content.parts {
            switch part {
            case .markdown(let markdown):
                let segments = MarkdownAttributed.rendered(for: markdown, style: style.markdown, cache: true,
                                                           trackerLinks: content.trackerLinks[markdown]).segments
                for (index, segment) in segments.enumerated() {
                    // Between a part and the one before it, the part gap;
                    // within a part, the paragraph gap.
                    let spacing = index == 0 ? ItemCardRenderer.partSpacing : ItemTypography.paragraphSpacing
                    switch segment {
                    case .text(let text):
                        add(.prose(text), spacing: spacing)
                    case .code(let language, let code):
                        add(.block(height: CodeBlockMetrics.height(code: code, style: style.code), width: width,
                                   copyText: code),
                            spacing: spacing, block: .code(language: language, code: code))
                    case .table(let table):
                        // The table keeps the card's full width and
                        // scrolls sideways inside it when it is wider.
                        let layout = ItemTableLayout(table: table)
                        add(.block(height: layout.size.height, width: width, copyText: TextRowBody.copyText(of: table)),
                            spacing: spacing, block: .table(layout))
                    }
                }
            case .attachment(let attachment):
                let piece = ItemHostedPiece.detail(.attachment(content.row, blobRef: attachment.blobRef))
                let size = hosted(piece, width)
                // The attachment keeps the full width to draw in and the
                // card hugs what it measured. A copy leaves it out, as the
                // whole-card Copy does.
                add(.block(height: size.height, width: size.width, copyText: ""),
                    spacing: ItemCardRenderer.partSpacing, block: .hosted(piece))
            }
        }
        if kinds.isEmpty, elements.count == 1, case .prose(let text) = elements[0].kind {
            let measured = TextKitMeasure.hugging(text, width: width)
            return ItemCardBody(body: TextRowBody(text: text, blocks: []), blockPieces: [],
                                viewWidth: measured.size.width, usedWidth: measured.size.width,
                                height: measured.size.height)
        }
        let body = TextRowBody.build(elements, trailingSpacing: 0,
                                     font: .systemFont(ofSize: style.markdown.baseFontSize))
        // Each block's placeholder is one character; its line is the
        // block's frame.
        let measured = TextKitMeasure.measure(body.text, width: width,
                                              locating: body.blocks.map { NSRange(location: $0.location, length: 1) })
        var pieces: [BlockPiece] = []
        for (block, rect) in zip(body.blocks, measured.rects) {
            // Every block's view takes the full width: an attachment
            // draws in it, hugging what it measured.
            guard let kind = kinds[block.segmentIndex],
                  case .block(let height, _, _) = elements[block.segmentIndex].kind else { continue }
            pieces.append(BlockPiece(kind: kind, frame: CGRect(x: 0, y: rect.minY, width: width, height: height)))
        }
        let height = max(measured.result.size.height, ceil(pieces.last?.frame.maxY ?? 0))
        return ItemCardBody(body: body, blockPieces: pieces, viewWidth: width,
                            usedWidth: min(width, measured.result.size.width), height: height)
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
