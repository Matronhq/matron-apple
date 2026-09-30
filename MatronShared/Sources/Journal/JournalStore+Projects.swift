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
    }

    public init(_ p: Project, sessionsByBoxJson: String? = nil) {
        id = p.id; num = p.num; state = p.state.rawValue; title = p.title; body = p.body
        status = p.status; statusBy = p.statusBy?.rawValue; statusUpdatedAt = ms(p.statusUpdatedAt)
        closeSummary = p.closeSummary; closedAt = ms(p.closedAt); mergedInto = p.mergedInto
        originConvoId = p.originConvoID; createdBy = p.createdBy.rawValue
        createdAt = ms(p.createdAt); updatedAt = ms(p.updatedAt)
        missionsRunning = p.missions.running; missionsWaiting = p.missions.waiting; missionsIdle = p.missions.idle
        missionsQuiet = p.missions.quiet; missionsClosed = p.missions.closed
        needsYou = p.needsYou; openItems = p.openItems; lastActivityAt = ms(p.lastActivityAt)
        self.sessionsByBoxJson = sessionsByBoxJson
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
                needsYou: needsYou, openItems: openItems, lastActivityAt: date(lastActivityAt))
    }
}
