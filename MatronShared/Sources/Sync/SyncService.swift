import Foundation
import MatronModels

/// Moved to MatronModels (journal swap); alias keeps existing imports compiling.
public typealias SyncConnectionState = MatronModels.SyncConnectionState

public protocol SyncService: Sendable {
    /// Starts sync. Caller must keep a strong reference.
    func start() async throws

    /// Stops sync.
    func stop() async

    /// True after `start()` succeeds, false after `stop()`.
    var isRunning: Bool { get async }

    /// Suspends until `start()` has been called and the sync engine reports
    /// ready.
    func waitUntilReady() async throws

    /// Long-lived stream of user-facing connection state for the
    /// chat-list banner. Yields the current value on subscribe so the
    /// View doesn't need a separate "what is it now?" query, then yields
    /// every transition until the service is stopped or the consumer
    /// drops the iterator. Multiple consumers each get their own stream
    /// — implementations fan out internally.
    func stateStream() async -> AsyncStream<SyncConnectionState>
}
