import Foundation
import MatronJournal
import MatronModels

/// Derives `QueuedReplyState` (MatronModels) from a conversation's
/// `queued_release` cards.

public enum ItemQueuedReplies {
    /// Derives the queue state of each of `itemID`'s replies (by comment id)
    /// from the origin conversation's `queued_release` cards and releases,
    /// oldest first. A delivered reply is absent — it reads as sent, which is
    /// what it is. Earliest release wins, as in `ChatViewModel`: the
    /// realistic double is a committed `send` followed by a boot reconcile's
    /// `expired`, and the send is what happened. Only bridge-authored rows
    /// (`agent:` senders) count — a card or release is the bridge's word
    /// about its own queue.
    public static func derive(rows: [JournalEvent], itemID: String) -> [String: QueuedReplyState] {
        struct Card { let commentID: String; let convoID: String; let seq: Int64; let sendOne: Bool }
        var cards: [String: Card] = [:] // prompt_id → card
        var released: [String: String] = [:] // prompt_id → first release action
        for row in rows where row.sender.hasPrefix("agent:") {
            let p = row.payload
            guard (p["kind"] as? String) == "queued_release", let promptID = p["prompt_id"] as? String else { continue }
            switch row.type {
            case JournalEventType.prompt:
                guard let item = p["item"] as? [String: Any], (item["item_id"] as? String) == itemID,
                      let commentID = item["comment_id"] as? String, !commentID.isEmpty else { continue }
                let actions = (p["actions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                cards[promptID] = Card(commentID: commentID, convoID: row.convoID, seq: row.seq,
                                       sendOne: actions.contains("send_one"))
            case JournalEventType.promptReply:
                guard let action = p["action"] as? String, released[promptID] == nil else { continue }
                released[promptID] = action
            default:
                continue
            }
        }
        var out: [String: QueuedReplyState] = [:]
        for (promptID, card) in cards {
            switch released[promptID] {
            case nil: out[card.commentID] = .queued(convoID: card.convoID, targetSeq: card.seq, offersSendOne: card.sendOne)
            case "cancel": out[card.commentID] = .cancelled
            case "expired": out[card.commentID] = .notDelivered
            default: continue // send / send_one: delivered
            }
        }
        return out
    }

    /// The card choice a Send now taps: just this reply when the card can,
    /// otherwise the whole queue (which includes this reply).
    public static func sendNowChoice(offersSendOne: Bool) -> String { offersSendOne ? "send_one" : "send" }
}

/// The origin conversation's `queued_release` cards and releases, live.
public protocol QueuedRepliesReading: Sendable {
    func queuedReleaseEventsStream(convoID: String) -> AsyncStream<[JournalEvent]>
}

extension JournalStore: QueuedRepliesReading {}

/// Answers a queued card — the same `prompt_reply` a tap on the card in the
/// conversation sends, so the bridge's router (and its provenance checks by
/// the card's seq) handles it exactly as it does there.
public protocol QueuedReplySending: Sendable {
    func sendQueuedRelease(convoID: String, targetSeq: Int64, choice: String) async throws
}

extension JournalSyncEngine: QueuedReplySending {
    public func sendQueuedRelease(convoID: String, targetSeq: Int64, choice: String) async throws {
        try await sendOp(.promptReply(convoID: convoID, targetSeq: targetSeq, choice: choice, text: nil))
    }
}
