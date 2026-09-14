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

private func msDate(_ v: Any?) -> Date? {
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

    public init(id: String, num: Int, state: MissionState = .open, title: String, body: String = "",
                closeSummary: String? = nil, closedBy: ItemAuthor? = nil, closedOverOpenItems: Int = 0,
                originConvoID: String, originDeviceID: Int64 = 0, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(), lastMilestoneAt: Date? = nil,
                closedAt: Date? = nil, openItems: Int = 0, needsYou: Int = 0, conversationCount: Int = 0,
                milestoneCount: Int = 0, lastMilestone: MissionLastMilestone? = nil) {
        self.id = id; self.num = num; self.state = state; self.title = title; self.body = body
        self.closeSummary = closeSummary; self.closedBy = closedBy; self.closedOverOpenItems = closedOverOpenItems
        self.originConvoID = originConvoID; self.originDeviceID = originDeviceID; self.createdBy = createdBy
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastMilestoneAt = lastMilestoneAt
        self.closedAt = closedAt; self.openItems = openItems; self.needsYou = needsYou
        self.conversationCount = conversationCount; self.milestoneCount = milestoneCount
        self.lastMilestone = lastMilestone
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
            lastMilestone: (json["last_milestone"] as? [String: Any]).flatMap(MissionLastMilestone.init(json:)))
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

/// A conversation belonging to a mission, as `GET /missions/:id` returns it.
/// Not a `ChatSummary`: it carries only what the mission page shows, and its
/// rows can name conversations this device has never synced.
public struct MissionConversation: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let box: String?
    public let state: String
    public init(id: String, title: String, box: String?, state: String) {
        self.id = id; self.title = title; self.box = box; self.state = state
    }
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.init(id: id, title: json["title"] as? String ?? "", box: json["box"] as? String,
                  state: json["state"] as? String ?? "")
    }
}
