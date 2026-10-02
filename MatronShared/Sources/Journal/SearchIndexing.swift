import Foundation
import MatronSearch
import os

/// What the local search index holds, and why it is small.
///
/// Global search and find-in-chat ask the journal server first
/// (`ServerFirstSearchService`); the local index is the offline fallback,
/// fed only by what this device has actually displayed — live sync
/// (`JournalSyncEngine`) and backward pagination (`JournalTimelineService`).
/// There is no history download any more (Dan, 2026-10-02): each device
/// used to walk every conversation's history into a 450 MB index, 71% of
/// it subagent chatter, and the phone's copy still had holes.
extension JournalEvent {
    /// The index row for this event, or `nil` when it should not be
    /// indexed: a subagent chat (never shown in search), tool output (the
    /// server does not index it either — retrieval noise, and where
    /// credentials land), or an event with nothing searchable.
    public func searchIndexEntry(now: Date = Date()) -> SearchIndexEntry? {
        guard !convoID.contains(JournalEventType.childConvoInfix),
              let body = searchableBody(now: now) else { return nil }
        return SearchIndexEntry(roomID: convoID, eventID: String(seq), sender: sender, timestamp: ts, body: body)
    }

    /// The text the search index should hold for this event, or `nil` when
    /// the event carries nothing searchable — the same prose rule as the
    /// journal server's `indexableBody`: `text` bodies and `diff`s.
    ///
    /// `now` exists because what the store no longer HOLDS must never be
    /// indexed: nothing older than the 30-day retention window for `diff`
    /// (the backward-pagination feeder fetches from the server, which keeps
    /// bodies forever, so without this a page-in would re-add what the
    /// maintenance sweep removed), mirroring `EventTombstone`.
    public func searchableBody(now: Date = Date()) -> String? {
        let body: String? = switch type {
        case JournalEventType.text: payload["body"] as? String
        case JournalEventType.diff:
            ts.addingTimeInterval(EventTombstone.retentionWindow) > now
                // diff → snippet precedence mirrors JournalTimelineMapper.
                ? (payload["diff"] as? String ?? payload["snippet"] as? String) : nil
        default: nil
        }
        guard let body, !body.isEmpty else { return nil }
        return body
    }
}
