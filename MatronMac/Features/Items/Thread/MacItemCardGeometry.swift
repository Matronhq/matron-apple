import AppKit
import MatronDesignSystem
import MatronModels

/// Where everything in one card of the native item thread goes, at one
/// width: the frames the cell draws at and the row height the table uses,
/// from one computation, so the two cannot disagree.
struct MacItemCardLayout: Equatable {
    enum Part: Equatable {
        /// A markdown segment, drawn by a `MessageBodyView` (TextKit 1).
        case text(selectionID: String, source: String)
        /// A piece the SwiftUI item view draws: caption, attachment,
        /// delivery line, the comment's buttons, a status note's line.
        case hosted(ItemDetailView.Piece)
    }

    var parts: [Part]
    /// In row coordinates, one per part.
    var frames: [CGRect]
    /// The card's ground: its padding around the caption, parts and
    /// delivery line. Not the status line above it or the buttons below.
    var cardFrame: CGRect
    /// The row's height, not counting the table's gap below it.
    var height: CGFloat
}

/// Lays a card out as `ItemDetailView`'s SwiftUI card lays itself out on the
/// Mac: in the thread's column, caption then parts then delivery line
/// `partSpacing` apart inside the card's padding, the card as wide as its
/// widest piece (text hugs, as `SelectableMessageText` does), the comment's
/// own buttons a thread gap below, a status note's line above.
enum MacItemCardGeometry {
    /// The gap between a card's caption, body parts and delivery line: the
    /// card `VStack`'s spacing.
    static let partSpacing: CGFloat = 6

    /// The thread's column in a row `rowWidth` wide: `ItemTypography
    /// .measure` at most, centred, inside the thread's padding.
    static func column(rowWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let width = max(0, min(rowWidth - 2 * ItemTypography.threadPadding, ItemTypography.measure))
        return ((rowWidth - width) / 2, width)
    }

    /// The selection id of each drawn text part of a card, in order. The
    /// SwiftUI thread numbers EVERY text segment of the body
    /// (`ItemDetailView.segmentSelectionID`), drawn or not, so the ids are
    /// counted over the whole split and the empty segments, which the row
    /// model drops, are skipped here too.
    static func textSelectionIDs(cardID: String, body: String, attachments: [TrackerAttachment]) -> [String] {
        var ids: [String] = []
        var textIndex = 0
        for segment in splitInlineAttachments(body: body, attachments: attachments).segments {
            guard case .text(let text) = segment else { continue }
            defer { textIndex += 1 }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ids.append(ItemDetailView.segmentSelectionID(cardID, textIndex: textIndex))
            }
        }
        return ids
    }

    /// The markdown of a text part, rendered as the SwiftUI card renders it.
    static func rendered(_ source: String) -> MarkdownAttributed.Rendered {
        MarkdownAttributed.rendered(for: source, style: .item, cache: true)
    }

    /// `textSelectionIDs`: one per `.markdown` part, in order
    /// (`textSelectionIDs(cardID:body:attachments:)`). `hostedSize`
    /// answers a SwiftUI piece's size at a width.
    static func layout(_ card: ItemCardContent, textSelectionIDs: [String], rowWidth: CGFloat,
                       hostedSize: (ItemDetailView.Piece, CGFloat) -> CGSize) -> MacItemCardLayout {
        let column = column(rowWidth: rowWidth)
        let padding = ItemTypography.cardPadding
        let inner = max(0, column.width - 2 * padding)
        let x = column.x + padding
        var parts: [MacItemCardLayout.Part] = []
        var frames: [CGRect] = []
        var top: CGFloat = 0
        var widest: CGFloat = 0
        let commentID: String? = if case .comment(let id) = card.row { id } else { nil }

        if card.hasStatusLine, let commentID {
            let piece = ItemDetailView.Piece.statusLine(commentID: commentID)
            let size = hostedSize(piece, column.width)
            parts.append(.hosted(piece))
            frames.append(CGRect(x: column.x, y: 0, width: column.width, height: size.height))
            top = size.height + ItemDetailView.statusNoteSpacing
        }
        var y = top + padding

        // The caption keeps the card's full width, so a date that grows
        // ("5 min ago" → "12 min ago") has room; the card hugs what it
        // measured.
        let caption = ItemDetailView.Piece.caption(card.row)
        let captionSize = hostedSize(caption, inner)
        parts.append(.hosted(caption))
        frames.append(CGRect(x: x, y: y, width: inner, height: captionSize.height))
        widest = max(widest, captionSize.width)
        y += captionSize.height

        var textIDs = textSelectionIDs.makeIterator()
        for part in card.parts {
            y += partSpacing
            switch part {
            case .markdown(let source):
                // Hugging, as `SelectableMessageText` does: `size(width:)`
                // answers the width the text takes and its height there.
                let size = rendered(source).size(width: inner)
                let width = min(ceil(size.width), inner)
                parts.append(.text(selectionID: textIDs.next() ?? "", source: source))
                frames.append(CGRect(x: x, y: y, width: width, height: ceil(size.height)))
                widest = max(widest, width)
                y += ceil(size.height)
            case .attachment(let attachment):
                let piece = ItemDetailView.Piece.attachment(card.row, blobRef: attachment.blobRef)
                let size = hostedSize(piece, inner)
                parts.append(.hosted(piece))
                frames.append(CGRect(x: x, y: y, width: inner, height: size.height))
                widest = max(widest, size.width)
                y += size.height
            }
        }
        if card.hasDelivery, let commentID {
            y += partSpacing
            let piece = ItemDetailView.Piece.delivery(commentID: commentID)
            let size = hostedSize(piece, inner)
            parts.append(.hosted(piece))
            frames.append(CGRect(x: x, y: y, width: inner, height: size.height))
            widest = inner
            y += size.height
        }
        y += padding
        let cardFrame = CGRect(x: column.x, y: top, width: min(widest, inner) + 2 * padding, height: y - top)

        if card.hasActions, let commentID {
            y += ItemTypography.threadSpacing
            let piece = ItemDetailView.Piece.commentActions(commentID: commentID)
            let size = hostedSize(piece, column.width)
            parts.append(.hosted(piece))
            frames.append(CGRect(x: column.x, y: y, width: column.width, height: size.height))
            y += size.height
        }
        return MacItemCardLayout(parts: parts, frames: frames, cardFrame: cardFrame, height: ceil(y))
    }
}
