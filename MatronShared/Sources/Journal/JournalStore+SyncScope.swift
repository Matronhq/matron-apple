import Foundation
import GRDB

/// What the `forYou` sync scope needs from the mirror (protocol "Sync
/// scope"): the replay's closing `cursor` frame, and a record of how far each
/// conversation is complete, since most conversations' events no longer
/// arrive as they happen.
///
/// The record: every conversation is complete up to `forYouSince`, the
/// cursor when this device stopped mirroring everything. A conversation
/// fetched since then is complete up to its own `syncedSeq`. Both live in
/// `meta`, so `wipe()` clears them with everything else.
extension JournalStore {
    static let forYouSinceKey = "for_you_since"
    static func syncedSeqKey(_ convoID: String) -> String { "synced_seq:\(convoID)" }

    /// Moves the cursor forward to `seq`, never back.
    public func advanceCursor(to seq: Int64) throws {
        try metrics.measureWrite("advanceCursor", on: db) { db in
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            if seq > current { try Self.setCursor(db, seq) }
        }
    }

    /// The cursor when this device last switched to `forYou`, or nil when it
    /// has not since the mirror was last reset.
    public func forYouSince() throws -> Int64? {
        try metaInt(Self.forYouSinceKey)
    }

    /// Records the switch to `forYou`. Kept as it is if already set: the
    /// mirror stopped being complete at the first switch, not a later one.
    public func markForYouStart() throws {
        try metrics.measureWrite("markForYouStart", on: db) { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?",
                                      arguments: [Self.forYouSinceKey]) == nil else { return }
            let cursor = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            try Self.setMeta(db, key: Self.forYouSinceKey, value: String(cursor))
        }
    }

    /// How far `convoID` is known to be complete: its own record, else the
    /// switch point, else nothing (an empty mirror is complete up to 0).
    public func syncedSeq(convoID: String) throws -> Int64 {
        try metaInt(Self.syncedSeqKey(convoID)) ?? forYouSince() ?? 0
    }

    /// Records that `convoID` is complete up to `seq`, never moving back.
    public func setSyncedSeq(_ seq: Int64, convoID: String) throws {
        try metrics.measureWrite("setSyncedSeq", on: db) { db in
            try Self.raiseSyncedSeq(db, seq, convoID: convoID)
        }
    }

    /// Lands a conversation's newest events, fetched because it was opened.
    ///
    /// `events` is one or more newest-first pages, ascending. With
    /// `reachesSyncedSeq` false they did not reach back to what the mirror
    /// already held, so the stored events older than them are cut off from
    /// the present by a gap. Those are dropped in the same transaction: an
    /// open timeline must never show them next to the new ones as if
    /// nothing came between. Scrolling back fetches them again from the
    /// journal (`paginateBackward` pages below the oldest stored event).
    ///
    /// Returns the seqs dropped, for the search index.
    @discardableResult
    public func insertConversationTail(_ events: [JournalEvent], convoID: String, reachesSyncedSeq: Bool,
                                       now: Date = Date()) throws -> [Int64] {
        guard let oldest = events.first?.seq, let newest = events.last?.seq else { return [] }
        return try metrics.measureWrite("insertConversationTail", on: db) { db in
            var dropped: [Int64] = []
            if !reachesSyncedSeq {
                dropped = try Int64.fetchAll(db, sql: "SELECT seq FROM event WHERE convo_id = ? AND seq < ?",
                                             arguments: [convoID, oldest])
                if !dropped.isEmpty {
                    try db.execute(sql: "DELETE FROM event WHERE convo_id = ? AND seq < ?", arguments: [convoID, oldest])
                    try db.execute(sql: "DELETE FROM summary_entry WHERE convo_id = ? AND seq < ?",
                                   arguments: [convoID, oldest])
                }
            }
            try self.insertHistoryRows(db, events, now: now)
            try Self.raiseSyncedSeq(db, newest, convoID: convoID)
            return dropped
        }
    }

    private static func raiseSyncedSeq(_ db: Database, _ seq: Int64, convoID: String) throws {
        let key = syncedSeqKey(convoID)
        let current = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
            .flatMap(Int64.init)
        guard seq > (current ?? -1) else { return }
        try setMeta(db, key: key, value: String(seq))
    }

    private func metaInt(_ key: String) throws -> Int64? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]).flatMap(Int64.init)
        }
    }
}
