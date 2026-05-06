import Foundation
import MatrixRustSDK

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

    /// Underlying SDK `SyncService` once `start()` has wired it; `nil` before
    /// then or after `stop()`. `ChatServiceLive` reaches through this for
    /// `roomListService()` to subscribe to the live room-list diff stream
    /// (Phase 2.5). Test fakes return `nil` and ChatServiceLive degrades to
    /// the construction-throw fallback poll path. Lives on the protocol —
    /// not just the concrete — because cross-module `as?` downcasts of
    /// `any SyncService` to `SyncServiceLive` were unreliable in some host-app
    /// link configurations and silently demoted production iOS to the polling
    /// fallback.
    func sdkService() async -> MatrixRustSDK.SyncService?
}
