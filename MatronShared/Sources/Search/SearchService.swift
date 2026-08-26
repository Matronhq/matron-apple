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

    /// Queries by free-text, grouped per conversation: at most `limit`
    /// rooms, each carrying its total match count and its newest hit,
    /// ordered by that newest hit's recency. The unit of the search UI's
    /// Messages section.
    func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit]

    /// Queries by free-text within ONE conversation. Returns at most
    /// `limit` hits, newest first — the in-conversation search's match
    /// list, navigated hit by hit.
    func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit]

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
    ///
    /// While a `SearchBackfillCoordinator` sweep may be running, call
    /// `SearchBackfillCoordinator.reset()` instead of this directly: only
    /// the coordinator's epoch guard stops an in-flight batch from
    /// re-inserting the bookkeeping this deletes.
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

    /// Default for fakes: group a flat query in memory. `SearchServiceLive`
    /// overrides with a single grouped SQL pass — this fallback's counts are
    /// only as complete as the flat query's limit.
    func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] {
        let hits = try await query(text, limit: 1_000)
        var order: [String] = []
        var grouped: [String: (count: Int, newest: SearchHit)] = [:]
        for hit in hits {  // hits are newest-first, so the first per room wins
            if var entry = grouped[hit.roomID] {
                entry.count += 1
                grouped[hit.roomID] = entry
            } else {
                grouped[hit.roomID] = (1, hit)
                order.append(hit.roomID)
            }
        }
        return order.prefix(limit).map { SearchChatHit(roomID: $0, count: grouped[$0]!.count,
                                                       newestHit: grouped[$0]!.newest) }
    }

    /// Default for fakes: filter a flat query in memory. Live overrides
    /// with a room-scoped SQL query so `limit` applies post-filter.
    func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] {
        try await query(text, limit: 1_000).filter { $0.roomID == roomID }.prefix(limit).map { $0 }
    }
}
