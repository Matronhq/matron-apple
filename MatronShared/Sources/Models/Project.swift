import Foundation

/// A mission's live state, computed by the journal (spec 2026-09-30 §2):
/// running — a linked conversation is running; waiting — one is waiting or
/// items await the user; quiet — nothing for 7 days; idle — none of those.
public enum MissionActivity: String, Codable, Sendable, CaseIterable {
    case running, waiting, idle, quiet

    /// Running first, quiet last — the row and card ordering.
    public var sortRank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .idle: return 2
        case .quiet: return 3
        }
    }

    public var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        case .quiet: return "Quiet"
        }
    }
}

/// The rollup's `missions` object (every project route sends it); zero when absent.
public struct ProjectMissionCounts: Equatable, Hashable, Sendable {
    public var running: Int, waiting: Int, idle: Int, quiet: Int, closed: Int
    public init(running: Int = 0, waiting: Int = 0, idle: Int = 0, quiet: Int = 0, closed: Int = 0) {
        self.running = running; self.waiting = waiting; self.idle = idle; self.quiet = quiet; self.closed = closed
    }
    public init(json: [String: Any]?) {
        func n(_ key: String) -> Int { (json?[key] as? NSNumber)?.intValue ?? 0 }
        self.init(running: n("running"), waiting: n("waiting"), idle: n("idle"), quiet: n("quiet"), closed: n("closed"))
    }
    /// Every mission that is not closed.
    public var open: Int { running + waiting + idle + quiet }
}

/// A project groups missions (spec 2026-09-30 §4). Numbered from the same
/// per-user counter as items, missions and milestones, so `#N` names it.
/// A mission belongs to at most one project.
public struct Project: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    /// `open` | `closed` — the same two values as a mission's.
    public let state: MissionState
    public let title: String
    public let body: String
    /// The Coordinator's paragraph. `nil` when unset or sieved.
    public let status: String?
    public let statusBy: ItemAuthor?
    public let statusUpdatedAt: Date?
    public let closeSummary: String?
    public let closedAt: Date?
    /// Set when a merge closed this project: the project its missions moved to.
    public let mergedInto: String?
    public let originConvoID: String?
    public let createdBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date
    /// The rollup's `missions` object (every project route sends it); zero when absent.
    public let missions: ProjectMissionCounts
    public let needsYou: Int
    public let openItems: Int
    public let lastActivityAt: Date?

    public init(id: String, num: Int, state: MissionState = .open, title: String, body: String = "",
                status: String? = nil, statusBy: ItemAuthor? = nil, statusUpdatedAt: Date? = nil,
                closeSummary: String? = nil, closedAt: Date? = nil, mergedInto: String? = nil,
                originConvoID: String? = nil, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                missions: ProjectMissionCounts = ProjectMissionCounts(), needsYou: Int = 0, openItems: Int = 0,
                lastActivityAt: Date? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body
        self.status = status; self.statusBy = statusBy; self.statusUpdatedAt = statusUpdatedAt
        self.closeSummary = closeSummary; self.closedAt = closedAt; self.mergedInto = mergedInto
        self.originConvoID = originConvoID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.missions = missions; self.needsYou = needsYou; self.openItems = openItems
        self.lastActivityAt = lastActivityAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let state = (json["state"] as? String).flatMap(MissionState.init(rawValue:)),
              let title = json["title"] as? String,
              let createdAt = msDate(json["created_at"]), let updatedAt = msDate(json["updated_at"])
        else { return nil }
        self.init(
            id: id, num: num, state: state, title: title, body: json["body"] as? String ?? "",
            status: (json["status"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            statusBy: (json["status_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
            statusUpdatedAt: msDate(json["status_updated_at"]),
            closeSummary: json["close_summary"] as? String, closedAt: msDate(json["closed_at"]),
            mergedInto: json["merged_into"] as? String, originConvoID: json["origin_convo_id"] as? String,
            createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
            createdAt: createdAt, updatedAt: updatedAt,
            missions: ProjectMissionCounts(json: json["missions"] as? [String: Any]),
            needsYou: (json["needs_you"] as? NSNumber)?.intValue ?? 0,
            openItems: (json["open_items"] as? NSNumber)?.intValue ?? 0,
            lastActivityAt: msDate(json["last_activity_at"]))
    }

    public var label: String { "#\(num) \(title)" }
}
