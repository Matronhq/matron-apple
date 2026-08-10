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
    /// Which agent box (journal device id) currently manages this
    /// conversation, or `nil` when the server has never recorded one (a row
    /// predating the column, or a server predating this field). Unlike
    /// `parentConvoID` this is mutable — resuming a session on another box
    /// legitimately repoints it.
    public let agentDeviceID: Int64?

    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64, lastTS: Int64? = nil, parentConvoID: String? = nil, agentDeviceID: Int64? = nil) {
        self.id = id
        self.title = title
        self.sessionState = sessionState
        self.lastSeq = lastSeq
        self.snippet = snippet
        self.createdAt = createdAt
        self.lastTS = lastTS
        self.parentConvoID = parentConvoID
        self.agentDeviceID = agentDeviceID
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
    /// The agent box that manages this conversation. Drives the box chip in
    /// the chat list and header. Mutable (see `ConvoSummaryDTO`).
    public var agentDeviceID: Int64?

    enum CodingKeys: String, CodingKey {
        case id, title, snippet, muted, hidden
        case sessionState = "session_state"
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case lastActivityTS = "last_activity_ts"
        case readUpToSeq = "read_up_to_seq"
        case unreadCount = "unread_count"
        case parentConvoID = "parent_convo_id"
        case agentDeviceID = "agent_device_id"
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

/// One unsent text message in the offline send queue. Rows are created by
/// `JournalSyncEngine.sendMessage`, flushed FIFO on (re)connect with the
/// same `local_id` every attempt (the server folds it into the row's
/// idem_key, so at-least-once resends are dedup-safe — protocol.md
/// "Publishes and sends are at-least-once"), and deleted only when the
/// own-text journal frame confirming delivery is applied.
public struct OutboxRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "outbox"

    public enum State: String, Codable, Sendable {
        /// Waiting for a connection (or for the next flush pass).
        case queued
        /// Rejected or given up — resent only via an explicit user retry.
        case failed
    }

    public var localID: String
    public var convoID: String
    public var body: String
    public var createdAt: Int64
    public var state: State
    public var attempts: Int
    public var lastError: String?

    public var created: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }

    public init(localID: String, convoID: String, body: String, createdAt: Int64,
                state: State, attempts: Int, lastError: String?) {
        self.localID = localID
        self.convoID = convoID
        self.body = body
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case body, state, attempts
        case localID = "local_id"
        case convoID = "convo_id"
        case createdAt = "created_at"
        case lastError = "last_error"
    }
}

/// One TOC entry per bridge summary pass. Derived from `summary` journal
/// events; the event's own seq is the transcript anchor.
public struct SummaryEntryRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "summary_entry"
    public var convoID: String
    public var seq: Int64
    public var toc: String
    public var detail: String
    /// Milliseconds since epoch, like every other Int64 timestamp column in this store.
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case convoID = "convo_id", seq, toc, detail, createdAt = "created_at"
    }

    public init?(event: JournalEvent) {
        guard event.type == JournalEventType.summary,
              let obj = try? JSONSerialization.jsonObject(with: event.payloadData) as? [String: Any],
              let toc = obj["toc"] as? String, !toc.isEmpty
        else { return nil }
        self.convoID = event.convoID
        self.seq = event.seq
        self.toc = toc
        self.detail = obj["detail"] as? String ?? ""
        self.createdAt = Int64(event.ts.timeIntervalSince1970 * 1000)
    }
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
            var config = Configuration()
            config.prepareDatabase { db in
                // WAL, not the default rollback journal. The live sync path
                // commits one transaction per journal frame (several per
                // second during a streaming turn); in rollback mode each of
                // those creates, fsyncs, and deletes a `-journal` file.
                // synchronous=NORMAL is the documented-safe WAL pairing: a
                // power cut can lose the tail transactions but never
                // corrupts, and the cursor/insert invariant makes that loss
                // benign — the server replays everything past the cursor.
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            // File protection (iOS): the mirror and its WAL sidecars all
            // carry the OS default, CompleteUntilFirstUserAuthentication —
            // deliberately NOT upgraded to NSFileProtectionComplete like
            // the search index's, because background sync and BGAppRefresh
            // write here while the device is locked and Complete would fail
            // those writes. The sidecars match the main file's class, so
            // WAL introduces no protection downgrade.
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
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
        // v3: offline send queue. Text sends that can't reach the server
        // yet persist here (surviving relaunch and the snapshot_required
        // mirror wipe — see `wipe()`) and flush FIFO on reconnect.
        migrator.registerMigration("v3") { db in
            try db.create(table: "outbox") { t in
                t.column("local_id", .text).primaryKey()
                t.column("convo_id", .text).notNull().indexed()
                t.column("body", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("state", .text).notNull().defaults(to: "queued")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
            }
        }
        // v4: TOC summary entries — one row per bridge summary pass, derived
        // from `summary` journal events. seq doubles as the transcript anchor.
        migrator.registerMigration("v4") { db in
            try db.create(table: "summary_entry") { t in
                t.column("convo_id", .text).notNull().indexed()
                t.column("seq", .integer).notNull()
                t.column("toc", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.primaryKey(["convo_id", "seq"])
            }
        }
        // v5: agent-box attribution (spec: agent box rename). `agent` is the
        // id -> name mirror of the server's `agents` snapshot list; the
        // conversation column names which of those boxes owns the row.
        // Additive: existing rows keep NULL and simply render no chip until
        // the next snapshot fills them in.
        migrator.registerMigration("v5") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "agent_device_id", .integer)
            }
            try db.create(table: "agent") { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull()
            }
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
            // Absent means "this server/row doesn't say", never "clear it" —
            // same discipline as parent_convo_id. Unlike parent, a PRESENT
            // value always wins: ownership legitimately moves between boxes.
            if let box = c.agentDeviceID {
                existing.agentDeviceID = box
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
                unreadCount: 0, parentConvoID: c.parentConvoID,
                agentDeviceID: c.agentDeviceID
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
            try self.applyOne(db, event)
        }
    }

    /// Catch-up replay fast path: applies a whole run of frames in ONE
    /// transaction. `applyJournal` per frame means one fsync'd commit per
    /// frame — and, worse, one `ValueObservation` re-fire per frame, so
    /// every subscriber (the full chat-list query, the open conversation's
    /// entire event list) re-fetches per replayed row: O(backlog × history)
    /// during catch-up, which is why loading history after an offline
    /// stretch visibly crawled (Dan, 2026-08-02: "could it not be
    /// instant?"). Batching collapses that to one commit and one
    /// observation fire per batch.
    ///
    /// All-or-nothing: any thrown write rolls back the whole batch, leaving
    /// the cursor at its pre-batch value — the same "cursor never advances
    /// past a failed write" shape as the single-frame path, coarser by at
    /// most one batch (the engine salvages the prefix one-by-one on
    /// failure; see `applyReplayBatch`). Returns the events actually
    /// applied (duplicates with seq <= cursor are skipped, exactly as in
    /// `applyJournal`), in order, so the caller can run per-event side
    /// effects (search indexing, media-send confirmation) for real writes
    /// only.
    public func applyJournalBatch(_ events: [JournalEvent]) throws -> [JournalEvent] {
        guard !events.isEmpty else { return [] }
        if let fail = failApplyForTesting, events.contains(where: { fail($0.seq) }) {
            throw JournalStoreTestError.simulatedWriteFailure
        }
        return try dbQueue.write { db in
            var applied: [JournalEvent] = []
            applied.reserveCapacity(events.count)
            for event in events {
                if try self.applyOne(db, event) { applied.append(event) }
            }
            return applied
        }
    }

    /// Shared per-event apply body, called inside a `dbQueue.write`
    /// transaction by both `applyJournal` (own transaction per event) and
    /// `applyJournalBatch` (one transaction for the run). Returns `false`
    /// for a duplicate (seq <= cursor) without writing anything.
    private func applyOne(_ db: Database, _ event: JournalEvent) throws -> Bool {
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            guard event.seq > current else { return false }
            try EventRecord(event).save(db)
            if let entry = SummaryEntryRecord(event: event) {
                try entry.insert(db, onConflict: .ignore)
            }

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
                // Which box owns this conversation, learned live so a
                // brand-new convo chips immediately. Re-pointed freely: a
                // session resumed on another box changes owner.
                if let box = (payload["agent_device_id"] as? NSNumber)?.int64Value {
                    convo.agentDeviceID = box
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
            // Delivery confirmation for the offline outbox, in the SAME
            // transaction as the row insert: an own-text frame is a queued
            // send landing (body-match is the only signal — the server
            // strips idem_key from broadcast rows). Doing it here rather
            // than as a follow-up write means the confirming row and its
            // outbox delete commit or fail together, so a relaunch can
            // never show a durable duplicate echo beside the delivered
            // message.
            if event.sender == ownSender, event.type == JournalEventType.text,
               let body = payload["body"] as? String {
                try Self.outboxDeleteFirstMatching(db, convoID: event.convoID, body: body)
            }
            return true
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
            // The agent-chat consent card carries no `description`, so the
            // generic branch produced a bare "permission: " in the chat list
            // — and disagreed with the server, whose snippetOf returns this
            // string for the same event. A snapshot and a live frame must
            // not render the same row two different ways.
            if payload["kind"] as? String == "agent_chat" { return "🤝 Agent chat request" }
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
                if let entry = SummaryEntryRecord(event: e) {
                    try entry.insert(db, onConflict: .ignore)
                }
            }
            // Delivery confirmation for the post-snapshot_required gap:
            // `applyColdSnapshot` jumps the cursor past the frames that
            // would have confirmed sends delivered just before the wipe,
            // so those frames only ever come back through history refills.
            // Without this pass the rows stayed queued forever, re-flushing
            // (idem-deduped, but ghost-echoing) on every reconnect. The
            // `journaledAtMs` guard keeps old replayed history from eating
            // a fresh queued send with the same body.
            for e in events where e.sender == ownSender && e.type == JournalEventType.text {
                guard let body = e.payload["body"] as? String else { continue }
                try Self.outboxDeleteFirstMatching(
                    db, convoID: e.convoID, body: body,
                    journaledAtMs: Int64(e.ts.timeIntervalSince1970 * 1000))
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

    /// Every conversation id in the mirror — including hidden rows and
    /// subagent children, which `conversations()` filters out — ordered
    /// most-recently-active first. Backs the search-history backfill sweep:
    /// hidden and child conversations still hold searchable messages, and
    /// activity ordering indexes the conversations the user is most likely
    /// to search before the long tail. (DESC puts NULL activity rows last,
    /// same as `conversations()`.)
    public func allConversationIDs() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM conversation
                ORDER BY last_activity_ts DESC, last_seq DESC
                """)
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

    /// TOC entries for one conversation, newest first — the summary rail's
    /// one-shot read.
    public func summaryEntries(convoID: String) throws -> [SummaryEntryRecord] {
        try dbQueue.read { db in
            try SummaryEntryRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq").desc)
                .fetchAll(db)
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

    /// One conversation by id, or nil when this device has never seen it.
    /// The store has `conversations()` (whole list, list-filtered) and
    /// `conversationExists(_:)` (a bare bool) but nothing that hands back a
    /// single row — which the box-name resolver needs.
    public func conversation(id: String) throws -> ConversationRecord? {
        try dbQueue.read { db in
            try ConversationRecord.fetchOne(db, key: id)
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

    /// Clears the journal mirror (events, conversations, cursor) but NOT
    /// the outbox: this runs on `snapshot_required` (replay gap too large),
    /// and a mirror wipe must not eat the user's unsent messages. Sign-out
    /// calls `wipeOutbox()` separately.
    public func wipe() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event; DELETE FROM conversation; DELETE FROM meta; DELETE FROM summary_entry;")
        }
    }

    // MARK: Outbox

    /// Enqueues one unsent text message. Idempotent on `localID` so a retry
    /// racing the original insert can't duplicate the row.
    public func outboxInsert(localID: String, convoID: String, body: String, now: Date = Date()) throws {
        try dbQueue.write { db in
            try OutboxRecord(
                localID: localID, convoID: convoID, body: body,
                createdAt: Int64(now.timeIntervalSince1970 * 1000),
                state: .queued, attempts: 0, lastError: nil
            ).insert(db, onConflict: .ignore)
        }
    }

    /// Every queued row across all conversations, oldest first — the flush
    /// order. Failed rows are excluded: they only move again via an
    /// explicit user retry (`outboxRequeue`).
    public func outboxPending() throws -> [OutboxRecord] {
        try dbQueue.read { db in
            try OutboxRecord
                .filter(Column("state") == OutboxRecord.State.queued.rawValue)
                .order(Column("created_at").asc, Column("local_id").asc)
                .fetchAll(db)
        }
    }

    /// All outbox rows for one conversation (queued AND failed), oldest
    /// first — what the timeline renders as pending/failed echoes.
    public func outboxRows(convoID: String) throws -> [OutboxRecord] {
        try dbQueue.read { db in
            try OutboxRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("created_at").asc, Column("local_id").asc)
                .fetchAll(db)
        }
    }

    /// One outbox row by primary key, or nil when it no longer exists
    /// (confirmed-deleted or discarded). The engine's rejection handler
    /// dispatches on the row's actual state — see
    /// `JournalSyncEngine.handleSendRejected`.
    public func outboxRow(localID: String) throws -> OutboxRecord? {
        try dbQueue.read { db in
            try OutboxRecord.fetchOne(db, key: localID)
        }
    }

    public func outboxMarkAttempt(localID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE outbox SET attempts = attempts + 1 WHERE local_id = ?",
                           arguments: [localID])
        }
    }

    public func outboxMarkFailed(localID: String, error: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE outbox SET state = 'failed', last_error = ? WHERE local_id = ?",
                           arguments: [error, localID])
        }
    }

    /// Puts a failed row back in the flush set (tap-to-retry).
    public func outboxRequeue(localID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE outbox SET state = 'queued', last_error = NULL WHERE local_id = ?",
                           arguments: [localID])
        }
    }

    public func outboxDelete(localID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE local_id = ?", arguments: [localID])
        }
    }

    /// Delivery confirmation: an own-text journal frame with `body` landed
    /// for `convoID` — delete the OLDEST attempted row with that body and
    /// return its `localID` (nil when nothing matches). The server strips
    /// the idem_key from broadcast rows, so body-match is the only signal
    /// (mirrors the echo-retirement heuristic in
    /// `JournalTimelineService.OverlayState.reconcile`). Only rows with
    /// `attempts > 0` qualify: a never-sent row can't be the one the frame
    /// confirms — deleting it would silently eat a message that never went
    /// out (e.g. the same text sent from another device).
    /// Queued rows are preferred over failed ones (mirroring the old echo
    /// retirement: "prefer a pending echo so a delivered copy's ack can't
    /// retire an undelivered one — but when only a failed copy matches,
    /// this own-row IS its successful retry landing").
    ///
    /// `applyJournal` runs the same deletion INSIDE its own transaction
    /// (via the static helper) so a confirming row and its outbox delete
    /// commit atomically — a delete failing after the row persisted would
    /// leave a durable duplicate echo after relaunch (bugbot "Outbox
    /// delete failure leaves duplicate"). This public wrapper remains for
    /// tests and non-transactional callers.
    @discardableResult
    public func outboxDeleteFirstMatching(convoID: String, body: String) throws -> String? {
        try dbQueue.write { db in
            try Self.outboxDeleteFirstMatching(db, convoID: convoID, body: body)
        }
    }

    /// `journaledAtMs` — when set, only rows created at or before that
    /// timestamp qualify: a confirming event can't predate its own row, so
    /// an OLD own-text replayed by history pagination must not retire a
    /// FRESH queued send with the same body (see `insertHistory`). Live
    /// `applyJournal` passes nil — its seq > cursor guard already excludes
    /// replays.
    @discardableResult
    private static func outboxDeleteFirstMatching(
        _ db: Database, convoID: String, body: String, journaledAtMs: Int64? = nil
    ) throws -> String? {
        let candidates = try OutboxRecord
            .filter(Column("convo_id") == convoID && Column("body") == body)
            .filter(Column("attempts") > 0)
            .order(Column("created_at").asc, Column("local_id").asc)
            .fetchAll(db)
            .filter { journaledAtMs == nil || $0.createdAt <= journaledAtMs! }
        guard let row = candidates.first(where: { $0.state == .queued }) ?? candidates.first
        else { return nil }
        try row.delete(db)
        return row.localID
    }

    /// Sign-out hygiene: the next account on this database file must not
    /// inherit (or send) the previous user's queued messages.
    public func wipeOutbox() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox")
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

    /// Live stream of one conversation's `session_state` — "running" while
    /// an agent turn is in flight, "waiting"/"done" otherwise, flipped by
    /// the bridge's durable `session_status` journal events at turn
    /// start/end. The floating stop button keys off this rather than the
    /// ephemeral activity indicator, which legitimately clears mid-turn
    /// (bridge dedups activity frames; the overlay staleness sweep drops a
    /// quiet indicator after 30s).
    public func sessionStateStream(convoID: String) -> AsyncStream<String> {
        let observation = ValueObservation.tracking { db in
            try ConversationRecord.fetchOne(db, key: convoID)?.sessionState ?? "waiting"
        }
        return Self.stream(observation, in: dbQueue)
    }

    /// Live stream of one conversation's outbox rows (queued + failed,
    /// oldest first). The timeline renders these as pending/failed echoes;
    /// re-fires on enqueue, state change, and delivery-confirmed delete.
    public func outboxStream(convoID: String) -> AsyncStream<[OutboxRecord]> {
        let observation = ValueObservation.tracking { db in
            try OutboxRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("created_at").asc, Column("local_id").asc)
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

    /// Live stream of one conversation's TOC entries, newest first.
    public func summaryEntriesStream(convoID: String) -> AsyncStream<[SummaryEntryRecord]> {
        let observation = ValueObservation.tracking { db in
            try SummaryEntryRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq").desc)
                .fetchAll(db)
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
