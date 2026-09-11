import Foundation
import MatronModels

/// The `milestone` journal event (protocol: "Marker events"). Its own `seq`
/// is the anchor — the row that renders it IS the jump target — so the
/// mapper keeps the event seq alongside it.
///
/// `missionTitle` is OPTIONAL on purpose. The journal drops it at write time
/// whenever the mission's origin conversation is private-owned and the
/// conversation being written to is not, so an ordinary agent replaying that
/// conversation never reads the private mission's name. `missionNum` always
/// survives; render `missionLabel`, never `missionTitle ?? ""`.
public struct MilestoneMarkerEvent: Equatable, Sendable {
    public let milestoneID: String
    public let num: Int
    public let kind: MilestoneKind
    public let title: String
    public let body: String
    public let missionID: String
    public let missionNum: Int
    public let missionTitle: String?
    public let by: ItemAuthor

    public init(milestoneID: String, num: Int, kind: MilestoneKind, title: String, body: String = "",
                missionID: String, missionNum: Int, missionTitle: String? = nil, by: ItemAuthor = .agent) {
        self.milestoneID = milestoneID; self.num = num; self.kind = kind; self.title = title
        self.body = body; self.missionID = missionID; self.missionNum = missionNum
        self.missionTitle = missionTitle; self.by = by
    }

    /// How to name the mission in the UI: its title when the marker carried
    /// one, otherwise its number. Never an empty string.
    public var missionLabel: String { missionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(missionNum)" }

    public static func parse(payload: [String: Any]) -> MilestoneMarkerEvent? {
        guard let milestoneID = payload["milestone_id"] as? String,
              let num = (payload["num"] as? NSNumber)?.intValue,
              let kind = (payload["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let title = payload["title"] as? String,
              let missionID = payload["mission_id"] as? String,
              let missionNum = (payload["mission_num"] as? NSNumber)?.intValue,
              let by = (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:))
        else { return nil }
        return MilestoneMarkerEvent(milestoneID: milestoneID, num: num, kind: kind, title: title,
                                    body: payload["body"] as? String ?? "", missionID: missionID,
                                    missionNum: missionNum, missionTitle: payload["mission_title"] as? String, by: by)
    }
}

/// The `mission` journal event. Purely an invalidation signal plus a
/// one-line inline notice — the apps re-read the mission over HTTP rather
/// than trusting anything here beyond the number and the action.
public struct MissionMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case created, joined, updated, closed }
    public let missionID: String
    public let num: Int
    /// Optional for the same boundary reason as `MilestoneMarkerEvent.missionTitle`.
    public let title: String?
    public let action: Action
    public let by: ItemAuthor
    /// Only on a user-forced close: the numbers of items still open at the
    /// time, hidden ones included (the user's own record of their override).
    public let openItemNums: [Int]

    public init(missionID: String, num: Int, title: String? = nil, action: Action,
                by: ItemAuthor = .agent, openItemNums: [Int] = []) {
        self.missionID = missionID; self.num = num; self.title = title
        self.action = action; self.by = by; self.openItemNums = openItemNums
    }

    public var missionLabel: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(num)" }

    public static func parse(payload: [String: Any]) -> MissionMarkerEvent? {
        guard let missionID = payload["mission_id"] as? String,
              let num = (payload["num"] as? NSNumber)?.intValue,
              let action = (payload["action"] as? String).flatMap(Action.init(rawValue:)),
              let by = (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:))
        else { return nil }
        return MissionMarkerEvent(missionID: missionID, num: num, title: payload["title"] as? String,
                                  action: action, by: by,
                                  openItemNums: (payload["open_item_nums"] as? [NSNumber])?.map(\.intValue) ?? [])
    }
}

/// Both marker types on one stream — `MissionsSync` reacts to either by
/// refetching the same mission, so a single feed keeps the engine's
/// publishing site and the actor's subscription simple.
public enum MissionMarker: Equatable, Sendable {
    case mission(MissionMarkerEvent)
    case milestone(MilestoneMarkerEvent)

    public var missionID: String {
        switch self {
        case .mission(let m): return m.missionID
        case .milestone(let m): return m.missionID
        }
    }
}
