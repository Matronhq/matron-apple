import Foundation

/// An agent-chat room as the mission views see it: the room conversation
/// plus the conversations taking part in it (each participant agent's own
/// session, journal-ordered). Only rooms whose participant conversations
/// are known are ever built — a room without them is in the Chats list
/// alone, never on a mission view.
public struct MissionRoom: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    /// The room's title, session short and room marker already peeled off.
    public let title: String
    /// The store's `session_state` for the room.
    public let sessionState: String
    public let lastActivity: Date?
    public let participantConvoIDs: [String]

    public init(id: String, title: String, sessionState: String, lastActivity: Date?, participantConvoIDs: [String]) {
        self.id = id; self.title = title; self.sessionState = sessionState
        self.lastActivity = lastActivity; self.participantConvoIDs = participantConvoIDs
    }
}

/// One row of a mission page's Rooms group.
public struct MissionRoomRow: Identifiable, Equatable, Hashable, Sendable {
    public let room: MissionRoom
    public let state: DashboardSessionState
    public var id: String { room.id }
    public init(room: MissionRoom, state: DashboardSessionState) { self.room = room; self.state = state }
}

/// Which missions a room belongs to (Dan, 2026-10-01): every OPEN mission
/// any of its participant conversations is ACTIVELY on (R7 — an ended link
/// does not count, and a closed mission has nobody on it). A room spanning
/// two missions belongs to both; a room with no participant on any open
/// mission belongs to none. A room that is itself actively linked to a
/// mission is a session there, not a room (an ENDED self-link does not stop
/// it being a room). The one place the rule lives, so the mission pages,
/// the cards and the project chips cannot disagree.
public enum RoomMissionRule {
    /// Whether room `roomID` is a room on one mission whose actively-linked
    /// conversation ids are `activeConvoIDs` (empty for a closed mission).
    public static func isOn(roomID: String, participantConvoIDs: [String], activeConvoIDs: Set<String>) -> Bool {
        !activeConvoIDs.contains(roomID) && participantConvoIDs.contains { activeConvoIDs.contains($0) }
    }

    /// Every mission room `roomID` is a room on, given conversation id →
    /// the open missions it is actively on.
    public static func missions(roomID: String, participantConvoIDs: [String],
                                activeMissionsByConvo: [String: Set<String>]) -> Set<String> {
        participantConvoIDs.reduce(into: Set<String>()) { $0.formUnion(activeMissionsByConvo[$1] ?? []) }
            .subtracting(activeMissionsByConvo[roomID] ?? [])
    }

    /// One mission page's Rooms group: each room on the mission once,
    /// newest activity first (never-active last, then id for a stable
    /// order). `liveStates` (conversation id → `session_state`) wins over
    /// the room's stored state, as it does for conversation rows.
    public static func rows(rooms: [MissionRoom], activeConvoIDs: Set<String>,
                            liveStates: [String: String] = [:]) -> [MissionRoomRow] {
        rooms.filter { isOn(roomID: $0.id, participantConvoIDs: $0.participantConvoIDs, activeConvoIDs: activeConvoIDs) }
            .sorted { a, b in
                switch (a.lastActivity, b.lastActivity) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.id < b.id
                }
            }
            .map { MissionRoomRow(room: $0, state: DashboardSessionState(sessionState: liveStates[$0.id] ?? $0.sessionState)) }
    }
}
