import Foundation
import MatronJournal

/// The one call that answers a hand-over card from the timeline. A slice,
/// not the whole API, like `AgentSpawnAnswering`.
public protocol GrantAnswering: Sendable {
    func answerGrant(grantID: String, approve: Bool, excludeMedia: [String]) async throws
}

extension JournalAPI: GrantAnswering {}
