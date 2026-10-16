import Foundation
import GRDB

/// Archived conversations (protocol "Archived conversations"): the
/// `archived_at` column, the archive feed's cursor, the Archived list, and
/// the purge of long-archived conversations' stored history.
extension JournalStore {
    /// `meta` key of the archive feed's cursor (`ArchiveSync`). Absent until
    /// this device first synced the archive with the journal; `wipe()`
    /// clears it with the rest of `meta`, so a re-bootstrapped mirror asks
    /// for the whole set again.
    static let archiveSinceKey = "archive_since"

    /// How long a conversation stays archived before its stored events
    /// (and their search rows) are dropped from this device. Its row stays.
    public static let archivedHistoryRetention: TimeInterval = 90 * 24 * 60 * 60

    /// Conversations whose history one purge transaction drops: small
    /// enough that a first pass over thousands of long-archived chats never
    /// holds the writer for long.
    static let archivePurgeChunkSize = 25

    // MARK: Cursor

    /// The archive feed's cursor, or nil when this device has not synced
    /// the archive with the journal yet.
    public func archiveSince() throws -> Int64? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.archiveSinceKey])
                .flatMap(Int64.init)
        }
    }

    /// Stores the cursor. Only ever moves it forward.
    public func setArchiveSince(_ at: Int64) throws {
        try db.write { db in try Self.advanceArchiveSince(db, to: at, creating: true) }
    }

    private static func advanceArchiveSince(_ db: Database, to at: Int64, creating: Bool) throws {
        let current = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [archiveSinceKey])
            .flatMap(Int64.init)
        guard current != nil || creating, at > (current ?? -1) else { return }
        try setMeta(db, key: archiveSinceKey, value: String(at))
    }

    // MARK: Writes

    /// The user's Archive (`archived: true`, stamped `now`) or Unarchive.
    /// A row already in that state is left as it is, so archiving twice
    /// keeps the first time.
    public func setArchived(_ convoIDs: [String], archived: Bool, now: Date = Date()) throws {
        guard !convoIDs.isEmpty else { return }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        try db.write { db in
            for id in convoIDs {
                try Self.writeArchive(db, convoID: id, archivedAt: archived ? ms : nil, keepingEarlier: true)
            }
        }
    }

    /// Changes from the journal's archive feed, in order, and the cursor
    /// moved to `at` once they are saved — only when one is stored already
    /// (the first sync stores it after its carry-over, `ArchiveSync`).
    /// Conversations this device does not have are skipped.
    public func applyArchiveChanges(_ changes: [ArchiveChange], advancingSinceTo at: Int64?) throws {
        try db.write { db in
            for change in changes {
                try Self.writeArchive(db, convoID: change.convoID, archivedAt: change.archivedAt, keepingEarlier: false)
            }
            if let at { try Self.advanceArchiveSince(db, to: at, creating: false) }
        }
    }

    /// The first sync's adoption of the journal's whole archived set:
    /// everything the journal has archived is archived here too, and what
    /// is archived only here stays archived. Returns those local-only ids,
    /// for the caller to send to the journal.
    public func adoptArchiveSet(_ changes: [ArchiveChange]) throws -> [String] {
        try db.write { db in
            var onJournal = Set<String>()
            for change in changes {
                if change.archivedAt != nil { onJournal.insert(change.convoID) } else { onJournal.remove(change.convoID) }
                guard change.archivedAt != nil else { continue }
                try Self.writeArchive(db, convoID: change.convoID, archivedAt: change.archivedAt, keepingEarlier: false)
            }
            let local = try String.fetchAll(db, sql: """
                SELECT id FROM conversation WHERE archived_at IS NOT NULL AND parent_convo_id IS NULL ORDER BY id
                """)
            return local.filter { !onJournal.contains($0) }
        }
    }

    /// Writes one row's archive state through `updateChanges`, so a no-op
    /// commits nothing and the change feed reports only real changes. An
    /// unarchive also clears `history_purged_at`: archived again later, the
    /// conversation is purged again in its turn.
    private static func writeArchive(_ db: Database, convoID: String, archivedAt: Int64?, keepingEarlier: Bool) throws {
        guard let original = try ConversationRecord.fetchOne(db, key: convoID) else { return }
        var record = original
        if let archivedAt {
            if record.archivedAt == nil || !keepingEarlier { record.archivedAt = archivedAt }
        } else {
            record.archivedAt = nil
            record.historyPurgedAt = nil
        }
        try record.updateChanges(db, from: original)
    }

    // MARK: Reads

    /// The Archived list: every archived top-level conversation, in the
    /// chat list's order (most recently active first). The one query behind
    /// `archivedConversations()` and `archivedConversationsStream()`, and
    /// what `ConversationIndex`'s Archived projection is held to.
    static func archivedListRecords(_ db: Database) throws -> [ConversationRecord] {
        try ConversationRecord
            .filter(Column("archived_at") != nil)
            .filter(Column("parent_convo_id") == nil)
            .order(Column("last_activity_ts").desc, Column("last_seq").desc)
            .fetchAll(db)
    }

    /// `archivedListRecords` with the read-time tool-output TTL applied.
    static func archivedList(_ db: Database, now: Date) throws -> [ConversationRecord] {
        try archivedListRecords(db).map { applyReadTimeSnippetTTL($0, now: now) }
    }

    public func archivedConversations(now: Date = Date()) throws -> [ConversationRecord] {
        try db.read { db in try Self.archivedList(db, now: now) }
    }

    /// Live Archived list. Like `conversationsStream()`, served from the
    /// `ConversationIndex` when the change feed is on.
    public func archivedConversationsStream() -> AsyncStream<[ConversationRecord]> {
        if usesChangeFeed { return conversationIndex.archivedListStream() }
        let observation = ValueObservation.measuredTracking("archivedConversationsStream", in: metrics) { db in
            try Self.archivedList(db, now: Date())
        }
        return Self.stream(observation.removeDuplicates(), in: db)
    }

    // MARK: Purging long-archived history

    /// Top-level conversations archived for longer than
    /// `archivedHistoryRetention` whose history is still stored, oldest
    /// archive first.
    public func archivedHistoryPurgeCandidates(now: Date = Date()) throws -> [String] {
        let cutoff = Int64(now.addingTimeInterval(-Self.archivedHistoryRetention).timeIntervalSince1970 * 1000)
        return try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM conversation
                WHERE archived_at IS NOT NULL AND archived_at < ? AND history_purged_at IS NULL
                  AND parent_convo_id IS NULL
                ORDER BY archived_at, id
                """, arguments: [cutoff])
        }
    }

    /// `convoIDs` and every sub-chat below them, at any depth: the rooms a
    /// purge of `convoIDs` drops, for the search index.
    public func conversationIDsIncludingSubChats(_ convoIDs: [String]) throws -> [String] {
        try db.read { db in try Self.withSubChats(db, convoIDs) }
    }

    private static func withSubChats(_ db: Database, _ convoIDs: [String]) throws -> [String] {
        var all = convoIDs
        var seen = Set(convoIDs)
        var frontier = convoIDs
        while !frontier.isEmpty {
            let marks = frontier.map { _ in "?" }.joined(separator: ",")
            let children = try String.fetchAll(db, sql: "SELECT id FROM conversation WHERE parent_convo_id IN (\(marks))",
                                               arguments: StatementArguments(frontier))
            frontier = children.filter { seen.insert($0).inserted }
            all += frontier
        }
        return all
    }

    /// Drops the stored events of `convoIDs` and of their sub-chats, and
    /// stamps `history_purged_at`. The conversation rows, their summaries
    /// and the tracker cache stay: the list still shows them, and opening
    /// one pages its history back from the journal
    /// (`JournalTimelineService.paginateBackward` finds no local rows and
    /// asks the server). A conversation that is no longer archived by the
    /// time its chunk runs is skipped. Runs in chunks, one transaction
    /// each. Returns the ids whose events were dropped.
    @discardableResult
    public func purgeArchivedHistory(_ convoIDs: [String], now: Date = Date()) throws -> [String] {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        var purged: [String] = []
        for start in stride(from: 0, to: convoIDs.count, by: Self.archivePurgeChunkSize) {
            let chunk = Array(convoIDs[start..<min(start + Self.archivePurgeChunkSize, convoIDs.count)])
            try db.write { db in
                try self.throwIfSuspended()
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let still = try String.fetchAll(db, sql: """
                    SELECT id FROM conversation
                    WHERE id IN (\(marks)) AND archived_at IS NOT NULL AND history_purged_at IS NULL
                    """, arguments: StatementArguments(chunk))
                guard !still.isEmpty else { return }
                let rooms = try Self.withSubChats(db, still)
                let roomMarks = rooms.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM event WHERE convo_id IN (\(roomMarks))", arguments: StatementArguments(rooms))
                let stillMarks = still.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "UPDATE conversation SET history_purged_at = ? WHERE id IN (\(stillMarks))",
                               arguments: StatementArguments([ms] as [DatabaseValueConvertible] + still))
                purged += rooms
            }
        }
        return purged
    }
}
