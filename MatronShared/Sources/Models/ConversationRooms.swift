import Foundation

/// One agent-chat room a conversation takes part in, as that
/// conversation's own header lists it ("Rooms · n"). The title is the
/// room's, session short and room marker already peeled off.
public struct ConversationRoom: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let state: DashboardSessionState

    public init(id: String, title: String, state: DashboardSessionState) {
        self.id = id; self.title = title; self.state = state
    }
}

/// Which rooms a conversation lists (Dan, 2026-10-01): every room it is a
/// participant of — the starter and everyone who joined alike — newest
/// activity first (never-active last, then id for a stable order). A room
/// is never a room of itself.
public enum ConversationRoomsRule {
    public static func rooms(of convoID: String, among rooms: [MissionRoom]) -> [ConversationRoom] {
        rooms.filter { $0.id != convoID && $0.participantConvoIDs.contains(convoID) }
            .sorted { a, b in
                switch (a.lastActivity, b.lastActivity) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.id < b.id
                }
            }
            .map { ConversationRoom(id: $0.id, title: $0.title, state: DashboardSessionState(sessionState: $0.sessionState)) }
    }
}
