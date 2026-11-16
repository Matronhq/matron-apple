import Foundation
import MatronJournal

/// The one call that resolves a spawn consent card. A slice, not the whole
/// API, for the same reason `AgentChatAnswering` is one: `ChatViewModel`
/// answers cards inline in the timeline and has no business doing anything
/// else with the server.
///
/// There is deliberately no `pending` counterpart here: unlike agent-chat,
/// a spawn's resolution is journalled (`spawn_outcome`), so the timeline —
/// not a poll of parked rows — is where resolved state comes from.
public protocol AgentSpawnAnswering: Sendable {
    func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision) async throws
    /// The same answer, with what the card showed: a spawn onto a
    /// protected box is signed, and the app checks the task it signs for
    /// against the task the user read (`SigningConsentService`).
    func answerAgentSpawn(_ ask: SpawnAsk, decision: AgentSpawnDecision) async throws
}

public extension AgentSpawnAnswering {
    func answerAgentSpawn(_ ask: SpawnAsk, decision: AgentSpawnDecision) async throws {
        try await answerAgentSpawn(requestID: ask.requestID, decision: decision)
    }
}

extension JournalAPI: AgentSpawnAnswering {}
