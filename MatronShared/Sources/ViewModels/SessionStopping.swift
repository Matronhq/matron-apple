import Foundation
import MatronJournal

/// Stops one session: the badge's **Stop session** on a spawn card the
/// Coordinator approved. It sends `/stop` into the spawned session's own
/// conversation, the same command the user would type there, through the
/// outbox, so it survives being offline. A slice, like
/// `AgentSpawnAnswering`, so the chat view model can stop a session and
/// nothing else.
public protocol SessionStopping: Sendable {
    func stopSession(convoID: String) async throws
}

extension JournalSyncEngine: SessionStopping {
    public func stopSession(convoID: String) async throws {
        try sendMessage(convoID: convoID, body: "/stop", localID: UUID().uuidString)
    }
}
