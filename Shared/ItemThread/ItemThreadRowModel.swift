import SwiftUI
import MatronDesignSystem
import MatronModels

// The native item thread's row model, shared by the iPhone's UIKit thread and
// the Mac's AppKit thread: which rows are native cards and which the SwiftUI
// item view draws whole, and the content value whose equality decides when a
// row is measured again. Pure: no UIKit or AppKit.

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
                hasher.combine(model.item.contributor)
                return .card(ItemCardContent(row: row, mine: model.item.isMine,
                                             parts: parts(body: model.item.body, attachments: model.item.attachments),
                                             hasDelivery: false, hasActions: false,
                                             hostedSignature: hasher.finalize()))
            case .comment(let id):
                guard let comment = comments[id] else { return nil }
                guard comment.kind == .status else {
                    let delivery = comment.author == .user ? model.queuedReplies[id] : nil
                    return .card(ItemCardContent(
                        row: row, mine: comment.isMine,
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
                    row: row, mine: comment.isMine,
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
                hasher.combine(pending.attachmentNames)
            }
        case .working:
            hasher.combine(model.working)
        }
        return hasher.finalize()
    }
}
