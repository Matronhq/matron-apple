import Foundation
import GRDB
import MatronModels

// Project cache (spec 2026-09-30 §4, §6). Records and queries for the
// `project` table created by migration v14. Filled from GET /projects and
// GET /projects/:id by `ProjectsSync` — never from the event log.

private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
private func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }
private func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
private func date(_ v: Int64?) -> Date? { v.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
    guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
    return String(decoding: data, as: UTF8.self)
}
private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
    json.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
}

public struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "project"
    public var id: String; public var num: Int; public var state: String
    public var title: String; public var body: String
    public var status: String?; public var statusBy: String?; public var statusUpdatedAt: Int64?
    public var closeSummary: String?; public var closedAt: Int64?; public var mergedInto: String?
    public var originConvoId: String?; public var createdBy: String
    public var createdAt: Int64; public var updatedAt: Int64
    public var missionsRunning: Int; public var missionsWaiting: Int; public var missionsIdle: Int
    public var missionsQuiet: Int; public var missionsClosed: Int
    public var needsYou: Int; public var openItems: Int; public var lastActivityAt: Int64?
    /// `GET /projects/:id`'s `sessions_by_box`, JSON. Kept across list
    /// refreshes (`JournalStore.upsertProjects` never writes it).
    public var sessionsByBoxJson: String?
    /// A list row's `ProjectCardFields`, JSON (v16). Kept across detail
    /// refreshes: the detail route's project carries no card fields.
    public var cardJson: String?
    /// `GET /projects/:id`'s first feed pages (`ProjectFeed`), JSON (v16).
    /// Kept across list refreshes, like `sessionsByBoxJson`.
    public var feedJson: String?

    enum CodingKeys: String, CodingKey {
        case id, num, state, title, body, status
        case statusBy = "status_by", statusUpdatedAt = "status_updated_at"
        case closeSummary = "close_summary", closedAt = "closed_at", mergedInto = "merged_into"
        case originConvoId = "origin_convo_id", createdBy = "created_by"
        case createdAt = "created_at", updatedAt = "updated_at"
        case missionsRunning = "missions_running", missionsWaiting = "missions_waiting"
        case missionsIdle = "missions_idle", missionsQuiet = "missions_quiet", missionsClosed = "missions_closed"
        case needsYou = "needs_you", openItems = "open_items", lastActivityAt = "last_activity_at"
        case sessionsByBoxJson = "sessions_by_box_json"
        case cardJson = "card_json", feedJson = "feed_json"
    }

    /// `cardJson` defaults to the project's own card fields (nil when it
    /// carries none).
    public init(_ p: Project, sessionsByBoxJson: String? = nil, cardJson: String? = nil, feedJson: String? = nil) {
        id = p.id; num = p.num; state = p.state.rawValue; title = p.title; body = p.body
        status = p.status; statusBy = p.statusBy?.rawValue; statusUpdatedAt = ms(p.statusUpdatedAt)
        closeSummary = p.closeSummary; closedAt = ms(p.closedAt); mergedInto = p.mergedInto
        originConvoId = p.originConvoID; createdBy = p.createdBy.rawValue
        createdAt = ms(p.createdAt); updatedAt = ms(p.updatedAt)
        missionsRunning = p.missions.running; missionsWaiting = p.missions.waiting; missionsIdle = p.missions.idle
        missionsQuiet = p.missions.quiet; missionsClosed = p.missions.closed
        needsYou = p.needsYou; openItems = p.openItems; lastActivityAt = ms(p.lastActivityAt)
        self.sessionsByBoxJson = sessionsByBoxJson
        self.cardJson = encodeJSON(p.card) ?? cardJson
        self.feedJson = feedJson
    }

    public var project: Project {
        Project(id: id, num: num, state: MissionState(rawValue: state) ?? .open, title: title, body: body,
                status: status, statusBy: statusBy.flatMap(ItemAuthor.init(rawValue:)),
                statusUpdatedAt: date(statusUpdatedAt), closeSummary: closeSummary, closedAt: date(closedAt),
                mergedInto: mergedInto, originConvoID: originConvoId,
                createdBy: ItemAuthor(rawValue: createdBy) ?? .agent,
                createdAt: date(createdAt), updatedAt: date(updatedAt),
                missions: ProjectMissionCounts(running: missionsRunning, waiting: missionsWaiting, idle: missionsIdle,
                                               quiet: missionsQuiet, closed: missionsClosed),
                needsYou: needsYou, openItems: openItems, lastActivityAt: date(lastActivityAt),
                card: decodeJSON(ProjectCardFields.self, cardJson))
    }

    public var feed: ProjectFeed? { decodeJSON(ProjectFeed.self, feedJson) }
}

extension JournalStore {
    private static let projectsOrder = """
        ORDER BY state DESC, last_activity_at IS NULL, last_activity_at DESC, num DESC
        """

    /// `sessions_by_box_json` and `feed_json` belong to the detail fetch;
    /// a list row has neither, so every save carries the stored values
    /// over. `card_json` belongs to the list: a project without card
    /// fields (the detail, create and merge routes, or an older journal)
    /// keeps the stored one, and one with them replaces it.
    private static func save(_ project: Project, _ db: Database) throws {
        let kept = try Row.fetchOne(db, sql: "SELECT sessions_by_box_json, card_json, feed_json FROM project WHERE id = ?",
                                    arguments: [project.id])
        try ProjectRecord(project, sessionsByBoxJson: kept?["sessions_by_box_json"],
                          cardJson: kept?["card_json"], feedJson: kept?["feed_json"]).save(db)
    }

    public func upsertProjects(_ projects: [Project]) throws {
        guard !projects.isEmpty else { return }
        try dbQueue.write { db in for p in projects { try Self.save(p, db) } }
    }

    /// `GET /projects` returns the complete set, so this write is
    /// authoritative (same reasoning as `replaceMissions`). `protectedIDs`:
    /// ids a detail fetch or a create wrote since the list GET started —
    /// kept, and not overwritten by the (older) list row.
    public func replaceProjects(_ projects: [Project], keeping protectedIDs: Set<String> = []) throws {
        try dbQueue.write { db in
            for p in projects where !protectedIDs.contains(p.id) { try Self.save(p, db) }
            let ids = Array(Set(projects.map(\.id)).union(protectedIDs))
            try ProjectRecord.filter(!ids.contains(Column("id"))).deleteAll(db)
        }
    }

    public func setProjectSessionsByBox(id: String, _ map: [String: Int]) throws {
        let data = try JSONEncoder().encode(map)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET sessions_by_box_json = ? WHERE id = ?",
                           arguments: [String(decoding: data, as: UTF8.self), id])
        }
    }

    /// Writes the detail's first feed pages. A no-op for a project not
    /// cached (the detail upserts the project first).
    public func setProjectFeed(id: String, _ feed: ProjectFeed) throws {
        let json = encodeJSON(feed)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE project SET feed_json = ? WHERE id = ?", arguments: [json, id])
        }
    }

    public func project(id: String) throws -> Project? {
        try dbQueue.read { db in try ProjectRecord.fetchOne(db, key: id)?.project }
    }

    /// Lookup by the human-facing `#N`, as `mission(num:)`.
    public func project(num: Int) throws -> Project? {
        try dbQueue.read { db in try ProjectRecord.filter(Column("num") == num).order(Column("id")).fetchOne(db)?.project }
    }

    public func projects() throws -> [Project] {
        try dbQueue.read { db in try ProjectRecord.fetchAll(db, sql: "SELECT * FROM project \(Self.projectsOrder)").map(\.project) }
    }

    public func projectsStream() -> AsyncStream<[Project]> {
        Self.stream(ValueObservation.tracking { db in
            try ProjectRecord.fetchAll(db, sql: "SELECT * FROM project \(Self.projectsOrder)").map(\.project)
        }.removeDuplicates(), in: dbQueue)
    }

    public func projectStream(id: String) -> AsyncStream<Project?> {
        Self.stream(ValueObservation.tracking { db in try ProjectRecord.fetchOne(db, key: id)?.project }
            .removeDuplicates(), in: dbQueue)
    }

    public func projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]> {
        Self.stream(ValueObservation.tracking { db -> [String: Int] in
            guard let json = try String.fetchOne(db, sql: "SELECT sessions_by_box_json FROM project WHERE id = ?",
                                                 arguments: [id]) else { return [:] }
            return (try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8))) ?? [:]
        }.removeDuplicates(), in: dbQueue)
    }

    /// The detail's first feed pages; `nil` until a detail refresh from a
    /// journal with the roll-up has written them.
    public func projectFeedStream(id: String) -> AsyncStream<ProjectFeed?> {
        Self.stream(ValueObservation.tracking { db -> ProjectFeed? in
            decodeJSON(ProjectFeed.self, try String.fetchOne(db, sql: "SELECT feed_json FROM project WHERE id = ?",
                                                             arguments: [id]))
        }.removeDuplicates(), in: dbQueue)
    }

    public func missionsStream(projectID: String) -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in
            try MissionRecord.fetchAll(db, sql: """
                SELECT * FROM mission WHERE project_id = ?
                ORDER BY state DESC, last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """, arguments: [projectID]).map(\.mission)
        }.removeDuplicates(), in: dbQueue)
    }

    /// The project page's "Add a mission" choices.
    public func unfiledOpenMissionsStream() -> AsyncStream<[Mission]> {
        Self.stream(ValueObservation.tracking { db in
            try MissionRecord.fetchAll(db, sql: """
                SELECT * FROM mission WHERE project_id IS NULL AND state = 'open'
                ORDER BY last_milestone_at IS NULL, last_milestone_at DESC, created_at DESC
                """).map(\.mission)
        }.removeDuplicates(), in: dbQueue)
    }

    /// Open items awaiting the user across every mission in the project.
    public func needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]> {
        Self.stream(ValueObservation.tracking { db in
            try ItemRecord.fetchAll(db, sql: """
                SELECT i.* FROM item i JOIN mission m ON m.id = i.mission_id
                WHERE m.project_id = ? AND i.state = 'open' AND i.awaiting = 'user'
                ORDER BY i.updated_at DESC, i.num DESC
                """, arguments: [projectID]).map(\.item)
        }.removeDuplicates(), in: dbQueue)
    }

    /// Every open item across every mission in the project, newest first —
    /// the project page's "Other open items" list (it leaves out the ones
    /// Needs you already shows).
    public func openItemsStream(projectID: String) -> AsyncStream<[TrackerItem]> {
        Self.stream(ValueObservation.tracking { db in
            try ItemRecord.fetchAll(db, sql: """
                SELECT i.* FROM item i JOIN mission m ON m.id = i.mission_id
                WHERE m.project_id = ? AND i.state = 'open'
                ORDER BY i.updated_at DESC, i.num DESC
                """, arguments: [projectID]).map(\.item)
        }.removeDuplicates(), in: dbQueue)
    }

    public func recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]> {
        Self.stream(ValueObservation.tracking { db in
            try MilestoneRecord.fetchAll(db, sql: """
                SELECT ml.* FROM milestone ml JOIN mission m ON m.id = ml.mission_id
                WHERE m.project_id = ? ORDER BY ml.created_at DESC, ml.num DESC LIMIT ?
                """, arguments: [projectID, limit]).map(\.milestone)
        }.removeDuplicates(), in: dbQueue)
    }
}
