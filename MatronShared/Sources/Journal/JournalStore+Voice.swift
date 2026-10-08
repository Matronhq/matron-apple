import Foundation
import GRDB

// Voice mode reads (spec 2026-10-03 §3, §5). Everything here is derived
// from tables the sync engine already fills: no new table, no new sync.

/// An ask-user or tool-permission `prompt` nobody has answered yet, with
/// the two facts about its conversation the voice queue says out loud.
public struct UnansweredPromptRow: Equatable, Sendable {
    public let event: JournalEvent
    public let convoTitle: String
    /// The agent box that manages the conversation, when known.
    public let agentName: String?

    public init(event: JournalEvent, convoTitle: String, agentName: String?) {
        self.event = event; self.convoTitle = convoTitle; self.agentName = agentName
    }
}

/// The agent's own words for one reply. The bridge splits a long reply
/// into several `text` rows and only the first carries the `message_ref`;
/// `body` is all of them, `seq` and `messageRef` the first one's.
public struct AgentReplyRow: Equatable, Sendable {
    public let seq: Int64
    /// The bridge's id for the reply (a summary's `spoken_ref` names it).
    /// `nil` only from a bridge that predates refs on unstreamed replies.
    public let messageRef: String?
    public let body: String

    public init(seq: Int64, messageRef: String?, body: String) {
        self.seq = seq; self.messageRef = messageRef; self.body = body
    }
}

extension JournalStore {
    /// `prompt` rows newer than `since` that the user has not answered:
    /// no `prompt_reply` of theirs targets the row, and they have sent
    /// nothing to that conversation after it (typing an answer instead of
    /// tapping one is still an answer). Busy-queue cards (`queued_release`)
    /// are not questions and are left out, as are prompts in a hidden or
    /// finished conversation. Oldest first.
    ///
    /// Reads `event_type_ts` for the candidates and `event_convo_type` for
    /// each one's later rows, so it never walks a conversation.
    public func unansweredPrompts(since: Date) throws -> [UnansweredPromptRow] {
        let sinceMS = Int64(since.timeIntervalSince1970 * 1000)
        let own = ownSender
        return try dbQueue.read { db in
            let candidates = try EventRecord.fetchAll(db, sql: """
                SELECT * FROM event WHERE type = 'prompt' AND ts >= ? ORDER BY seq
                """, arguments: [sinceMS])
            var out: [UnansweredPromptRow] = []
            for record in candidates where record.sender != own {
                let event = record.journalEvent
                if (event.payload["kind"] as? String) == "queued_release" { continue }
                let later = try EventRecord.fetchAll(db, sql: """
                    SELECT * FROM event
                    WHERE convo_id = ? AND type IN ('text', 'file', 'image', 'prompt_reply')
                      AND seq > ? AND sender = ?
                    """, arguments: [event.convoID, event.seq, own])
                let answered = later.contains { row in
                    guard row.type == JournalEventType.promptReply else { return true }
                    return (row.journalEvent.payload["target_seq"] as? NSNumber)?.int64Value == event.seq
                }
                if answered { continue }
                guard let convo = try ConversationRecord.fetchOne(db, key: event.convoID),
                      !convo.hidden, convo.sessionState != "done" else { continue }
                let agent = try convo.agentDeviceID.flatMap {
                    try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [$0])
                }
                out.append(UnansweredPromptRow(event: event, convoTitle: convo.title, agentName: agent))
            }
            return out
        }
    }

    /// The agent's newest reply in a conversation, above `afterSeq`: the
    /// newest assistant `text` row that carries a `message_ref`, with the
    /// unreferenced `text` rows the bridge published straight after it
    /// (the later chunks of a long reply). From a bridge that sends no
    /// ref on an unstreamed reply, the newest assistant `text` row alone.
    ///
    /// The journal's old-client mirror of an item marker (`fallback_for`)
    /// is not a reply and is skipped. `message_ref` needs no column: the
    /// mirror stores every payload whole.
    public func lastAgentReply(convoID: String, afterSeq: Int64 = 0) throws -> AgentReplyRow? {
        let own = ownSender
        return try dbQueue.read { db in
            let rows = try EventRecord.fetchAll(db, sql: """
                SELECT * FROM event
                WHERE convo_id = ? AND type = 'text' AND seq > ? AND sender != ?
                ORDER BY seq DESC LIMIT 40
                """, arguments: [convoID, afterSeq, own])
            var newestPlain: AgentReplyRow?
            for row in rows {
                let payload = row.journalEvent.payload
                if payload["fallback_for"] != nil { continue }
                guard let body = payload["body"] as? String, !body.isEmpty else { continue }
                guard let ref = payload["message_ref"] as? String, !ref.isEmpty else {
                    if newestPlain == nil { newestPlain = AgentReplyRow(seq: row.seq, messageRef: nil, body: body) }
                    continue
                }
                // The first chunk. Whatever text the same sender published
                // straight after it, without a ref, is the rest of it.
                var chunks = [body]
                let later = try EventRecord.fetchAll(db, sql: """
                    SELECT * FROM event WHERE convo_id = ? AND seq > ? ORDER BY seq LIMIT 40
                    """, arguments: [convoID, row.seq])
                for next in later {
                    if !JournalEventType.messageTypes.contains(next.type),
                       next.type != JournalEventType.sessionStatus { continue }
                    let nextPayload = next.journalEvent.payload
                    guard next.type == JournalEventType.text, next.sender == row.sender,
                          nextPayload["message_ref"] == nil, nextPayload["fallback_for"] == nil,
                          let more = nextPayload["body"] as? String else { break }
                    chunks.append(more)
                }
                return AgentReplyRow(seq: row.seq, messageRef: ref, body: chunks.joined(separator: "\n\n"))
            }
            return newestPlain
        }
    }

    /// The summary entry carrying the spoken lines for `reply`: the newest
    /// one whose `spoken_ref` is the reply's `message_ref`. The bridge
    /// sends `spoken` and `spoken_ref` together or not at all, and a
    /// summary can land after a newer reply has been published, so a
    /// spoken line is only ever used for the reply its ref names. `nil`
    /// until the summary pass lands, and for ever when there is none (no
    /// summary key on the box, an old bridge, a turn with no reply).
    public func spokenSummary(convoID: String, for reply: AgentReplyRow) throws -> SummaryEntryRecord? {
        guard let ref = reply.messageRef else { return nil }
        return try dbQueue.read { db in
            try SummaryEntryRecord.fetchOne(db, sql: """
                SELECT * FROM summary_entry
                WHERE convo_id = ? AND spoken IS NOT NULL AND spoken_ref = ?
                ORDER BY seq DESC LIMIT 1
                """, arguments: [convoID, ref])
        }
    }
}
