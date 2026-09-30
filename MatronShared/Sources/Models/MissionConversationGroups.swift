import Foundation

/// One top-level conversation on a mission page, its sub-chats folded in.
public struct MissionConversationRow: Identifiable, Equatable, Hashable, Sendable {
    public let conversation: MissionConversation
    public let state: DashboardSessionState
    public let subchats: [MissionConversation]
    public var id: String { conversation.id }
    /// The journal's folded count when it didn't list them, else the listed ones.
    public var subchatCount: Int { max(conversation.subchatCount, subchats.count) }

    /// "also on #N": this row's own link is active and the conversation
    /// has another active link — the current one first, as the journal
    /// orders `other_missions`.
    public var alsoOn: MissionOtherLink? {
        guard conversation.isActive else { return nil }
        return conversation.otherMissions.first(where: \.isActive)
    }

    /// "moved to #N": this row's own link ended while another link was
    /// then current — joined at or before the end, and not ended before it.
    /// A link flagged current wins; otherwise the one joined latest.
    public var movedTo: MissionOtherLink? {
        guard let ended = conversation.endedAt else { return nil }
        let then = conversation.otherMissions.filter { other in
            guard let joined = other.joinedAt, joined <= ended else { return false }
            return other.endedAt.map { $0 >= ended } ?? true
        }
        return then.first(where: \.isCurrent)
            ?? then.max { ($0.joinedAt ?? .distantPast) < ($1.joinedAt ?? .distantPast) }
    }

    /// The one chip a row shows; its `link.id` is the mission it opens.
    public var linkedMission: LinkedMission? { alsoOn.map(LinkedMission.alsoOn) ?? movedTo.map(LinkedMission.movedTo) }
    public init(conversation: MissionConversation, state: DashboardSessionState, subchats: [MissionConversation] = []) {
        self.conversation = conversation; self.state = state; self.subchats = subchats
    }
}

/// A conversation row's chip to another mission it is (or was) on.
public enum LinkedMission: Equatable, Hashable, Sendable {
    case alsoOn(MissionOtherLink)
    case movedTo(MissionOtherLink)
    public var link: MissionOtherLink {
        switch self { case .alsoOn(let l), .movedTo(let l): return l }
    }
    /// "also on" / "moved to" — followed by the `#N` chip.
    public var label: String {
        switch self { case .alsoOn: return "also on"; case .movedTo: return "moved to" }
    }
}

/// The mission page's "On it now" / "Earlier" split (spec §2). On it now:
/// an active link on an open mission. Earlier: an ended link, or every
/// link once the mission is closed. A sub-chat folds under its parent when
/// the parent is listed; otherwise it is a row of its own.
public struct MissionConversationGroups: Equatable, Sendable {
    public let onItNow: [MissionConversationRow]
    public let earlier: [MissionConversationRow]

    public var subchatTotal: Int { (onItNow + earlier).reduce(0) { $0 + $1.subchatCount } }

    /// `liveStates`: conversation id → the store's `session_state`, which
    /// wins over the detail row's (possibly stale) `state`.
    public init(conversations: [MissionConversation], missionState: MissionState, liveStates: [String: String] = [:]) {
        let ids = Set(conversations.map(\.id))
        var children: [String: [MissionConversation]] = [:]
        var top: [MissionConversation] = []
        for c in conversations {
            if let parent = c.parentConvoID, ids.contains(parent) {
                children[parent, default: []].append(c)
            } else {
                top.append(c)
            }
        }
        let rows = top.map { c in
            MissionConversationRow(conversation: c,
                                   state: DashboardSessionState(sessionState: liveStates[c.id] ?? c.state),
                                   subchats: (children[c.id] ?? []).sorted { $0.id < $1.id })
        }
        let open = missionState == .open
        onItNow = rows.filter { open && $0.conversation.isActive }.sorted(by: Self.onItNowPrecedes)
        earlier = rows.filter { !(open && $0.conversation.isActive) }.sorted(by: Self.earlierPrecedes)
    }

    private static func onItNowPrecedes(_ a: MissionConversationRow, _ b: MissionConversationRow) -> Bool {
        if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
        let (ja, jb) = (a.conversation.joinedAt ?? .distantPast, b.conversation.joinedAt ?? .distantPast)
        if ja != jb { return ja > jb }
        return a.id < b.id
    }

    private static func earlierPrecedes(_ a: MissionConversationRow, _ b: MissionConversationRow) -> Bool {
        let (ea, eb) = (a.conversation.endedAt ?? .distantPast, b.conversation.endedAt ?? .distantPast)
        if ea != eb { return ea > eb }
        return a.id < b.id
    }
}
