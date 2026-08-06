import Foundation

/// Local full-text search index over decrypted message bodies. Backed by
/// SQLite/FTS5 in production (`SearchServiceLive`); fakeable for view-model and
/// backfill tests.
public protocol SearchService: Sendable {
    /// Inserts a single message into the index. Idempotent on (roomID, eventID).
    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws

    /// Indexes many messages in one call. Same idempotence as `index`;
    /// `SearchServiceLive` does the whole batch in a single write
    /// transaction (a catch-up replay used to spawn one transaction — and
    /// one unstructured Task — per frame). A protocol requirement (not just
    /// an extension helper) so `any SearchService` dispatches to the live
    /// override; the extension default below keeps existing fakes compiling.
    func indexBatch(_ entries: [SearchIndexEntry]) async throws

    /// Removes a single event (used for redactions).
    func remove(eventID: String) async throws

    /// Queries by free-text. Returns at most `limit` hits, newest first.
    func query(_ text: String, limit: Int) async throws -> [SearchHit]

    /// Wipes all data (used on sign-out).
    func wipe() async throws

    /// Records progress for a room's backfill.
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws

    /// True if backfill has previously completed for `roomID`.
    func backfillComplete(roomID: String) async throws -> Bool

    /// The oldest event id a previous backfill walk reached for `roomID`
    /// (recorded via `recordBackfillProgress`), or `nil` if backfill has
    /// never run there. The walk's resume point.
    func backfillOldestEventID(roomID: String) async throws -> String?

    /// Clears all backfill bookkeeping while keeping the indexed messages.
    /// Called when the local journal mirror re-bootstraps from a snapshot:
    /// the unbridgeable replay gap means "complete" flags may now hide
    /// head-side holes, so every room must be re-walked (cheap — already-
    /// indexed events just re-INSERT OR REPLACE).
    func resetBackfill() async throws

    /// Number of indexed events for `roomID` (used by BackfillRunner to resume).
    func eventCount(roomID: String) async throws -> Int

    /// True if an event with `eventID` is already indexed (used by BackfillRunner to skip duplicates).
    func contains(eventID: String) async throws -> Bool
}

/// One message's index-ready fields — the unit of `indexBatch`.
public struct SearchIndexEntry: Sendable {
    public let roomID: String
    public let eventID: String
    public let sender: String
    public let timestamp: Date
    public let body: String

    public init(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) {
        self.roomID = roomID
        self.eventID = eventID
        self.sender = sender
        self.timestamp = timestamp
        self.body = body
    }
}

public extension SearchService {
    func indexBatch(_ entries: [SearchIndexEntry]) async throws {
        for entry in entries {
            try await index(roomID: entry.roomID, eventID: entry.eventID,
                            sender: entry.sender, timestamp: entry.timestamp, body: entry.body)
        }
    }
}
