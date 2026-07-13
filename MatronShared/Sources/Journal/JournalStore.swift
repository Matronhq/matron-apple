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

    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64, lastTS: Int64? = nil) {
        self.id = id
        self.title = title
        self.sessionState = sessionState
        self.lastSeq = lastSeq
        self.snippet = snippet
        self.createdAt = createdAt
        self.lastTS = lastTS
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

    enum CodingKeys: String, CodingKey {
        case id, title, snippet, muted, hidden
        case sessionState = "session_state"
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case lastActivityTS = "last_activity_ts"
        case readUpToSeq = "read_up_to_seq"
        case unreadCount = "unread_count"
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
        try migrator.migrate(dbQueue)
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
                unreadCount: 0
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
                lastActivityTS: nil, muted: false, hidden: false, readUpToSeq: 0, unreadCount: 0)

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

    public func conversations() throws -> [ConversationRecord] {
        try dbQueue.read { db in
            try ConversationRecord
                .filter(Column("hidden") == false)
                .order(Column("last_seq").desc)
                .fetchAll(db)
        }
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
            try ConversationRecord
                .filter(Column("hidden") == false)
                .order(Column("last_seq").desc)
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
