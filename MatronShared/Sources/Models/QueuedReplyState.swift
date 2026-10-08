import Foundation

/// Whether a reply the user added to an item has actually reached the agent
/// ("show clearly whether it has really been sent or is
/// still queued").
///
/// The journal takes an item comment at once, so the comment is in the
/// thread — but the bridge turns it into a 📌 turn, and when the agent is
/// mid-turn it parks that turn on the session's busy queue and posts a
/// `queued_release` card in the conversation ("📨 Queued … ⚡ Send now /
/// ✕ Cancel"). The card names the reply it holds (`item: {item_id,
/// comment_id}`, bridge 2026-10-01), and the bridge's `queued_release`
/// prompt_reply with the card's `prompt_id` resolves it: `send`/`send_one`
/// (delivered), `cancel`, or `expired` (the session ended first).
public enum QueuedReplyState: Equatable, Sendable {
    /// Waiting on the busy queue. `targetSeq` is the card's own seq — what a
    /// Send now answers; `offersSendOne` says the card can release this one
    /// reply alone (else `send` releases the whole queue, as in chat).
    case queued(convoID: String, targetSeq: Int64, offersSendOne: Bool)
    /// Send now tapped here; the bridge's release hasn't come back yet.
    case sending
    /// Cancel tapped here; the bridge's release hasn't come back yet.
    case cancelling
    /// Send now or Cancel couldn't be sent, or the bridge never confirmed
    /// it (offline, say) — still queued, tap again.
    case sendFailed(convoID: String, targetSeq: Int64, offersSendOne: Bool, reason: String)
    /// Cancelled — from the item thread or the conversation's card: the
    /// agent never got it. The comment stays in the thread, marked.
    case cancelled
    /// The session ended before the queue flushed: the agent never got it.
    case notDelivered
}
