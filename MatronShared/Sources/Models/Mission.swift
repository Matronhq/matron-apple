import Foundation

/// A mission's lifecycle. Mirrors the journal's `missions.state` CHECK.
public enum MissionState: String, Codable, Sendable, CaseIterable { case open, closed }

/// Why a milestone was posted. `user_input` is the one that answers Dan's
/// stated pain ("get back to my last input"); `progress` is the agent's own
/// checkpoint and has no cap.
public enum MilestoneKind: String, Codable, Sendable, CaseIterable {
    case userInput = "user_input"
    case progress
}

func msDate(_ v: Any?) -> Date? {
    guard let n = v as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000)
}

/// The `last_milestone` summary the journal attaches to each `GET /missions`
/// row — enough for the list row without a second fetch. For a filtered
/// (ordinary agent) caller the journal sieves this; for a client device it is
/// the real newest one.
public struct MissionLastMilestone: Equatable, Hashable, Sendable, Codable {
    public let num: Int
    public let title: String
    public let kind: MilestoneKind
    public let createdAt: Date
    public init(num: Int, title: String, kind: MilestoneKind, createdAt: Date) {
        self.num = num; self.title = title; self.kind = kind; self.createdAt = createdAt
    }
    public init?(json: [String: Any]) {
        guard let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let createdAt = msDate(json["created_at"]) else { return nil }
        self.init(num: num, title: json["title"] as? String ?? "", kind: kind, createdAt: createdAt)
    }
}

/// One mission — the human-readable record of a piece of work, numbered from
/// the same per-user counter as items and milestones (`#61` names exactly one
/// thing). `idem_key` is internal to the journal and never on the wire.
public struct Mission: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let state: MissionState
    public let title: String
    public let body: String
    public let closeSummary: String?
    public let closedBy: ItemAuthor?
    /// Count of items still open when a user forced the close. Includes
    /// items this caller cannot see (protocol, "Accepted exception —
    /// numbers, never words"), so it can exceed `openItems`.
    public let closedOverOpenItems: Int
    public let originConvoID: String
    public let originDeviceID: Int64
    public let createdBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date
    /// The list's sort key. `nil` for a mission with no milestones yet.
    public let lastMilestoneAt: Date?
    public let closedAt: Date?
    // Counts, present only on `GET /missions` rows; zero elsewhere.
    public let openItems: Int
    public let needsYou: Int
    public let conversationCount: Int
    public let milestoneCount: Int
    public let lastMilestone: MissionLastMilestone?
    /// The mission's written status (spec 2026-09-28 missions dashboard
    /// §1): one short markdown paragraph an agent keeps current, the
    /// headline on the mission's dashboard card. `nil` when unset, withheld
    /// by the privacy sieve, or the journal predates the field.
    public let status: String?
    /// Who wrote `status` — the writing device's kind. `nil` when unset or
    /// a value this build doesn't know.
    public let statusBy: ItemAuthor?
    public let statusUpdatedAt: Date?
    /// The project this mission is filed in (spec 2026-09-30 §4), or nil.
    public let projectID: String?
    /// That project's `#N`, for a chip when the project isn't cached.
    public let projectNum: Int?
    /// The journal's activity state (§2). `nil` from a journal that
    /// predates it — `ProjectsHomeAssembly.activity` derives one then.
    public let activity: MissionActivity?
    /// The server's own last-activity timestamp (§2): the max of created,
    /// last milestone, status, and each active link's join and its
    /// conversation's newest message. `nil` from an older journal.
    public let lastActivityAt: Date?

    public init(id: String, num: Int, state: MissionState = .open, title: String, body: String = "",
                closeSummary: String? = nil, closedBy: ItemAuthor? = nil, closedOverOpenItems: Int = 0,
                originConvoID: String, originDeviceID: Int64 = 0, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(), lastMilestoneAt: Date? = nil,
                closedAt: Date? = nil, openItems: Int = 0, needsYou: Int = 0, conversationCount: Int = 0,
                milestoneCount: Int = 0, lastMilestone: MissionLastMilestone? = nil,
                status: String? = nil, statusBy: ItemAuthor? = nil, statusUpdatedAt: Date? = nil,
                projectID: String? = nil, projectNum: Int? = nil, activity: MissionActivity? = nil,
                lastActivityAt: Date? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body
        self.closeSummary = closeSummary; self.closedBy = closedBy; self.closedOverOpenItems = closedOverOpenItems
        self.originConvoID = originConvoID; self.originDeviceID = originDeviceID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastMilestoneAt = lastMilestoneAt
        self.closedAt = closedAt; self.openItems = openItems; self.needsYou = needsYou
        self.conversationCount = conversationCount; self.milestoneCount = milestoneCount
        self.lastMilestone = lastMilestone
        self.status = status; self.statusBy = statusBy; self.statusUpdatedAt = statusUpdatedAt
        self.projectID = projectID; self.projectNum = projectNum; self.activity = activity
        self.lastActivityAt = lastActivityAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let state = (json["state"] as? String).flatMap(MissionState.init(rawValue:)),
              let title = json["title"] as? String,
              let origin = json["origin_convo_id"] as? String,
              let createdAt = msDate(json["created_at"]), let updatedAt = msDate(json["updated_at"])
        else { return nil }
        self.init(
            id: id, num: num, state: state, title: title, body: json["body"] as? String ?? "",
            closeSummary: json["close_summary"] as? String,
            closedBy: (json["closed_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
            closedOverOpenItems: (json["closed_over_open_items"] as? NSNumber)?.intValue ?? 0,
            originConvoID: origin, originDeviceID: (json["origin_device_id"] as? NSNumber)?.int64Value ?? 0,
            createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
            createdAt: createdAt, updatedAt: updatedAt,
            lastMilestoneAt: msDate(json["last_milestone_at"]), closedAt: msDate(json["closed_at"]),
            openItems: (json["open_items"] as? NSNumber)?.intValue ?? 0,
            needsYou: (json["needs_you"] as? NSNumber)?.intValue ?? 0,
            conversationCount: (json["conversations"] as? NSNumber)?.intValue ?? 0,
            milestoneCount: (json["milestones"] as? NSNumber)?.intValue ?? 0,
            lastMilestone: (json["last_milestone"] as? [String: Any]).flatMap(MissionLastMilestone.init(json:)),
            // Lenient on purpose: a sieved (null), absent or unknown value
            // reads as "no status", never as a malformed row.
            status: (json["status"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            statusBy: (json["status_by"] as? String).flatMap(ItemAuthor.init(rawValue:)),
            statusUpdatedAt: msDate(json["status_updated_at"]),
            projectID: (json["project_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            projectNum: (json["project_num"] as? NSNumber)?.intValue,
            activity: (json["activity"] as? String).flatMap(MissionActivity.init(rawValue:)),
            lastActivityAt: msDate(json["last_activity_at"]))
    }

    /// What the mission is called wherever a number alone would be opaque.
    public var label: String { "#\(num) \(title)" }
}

/// One checkpoint. `seq` is the anchor: the `milestone` marker event's own
/// seq in `convoID`, and the only way back to where it happened.
public struct Milestone: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let missionID: String
    public let num: Int
    public let kind: MilestoneKind
    public let title: String
    public let body: String
    public let convoID: String
    public let seq: Int64
    public let deviceID: Int64
    public let createdBy: ItemAuthor
    public let createdAt: Date

    public init(id: String, missionID: String, num: Int, kind: MilestoneKind, title: String, body: String = "",
                convoID: String, seq: Int64, deviceID: Int64 = 0, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date()) {
        self.id = id; self.missionID = missionID; self.num = num; self.kind = kind; self.title = title
        self.body = body; self.convoID = convoID; self.seq = seq; self.deviceID = deviceID
        self.createdBy = createdBy; self.createdAt = createdAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let missionID = json["mission_id"] as? String,
              let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let title = json["title"] as? String, let convoID = json["convo_id"] as? String,
              // No seq, no anchor — and a milestone with no anchor is worse
              // than none (spec, "Milestone anchor").
              let seq = (json["seq"] as? NSNumber)?.int64Value,
              let createdAt = msDate(json["created_at"]) else { return nil }
        self.init(id: id, missionID: missionID, num: num, kind: kind, title: title,
                  body: json["body"] as? String ?? "", convoID: convoID, seq: seq,
                  deviceID: (json["device_id"] as? NSNumber)?.int64Value ?? 0,
                  createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                  createdAt: createdAt)
    }
}

/// One of a conversation row's OTHER mission links (`other_missions`,
/// journal plan addendum to spec 2026-09-30 §3): enough for an "also on #N"
/// or "moved to #N" chip that opens that mission. Codable so the store can
/// keep it as JSON on the link row.
public struct MissionOtherLink: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let num: Int
    public let title: String
    public let isCurrent: Bool
    public let isActive: Bool
    public let joinedAt: Date?
    public let endedAt: Date?

    public init(id: String, num: Int, title: String = "", isCurrent: Bool = false, isActive: Bool = true,
                joinedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.num = num; self.title = title; self.isCurrent = isCurrent; self.isActive = isActive
        self.joinedAt = joinedAt; self.endedAt = endedAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue else { return nil }
        let ended = msDate(json["ended_at"])
        self.init(id: id, num: num, title: json["title"] as? String ?? "", isCurrent: json["current"] as? Bool ?? false,
                  isActive: json["active"] as? Bool ?? (ended == nil), joinedAt: msDate(json["joined_at"]), endedAt: ended)
    }
}

/// A conversation belonging to a mission, as `GET /missions/:id` returns it.
/// Not a `ChatSummary`: it carries only what the mission page shows, and its
/// rows can name conversations this device has never synced. The link
/// fields (spec 2026-09-30 §3) are absent from an older journal: such a row
/// reads as an active, non-current link with no dates.
public struct MissionConversation: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let box: String?
    public let state: String
    public let isCurrent: Bool
    public let joinedAt: Date?
    /// `nil` while the link is active.
    public let endedAt: Date?
    /// `origin` | `joined` | `spawned` | `inherited` | `backfill`.
    public let how: String?
    public let parentConvoID: String?
    /// Sub-chats folded into this row by the journal.
    public let subchatCount: Int
    /// The conversation's other links, current → other active → ended.
    /// Empty on folded sub-chats and from an old journal.
    public let otherMissions: [MissionOtherLink]

    public var isActive: Bool { endedAt == nil }

    public init(id: String, title: String, box: String?, state: String, isCurrent: Bool = false,
                joinedAt: Date? = nil, endedAt: Date? = nil, how: String? = nil,
                parentConvoID: String? = nil, subchatCount: Int = 0, otherMissions: [MissionOtherLink] = []) {
        self.id = id; self.title = title; self.box = box; self.state = state; self.isCurrent = isCurrent
        self.joinedAt = joinedAt; self.endedAt = endedAt; self.how = how
        self.parentConvoID = parentConvoID; self.subchatCount = subchatCount; self.otherMissions = otherMissions
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", box: json["box"] as? String,
                  state: json["state"] as? String ?? "", isCurrent: json["current"] as? Bool ?? false,
                  joinedAt: msDate(json["joined_at"]), endedAt: msDate(json["ended_at"]),
                  how: json["how"] as? String, parentConvoID: json["parent_convo_id"] as? String,
                  subchatCount: (json["subchat_count"] as? NSNumber)?.intValue ?? 0,
                  otherMissions: (json["other_missions"] as? [[String: Any]] ?? []).compactMap(MissionOtherLink.init(json:)))
    }
}
