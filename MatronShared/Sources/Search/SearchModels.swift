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
