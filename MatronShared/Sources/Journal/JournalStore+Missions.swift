import Foundation
import GRDB
import MatronModels

// Mission cache (spec 2026-09-10 missions-milestones). Records and queries
// for the `mission` / `milestone` / `mission_conversation` tables created by
// migration v10 (JournalStore.swift). Filled from GET /missions and
// GET /missions/:id by `MissionsSync` — never from the event log.

private let missionsEncoder = JSONEncoder()
private let missionsDecoder = JSONDecoder()

private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
private func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }
private func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
private func date(_ v: Int64?) -> Date? { v.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

public struct MissionRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "mission"
    public var id: String; public var num: Int; public var state: String
    public var title: String; public var body: String
    public var closeSummary: String?; public var closedBy: String?; public var closedOverOpenItems: Int
    public var originConvoId: String; public var originDeviceId: Int64; public var createdBy: String
    public var createdAt: Int64; public var updatedAt: Int64
    public var lastMilestoneAt: Int64?; public var closedAt: Int64?
    public var openItems: Int; public var needsYou: Int; public var conversationCount: Int
    public var milestoneCount: Int; public var lastMilestoneJson: String?

    enum CodingKeys: String, CodingKey {
        case id, num, state, title, body
        case closeSummary = "close_summary", closedBy = "closed_by", closedOverOpenItems = "closed_over_open_items"
        case originConvoId = "origin_convo_id", originDeviceId = "origin_device_id", createdBy = "created_by"
        case createdAt = "created_at", updatedAt = "updated_at", lastMilestoneAt = "last_milestone_at"
        case closedAt = "closed_at", openItems = "open_items", needsYou = "needs_you"
        case conversationCount = "conversation_count", milestoneCount = "milestone_count"
        case lastMilestoneJson = "last_milestone_json"
    }

    /// Codable mirror of `MissionLastMilestone` with wire-shaped keys, so
    /// the stored JSON reads the same as the payload it came from.
    private struct LastMilestone: Codable {
        var num: Int; var title: String; var kind: String; var createdAt: Int64
        enum CodingKeys: String, CodingKey { case num, title, kind; case createdAt = "created_at" }
    }

    public init(_ m: Mission) {
        id = m.id; num = m.num; state = m.state.rawValue; title = m.title; body = m.body
        closeSummary = m.closeSummary; closedBy = m.closedBy?.rawValue; closedOverOpenItems = m.closedOverOpenItems
        originConvoId = m.originConvoID; originDeviceId = m.originDeviceID; createdBy = m.createdBy.rawValue
        createdAt = ms(m.createdAt); updatedAt = ms(m.updatedAt)
        lastMilestoneAt = ms(m.lastMilestoneAt); closedAt = ms(m.closedAt)
        openItems = m.openItems; needsYou = m.needsYou; conversationCount = m.conversationCount
        milestoneCount = m.milestoneCount
        lastMilestoneJson = m.lastMilestone.flatMap {
            let l = LastMilestone(num: $0.num, title: $0.title, kind: $0.kind.rawValue, createdAt: ms($0.createdAt))
            return (try? String(data: missionsEncoder.encode(l), encoding: .utf8)) ?? nil
        }
    }

    public var mission: Mission {
        let last = lastMilestoneJson
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? missionsDecoder.decode(LastMilestone.self, from: $0) }
            .flatMap { l -> MissionLastMilestone? in
                guard let kind = MilestoneKind(rawValue: l.kind) else { return nil }
                return MissionLastMilestone(num: l.num, title: l.title, kind: kind, createdAt: date(l.createdAt))
            }
        return Mission(id: id, num: num, state: MissionState(rawValue: state) ?? .open, title: title, body: body,
                       closeSummary: closeSummary, closedBy: closedBy.flatMap(ItemAuthor.init(rawValue:)),
                       closedOverOpenItems: closedOverOpenItems, originConvoID: originConvoId,
                       originDeviceID: originDeviceId, createdBy: ItemAuthor(rawValue: createdBy) ?? .agent,
                       createdAt: date(createdAt), updatedAt: date(updatedAt),
                       lastMilestoneAt: date(lastMilestoneAt), closedAt: date(closedAt),
                       openItems: openItems, needsYou: needsYou, conversationCount: conversationCount,
                       milestoneCount: milestoneCount, lastMilestone: last)
    }
}

public struct MilestoneRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "milestone"
    public var id: String; public var missionId: String; public var num: Int; public var kind: String
    public var title: String; public var body: String; public var convoId: String; public var seq: Int64
    public var deviceId: Int64; public var createdBy: String; public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, num, kind, title, body, seq
        case missionId = "mission_id", convoId = "convo_id", deviceId = "device_id"
        case createdBy = "created_by", createdAt = "created_at"
    }

    public init(_ m: Milestone) {
        id = m.id; missionId = m.missionID; num = m.num; kind = m.kind.rawValue; title = m.title
        body = m.body; convoId = m.convoID; seq = m.seq; deviceId = m.deviceID
        createdBy = m.createdBy.rawValue; createdAt = ms(m.createdAt)
    }

    public var milestone: Milestone {
        Milestone(id: id, missionID: missionId, num: num, kind: MilestoneKind(rawValue: kind) ?? .progress,
                  title: title, body: body, convoID: convoId, seq: seq, deviceID: deviceId,
                  createdBy: ItemAuthor(rawValue: createdBy) ?? .agent, createdAt: date(createdAt))
    }
}

public struct MissionConversationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "mission_conversation"
    public var missionId: String; public var convoId: String
    public var title: String; public var box: String?; public var state: String
    enum CodingKeys: String, CodingKey {
        case title, box, state
        case missionId = "mission_id", convoId = "convo_id"
    }
    public init(missionID: String, _ c: MissionConversation) {
        missionId = missionID; convoId = c.id; title = c.title; box = c.box; state = c.state
    }
    public var conversation: MissionConversation {
        MissionConversation(id: convoId, title: title, box: box, state: state)
    }
}

extension JournalStore {
    // MARK: Missions

    /// Open missions sort newest-activity first with never-checkpointed
    /// missions last (`last_milestone_at DESC NULLS LAST, created_at DESC`,
    /// the journal's own order); closed ones sort newest-closed first.
    /// SQLite has no NULLS LAST, so the `IS NULL` term does it.
    private static func missionsRequest(_ state: MissionState?) -> SQLRequest<MissionRecord> {
        switch state {
        case .some(.closed):
            return SQLRequest<MissionRecord>(sql: "SELECT * FROM mission WHERE state = 'closed' ORDER BY closed_at DESC, num DESC")
        case .some(.open):
            return SQLRequest<MissionRecord>(sql: """
                SELECT * FROM mission WHERE state = 'open'
                ORDER BY last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """)
        case .none:
            return SQLRequest<MissionRecord>(sql: """
                SELECT * FROM mission
                ORDER BY state, last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """)
        }
    }

    public func upsertMissions(_ missions: [Mission]) throws {
        guard !missions.isEmpty else { return }
        try dbQueue.write { db in for m in missions { try MissionRecord(m).save(db) } }
    }

    public func missions(state: MissionState?) throws -> [Mission] {
        try dbQueue.read { db in try Self.missionsRequest(state).fetchAll(db).map(\.mission) }
    }

    public func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in try Self.missionsRequest(state).fetchAll(db).map(\.mission) }, in: dbQueue)
    }

    public func mission(id: String) throws -> Mission? {
        try dbQueue.read { db in try MissionRecord.fetchOne(db, key: id)?.mission }
    }

    /// Lookup by the human-facing `#N`. Numbers are unique across items,
    /// missions and milestones, so at most one row can match.
    public func mission(num: Int) throws -> Mission? {
        try dbQueue.read { db in try MissionRecord.filter(Column("num") == num).order(Column("id")).fetchOne(db)?.mission }
    }

    public func missionStream(id: String) -> AsyncStream<Mission?> {
        Self.stream(ValueObservation.tracking { db in try MissionRecord.fetchOne(db, key: id)?.mission }, in: dbQueue)
    }

    // MARK: Milestones

    /// Wholesale replace for one mission, mirroring `replaceComments`: the
    /// detail fetch is the authority, so a milestone the server no longer
    /// returns (sieved, or the mission repointed) must not linger.
    public func replaceMilestones(missionID: String, _ milestones: [Milestone]) throws {
        try dbQueue.write { db in
            try MilestoneRecord.filter(Column("mission_id") == missionID).deleteAll(db)
            for m in milestones { try MilestoneRecord(m).insert(db) }
        }
    }

    private static func milestonesForMission(_ missionID: String) -> QueryInterfaceRequest<MilestoneRecord> {
        MilestoneRecord.filter(Column("mission_id") == missionID)
            .order(Column("created_at").desc, Column("num").desc)
    }

    public func milestones(missionID: String) throws -> [Milestone] {
        try dbQueue.read { db in try Self.milestonesForMission(missionID).fetchAll(db).map(\.milestone) }
    }

    public func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> {
        Self.stream(ValueObservation.tracking { db in try Self.milestonesForMission(missionID).fetchAll(db).map(\.milestone) }, in: dbQueue)
    }

    /// The per-conversation view (`GET /milestones?convo=`), newest first.
    /// Kept and tested even though no surface consumes it yet — same
    /// reasoning as `JournalAPI.milestones(convoID:)` (MINOR-1).
    public func milestones(convoID: String) throws -> [Milestone] {
        try dbQueue.read { db in
            try MilestoneRecord.filter(Column("convo_id") == convoID).order(Column("seq").desc).fetchAll(db).map(\.milestone)
        }
    }

    // MARK: Conversations of a mission

    public func replaceMissionConversations(missionID: String, _ conversations: [MissionConversation]) throws {
        try dbQueue.write { db in
            try MissionConversationRecord.filter(Column("mission_id") == missionID).deleteAll(db)
            for c in conversations { try MissionConversationRecord(missionID: missionID, c).insert(db) }
        }
    }

    private static func missionConversationsRequest(_ missionID: String) -> QueryInterfaceRequest<MissionConversationRecord> {
        MissionConversationRecord.filter(Column("mission_id") == missionID).order(Column("convo_id"))
    }

    public func missionConversations(missionID: String) throws -> [MissionConversation] {
        try dbQueue.read { db in try Self.missionConversationsRequest(missionID).fetchAll(db).map(\.conversation) }
    }

    public func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> {
        Self.stream(ValueObservation.tracking { db in
            try Self.missionConversationsRequest(missionID).fetchAll(db).map(\.conversation)
        }, in: dbQueue)
    }

    // MARK: A conversation's mission

    /// Which mission a conversation belongs to, derived locally.
    ///
    /// `GET /snapshot` does NOT carry `conversations.mission_id`, so there is
    /// no column to mirror. Three lookups, in order: origin
    /// (`missions.origin_convo_id`); `mission_conversation`, the
    /// authoritative membership list a detail fetch populates the moment a
    /// `join` marker or a server-side inheritance names this conversation —
    /// checking it here means the title-tap affordance appears as soon as
    /// membership is known, not only once a milestone has actually been
    /// posted; then any milestone posted in the conversation, which still
    /// matters as a fallback until the owning mission's own detail fetch
    /// has ever landed. `nil` until the first missions refresh lands, which
    /// is exactly when the title-tap affordance should appear.
    private static func missionIDQuery(_ db: Database, _ convoID: String) throws -> String? {
        if let origin = try String.fetchOne(db, sql: "SELECT id FROM mission WHERE origin_convo_id = ? ORDER BY id LIMIT 1", arguments: [convoID]) {
            return origin
        }
        if let joined = try String.fetchOne(db, sql: "SELECT mission_id FROM mission_conversation WHERE convo_id = ? ORDER BY mission_id LIMIT 1", arguments: [convoID]) {
            return joined
        }
        return try String.fetchOne(db, sql: "SELECT mission_id FROM milestone WHERE convo_id = ? ORDER BY seq DESC LIMIT 1", arguments: [convoID])
    }

    public func missionID(convoID: String) throws -> String? {
        try dbQueue.read { db in try Self.missionIDQuery(db, convoID) }
    }

    public func missionIDStream(convoID: String) -> AsyncStream<String?> {
        Self.stream(ValueObservation.tracking { db in try Self.missionIDQuery(db, convoID) }, in: dbQueue)
    }

    // MARK: Wipe

    /// Sign-out clear for the mission cache alone. `wipe()` clears the same
    /// tables inline (it cannot nest another `dbQueue.write`) — both go
    /// through `wipeMissionTables`, so "the mission cache" is defined once.
    public func wipeMissions() throws {
        try dbQueue.write { db in try Self.wipeMissionTables(db) }
    }

    /// The mission cache's three tables, cleared inside a transaction the
    /// caller already owns. `JournalStore.wipe()` calls it from the middle
    /// of its own `dbQueue.write`; `wipeMissions()` opens one of its own.
    /// Internal (same module as `wipe()`), and `static` so neither caller
    /// needs an instance hop mid-transaction.
    static func wipeMissionTables(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM mission; DELETE FROM milestone; DELETE FROM mission_conversation;")
    }
}
