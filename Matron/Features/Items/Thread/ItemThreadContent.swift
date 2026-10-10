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

/// What one native card draws: the item's body or a comment. Equal contents
/// measure and draw the same, so a cached measurement is reused only while
/// its content is.
struct ItemCardContent: Equatable {
    enum Part: Equatable {
        case markdown(String)
        case attachment(TrackerAttachment)
    }

    let row: ItemThreadRow
    let mine: Bool
    /// The body's text and inline attachments in order, then the
    /// attachments no reference placed.
    let parts: [Part]
    /// A reply the agent hasn't got yet draws its delivery line, dimmed.
    let hasDelivery: Bool
    /// The comment's own action buttons, under the card.
    let hasActions: Bool
    /// Everything else the card's hosted pieces (caption, delivery line,
    /// buttons) draw from.
    let hostedSignature: Int
    /// The note of a close or reopen draws the centred line that says so
    /// over its card.
    var hasStatusLine = false
}

/// One row of the native thread: a card with native text, or a row the
/// existing SwiftUI view draws whole.
enum ItemThreadRowContent: Equatable {
    case card(ItemCardContent)
    case hosted(ItemThreadRow, signature: Int)

    var row: ItemThreadRow {
        switch self {
        case .card(let card): return card.row
        case .hosted(let row, _): return row
        }
    }
}

enum ItemThreadContentBuilder {
    /// The thread's rows as the native thread draws them. `rows` is
    /// `ItemDetailView.threadRows`; a comment that has gone from the model
    /// is dropped.
    static func contents(rows: [ItemThreadRow], model: ItemDetailView.Model,
                         answersCommentActions: Bool) -> [ItemThreadRowContent] {
        let comments = Dictionary(model.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.compactMap { row in
            switch row {
            case .body:
                var hasher = Hasher()
                hasher.combine(model.item.createdBy)
                hasher.combine(model.item.createdAt)
                return .card(ItemCardContent(row: row, mine: model.item.createdBy == .user,
                                             parts: parts(body: model.item.body, attachments: model.item.attachments),
                                             hasDelivery: false, hasActions: false,
                                             hostedSignature: hasher.finalize()))
            case .comment(let id):
                guard let comment = comments[id] else { return nil }
                guard comment.kind == .status else {
                    let delivery = comment.author == .user ? model.queuedReplies[id] : nil
                    return .card(ItemCardContent(
                        row: row, mine: comment.author == .user,
                        parts: parts(body: comment.body, attachments: comment.attachments),
                        hasDelivery: delivery != nil,
                        hasActions: ItemDetailView.offersCommentActions(comment, in: model, answers: answersCommentActions),
                        hostedSignature: signature(of: row, model: model, comment: comment)))
                }
                // A bare status row is one centred line: the SwiftUI row
                // draws it.
                guard !comment.body.isEmpty else {
                    return .hosted(row, signature: signature(of: row, model: model, comment: comment))
                }
                // The note left when closing or reopening is a message
                // like any other, and as long: a card under that line,
                // measured as every card is. It has no delivery line or
                // buttons, and draws only the attachments its text places.
                return .card(ItemCardContent(
                    row: row, mine: comment.author == .user,
                    parts: parts(body: comment.body, attachments: comment.attachments, showsTrailing: false),
                    hasDelivery: false, hasActions: false,
                    hostedSignature: signature(of: row, model: model, comment: comment),
                    hasStatusLine: ItemDetailView.statusLine(comment) != nil))
            default:
                return .hosted(row, signature: signature(of: row, model: model, comment: nil))
            }
        }
    }

    static func parts(body: String, attachments: [TrackerAttachment],
                      showsTrailing: Bool = true) -> [ItemCardContent.Part] {
        let split = splitInlineAttachments(body: body, attachments: attachments)
        var parts: [ItemCardContent.Part] = split.segments.compactMap { segment in
            switch segment {
            case .text(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .markdown(text)
            case .attachment(let attachment):
                return .attachment(attachment)
            }
        }
        if showsTrailing { parts += split.trailing.map { .attachment($0) } }
        return parts
    }

    /// What a hosted row, or a card's hosted pieces, draws from. It only
    /// has to change when their height might: a hosted view on screen
    /// redraws from the live model whatever this says.
    private static func signature(of row: ItemThreadRow, model: ItemDetailView.Model, comment: TrackerComment?) -> Int {
        var hasher = Hasher()
        let item = model.item
        switch row {
        case .header:
            hasher.combine(item.num)
            hasher.combine(item.title)
            hasher.combine(item.kind)
            hasher.combine(item.state)
            hasher.combine(item.resolution)
            hasher.combine(item.awaiting)
            hasher.combine(String(describing: model.context))
        case .meta:
            hasher.combine(item.labels)
            hasher.combine(item.links)
        case .consent:
            hasher.combine(String(describing: model.spawnConsent))
        case .actions:
            hasher.combine(model.actions)
            hasher.combine(model.selectedAction)
        case .body, .divider:
            break
        case .comment(let id):
            hasher.combine(comment)
            hasher.combine(model.selectedCommentActions[id])
            hasher.combine(String(describing: model.queuedReplies[id]))
            hasher.combine(item.state)
            if let convo = comment?.convoID { hasher.combine(model.openableConvoIDs.contains(convo)) }
        case .pending(let id):
            if let pending = model.pending.first(where: { $0.id == id }) {
                hasher.combine(pending.body)
                hasher.combine(pending.attachmentCount)
                hasher.combine(pending.attempts)
                hasher.combine(pending.lastError)
            }
        }
        return hasher.finalize()
    }
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
                let segments = MarkdownAttributed.rendered(for: markdown, style: style.markdown, cache: true).segments
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
