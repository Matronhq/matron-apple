import Foundation
import os
import MatronModels

private let missionsAPILogger = Logger(subsystem: "chat.matron", category: "missions-api")

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

/// `decodeMissions`' result: the rows that decoded, plus the ids of any
/// that didn't (fix round 2, addendum — Bugbot on #216). A dropped row's
/// id still names a real, previously-cached mission; `MissionsSync`
/// folds `droppedIDs` into the same protected set it already keeps
/// detail-refreshed ids in, so a decode failure on this device (a field
/// this build doesn't understand yet, say) can never masquerade as "the
/// server stopped returning it" and get the authoritative replace to
/// delete it.
public struct MissionsListDecode: Equatable, Sendable {
    public let missions: [Mission]
    public let droppedIDs: [String]
    public init(missions: [Mission], droppedIDs: [String]) {
        self.missions = missions; self.droppedIDs = droppedIDs
    }
}

/// The read surface the apps need, plus the one write they are allowed:
/// a USER close. Creating, joining, renaming and moving items are agent-only
/// (bridge tools) and deliberately absent.
public protocol MissionsProviding: Sendable {
    func listMissions(_ query: MissionsListQuery) async throws -> MissionsListDecode
    func mission(id: String) async throws -> MissionDetail
    func milestones(convoID: String) async throws -> [Milestone]
    func closeMission(id: String, summary: String) async throws -> Mission
}

extension JournalAPI: MissionsProviding {
    /// Internal (not private) so `MissionsAPITests` can pin the decoding
    /// without standing up an HTTP stub for every shape. Lenient on
    /// individual rows on purpose — CodeRabbit #209 asked for a malformed
    /// row to fail the whole response, but the controller ruling keeps
    /// this the way `decodeMission`'s siblings (`items`, `milestones`,
    /// `conversations`) already behave: one bad row must not blank the
    /// entire list. The drop is logged, and (fix round 2, addendum) its
    /// id — when the row has one — is returned in `droppedIDs` so the
    /// caller can protect it from being read as "gone."
    ///
    /// The TOP-LEVEL `missions` key is a different failure mode (fix
    /// round 2, L1): absent or not an array means the response itself is
    /// malformed, not merely one bad row, and an authoritative replace
    /// must not treat that as "the server says there are now zero
    /// missions" — so this throws instead of defaulting to `[]`. A
    /// present-but-empty array is a legitimate "no missions" answer and
    /// still decodes.
    static func decodeMissions(_ obj: [String: Any]) throws -> MissionsListDecode {
        guard let rows = obj["missions"] as? [Any] else {
            throw JournalAPIError.transport("malformed missions response")
        }
        var missions: [Mission] = []
        var droppedIDs: [String] = []
        for element in rows {
            let row = element as? [String: Any]
            if let row, let mission = Mission(json: row) {
                missions.append(mission)
                continue
            }
            let id = row?["id"] as? String
            let num = (row?["num"] as? Int).map(String.init) ?? "?"
            missionsAPILogger.error("dropped malformed mission row id=\(id ?? "?", privacy: .public) num=\(num, privacy: .public)")
            if let id { droppedIDs.append(id) }
        }
        return MissionsListDecode(missions: missions, droppedIDs: droppedIDs)
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

    public func listMissions(_ query: MissionsListQuery) async throws -> MissionsListDecode {
        try Self.decodeMissions(try await request(path: "/missions", query: query.queryItems))
    }

    public func mission(id: String) async throws -> MissionDetail {
        try Self.decodeMissionDetail(try await request(path: "/missions/\(Self.pathSegment(id))"))
    }

    /// `GET /milestones?convo=` — spec-listed read surface, kept and tested
    /// (`MissionsAPITests`) even though no surface consumes it yet: the
    /// transcript renders milestones from timeline events and the mission
    /// page from the detail fetch (MINOR-1).
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
