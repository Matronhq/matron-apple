import Foundation
import MatronModels

public struct MissionsListQuery: Equatable, Sendable {
    /// Omitted means "both states" — the journal has no `state=any`.
    public var state: MissionState?
    /// `?since=<ms>`. The journal matches the STORED `updated_at`, so a
    /// hidden milestone can make a mission match; the row that comes back is
    /// fully sieved either way (protocol, "Accepted exception").
    public var since: Date?
    public init() {}

    var queryItems: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let state { q.append(.init(name: "state", value: state.rawValue)) }
        if let since { q.append(.init(name: "since", value: String(Int64(since.timeIntervalSince1970 * 1000)))) }
        return q
    }
}

/// What `GET /missions/:id` returns. `conversations` has no local equivalent
/// anywhere else — the snapshot never says which conversations a mission
/// owns — so this is the only source for the mission page's chat list.
public struct MissionDetail: Equatable, Sendable {
    public let mission: Mission
    public let milestones: [Milestone]
    public let items: [TrackerItem]
    public let conversations: [MissionConversation]
    public init(mission: Mission, milestones: [Milestone], items: [TrackerItem], conversations: [MissionConversation]) {
        self.mission = mission; self.milestones = milestones; self.items = items; self.conversations = conversations
    }
}

/// The read surface the apps need, plus the one write they are allowed:
/// a USER close. Creating, joining, renaming and moving items are agent-only
/// (bridge tools) and deliberately absent.
public protocol MissionsProviding: Sendable {
    func listMissions(_ query: MissionsListQuery) async throws -> [Mission]
    func mission(id: String) async throws -> MissionDetail
    func milestones(convoID: String) async throws -> [Milestone]
    func closeMission(id: String, summary: String) async throws -> Mission
}

extension JournalAPI: MissionsProviding {
    /// Internal (not private) so `MissionsAPITests` can pin the decoding
    /// without standing up an HTTP stub for every shape.
    static func decodeMissions(_ obj: [String: Any]) -> [Mission] {
        (obj["missions"] as? [[String: Any]] ?? []).compactMap(Mission.init(json:))
    }

    static func decodeMission(_ obj: [String: Any]) throws -> Mission {
        guard let mission = (obj["mission"] as? [String: Any]).flatMap(Mission.init(json:)) else {
            throw JournalAPIError.transport("malformed mission response")
        }
        return mission
    }

    static func decodeMissionDetail(_ obj: [String: Any]) throws -> MissionDetail {
        MissionDetail(
            mission: try decodeMission(obj),
            milestones: (obj["milestones"] as? [[String: Any]] ?? []).compactMap(Milestone.init(json:)),
            items: (obj["items"] as? [[String: Any]] ?? []).compactMap(TrackerItem.init(json:)),
            conversations: (obj["conversations"] as? [[String: Any]] ?? []).compactMap(MissionConversation.init(json:)))
    }

    public func listMissions(_ query: MissionsListQuery) async throws -> [Mission] {
        Self.decodeMissions(try await request(path: "/missions", query: query.queryItems))
    }

    public func mission(id: String) async throws -> MissionDetail {
        try Self.decodeMissionDetail(try await request(path: "/missions/\(Self.pathSegment(id))"))
    }

    public func milestones(convoID: String) async throws -> [Milestone] {
        let obj = try await request(path: "/milestones", query: [.init(name: "convo", value: convoID)])
        return (obj["milestones"] as? [[String: Any]] ?? []).compactMap(Milestone.init(json:))
    }

    /// A device close always succeeds server-side, even over open items —
    /// the journal records `closed_over_open_items` and names the numbers in
    /// the close marker. The 409s in the protocol's *Closing* section apply
    /// to AGENT callers, so this method never has to render one.
    public func closeMission(id: String, summary: String) async throws -> Mission {
        try Self.decodeMission(try await request(path: "/missions/\(Self.pathSegment(id))/close",
                                                 method: "POST", body: ["summary": summary]))
    }
}
