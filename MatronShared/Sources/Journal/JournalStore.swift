import Foundation
import GRDB

/// Server-side conversation summary (shape of /snapshot rows). Also the
/// input to store upserts, so it lives here rather than in JournalAPI.
public struct ConvoSummaryDTO: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sessionState: String
    public let lastSeq: Int64
    public let snippet: String
    public let createdAt: Int64

    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64) {
        self.id = id
        self.title = title
        self.sessionState = sessionState
        self.lastSeq = lastSeq
        self.snippet = snippet
        self.createdAt = createdAt
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

/// Local mirror of the user's journal. The UI reads ONLY this store; the
/// sync engine is the only writer. `cursor` advances inside the same
/// transaction as the event insert — the wedge-proof property.
public final class JournalStore: @unchecked Sendable {
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
            try existing.update(db)
        } else {
            try ConversationRecord(
                id: c.id, title: c.title, sessionState: c.sessionState,
                lastSeq: c.lastSeq, snippet: c.snippet, createdAt: c.createdAt,
                lastActivityTS: nil, muted: false, hidden: false,
                readUpToSeq: resetLocalState ? c.lastSeq : 0,
                unreadCount: 0
            ).insert(db)
        }
    }

    // MARK: Journal apply

    @discardableResult
    public func applyJournal(_ event: JournalEvent) throws -> Bool {
        try dbQueue.write { db in
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            guard event.seq > current else { return false }
            try EventRecord(event).save(db)

            var convo = try ConversationRecord.fetchOne(db, key: event.convoID) ?? ConversationRecord(
                id: event.convoID, title: "", sessionState: "running", lastSeq: 0,
                snippet: "", createdAt: Int64(event.ts.timeIntervalSince1970 * 1000),
                lastActivityTS: nil, muted: false, hidden: false, readUpToSeq: 0, unreadCount: 0)

            convo.lastSeq = max(convo.lastSeq, event.seq)
            convo.lastActivityTS = Int64(event.ts.timeIntervalSince1970 * 1000)

            let payload = event.payload
            if event.type == JournalEventType.sessionStatus {
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
            // .async(onQueue:) may be started from any thread (unlike .immediate,
            // which asserts off-main); the initial value is fetched and delivered
            // on the next main-queue hop, which is "immediate" from an
            // AsyncStream consumer's point of view. Crucially the cancellable is
            // assigned synchronously, so onTermination can never miss it.
            let cancellable = observation.start(in: dbQueue, scheduling: .async(onQueue: .main)) { _ in
                continuation.finish()
            } onChange: { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
