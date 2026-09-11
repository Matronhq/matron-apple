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
    /// Every agent box in a multi-agent room (the journal's recorded owner
    /// plus joined participants), or `nil` when the server omits the key —
    /// a solo conversation, a dissolved room, or a server predating the
    /// field. Absent never clears a stored set (same discipline as
    /// `agentDeviceID`); present replaces it wholesale.
    public let participants: [Int64]?

    public init(id: String, title: String, sessionState: String, lastSeq: Int64, snippet: String, createdAt: Int64, lastTS: Int64? = nil, parentConvoID: String? = nil, agentDeviceID: Int64? = nil, participants: [Int64]? = nil) {
        self.id = id
        self.title = title
        self.sessionState = sessionState
        self.lastSeq = lastSeq
        self.snippet = snippet
        self.createdAt = createdAt
        self.lastTS = lastTS
        self.parentConvoID = parentConvoID
        self.agentDeviceID = agentDeviceID
        self.participants = participants
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
    /// JSON-encoded `[Int64]` of every box in a multi-agent room (owner +
    /// joined participants, journal-ordered), else `nil`. Stored as text so
    /// the column stays a plain additive migration; read through
    /// `participantIDs`. Replaced wholesale when the wire sends the key,
    /// untouched when it doesn't (see `ConvoSummaryDTO.participants`).
    public var participants: String?

    /// The `type` of the newest message-type event in this conversation
    /// (`JournalEventType.messageTypes`), or `nil` when none has landed.
    /// Maintained on write (`applyOne`, `insertHistory`) so the chat list's
    /// read-time tool-output TTL is pure column logic — before v11 it ran a
    /// `MAX(seq)` sub-query on `event` per stale conversation, which is what
    /// made the whole list observation track the `event` table.
    public var lastMessageType: String?
    /// What the list must show instead of `snippet` once that newest
    /// message-type event's 24 h tool-log TTL has passed: `"$ <command>"`,
    /// capped at 120 characters like every other snippet. `nil` whenever
    /// substitution does not apply (not a tool_output, no command, or a
    /// legacy payload that was never a live log and is not tombstoned).
    public var expiredSnippet: String?

    /// Decoded `participants`. Empty for anything that is not a known
    /// multi-agent room (nil column, or a value that fails to decode).
    public var participantIDs: [Int64] {
        guard let participants,
              let ids = try? JSONDecoder().decode([Int64].self, from: Data(participants.utf8))
        else { return [] }
        return ids
    }

    static func encodeParticipants(_ ids: [Int64]) -> String? {
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, snippet, muted, hidden, participants
        case sessionState = "session_state"
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case lastActivityTS = "last_activity_ts"
        case readUpToSeq = "read_up_to_seq"
        case unreadCount = "unread_count"
        case parentConvoID = "parent_convo_id"
        case agentDeviceID = "agent_device_id"
        case lastMessageType = "last_message_type"
        case expiredSnippet = "expired_snippet"
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
    // Module-internal (not private): JournalStore+Items.swift extends this
    // type from a different file for the tracker cache (spec
    // 2026-09-08-items-tracker-apps task 4) and needs direct access.
    let dbQueue: DatabaseQueue
    private let ownSender: String

    /// How long the schema migration took during this store's open, or `nil`
    /// when every migration was already applied. Published rather than
    /// reported: `AppDependencies` turns it into the launch timeline's
    /// nested `migration` interval, so this module keeps no dependency on
    /// the timeline and writes no `UserDefaults` (see the plan's R7).
    public private(set) var lastMigrationDuration: Duration?

    /// Where this mirror lives, or `nil` for an in-memory store. Read by
    /// `StoreDiagnostics` for the Settings › Storage size row.
    public let databaseURL: URL?

    public init(databaseURL: URL?, ownSender: String) throws {
        self.ownSender = ownSender
        self.databaseURL = databaseURL
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
        // Migrations run synchronously here, before any caller can read the
        // store, so the one launch that runs v11 pays its index build and
        // backfill up front. `ContinuousClock` (not `Date`) because this is
        // an elapsed-time measurement: it cannot be skewed by an NTP step
        // landing mid-migration.
        let migrator = Self.migrator()
        let applied = (try? dbQueue.read { try migrator.appliedIdentifiers($0) }) ?? []
        let hasPending = migrator.migrations.contains { !applied.contains($0) }
        let clock = ContinuousClock()
        let began = clock.now
        try migrator.migrate(dbQueue)
        lastMigrationDuration = hasPending ? clock.now - began : nil
    }

    /// The full schema migration chain. Static (rather than inline in
    /// `init`) so tests can freeze a database at an intermediate version
    /// with `migrate(_:upTo:)` and prove a later migration's work against
    /// real pre-upgrade state.
    static func migrator() -> DatabaseMigrator {
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
        // v6: multi-agent room membership (spec: multi-agent room tags).
        // JSON `[Int64]` of the journal's owner + joined participant device
        // ids, NULL for everything that is not a room. Additive like v5:
        // existing rows keep NULL and chip as before until the next
        // snapshot / membership convo_meta fills them in.
        migrator.registerMigration("v6") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "participants", .text)
            }
        }
        // v7: backfill summary_entry from `summary` events already in the
        // local mirror. v4 created the table but only the live apply path
        // ever filled it, so a device that had synced history before
        // upgrading showed an empty TOC for every existing conversation
        // until a from-scratch re-sync. Runs as its own version (not folded
        // into v4) so installs that already ran v4 get backfilled too. Same
        // conversion and insert as the live path (`SummaryEntryRecord(event:)`
        // + insert-or-ignore), so backfilled rows are indistinguishable from
        // live-ingested ones and rows the live path already wrote win.
        // Payloads that don't decode to a TOC entry are skipped, exactly as
        // live ingest skips them. (`event` and `summary_entry` are still at
        // their v1/v4 shapes when v7 runs, so using the record types here is
        // safe.)
        migrator.registerMigration("v7") { db in
            let rows = try EventRecord
                .filter(Column("type") == JournalEventType.summary)
                .fetchAll(db)
            for row in rows {
                guard let entry = SummaryEntryRecord(event: row.journalEvent) else { continue }
                try entry.insert(db, onConflict: .ignore)
            }
        }
        // v8: journal-held roster tag characters (spec: box tag characters).
        // Mirrors the server's `tag_char` per agent box; NULL = automatic.
        // Additive like v5 — rows fill in from the next snapshot. Numbered v8
        // because main landed its own "v7" (the summary_entry backfill) first:
        // a duplicate identifier is a registration precondition failure, and
        // re-using the name on an installed device would silently skip this
        // column (GRDB records the identifier, not the body).
        migrator.registerMigration("v8") { db in
            try db.alter(table: "agent") { t in
                t.add(column: "tag_char", .text)
            }
        }
        // v9: tracker cache (spec 2026-09-08 task-decision-tracker). Filled
        // from GET /items, never from the event log; the `item` marker
        // event is only an invalidation signal (ItemsSync).
        migrator.registerMigration("v9") { db in
            try db.create(table: "item") { t in
                t.column("id", .text).primaryKey()
                t.column("num", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("resolution", .text)
                t.column("awaiting", .text)
                t.column("rank", .double).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("labels_json", .text).notNull().defaults(to: "[]")
                t.column("links_json", .text).notNull().defaults(to: "[]")
                t.column("attachments_json", .text).notNull().defaults(to: "[]")
                t.column("supersedes", .text)
                t.column("origin_convo_id", .text).notNull()
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("closed_at", .integer)
                t.column("comment_count", .integer).notNull().defaults(to: 0)
                t.column("last_comment_at", .integer)
                t.column("has_image", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "item_convo_state", on: "item", columns: ["origin_convo_id", "state"])
            try db.create(index: "item_state_rank", on: "item", columns: ["state", "rank"])
            try db.create(table: "item_comment") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().indexed()
                t.column("author", .text).notNull()
                t.column("device_id", .integer).notNull().defaults(to: 0)
                t.column("kind", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("attachments_json", .text).notNull().defaults(to: "[]")
                t.column("meta_json", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "item_outbox") { t in
                t.column("local_id", .text).primaryKey()
                t.column("item_id", .text).indexed()
                t.column("op", .text).notNull()
                t.column("payload_json", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
            }
        }
        // v10: mission cache (spec 2026-09-10 missions-milestones). Purely
        // ADDITIVE — three new tables plus two nullable columns on `item`.
        // Filled from GET /missions and GET /missions/:id, never from the
        // event log: the `mission`/`milestone` markers are invalidation
        // signals, and the journal omits their titles when they cross the
        // privacy boundary, so a marker is never a source of truth for a
        // name (MissionsSync).
        migrator.registerMigration("v10") { db in
            try db.create(table: "mission") { t in
                t.column("id", .text).primaryKey()
                t.column("num", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("close_summary", .text)
                t.column("closed_by", .text)
                t.column("closed_over_open_items", .integer).notNull().defaults(to: 0)
                t.column("origin_convo_id", .text).notNull()
                t.column("origin_device_id", .integer).notNull().defaults(to: 0)
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("last_milestone_at", .integer)
                t.column("closed_at", .integer)
                t.column("open_items", .integer).notNull().defaults(to: 0)
                t.column("needs_you", .integer).notNull().defaults(to: 0)
                t.column("conversation_count", .integer).notNull().defaults(to: 0)
                t.column("milestone_count", .integer).notNull().defaults(to: 0)
                t.column("last_milestone_json", .text)
            }
            try db.create(index: "mission_state_activity", on: "mission", columns: ["state", "last_milestone_at"])
            try db.create(index: "mission_origin", on: "mission", columns: ["origin_convo_id"])
            try db.create(table: "milestone") { t in
                t.column("id", .text).primaryKey()
                t.column("mission_id", .text).notNull()
                t.column("num", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("convo_id", .text).notNull()
                t.column("seq", .integer).notNull()
                t.column("device_id", .integer).notNull().defaults(to: 0)
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "milestone_mission", on: "milestone", columns: ["mission_id", "created_at"])
            try db.create(index: "milestone_convo", on: "milestone", columns: ["convo_id", "seq"])
            try db.create(table: "mission_conversation") { t in
                t.column("mission_id", .text).notNull()
                t.column("convo_id", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("box", .text)
                t.column("state", .text).notNull().defaults(to: "")
                t.primaryKey(["mission_id", "convo_id"])
            }
            try db.alter(table: "item") { t in
                t.add(column: "mission_id", .text)
                t.add(column: "mission_num", .integer)
            }
            try db.create(index: "item_mission", on: "item", columns: ["mission_id", "state", "awaiting"])
            // The two new columns above land as NULL on every item row
            // already cached — `ItemsSync.refreshOnce` fetches `?since=`
            // its persisted watermark, which skips rows the server hasn't
            // touched since, so those items would never gain a mission
            // until each one changes again (Bugbot). Clearing the
            // watermark keys (same statement `wipeItems()` runs) forces
            // the very next refresh, for every scope, to be a full
            // `GET /items` fetch that re-fills `mission_id`/`mission_num`
            // from the server's current values.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'items_watermark_all' OR key LIKE 'items_watermark_convo_%'")
        }
        // v11: launch performance (spec 2026-09-10). Purely ADDITIVE — one
        // index plus two nullable columns on `conversation`, then a
        // one-conversation-at-a-time backfill over the existing `convo_id`
        // index.
        //
        // `event_type_ts` is what makes the tool-output sweep incremental:
        // before it, every sweep was a full `event` scan (1.5 s and 75,791
        // row decodes on the Mac copy, on every store open).
        //
        // `last_message_type` / `expired_snippet` are what let the chat
        // list's TTL be pure column logic, which in turn stops the list
        // observation from tracking the `event` table at all.
        //
        // The backfill is the one-off cost of this migration — an index
        // build over ~457k rows plus one indexed point lookup per
        // conversation (~6k), estimated 2-4 s on the Mac copy, once.
        // `LaunchTimeline` records it as a nested `migration` interval so
        // the number on the phone is known rather than guessed.
        migrator.registerMigration("v11") { db in
            try db.create(index: "event_type_ts", on: "event", columns: ["type", "ts"])
            try db.alter(table: "conversation") { t in
                t.add(column: "last_message_type", .text)
                t.add(column: "expired_snippet", .text)
            }
            let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
            let messageTypes = Array(JournalEventType.messageTypes)
            for id in try String.fetchAll(db, sql: "SELECT id FROM conversation") {
                var arguments: [DatabaseValueConvertible] = [id]
                arguments.append(contentsOf: messageTypes)
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT type, payload FROM event
                    WHERE convo_id = ? AND type IN (\(placeholders))
                    ORDER BY seq DESC LIMIT 1
                    """, arguments: StatementArguments(arguments))
                else { continue }
                let type: String = row["type"]
                let payloadData: Data = row["payload"]
                try db.execute(
                    sql: "UPDATE conversation SET last_message_type = ?, expired_snippet = ? WHERE id = ?",
                    arguments: [type, Self.expiredSnippet(type: type, payloadData: payloadData), id])
            }
        }
        return migrator
    }

    // MARK: Background maintenance sweeps

    /// `meta` keys written by the sweeps. None is written by a migration;
    /// `wipe()`'s `DELETE FROM meta` resets all four, which is exactly
    /// right — a re-bootstrapped mirror must re-sweep from scratch.
    static let snippetTTLWatermarkKey = "snippet_ttl_ts"
    static let retentionWatermarkKey = "retention_ts"
    static let maintenanceLastRunKey = "maintenance_last_run"
    /// Separate from `retentionWatermarkKey`: the tombstone sweep runs
    /// whether or not a search index is attached (a locked background
    /// launch on iOS opens it late via `adoptSearch`, and `applyRetention`'s
    /// returned seqs were being silently dropped whenever that happened —
    /// Bugbot High "search removal is never retried" on PR #212). Search
    /// retirement is its own pass over the same `event_type_ts` range,
    /// gated on this independent watermark, so a maintenance run with no
    /// search attached leaves this watermark untouched and a later run
    /// (once search IS attached) re-discovers the same rows instead of
    /// having lost them.
    static let searchRetentionWatermarkKey = "search_retention_ts"

    /// Rows per write transaction. The store is a single-connection
    /// `DatabaseQueue`, so a sweep that took one transaction for the whole
    /// range would block every UI read for its duration; 500 keeps each
    /// transaction short enough to interleave.
    static let sweepChunkSize = 500

    /// Rewrites aged-out `tool_output` payloads to the tombstone shape,
    /// incrementally: everything at or below `meta.snippet_ttl_ts` was
    /// covered by an earlier sweep and is skipped, and the range scan uses
    /// the `event_type_ts` index rather than reading the whole table.
    ///
    /// Same name and signature as the boot-time sweep it replaces — the
    /// difference is that nothing calls it from `JournalStore.init` any
    /// more (`JournalMaintenance` owns it, off the launch path).
    ///
    /// First run after the update has no watermark and therefore scans every
    /// tool-output row older than 24 h once, in the background.
    public func purgeExpiredToolOutputSnippets(now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.toolLogTTL * 1000)
        _ = try sweepTombstones(types: [JournalEventType.toolOutput],
                                watermarkKey: Self.snippetTTLWatermarkKey,
                                cutoffMs: cutoff, now: now)
    }

    /// Local retention (spec §3.4 / §4 decision 1): tool-output and diff
    /// BODIES older than 30 days are tombstoned on this device. The server
    /// still has them; recovering them locally means a wipe + re-sync, which
    /// is the existing `snapshot_required` path.
    ///
    /// Returns every `tool_output`/`diff` seq this pass VISITED inside the
    /// retention range — not just the ones it rewrote. A row the 24h sweep
    /// already tombstoned (snippet gone, `expired: true`) is typically a
    /// no-op for the 30-day rule (its command is already short), so it
    /// would never appear in a rewrite-only list — but its search row was
    /// indexed while the row was still fresh, and nothing else ever visits
    /// this seq again (the watermark guarantees exactly one visit).
    ///
    /// `JournalMaintenance` no longer consumes this return value for search
    /// removal (Bugbot High, PR #212: a nil-or-not-yet-attached `search`
    /// made that removal silently permanent, since this watermark had
    /// already advanced past the rows by the time search was attached).
    /// Search retirement now runs off its own independent watermark via
    /// `pendingSearchRetirements(now:)` / `recordSearchRetirement(upTo:)`,
    /// scanning the same range on its own schedule. This method's signature
    /// and return value are unchanged — Task 4's tests pin them — the seqs
    /// are just no longer anyone's only path to the search index.
    @discardableResult
    public func applyRetention(now: Date = Date()) throws -> [Int64] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.retentionWindow * 1000)
        return try sweepTombstones(types: [JournalEventType.toolOutput, JournalEventType.diff],
                                   watermarkKey: Self.retentionWatermarkKey,
                                   cutoffMs: cutoff, now: now, returnAllVisited: true)
    }

    /// The shared sweep engine: walk `(type, ts)` forward from the watermark
    /// to `cutoffMs` in chunks, rewrite what `EventTombstone` changes, then
    /// move the watermark to the cutoff.
    ///
    /// Paging is keyset-based on `(ts, seq)` rather than OFFSET: rows sharing
    /// a millisecond are common (a batch apply stamps many at once), and an
    /// offset walk over a table being written underneath would skip them.
    ///
    /// - Parameter returnAllVisited: `false` (the TTL sweep) returns only
    ///   the seqs actually rewritten; `true` (retention) returns every seq
    ///   the scan visited in range, rewritten or not — see `applyRetention`.
    ///   Either way the actual payload writes are rewrite-only: this only
    ///   changes what the function reports, never what it touches on disk.
    private func sweepTombstones(types: [String], watermarkKey: String,
                                 cutoffMs: Int64, now: Date,
                                 returnAllVisited: Bool = false) throws -> [Int64] {
        var tombstoned: [Int64] = []
        var visited: [Int64] = []
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        var afterTS = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [watermarkKey]) ?? 0
        }
        // A persisted watermark can sit ABOVE this call's own cutoff: the
        // boot-time sweep (`JournalStore.init`) always runs at the real
        // wall clock, so on a store that is later driven with an injected
        // `now:` smaller than real time (every test, and any replay of
        // historical `now:` values), the watermark from that boot pass
        // would otherwise blind this scan to rows genuinely inside this
        // call's own `(0, cutoffMs]` range. Treat "watermark past our own
        // cutoff" as "nothing verified for OUR range yet" rather than as
        // coverage — it is never coverage for a smaller cutoff, since a
        // watermark only certifies the range it was actually computed
        // against.
        if afterTS > cutoffMs {
            afterTS = 0
        }
        // `Int64.max` on the first page makes the seed behave as `ts >
        // watermark`, so a row exactly at the watermark is not re-swept.
        var afterSeq = Int64.max
        while true {
            // `Task.isCancelled` reads the calling `Task`'s cancellation
            // flag when this synchronous function is invoked from inside
            // one (e.g. `JournalMaintenance.stop()` awaiting an in-flight
            // pass, R11); outside any `Task` — the `init`-time boot call —
            // it is always `false`, so that call is unaffected. Bailing at
            // a chunk boundary rather than mid-transaction, and skipping
            // the watermark write below on exit, means the chunks already
            // committed stay exactly as durable and idempotent as a normal
            // interrupted sweep (app killed mid-pass): the next call simply
            // resumes from the same watermark and re-covers the rest.
            if Task.isCancelled {
                return returnAllVisited ? visited : tombstoned
            }
            let chunk: [EventRecord] = try dbQueue.write { db in
                var arguments: [DatabaseValueConvertible] = types
                arguments.append(contentsOf: [cutoffMs, afterTS, afterTS, afterSeq])
                let rows = try EventRecord.fetchAll(db, sql: """
                    SELECT * FROM event
                    WHERE type IN (\(placeholders)) AND ts <= ?
                      AND (ts > ? OR (ts = ? AND seq > ?))
                    ORDER BY ts, seq
                    LIMIT \(Self.sweepChunkSize)
                    """, arguments: StatementArguments(arguments))
                var touched = Set<String>()
                for var row in rows {
                    visited.append(row.seq)
                    guard let payload = (try? JSONSerialization.jsonObject(with: row.payload)) as? [String: Any],
                          let rewritten = EventTombstone.apply(
                            to: payload, type: row.type,
                            ts: Date(timeIntervalSince1970: Double(row.ts) / 1000), now: now)
                    else { continue }
                    row.payload = try JSONSerialization.data(withJSONObject: rewritten)
                    try row.update(db)
                    tombstoned.append(row.seq)
                    touched.insert(row.convoID)
                }
                // A tombstoned row can be its conversation's newest message —
                // and a payload that was never a live log had no
                // `expired_snippet` at insert time, so the list would keep
                // showing a body that is no longer on disk. One indexed
                // lookup per touched conversation, and no write at all when
                // the columns already agree (so the chat-list observation
                // does not re-fire for a sweep that changed nothing it shows).
                for convoID in touched {
                    try Self.refreshLastMessageColumns(db, convoID: convoID)
                }
                return rows
            }
            guard let last = chunk.last else { break }
            afterTS = last.ts
            afterSeq = last.seq
        }
        try dbQueue.write { db in
            try Self.setMeta(db, key: watermarkKey, value: String(cutoffMs))
        }
        return returnAllVisited ? visited : tombstoned
    }

    /// Recomputes `last_message_type` / `expired_snippet` for one
    /// conversation, writing only when a value actually changed.
    static func refreshLastMessageColumns(_ db: Database, convoID: String) throws {
        guard var convo = try ConversationRecord.fetchOne(db, key: convoID) else { return }
        let columns = try newestMessageColumns(db, convoID: convoID)
        guard convo.lastMessageType != columns.type || convo.expiredSnippet != columns.expiredSnippet
        else { return }
        convo.lastMessageType = columns.type
        convo.expiredSnippet = columns.expiredSnippet
        try convo.update(db)
    }

    /// When the maintenance sweeps last completed a full pass — the Settings
    /// › Storage "Last maintenance" row, and the foreground scheduler's
    /// due-check. Stored as epoch milliseconds in `meta`, like the cursor.
    public func maintenanceLastRun() throws -> Date? {
        try dbQueue.read { db in
            guard let ms = try Int64.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Self.maintenanceLastRunKey]) else { return nil }
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
    }

    public func recordMaintenanceRun(at date: Date) throws {
        try dbQueue.write { db in
            try Self.setMeta(db, key: Self.maintenanceLastRunKey,
                             value: String(Int64(date.timeIntervalSince1970 * 1000)))
        }
    }

    /// `tool_output`/`diff` seqs whose bodies have aged past the retention
    /// window and have not yet been retired from the search index, plus the
    /// timestamp this call actually finished scanning up to.
    ///
    /// A read-only sibling of `sweepTombstones`, over the same
    /// `event_type_ts` range and the same 30-day cutoff as `applyRetention`,
    /// but gated on its own `searchRetentionWatermarkKey` rather than
    /// `retentionWatermarkKey` — see that key's doc comment for why the two
    /// must not share a watermark. Paged the same way (keyset on `(ts,
    /// seq)`, `sweepChunkSize` rows per chunk) so a large backlog doesn't
    /// hold one long read transaction.
    ///
    /// `cutoff` is the full `now − retentionWindow` instant — the same
    /// value `applyRetention(now:)` would tombstone up to — but ONLY when
    /// the scan actually ran to completion.
    ///
    /// On `Task.isCancelled`, this records NOTHING: `cutoff` falls back to
    /// the watermark the scan started from, so a caller that persists it
    /// via `recordSearchRetirement` writes back exactly what was already
    /// there — a pure no-op — and the next call re-scans this same,
    /// still-fully-outstanding range from scratch. The `seqs` collected
    /// before cancellation are still returned (harmless to remove from the
    /// search index; idempotent, and they get re-reported and re-removed
    /// next pass regardless).
    ///
    /// A cutoff derived from the last row actually seen was tried and
    /// reverted (re-review of PR #212, round 2A): a chunk fetch that
    /// returned a FULL `sweepChunkSize` never proves every row sharing that
    /// row's `ts` was fetched — same-millisecond ties are routine (a batch
    /// apply stamps many rows at once) — so persisting that `ts` as the new
    /// watermark could permanently orphan un-fetched siblings past it, since
    /// a resumed scan seeds `afterSeq = Int64.max` and so never revisits
    /// ties AT the watermark. `sweepTombstones` already treats cancellation
    /// this same way — persist nothing, let the next call redo the work —
    /// and there is no cost to matching it here: `pendingSearchRetirements`
    /// is read-only, so "redo the work" is just a re-scan, not a re-write.
    public func pendingSearchRetirements(now: Date = Date()) throws -> (seqs: [Int64], cutoff: Date) {
        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.retentionWindow * 1000)
        let types = [JournalEventType.toolOutput, JournalEventType.diff]
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        var afterTS = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?",
                               arguments: [Self.searchRetentionWatermarkKey]) ?? 0
        }
        // Same "watermark past our own cutoff means no coverage for THIS
        // call's range" rule as `sweepTombstones` — see its comment.
        if afterTS > cutoffMs { afterTS = 0 }
        // The value the scan STARTED from — what a cancelled scan reports
        // back as `cutoff`, below.
        let startTS = afterTS
        var afterSeq = Int64.max
        var seqs: [Int64] = []
        while true {
            if Task.isCancelled {
                return (seqs, Date(timeIntervalSince1970: Double(startTS) / 1000))
            }
            let chunk: [(seq: Int64, ts: Int64)] = try dbQueue.read { db in
                var arguments: [DatabaseValueConvertible] = types
                arguments.append(contentsOf: [cutoffMs, afterTS, afterTS, afterSeq])
                return try Row.fetchAll(db, sql: """
                    SELECT seq, ts FROM event
                    WHERE type IN (\(placeholders)) AND ts <= ?
                      AND (ts > ? OR (ts = ? AND seq > ?))
                    ORDER BY ts, seq
                    LIMIT \(Self.sweepChunkSize)
                    """, arguments: StatementArguments(arguments))
                    .map { (seq: $0["seq"] as Int64, ts: $0["ts"] as Int64) }
            }
            guard let last = chunk.last else { break }
            seqs.append(contentsOf: chunk.map { $0.seq })
            afterTS = last.ts
            afterSeq = last.seq
        }
        return (seqs, Date(timeIntervalSince1970: Double(cutoffMs) / 1000))
    }

    /// Advances the search-retention watermark. Callers must only invoke
    /// this after `SearchService.removeAll(eventIDs:)` has actually
    /// succeeded for the `seqs` that came with this `cutoff` from
    /// `pendingSearchRetirements` — see `JournalMaintenance.run`.
    public func recordSearchRetirement(upTo cutoff: Date) throws {
        try dbQueue.write { db in
            try Self.setMeta(db, key: Self.searchRetentionWatermarkKey,
                             value: String(Int64(cutoff.timeIntervalSince1970 * 1000)))
        }
    }

    static func setMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value])
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
            // Same absent-never-clears rule: only a present membership array
            // replaces the stored one (a dissolved room's snapshot omits the
            // key, and the last-known chips are still the right tags).
            if let parts = c.participants {
                existing.participants = ConversationRecord.encodeParticipants(parts)
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
                agentDeviceID: c.agentDeviceID,
                participants: c.participants.flatMap(ConversationRecord.encodeParticipants)
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
    public func applyJournal(_ event: JournalEvent, now: Date = Date()) throws -> Bool {
        if failApplyForTesting?(event.seq) == true {
            throw JournalStoreTestError.simulatedWriteFailure
        }
        return try dbQueue.write { db in
            try self.applyOne(db, event, now: now)
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
    public func applyJournalBatch(_ events: [JournalEvent], now: Date = Date()) throws -> [JournalEvent] {
        guard !events.isEmpty else { return [] }
        if let fail = failApplyForTesting, events.contains(where: { fail($0.seq) }) {
            throw JournalStoreTestError.simulatedWriteFailure
        }
        return try dbQueue.write { db in
            var applied: [JournalEvent] = []
            applied.reserveCapacity(events.count)
            for event in events {
                if try self.applyOne(db, event, now: now) { applied.append(event) }
            }
            return applied
        }
    }

    /// Shared per-event apply body, called inside a `dbQueue.write`
    /// transaction by both `applyJournal` (own transaction per event) and
    /// `applyJournalBatch` (one transaction for the run). Returns `false`
    /// for a duplicate (seq <= cursor) without writing anything.
    private func applyOne(_ db: Database, _ event: JournalEvent, now: Date) throws -> Bool {
            let current = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'") ?? 0
            guard event.seq > current else { return false }
            // Stored tombstoned when it is already past a cutoff — see
            // `tombstonedForStorage`. Everything below reads `stored`, so the
            // conversation's snippet and columns describe what is on disk.
            let stored = Self.tombstonedForStorage(event, now: now)
            try EventRecord(stored).save(db)
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

            let payload = stored.payload
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
                // Room membership, learned live so a room re-chips the
                // moment an agent joins or leaves (the journal fans a
                // membership-only convo_meta). Present replaces wholesale;
                // absent (a plain rename meta) leaves the stored set alone.
                if let parts = payload["participants"] as? [NSNumber] {
                    convo.participants = ConversationRecord.encodeParticipants(parts.map(\.int64Value))
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
                // `convo.snippet` is computed from the ORIGINAL wire payload,
                // never the stored (possibly tombstoned) one: a message that
                // expires later keeps its `conversation.snippet` exactly as
                // written — the purge no longer rewrites it (Step 6) — and
                // relies on `applyReadTimeSnippetTTL` to hide it at read
                // time for the one type that TTL covers (`tool_output`). A
                // message that arrives ALREADY past its cutoff must behave
                // identically (in-place-expiry parity), not freeze whatever
                // placeholder shape `Self.snippet`'s default case produces
                // for a type it has no case for — round 1 fixed this for
                // `tool_output` only; Bugbot (PR #212) found the same bug
                // for `diff`, which has no read-time override at all, so an
                // old diff read the literal `"[diff]"` forever.
                convo.snippet = Self.snippet(type: event.type, payload: event.payload)
                // These two columns DO come from the stored payload — they
                // describe what's actually on disk, which is what the
                // tool-output read-time TTL (`applyReadTimeSnippetTTL`)
                // needs to reproduce the tombstone shape at read time.
                convo.lastMessageType = event.type
                convo.expiredSnippet = Self.expiredSnippet(type: event.type, payload: payload)
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
            // Skip the journal's flagged fallback mirror of an item marker
            // (spec 2026-09-08, "Old-client fallback"): it is a synthetic
            // echo of a card the user never typed into the composer, so a
            // coincidental body match must not confirm an unrelated queued
            // outbox row.
            if event.sender == ownSender, event.type == JournalEventType.text,
               payload["fallback_for"] == nil,
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
            // The agent-spawn card is the same shape from the other side —
            // no `description` either, and the server gives it its own line.
            if payload["kind"] as? String == "agent_spawn" { return "🤝 Agent spawn request" }
            return "permission: " + String((payload["description"] as? String ?? "").prefix(100))
        case JournalEventType.spawnOutcome:
            // A resolution retires the card's snippet, so the chat list stops
            // advertising a settled ask. These are byte-exact mirrors of the
            // server's snippetOf strings — bare, no error-code suffix — so a
            // locally-derived snippet never disagrees with a server-minted
            // snapshot one. Deliberately NOT `SpawnOutcome.displayLine`
            // (MatronEvents), whose richer copy (" — errorCode" on failures)
            // is for the timeline row only; MatronJournal is a leaf module
            // and could not import it anyway. Pinned to the server by test.
            switch payload["outcome"] as? String ?? "" {
            case "started": return "🚀 Spawned session started"
            case "declined": return "🚫 Spawn declined"
            case "expired": return "⌛ Spawn request expired"
            case "failed": return "❌ Spawn failed"
            default: return "[\(type)]"
            }
        default:
            if let s = payload["snippet"] as? String { return String(s.prefix(120)) }
            return "[\(type)]"
        }
    }

    /// The chat-list preview a tool_output falls back to once its output is
    /// gone — the server's own `"$ <command>"` shape, capped at the same 120
    /// characters as `snippet(type:payload:)`.
    ///
    /// Returns `nil` unless the payload is a tool_output that is either a
    /// live log (the only shape the 24 h TTL applies to — see
    /// `EventTombstone`) or already tombstoned (`expired: true`, server-side
    /// or by the retention sweep). A legacy/offloaded tool_output with a
    /// durable snippet and no `live_log` keeps showing that snippet forever,
    /// which is the behaviour `testPurgeLeavesYoungAndNonLiveLogRows` pins.
    static func expiredSnippet(type: String, payload: [String: Any]) -> String? {
        guard type == JournalEventType.toolOutput,
              payload["live_log"] as? Bool == true || payload["expired"] as? Bool == true,
              let command = payload["command"] as? String, !command.isEmpty
        else { return nil }
        return String("$ \(command)".prefix(120))
    }

    /// `expiredSnippet(type:payload:)` over raw stored bytes — the form the
    /// migration and the per-conversation refresh use, where the payload
    /// comes back from SQLite as a BLOB.
    static func expiredSnippet(type: String, payloadData: Data) -> String? {
        guard let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }
        return expiredSnippet(type: type, payload: payload)
    }

    /// The form of `event` that actually goes to disk: a `tool_output` or
    /// `diff` that is ALREADY past one of `EventTombstone`'s cutoffs when it
    /// arrives is stored tombstoned, never in full.
    ///
    /// This is what makes the sweeps' watermarks complete. A sweep skips
    /// everything at or below its watermark, so a row older than that can
    /// only be correct if the two insert paths applied the identical rule on
    /// the way in — which is why both of them, and both sweeps, call
    /// `EventTombstone.apply` and nothing else.
    static func tombstonedForStorage(_ event: JournalEvent, now: Date) -> JournalEvent {
        guard let rewritten = EventTombstone.apply(to: event.payload, type: event.type,
                                                   ts: event.ts, now: now),
              let data = try? JSONSerialization.data(withJSONObject: rewritten)
        else { return event }
        return JournalEvent(seq: event.seq, convoID: event.convoID, ts: event.ts,
                            sender: event.sender, type: event.type, payloadData: data)
    }

    /// The newest message-type event's derived facts for `convoID`, or
    /// `(nil, nil)` when the conversation has no message-type event. One
    /// indexed lookup on `convo_id`; called only from write paths, never
    /// from a read.
    static func newestMessageColumns(_ db: Database, convoID: String) throws
        -> (type: String?, expiredSnippet: String?) {
        let placeholders = JournalEventType.messageTypes.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [convoID]
        arguments.append(contentsOf: Array(JournalEventType.messageTypes))
        guard let row = try Row.fetchOne(db, sql: """
            SELECT type, payload FROM event
            WHERE convo_id = ? AND type IN (\(placeholders))
            ORDER BY seq DESC LIMIT 1
            """, arguments: StatementArguments(arguments))
        else { return (nil, nil) }
        let type: String = row["type"]
        let payloadData: Data = row["payload"]
        return (type, expiredSnippet(type: type, payloadData: payloadData))
    }

    // MARK: History

    public func insertHistory(_ events: [JournalEvent], now: Date = Date()) throws {
        try dbQueue.write { db in
            for e in events {
                try EventRecord(Self.tombstonedForStorage(e, now: now)).insert(db, onConflict: .ignore)
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
            // a fresh queued send with the same body. The `fallback_for`
            // guard mirrors the live path above: the journal's old-client
            // mirror of an item marker is a synthetic own-sender text the
            // user never typed, so it must not confirm a queued send either
            // (Bugbot PR #185, "History path still confirms fallback texts").
            for e in events where e.sender == ownSender && e.type == JournalEventType.text
                && e.payload["fallback_for"] == nil {
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
            //
            // Backfilled rows can also become a conversation's newest
            // message-type event without moving `last_seq`, so the two TTL
            // columns are recomputed in the same pass — one indexed lookup
            // per touched conversation, exactly like the recount.
            for convoID in Set(events.map(\.convoID)) {
                guard var convo = try ConversationRecord.fetchOne(db, key: convoID) else { continue }
                convo.unreadCount = try Self.recountUnread(db, convoID: convoID,
                                                           after: convo.readUpToSeq, ownSender: ownSender)
                let columns = try Self.newestMessageColumns(db, convoID: convoID)
                convo.lastMessageType = columns.type
                convo.expiredSnippet = columns.expiredSnippet
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
            return records.map { Self.applyReadTimeSnippetTTL($0, now: now) }
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

    /// Row counts for the Settings › Storage section.
    ///
    /// Two `COUNT(*)`s on the store's single connection. On a 457k-row mirror
    /// the `event` count is a full index scan — SQLite counts over the
    /// smallest available index, which after v11 is `event_type_ts` — and it
    /// holds that connection for its duration, stalling the chat-list
    /// observation while Settings is open. That is why this is on-demand
    /// only, never on the launch path, and why the section shows a spinner
    /// until it returns. The counts are a spec requirement (§3.6), so the
    /// cost is accepted and documented rather than approximated.
    public func rowCounts() throws -> (events: Int, conversations: Int) {
        try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0)
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

    /// Read-time mirror of the tool-output tombstone, applied WITHOUT a
    /// write and WITHOUT reading `event`.
    ///
    /// An app left running past the 24 h tool-output TTL (docs/protocol.md
    /// Retention) must stop surfacing an expired `live_log` snippet in the
    /// conversation list the next time it is read, exactly as
    /// `JournalTimelineMapper` already hides it in the open thread. Before
    /// v11 that answer came from a `MAX(seq)` sub-query plus an event fetch
    /// per stale conversation — ~0.4 s for 526 stale conversations on the
    /// Mac copy, and, worse, it made the whole chat-list observation track
    /// the `event` table, so every applied frame re-ran the entire list
    /// fetch. Both facts now live on the conversation row, maintained on
    /// write (`applyOne`, `insertHistory`, and the sweeps).
    private static func applyReadTimeSnippetTTL(_ record: ConversationRecord,
                                                now: Date) -> ConversationRecord {
        guard record.lastMessageType == JournalEventType.toolOutput,
              let expiredSnippet = record.expiredSnippet,
              let activityTS = record.lastActivityTS
        else { return record }
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(EventTombstone.toolLogTTL * 1000)
        guard activityTS <= cutoff else { return record }
        var expired = record
        expired.snippet = expiredSnippet
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

    /// `image`/`file` events for one conversation, newest first — the
    /// media & links browser's Media and Files tabs. Reads the full local
    /// history: the timeline's 120-row window cannot see older attachments.
    public func attachmentEvents(convoID: String) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .filter(Column("convo_id") == convoID)
                .filter([JournalEventType.image, JournalEventType.file].contains(Column("type")))
                .order(Column("seq").desc)
                .fetchAll(db)
                .map(\.journalEvent)
        }
    }

    /// `text` events that plausibly contain a URL, newest first — a cheap
    /// SQL prefilter; precise extraction happens in Swift (`LinkExtractor`).
    /// `payload` is a JSON BLOB, so CAST to TEXT before LIKE (SQLite's LIKE
    /// is not defined over blobs).
    public func linkCandidateEvents(convoID: String) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .fetchAll(db, sql: """
                    SELECT * FROM event
                    WHERE convo_id = ? AND type = 'text'
                      AND CAST(payload AS TEXT) LIKE '%http%'
                    ORDER BY seq DESC
                    """, arguments: [convoID])
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

    // MARK: Agent roster

    /// Mirrors `GET /snapshot`'s `agents` list. Wholesale replace so a box
    /// revoked server-side stops resolving here too. An EMPTY list is
    /// ignored: a server predating the field sends nothing, and wiping the
    /// roster would silently drop every chip.
    public func replaceAgents(_ agents: [AgentDTO]) throws {
        guard !agents.isEmpty else { return }
        try dbQueue.write { db in
            // A server predating tags never sends `tag_char` at all
            // (`tagCharKnown == false`) — its nil means "unknown", not
            // "cleared", so the standing local tag survives the replace.
            // Without this, every snapshot from a pre-tag journal would
            // wipe the letters `seedAgentTagChars` carried over from the
            // legacy UserDefaults migration. A tag-aware server's explicit
            // null is authoritative and clears, as before.
            let standing = try Self.agentTagCharMap(db)
            try db.execute(sql: "DELETE FROM agent")
            for a in agents {
                let tag = a.tagCharKnown ? a.tagChar : standing[a.id]
                try db.execute(sql: "INSERT INTO agent(id, name, tag_char) VALUES(?, ?, ?)",
                               arguments: [a.id, a.name, tag])
            }
        }
    }

    /// Migration aid for pre-sync letter overrides: writes `letters` into
    /// UNTAGGED roster rows only. A journal-held tag always wins (it is
    /// newer by construction — the legacy store stopped taking writes when
    /// tags moved to the journal), and ids the mirror doesn't know are
    /// skipped rather than becoming phantom rows without names.
    public func seedAgentTagChars(_ letters: [Int64: String]) throws {
        guard !letters.isEmpty else { return }
        try dbQueue.write { db in
            for (id, letter) in letters {
                try db.execute(sql: "UPDATE agent SET tag_char = ? WHERE id = ? AND tag_char IS NULL",
                               arguments: [letter, id])
            }
        }
    }

    /// Applies one live `device_meta` frame. Upsert, not update: the frame
    /// may name a box this device has not snapshotted yet. The name half
    /// always applies. The tag half follows the same key-presence rule as
    /// `replaceAgents`: a tag-aware server sends the device's full current
    /// meta, so its `tag_char` — value OR explicit null — is authoritative,
    /// but a server predating tags sends no key at all (`tagCharKnown ==
    /// false`) and its nil means "unknown", not "cleared". Overwriting on
    /// that frame let a plain rename wipe a letter `seedAgentTagChars`
    /// carried over from the legacy UserDefaults migration — a local tag
    /// the snapshot path already protects.
    public func applyDeviceMeta(id: Int64, name: String, tagChar: String?,
                                tagCharKnown: Bool = true) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO agent(id, name, tag_char) VALUES(?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        tag_char = CASE WHEN ? THEN excluded.tag_char ELSE agent.tag_char END
                    """,
                arguments: [id, name, tagChar, tagCharKnown])
        }
    }

    /// id → name for every known box. The chat list joins against this to
    /// label rows, and its COUNT is the "does this user have ≥2 boxes" gate.
    public func agentNames() throws -> [Int64: String] {
        try dbQueue.read(Self.agentNameMap)
    }

    private static func agentNameMap(_ db: Database) throws -> [Int64: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM agent")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["name"] as String) })
    }

    /// id → tag character for every box that has one. The journal-held
    /// override map `SessionTag.boxLetters` applies after derivation —
    /// boxes without a row here get the automatic letter.
    public func agentTagChars() throws -> [Int64: String] {
        try dbQueue.read(Self.agentTagCharMap)
    }

    private static func agentTagCharMap(_ db: Database) throws -> [Int64: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, tag_char FROM agent WHERE tag_char IS NOT NULL")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["tag_char"] as String) })
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

    /// Seq of the newest message the user themself sent in `convoID` — a
    /// `text`, `image` or `file` row from `ownSender` — or nil when they
    /// never wrote there. The chat view's "jump to my last message"
    /// control lands on it (item #60). Skips the journal's `fallback_for`
    /// text mirrors of item markers: those carry the user's sender but
    /// were never typed, and `JournalTimelineMapper` drops them, so
    /// landing on one would target a row the transcript does not render.
    /// The mirror check reads the payload in Swift rather than via
    /// `json_extract` — the column is a blob, and SQLite's JSON functions
    /// treat a blob argument as JSONB, not text — so the scan walks own
    /// rows newest-first in batches until it finds a real message or
    /// runs out (CodeRabbit, PR #202: a fixed cut-off could be exhausted
    /// by mirrors alone).
    public func newestOwnMessageSeq(convoID: String) throws -> Int64? {
        try dbQueue.read { db in
            var before: Int64?
            while true {
                var query = EventRecord
                    .filter(Column("convo_id") == convoID
                            && Column("sender") == ownSender
                            && Self.ownMessageTypes.contains(Column("type")))
                if let before { query = query.filter(Column("seq") < before) }
                let batch = try query
                    .order(Column("seq").desc)
                    .limit(Self.ownMessageScanBatch)
                    .fetchAll(db)
                if let hit = batch.first(where: { $0.journalEvent.payload["fallback_for"] == nil }) {
                    return hit.seq
                }
                guard batch.count == Self.ownMessageScanBatch, let last = batch.last else { return nil }
                before = last.seq
            }
        }
    }

    /// The event types a person produces from the composer.
    private static let ownMessageTypes = [JournalEventType.text, JournalEventType.image, JournalEventType.file]
    /// Rows per batch in `newestOwnMessageSeq`'s scan. Mirrors are rare —
    /// one per item marker at most — so the first batch almost always
    /// answers; the loop exists for correctness, not throughput.
    static let ownMessageScanBatch = 50

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

    /// Clears the journal mirror (events, conversations, cursor) and the
    /// tracker cache (item, item_comment) but NOT the outbox tables
    /// (outbox, item_outbox): this runs on `snapshot_required` (replay gap
    /// too large), and a mirror wipe must not eat the user's unsent
    /// messages OR unsent tracker comments/creates — both are refetched or
    /// replayed independently of the mirror, but the outbox rows are the
    /// only record of what hasn't gone out yet. Sign-out calls
    /// `wipeOutbox()` separately for those.
    public func wipe() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event; DELETE FROM conversation; DELETE FROM meta; DELETE FROM summary_entry;")
            // Tracker cache (item/item_comment only — NOT item_outbox, see
            // the doc comment above): cleared inline, in the same
            // transaction, rather than via `wipeItems()` — that helper
            // opens its own `dbQueue.write`, which would deadlock nested
            // inside this one, and also clears item_outbox which this path
            // must not touch.
            try db.execute(sql: "DELETE FROM item; DELETE FROM item_comment;")
            // Mission cache — same rule as the tracker cache above: cleared
            // inline, because this method is already inside `dbQueue.write`
            // and cannot nest another. One bootstrap later, `GET /missions`
            // refills it.
            try Self.wipeMissionTables(db)
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
    /// inherit (or send) the previous user's queued messages or queued
    /// tracker comments/creates — clears both `outbox` and `item_outbox`.
    public func wipeOutbox() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox; DELETE FROM item_outbox;")
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
            // every change GRDB observes for the tables it reads, so a
            // long-lived subscriber still gets the TTL re-evaluated against
            // current wall time rather than "now" at subscribe time.
            return records.map { Self.applyReadTimeSnippetTTL($0, now: Date()) }
        }
        // This observation reads ONLY the `conversation` table: the TTL is
        // pure column logic (see `applyReadTimeSnippetTTL`), so an applied
        // journal frame re-runs the list fetch only when it actually touches
        // a conversation row. `removeDuplicates()` stays as the guard
        // against re-render churn from writes that change a row the list
        // does not display.
        return Self.stream(observation.removeDuplicates(), in: dbQueue)
    }

    /// Live id → name map of the user's agent boxes. Deliberately separate
    /// from `conversationsStream()`: a GRDB observation only re-fires for
    /// the tables its fetch actually reads, and the conversations fetch
    /// never touches `agent` — so a `device_meta` rename landing mid-session
    /// would otherwise leave every open chip on the old label until some
    /// unrelated conversation write happened to re-fire the list.
    public func agentNamesStream() -> AsyncStream<[Int64: String]> {
        Self.stream(ValueObservation.tracking(Self.agentNameMap), in: dbQueue)
    }

    /// Live (names, tagChars) of the user's agent boxes — one observation,
    /// one re-fire, because the chat list needs the two maps in lockstep:
    /// letters are derived from the whole name set and then overridden by
    /// the tags, so delivering them separately could paint one update with
    /// a name set and tag map from different instants.
    public func agentRosterStream() -> AsyncStream<(names: [Int64: String], tagChars: [Int64: String])> {
        Self.stream(ValueObservation.tracking { db in
            (names: try Self.agentNameMap(db), tagChars: try Self.agentTagCharMap(db))
        }, in: dbQueue)
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

    /// Live tail of one conversation's events: every row with
    /// `seq >= sinceSeq`, ascending. Anchored — not the whole history —
    /// because the `convo_id` filter is non-key, which makes GRDB observe
    /// the ENTIRE event table: every applied journal frame in ANY
    /// conversation re-runs this fetch. Unanchored, that re-fetched and
    /// re-decoded the open chat's full history per commit — O(history) per
    /// delta, quadratic over a streaming turn, and the dominant cost in the
    /// 2026-08-26 lag captures. Callers pick the anchor via
    /// `tailWindowStart(convoID:limit:)` and reveal older rows with the
    /// one-shot `events(convoID:beforeSeq:limit:)`.
    ///
    /// `removeDuplicates()` matters for the same reason: the per-commit
    /// re-runs can't be avoided (SQLite has no narrower region for this
    /// filter), but a frame landing in another conversation yields an
    /// identical tail, and dropping it here spares the whole downstream
    /// pipeline (overlay reconcile → mapper → SwiftUI diff).
    public func eventsStream(convoID: String, sinceSeq: Int64) -> AsyncStream<[JournalEvent]> {
        let observation = ValueObservation.tracking { db in
            try EventRecord
                .filter(Column("convo_id") == convoID && Column("seq") >= sinceSeq)
                .order(Column("seq"))
                .fetchAll(db)
                .map(\.journalEvent)
        }
        return Self.stream(observation.removeDuplicates(), in: dbQueue)
    }

    /// The anchor for `eventsStream(convoID:sinceSeq:)`: the lowest seq
    /// within the newest `limit` events. A conversation with fewer rows
    /// than `limit` anchors at its oldest row, and one with no rows at all
    /// anchors at 0 — both mean "observe everything it has"; new live rows
    /// always land above the anchor, and only backward pagination goes
    /// below it.
    public func tailWindowStart(convoID: String, limit: Int) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT MIN(seq) FROM (
                    SELECT seq FROM event WHERE convo_id = ? ORDER BY seq DESC LIMIT ?
                )
                """, arguments: [convoID, limit]) ?? 0
        }
    }

    /// One page of events strictly older than `beforeSeq`, ascending — the
    /// local-mirror side of backward pagination. Rows below the events
    /// stream's anchor are fetched once here (they're immutable) instead of
    /// riding the live observation.
    public func events(convoID: String, beforeSeq: Int64, limit: Int) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .filter(Column("convo_id") == convoID && Column("seq") < beforeSeq)
                .order(Column("seq").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
                .map(\.journalEvent)
        }
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

    // Module-internal (not private): JournalStore+Items.swift's item
    // streams (spec 2026-09-08-items-tracker-apps task 4) reuse this from
    // a different file.
    static func stream<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        in dbQueue: DatabaseQueue
    ) -> AsyncStream<Reducer.Value> where Reducer.Value: Sendable {
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
