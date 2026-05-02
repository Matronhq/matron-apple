import Foundation

public protocol SyncService: Sendable {
    /// Starts sliding sync. Caller must keep a strong reference.
    func start() async throws

    /// Stops sliding sync.
    func stop() async

    /// True after `start()` succeeds, false after `stop()`.
    var isRunning: Bool { get async }

    /// Suspends until `start()` has been called and the underlying SDK reports
    /// that `RoomListService` is non-nil. Callers that need to subscribe to the
    /// room list (e.g. `ChatServiceLive`) must await this before issuing
    /// `client.syncService().roomListService()`.
    func waitUntilReady() async throws
}
