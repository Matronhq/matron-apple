import Foundation

/// A single full-text search match, surfaced in the Messages section of the
/// search UI. `snippet` carries FTS5 `<mark>…</mark>` markup around the matched
/// terms; `SearchResultRow` parses it into a highlighted `Text`.
public struct SearchHit: Equatable, Identifiable, Sendable {
    public let id: String                  // event ID
    public let roomID: String
    public let sender: String
    public let timestamp: Date
    public let snippet: String             // contains <mark>…</mark> markup

    public init(id: String, roomID: String, sender: String, timestamp: Date, snippet: String) {
        self.id = id; self.roomID = roomID; self.sender = sender; self.timestamp = timestamp; self.snippet = snippet
    }
}

/// One conversation's aggregate in the grouped message-search results:
/// how many messages match, plus the newest matching message's snippet for
/// the row's preview line. The search UI shows ONE of these per chat
/// (WhatsApp-style) instead of a flat flood of per-message hits — a common
/// word's screenful of same-chat rows drowned everything else (Dan,
/// 2026-08-26). `newestHit` doubles as the jump target when the user opens
/// the chat's in-conversation search.
public struct SearchChatHit: Equatable, Identifiable, Sendable {
    public var id: String { roomID }
    public let roomID: String
    /// Total matching messages in this conversation.
    public let count: Int
    /// The newest matching message — timestamp orders the grouped list,
    /// snippet feeds the row preview.
    public let newestHit: SearchHit

    public init(roomID: String, count: Int, newestHit: SearchHit) {
        self.roomID = roomID; self.count = count; self.newestHit = newestHit
    }
}

/// Per-room backfill progress, recorded into / read from `indexed_rooms`.
/// (Distinct from the UI-facing aggregate progress across all rooms, which the
/// view model models separately.)
public struct BackfillProgress: Equatable, Sendable {
    public let roomID: String
    public let eventsIndexed: Int
    public let isComplete: Bool

    public init(roomID: String, eventsIndexed: Int, isComplete: Bool) {
        self.roomID = roomID; self.eventsIndexed = eventsIndexed; self.isComplete = isComplete
    }
}
