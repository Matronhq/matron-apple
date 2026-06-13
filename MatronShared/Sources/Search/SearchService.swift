import Foundation

/// Local full-text search index over decrypted message bodies. Backed by
/// SQLite/FTS5 in production (`SearchServiceLive`); fakeable for view-model and
/// backfill tests.
public protocol SearchService: Sendable {
    /// Inserts a single message into the index. Idempotent on (roomID, eventID).
    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws

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

    /// Number of indexed events for `roomID` (used by BackfillRunner to resume).
    func eventCount(roomID: String) async throws -> Int

    /// True if an event with `eventID` is already indexed (used by BackfillRunner to skip duplicates).
    func contains(eventID: String) async throws -> Bool
}
