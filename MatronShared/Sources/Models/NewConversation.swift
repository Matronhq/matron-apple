import Foundation

/// A top-level conversation born while the client was connected and caught
/// up — what `SyncService.newConversations()` yields.
///
/// `startedHere` is the whole difference between "open it" and "leave the
/// user alone": true only when THIS device asked for a session just before
/// the conversation appeared (New Chat, or a `/start` sent from here).
/// Everything else — a session another agent spawned, one the Coordinator
/// or a routine started, one the user started on another device — arrives
/// with `startedHere == false`, and hosts list it with a "New" marker
/// instead of selecting or navigating to it (Dan, 2026-10-02: agents spawn
/// sessions all day, and each one pulled him out of what he was doing).
public struct NewConversation: Equatable, Sendable {
    public let id: String
    public let startedHere: Bool

    public init(id: String, startedHere: Bool) {
        self.id = id
        self.startedHere = startedHere
    }
}
