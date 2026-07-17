import Foundation
import GRDB
import os

/// Server-side conversation summary (shape of /snapshot rows). Also the
/// input to store upserts, so it lives here rather than in JournalAPI.
public struct ConvoSummaryDTO: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sessionState: String
    public let lastSeq: Int64
    public let snippet: String
    public let createdAt: Int64
    /// Timestamp (ms) of the conversation's newest event, when the server
    /// includes it (`last_ts`, added after v1). `nil` on older servers —
    /// upserts then leave the stored `lastActivityTS` alone rather than
    /// regress it.
    public let lastTS: Int64?
    /// Parent conversation id for a subagent child, else `nil` (a normal
    /// conversation). Immutable server-side — a snapshot row that omits it
    /// (older server) must not clear a linkage learned live via convo_meta.
    public let parentConvoID: String?

    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64, lastTS: Int64? = nil, parentConvoID: String? = nil) {
        self.id = id
        self.title = title
        self.sessionState = sessionState
        self.lastSeq = lastSeq
        self.snippet = snippet
        self.createdAt = createdAt
        self.lastTS = lastTS
        self.parentConvoID = parentConvoID
    }
}

public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "conversation"

    public var id: String
    public var title: String
    public var sessionState: String
    public var lastSeq: Int64
    public var snippet: String
    public var createdAt: Int64
    public var lastActivityTS: Int64?
    public var muted: Bool
    public var hidden: Bool
    public var readUpToSeq: Int64
    public var unreadCount: Int
    /// Parent conversation id for a subagent child, else `nil`. Set at row
    /// creation from convo_meta / snapshot and never repointed (server-side
    /// immutable). Drives the chat-list filter (`parent_convo_id IS NULL`)
    /// and `children(of:)`.
    public var parentConvoID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, snippet, muted, hidden
        case sessionState = "session_state"
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case lastActivityTS = "last_activity_ts"
        case readUpToSeq = "read_up_to_seq"
        case unreadCount = "unread_count"
        case parentConvoID = "parent_convo_id"
    }
}

struct EventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "event"
    var seq: Int64
    var convoID: String
    var ts: Int64
    var sender: String
    var type: String
    var payload: Data

    enum CodingKeys: String, CodingKey {
        case seq, ts, sender, type, payload
        case convoID = "convo_id"
    }

    var journalEvent: JournalEvent {
        JournalEvent(seq: seq, convoID: convoID, ts: Date(timeIntervalSince1970: Double(ts) / 1000),
                     sender: sender, type: type, payloadData: payload)
    }

    init(_ e: JournalEvent) {
        seq = e.seq
        convoID = e.convoID
        ts = Int64(e.ts.timeIntervalSince1970 * 1000)
        sender = e.sender
        type = e.type
        payload = e.payloadData
    }
}

/// Test-only error thrown by `JournalStore.failApplyForTesting`'s injection
/// hook. Not meant to be pattern-matched by production code.
enum JournalStoreTestError: Error {
    case simulatedWriteFailure
}

/// Local mirror of the user's journal. The UI reads ONLY this store; the
/// sync engine is the only writer. `cursor` advances inside the same
/// transaction as the event insert — the wedge-proof property.
public final class JournalStore: @unchecked Sendable {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-store")
    private let dbQueue: DatabaseQueue
    private let ownSender: String

    public init(databaseURL: URL?, ownSender: String) throws {
        self.ownSender = ownSender
        if let url = databaseURL {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: url.path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("session_state", .text).notNull().defaults(to: "running")
                t.column("last_seq", .integer).notNull().defaults(to: 0)
                t.column("snippet", .text).notNull().defaults(to: "")
                t.column("created_at", .integer).notNull().defaults(to: 0)
                t.column("last_activity_ts", .integer)
                t.column("muted", .boolean).notNull().defaults(to: false)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("read_up_to_seq", .integer).notNull().defaults(to: 0)
                t.column("unread_count", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "event") { t in
                t.column("seq", .integer).primaryKey()
                t.column("convo_id", .text).notNull().indexed()
                t.column("ts", .integer).notNull()
                t.column("sender", .text).notNull()
                t.column("type", .text).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        // v2: subagent sub-chats. A conversation gains a nullable, indexed
        // `parent_convo_id` — null for normal conversations, the parent's
        // convo id for a subagent child. Additive column: existing rows
        // survive with a NULL default, so a device that already synced its
        // journal keeps every conversation and simply treats them all as
        // top-level until the bridge starts publishing children.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "parent_convo_id", .text)
            }
            try db.create(indexOn: "conversation", columns: ["parent_convo_id"])
        }
        try migrator.migrate(dbQueue)
        // Boot-time TTL sweep, mirroring the server's expire-logs job
        // (matron-journal docs/protocol.md Retention): a cached live_log
        // snippet must not outlive the 24h TTL just because this device
        // never re-synced the row. Best-effort — a failed sweep must not
        // block opening the store (the mapper's render-time TTL guard keeps
        // the DISPLAY correct either way; the sweep is what cleans the disk).
        do {
            try purgeExpiredToolOutputSnippets()
        } catch {
            Self.logger.error("tool-output TTL sweep failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Tool-output TTL

    /// Rewrites every `tool_output` event payload with `live_log: true`
    /// older than 24h to the server's tombstone shape — snippet removed,
    /// `expired: true`, `blob_ref: null` — and, when the purged event is
    /// still the newest message-type event in its conversation, rewrites the
    /// conversation-list preview to `$ <command>` exactly as the server
    /// does. Idempotent: already-expired payloads are skipped. `now` is
    /// injectable for tests only.
    public func purgeExpiredToolOutputSnippets(now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(24 * 3600 * 1000)
        try dbQueue.write { db in
            let rows = try EventRecord
                .filter(Column("type") == JournalEventType.toolOutput && Column("ts") <= cutoff)
                .fetchAll(db)
            for var row in rows {
                guard var payload = (try? JSONSerialization.jsonObject(with: row.payload)) as? [String: Any],
                      payload["live_log"] as? Bool == true,
                      payload["expired"] as? Bool != true
                else { continue }
                payload.removeValue(forKey: "snippet")
                payload["expired"] = true
                payload["blob_ref"] = NSNull()
                row.payload = try JSONSerialization.data(withJSONObject: payload)
                try row.update(db)

                guard let command = payload["command"] as? String, !command.isEmpty,
                      var convo = try ConversationRecord.fetchOne(db, key: row.convoID)
                else { continue }
                let newestMessageSeq = try Self.newestMessageSeq(db, convoID: row.convoID)
                if newestMessageSeq == row.seq {
                    convo.snippet = String("$ \(command)".prefix(120))
                    try convo.update(db)
                }
            }
        }
    }

    private static func newestMessageSeq(_ db: Database, convoID: String) throws -> Int64? {
        let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [convoID]
        arguments.append(contentsOf: Array(JournalEventType.messageTypes))
        return try Int64.fetchOne(db, sql: """
            SELECT MAX(seq) FROM event WHERE convo_id = ? AND type IN (\(placeholders))
            """, arguments: StatementArguments(arguments))
    }

    // MARK: Cursor

    public var cursor: Int64 {
        (try? dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'")
        }) ?? 0
    }

    private static func setCursor(_ db: Database, _ value: Int64) throws {
        try db.execute(
            sql: "INSERT INTO meta(key, value) VALUES('cursor', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [value])
    }

    // MARK: Snapshot

    public func applyColdSnapshot(_ convos: [ConvoSummaryDTO], headSeq: Int64) throws {
        try dbQueue.write { db in
            for c in convos {
                try Self.upsertSummary(db, c, resetLocalState: true)
            }
            try Self.setCursor(db, headSeq)
        }
    }

    public func refreshSummaries(_ convos: [ConvoSummaryDTO]) throws {
        try dbQueue.write { db in
            for c in convos {
                try Self.upsertSummary(db, c, resetLocalState: false)
            }
        }
    }

    private static func upsertSummary(_ db: Database, _ c: ConvoSummaryDTO, resetLocalState: Bool) throws {
        if var existing = try ConversationRecord.fetchOne(db, key: c.id) {
            existing.title = c.title
            existing.sessionState = c.sessionState
            // parent_convo_id is immutable once known: set it only when this
            // row doesn't have one yet (a live convo_meta may have taught us
            // the linkage before /snapshot; an older server omitting the
            // field must not clear it). Never repointed.
            if existing.parentConvoID == nil, let parent = c.parentConvoID {
                existing.parentConvoID = parent
            }
            if c.lastSeq > existing.lastSeq {
                existing.lastSeq = c.lastSeq
                existing.snippet = c.snippet
            }
            // Without this a snapshot refresh could advance the snippet but
            // leave the displayed "last activity" time frozen at whatever
            // journal frame was applied last (the "20h ago" row hiding
            // 4-minute-old messages). Monotonic max so a stale snapshot
            // can't roll a fresher live-frame timestamp backwards.
            if let ts = c.lastTS, ts > (existing.lastActivityTS ?? 0) {
                existing.lastActivityTS = ts
            }
            try existing.update(db)
        } else {
            try ConversationRecord(
                id: c.id, title: c.title, sessionState: c.sessionState,
                lastSeq: c.lastSeq, snippet: c.snippet, createdAt: c.createdAt,
                lastActivityTS: c.lastTS, muted: false, hidden: false,
                readUpToSeq: resetLocalState ? c.lastSeq : 0,
                unreadCount: 0, parentConvoID: c.parentConvoID
            ).insert(db)
        }
    }

    // MARK: Journal apply

    /// Test-only failure injection: when set and it returns `true` for a
    /// given seq, `applyJournal` throws instead of writing, simulating a
    /// disk-full / SQLite I/O error without needing a real failing backend.
    /// Checked at the very top of `applyJournal`, before the transaction
    /// opens, so nothing is written and the cursor is left untouched — the
    /// same shape a real write failure takes. Internal (not public):
    /// production code never sets this; only `@testable import` test targets
    /// can reach it.
    var failApplyForTesting: ((Int64) -> Bool)?

    @discardableResult
    public func applyJournal(_ event: JournalEvent) throws -> Bool {
        if failApplyForTesting?(event.seq) == true {
            throw JournalStoreTestError.simulatedWriteFailure
        }
        return try dbQueue.write { db in
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            guard event.seq > current else { return false }
            try EventRecord(event).save(db)

            var convo = try ConversationRecord.fetchOne(db, key: event.convoID) ?? ConversationRecord(
                id: event.convoID, title: "", sessionState: "running", lastSeq: 0,
                snippet: "", createdAt: Int64(event.ts.timeIntervalSince1970 * 1000),
                lastActivityTS: nil, muted: false, hidden: false, readUpToSeq: 0,
                unreadCount: 0, parentConvoID: nil)

            convo.lastSeq = max(convo.lastSeq, event.seq)
            // Only real message traffic counts as "activity" for the chat
            // list's timestamp. Bumping it for every frame meant merely
            // OPENING a conversation stamped it "now": markAsRead sends a
            // read_marker op, the server echoes it as a journal row with a
            // fresh ts, and the list showed phantom aliveness. (lastSeq
            // still tracks every frame — it mirrors the server's last_seq,
            // which drives snapshot ordering.)
            if JournalEventType.messageTypes.contains(event.type) {
                convo.lastActivityTS = Int64(event.ts.timeIntervalSince1970 * 1000)
            }

            let payload = event.payload
            if event.type == JournalEventType.convoMeta {
                // Live title updates (and the title of a conversation that
                // first appears over the socket, e.g. one the bridge just
                // created). Without this branch, titles only ever came from
                // /snapshot, so newly-created convos rendered blank until a
                // reconnect. Empty titles are ignored so a stray meta frame
                // can't wipe a good title.
                if let title = payload["title"] as? String, !title.isEmpty {
                    convo.title = title
                }
                // Learn the parent linkage the moment a child is created —
                // the bridge always fans out a convo_meta (even titleless)
                // carrying parent_convo_id, so live clients link the child
                // to its parent without waiting for /snapshot. Immutable:
                // set once, never repointed, never cleared by a later meta
                // that omits the field.
                if convo.parentConvoID == nil,
                   let parent = payload["parent_convo_id"] as? String, !parent.isEmpty {
                    convo.parentConvoID = parent
                }
            } else if event.type == JournalEventType.sessionStatus {
                if let state = payload["state"] as? String { convo.sessionState = state }
            } else if event.type == JournalEventType.readMarker {
                // All read_markers are the user's own (other devices included).
                let upTo = (payload["up_to_seq"] as? NSNumber)?.int64Value ?? 0
                convo.readUpToSeq = max(convo.readUpToSeq, upTo)
                convo.unreadCount = try Self.recountUnread(db, convoID: convo.id,
                                                           after: convo.readUpToSeq, ownSender: ownSender)
            } else if JournalEventType.messageTypes.contains(event.type) {
                convo.snippet = Self.snippet(type: event.type, payload: payload)
                if event.sender != ownSender, event.seq > convo.readUpToSeq {
                    convo.unreadCount += 1
                }
            }
            try convo.save(db)
            try Self.setCursor(db, event.seq)
            return true
        }
    }

    private static func recountUnread(_ db: Database, convoID: String, after seq: Int64, ownSender: String) throws -> Int {
        let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [convoID, seq]
        arguments.append(contentsOf: Array(JournalEventType.messageTypes))
        arguments.append(ownSender)
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM event
            WHERE convo_id = ? AND seq > ? AND type IN (\(placeholders)) AND sender != ?
            """, arguments: StatementArguments(arguments)) ?? 0
    }

    /// Mirrors the server's snippetOf (src/journal.js).
    static func snippet(type: String, payload: [String: Any]) -> String {
        switch type {
        case JournalEventType.text:
            return String((payload["body"] as? String ?? "").prefix(120))
        case JournalEventType.prompt:
            return "? " + String((payload["question"] as? String ?? "").prefix(110))
        case JournalEventType.permissionRequest:
            return "permission: " + String((payload["description"] as? String ?? "").prefix(100))
        default:
            if let s = payload["snippet"] as? String { return String(s.prefix(120)) }
            return "[\(type)]"
        }
    }

    // MARK: History

    public func insertHistory(_ events: [JournalEvent]) throws {
        try dbQueue.write { db in
            for e in events {
                try EventRecord(e).insert(db, onConflict: .ignore)
            }
            // Paginated rows can include unread messages (e.g. the refill
            // after a snapshot_required wipe re-fetches the newest page).
            // Live `applyJournal` counts unread incrementally; without a
            // recount here the chat list under-reports until the next
            // read_marker frame lands (bugbot "History insert skips unread").
            for convoID in Set(events.map(\.convoID)) {
                guard var convo = try ConversationRecord.fetchOne(db, key: convoID) else { continue }
                convo.unreadCount = try Self.recountUnread(db, convoID: convoID,
                                                           after: convo.readUpToSeq, ownSender: ownSender)
                try convo.update(db)
            }
        }
    }

    // MARK: Reads

    /// `now` is injectable for tests only; production callers take the
    /// default so every read reflects the wall clock at call time.
    public func conversations(now: Date = Date()) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let records = try ConversationRecord
                .filter(Column("hidden") == false)
                // Subagent children never appear in the main chat list — they
                // are reachable only through their parent's running-subagent
                // strip (spec §2). `IS NULL` also matches a device that hasn't
                // yet learned the linkage (parent_convo_id still NULL), which
                // is correct: an unlinked row is treated as top-level.
                .filter(Column("parent_convo_id") == nil)
                // Ordered by `last_activity_ts` (bumped only for message
                // traffic, see `applyJournal`) rather than `last_seq` alone
                // (bumped for every frame incl. read_marker/session_status)
                // so a bookkeeping frame from another device can't float a
                // stale chat to the top. `last_seq` is only a tiebreak
                // (e.g. rows sharing a null `last_activity_ts`); SQLite
                // sorts NULL last under DESC, so rows that never got an
                // activity timestamp fall to the bottom on their own.
                .order(Column("last_activity_ts").desc, Column("last_seq").desc)
                .fetchAll(db)
            return try records.map { try Self.applyReadTimeSnippetTTL($0, db: db, now: now) }
        }
    }

    /// A parent's subagent children, in creation order. Includes both
    /// running and finished children (`sessionState`) so callers filter —
    /// the running-subagent strip shows only `running`, the switcher menu
    /// lists all active ones. Nesting recurses naturally: a child's own
    /// children are just rows whose `parent_convo_id` is that child's id,
    /// so this works at any depth with no special casing.
    public func children(of parentConvoID: String) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            try ConversationRecord
                .filter(Column("parent_convo_id") == parentConvoID)
                .order(Column("created_at").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    /// The parent conversation id of `convoID`, or `nil` for a top-level
    /// conversation (or one whose linkage isn't known yet). Lets the sync
    /// engine keep subagent children out of live auto-navigation and any
    /// unread/notification surface without the caller reaching into the
    /// record shape.
    public func parentConvoID(of convoID: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT parent_convo_id FROM conversation WHERE id = ?",
                                arguments: [convoID])
        }
    }

    /// Read-time mirror of `purgeExpiredToolOutputSnippets`'s tombstone
    /// rewrite, applied WITHOUT a write. The boot-time sweep only runs when
    /// the store opens — an app left running past the 24h tool-output TTL
    /// (docs/protocol.md Retention) must still stop surfacing an expired
    /// `live_log` snippet in the conversation list the next time it's read,
    /// exactly as `JournalTimelineMapper` already hides it in the open
    /// thread (bugbot: "stale list preview after tool-snippet TTL"). Only
    /// touches the in-memory record; the disk sweep is still what cleans
    /// the payload.
    private static func applyReadTimeSnippetTTL(
        _ record: ConversationRecord, db: Database, now: Date
    ) throws -> ConversationRecord {
        guard let activityTS = record.lastActivityTS else { return record }
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(24 * 3600 * 1000)
        guard activityTS <= cutoff else { return record }
        guard let seq = try newestMessageSeq(db, convoID: record.id),
              let event = try EventRecord.fetchOne(db, key: seq),
              event.type == JournalEventType.toolOutput,
              let payload = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any],
              payload["live_log"] as? Bool == true,
              payload["expired"] as? Bool != true,
              let command = payload["command"] as? String, !command.isEmpty
        else { return record }
        var expired = record
        expired.snippet = String("$ \(command)".prefix(120))
        return expired
    }

    public func events(convoID: String) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq"))
                .fetchAll(db)
                .map(\.journalEvent)
        }
    }

    /// Whether a conversation row already exists. Used by the sync engine to
    /// tell a brand-new conversation (its first-ever frame) apart from a
    /// later frame on an existing one, so it can surface only the former.
    /// Creates a placeholder conversation row if none exists. The New Chat
    /// flow navigates by the convo_id a `start` RPC returned, which can
    /// land before the conversation's first journal frame — the target row
    /// must exist for list selection to hold. The real convo_meta /
    /// snapshot refresh overwrites the placeholder; an existing row is
    /// never touched.
    public func ensureConversation(id: String, title: String, now: Date = Date()) throws {
        try dbQueue.write { db in
            guard try ConversationRecord.fetchOne(db, key: id) == nil else { return }
            let ms = Int64(now.timeIntervalSince1970 * 1000)
            try ConversationRecord(
                id: id, title: title, sessionState: "running",
                lastSeq: 0, snippet: "", createdAt: ms,
                lastActivityTS: ms, muted: false, hidden: false,
                readUpToSeq: 0, unreadCount: 0, parentConvoID: nil
            ).insert(db)
        }
    }

    public func conversationExists(_ convoID: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM conversation WHERE id = ?)",
                              arguments: [convoID]) ?? false
        }
    }

    public func minSeq(convoID: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM event WHERE convo_id = ?", arguments: [convoID])
        }
    }

    public func maxSeq(convoID: String) throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM event WHERE convo_id = ?", arguments: [convoID])
        }
    }

    public func setMuted(_ muted: Bool, convoID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET muted = ? WHERE id = ?", arguments: [muted, convoID])
        }
    }

    public func setHidden(_ hidden: Bool, convoID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET hidden = ? WHERE id = ?", arguments: [hidden, convoID])
        }
    }

    public func wipe() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event; DELETE FROM conversation; DELETE FROM meta;")
        }
    }

    // MARK: Observation

    public func conversationsStream() -> AsyncStream<[ConversationRecord]> {
        let observation = ValueObservation.tracking { db in
            let records = try ConversationRecord
                .filter(Column("hidden") == false)
                .filter(Column("parent_convo_id") == nil)  // children live in the parent strip, not the list
                // See the matching comment on `conversations(now:)`:
                // `last_activity_ts` primary, `last_seq` tiebreak — a
                // bookkeeping-only frame must not float a stale chat to
                // the top just because it bumped `last_seq`.
                .order(Column("last_activity_ts").desc, Column("last_seq").desc)
                .fetchAll(db)
            // Fresh `Date()` per re-run: the tracking closure re-executes on
            // every DB change the store observes, so a subscriber that's
            // been open a while still gets the TTL re-evaluated against
            // current wall time rather than whatever "now" was at
            // subscribe time. See `applyReadTimeSnippetTTL`.
            return try records.map { try Self.applyReadTimeSnippetTTL($0, db: db, now: Date()) }
        }
        return Self.stream(observation, in: dbQueue)
    }

    /// Live stream of a parent's subagent children (in creation order,
    /// running + finished). Re-fires whenever a child is created, renamed,
    /// or transitions running→done, so the running-subagent strip and the
    /// switcher menu stay current without polling.
    public func childrenStream(of parentConvoID: String) -> AsyncStream<[ConversationRecord]> {
        let observation = ValueObservation.tracking { db in
            try ConversationRecord
                .filter(Column("parent_convo_id") == parentConvoID)
                .order(Column("created_at").asc, Column("id").asc)
                .fetchAll(db)
        }
        return Self.stream(observation, in: dbQueue)
    }

    public func eventsStream(convoID: String) -> AsyncStream<[JournalEvent]> {
        let observation = ValueObservation.tracking { db in
            try EventRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq"))
                .fetchAll(db)
                .map(\.journalEvent)
        }
        return Self.stream(observation, in: dbQueue)
    }

    private static func stream<T: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<T>>,
        in dbQueue: DatabaseQueue
    ) -> AsyncStream<T> {
        AsyncStream { continuation in
            // Box so the restart closure below can swap the live cancellable
            // without capturing itself recursively.
            let holder = ObservationHolder()
            // .async(onQueue:) may be started from any thread (unlike .immediate,
            // which asserts off-main); the initial value is fetched and delivered
            // on the next main-queue hop, which is "immediate" from an
            // AsyncStream consumer's point of view. Crucially the cancellable is
            // assigned synchronously, so onTermination can never miss it.
            //
            // On observation error: GRDB permanently ends the observation, and
            // finishing the stream here silently killed every UI surface fed by
            // it — the chat list / open timeline froze on their last snapshot
            // with no log and no recovery (bugbot "Observation errors end UI
            // streams"). A transient SQLite error (I/O pressure, interrupt)
            // shouldn't be terminal: log it loudly and re-subscribe after a
            // short pause. The fresh observation re-delivers the current value
            // on start, so consumers self-heal. Cancellation (onTermination)
            // stops any pending restart via the holder's `cancelled` latch.
            func subscribe() {
                holder.cancellable = observation.start(
                    in: dbQueue, scheduling: .async(onQueue: .main)
                ) { error in
                    Self.logger.error("value observation failed — restarting in 1s: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard !holder.cancelled else { return }
                        subscribe()
                    }
                } onChange: { value in
                    continuation.yield(value)
                }
            }
            subscribe()
            continuation.onTermination = { _ in
                // Hop to main so the latch write serializes with the
                // restart closure (also main-queue) — onTermination itself
                // can fire from any thread.
                DispatchQueue.main.async {
                    holder.cancelled = true
                    holder.cancellable?.cancel()
                }
            }
        }
    }

    /// Mutable box for the live observation cancellable + a cancellation
    /// latch, shared between `subscribe()` restarts and `onTermination`.
    /// All mutation happens on the main queue (observation scheduling, the
    /// restart dispatch, and the termination hop above), so plain vars are
    /// safe.
    private final class ObservationHolder: @unchecked Sendable {
        var cancellable: (any DatabaseCancellable)?
        var cancelled = false
    }
}
