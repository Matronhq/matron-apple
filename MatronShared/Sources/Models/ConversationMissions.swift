import Foundation

/// One mission a conversation has touched (spec 2026-09-30 §3), as
/// `GET /conversations/:id/missions` returns it — the mission row itself
/// plus the link's own fields.
public struct ConversationMissionLink: Identifiable, Equatable, Hashable, Sendable {
    public let mission: Mission
    /// Where `milestone_post` goes by default. At most one link is current.
    public let isCurrent: Bool
    public let isActive: Bool
    public let joinedAt: Date?
    public let endedAt: Date?
    public let how: String?

    public var id: String { mission.id }
    /// History: an ended link, or any link to a closed mission.
    public var isEarlier: Bool { !isActive || mission.state == .closed }

    public init(mission: Mission, isCurrent: Bool = false, isActive: Bool = true,
                joinedAt: Date? = nil, endedAt: Date? = nil, how: String? = nil) {
        self.mission = mission; self.isCurrent = isCurrent; self.isActive = isActive
        self.joinedAt = joinedAt; self.endedAt = endedAt; self.how = how
    }

    /// The spec spreads the mission row flat into each element; a nested
    /// `mission` object is accepted too, so either journal shape decodes.
    public init?(json: [String: Any]) {
        let row = (json["mission"] as? [String: Any]) ?? json
        guard let mission = Mission(json: row) else { return nil }
        let ended = msDate(json["ended_at"])
        self.init(mission: mission, isCurrent: json["current"] as? Bool ?? false,
                  isActive: json["active"] as? Bool ?? (ended == nil),
                  joinedAt: msDate(json["joined_at"]), endedAt: ended, how: json["how"] as? String)
    }
}

/// The header's Current / Also on / Earlier split.
public struct ConversationMissionSections: Equatable, Sendable {
    public let current: ConversationMissionLink?
    /// Active links to open missions other than the current one, newest joined first.
    public let alsoOn: [ConversationMissionLink]
    /// Ended links and links to closed missions, most recently ended first.
    public let earlier: [ConversationMissionLink]

    public init(_ links: [ConversationMissionLink]) {
        let live = links.filter { !$0.isEarlier }
        let current = live.first(where: \.isCurrent)
        self.current = current
        alsoOn = live.filter { $0.id != current?.id }
            .sorted { ($0.joinedAt ?? .distantPast) > ($1.joinedAt ?? .distantPast) }
        earlier = links.filter(\.isEarlier).sorted {
            ($0.endedAt ?? $0.mission.closedAt ?? .distantPast) > ($1.endedAt ?? $1.mission.closedAt ?? .distantPast)
        }
    }

    public var isEmpty: Bool { current == nil && alsoOn.isEmpty && earlier.isEmpty }

    /// What the chip names: the current mission, else the newest active,
    /// else the most recent earlier one.
    public var headline: ConversationMissionLink? { current ?? alsoOn.first ?? earlier.first }

    /// The chip's "+n": every other mission this conversation touched.
    /// `snapshotCount` (the snapshot's `mission_count`) wins when larger —
    /// the links may not have been fetched yet.
    public func othersCount(snapshotCount: Int?) -> Int {
        guard headline != nil else { return 0 }
        let known = (current == nil ? 0 : 1) + alsoOn.count + earlier.count
        return max(0, max(known, snapshotCount ?? 0) - 1)
    }
}

/// What `JournalStore.missionsStream(convoID:)` yields.
public struct ConversationMissions: Equatable, Sendable {
    public var links: [ConversationMissionLink]
    public var snapshotCount: Int?
    public init(links: [ConversationMissionLink] = [], snapshotCount: Int? = nil) {
        self.links = links; self.snapshotCount = snapshotCount
    }
    public var sections: ConversationMissionSections { ConversationMissionSections(links) }
    public var othersCount: Int { sections.othersCount(snapshotCount: snapshotCount) }
}
