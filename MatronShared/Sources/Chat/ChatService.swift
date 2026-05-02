import Foundation

public protocol ChatService: Sendable {
    /// Async stream of room list snapshots (full list, not deltas).
    /// Emits a new snapshot any time the underlying room list changes.
    func chatSummaries() -> AsyncStream<[ChatSummary]>
}
