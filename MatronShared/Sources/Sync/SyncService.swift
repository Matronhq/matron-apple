import Foundation
import MatrixRustSDK

/// User-facing rendering of sliding-sync's connection state. Maps from the
/// SDK's `SyncServiceState` (`.idle`, `.running`, `.terminated`, `.error`,
/// `.offline`) onto a smaller set the chat-list banner can switch on.
///
/// `.connecting` covers the "no signal yet" window (initial `.idle` before
/// `.running` ever fires), so the user sees a banner instead of a silently
/// empty list while sliding sync warms up. `.running` is the steady-state
/// (banner hides). `.offline` covers the SDK's `.offline` and the
/// pre-`.running` `.terminated` / `.error` cases — anything that means
/// "we're not currently exchanging data with the server" — so the banner
/// can render a red strip with a reason while reconnect is in flight.
///
/// Mid-session blips (e.g. an `.error` AFTER we've ever been `.running`) do
/// NOT promote to `.offline` here — sliding sync auto-recovers from those
/// and a banner flash on every transient hiccup is just noise. Mirrors the
/// `hasEverBeenRunning` posture that `waitUntilReady()` already takes.
public enum SyncConnectionState: Equatable, Sendable {
    case connecting
    case running
    case offline(reason: String?)
}

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

    /// Long-lived stream of user-facing connection state for the
    /// chat-list banner. Yields the current value on subscribe so the
    /// View doesn't need a separate "what is it now?" query, then yields
    /// every transition until the service is stopped or the consumer
    /// drops the iterator. Multiple consumers each get their own stream
    /// — implementations fan out internally.
    func stateStream() async -> AsyncStream<SyncConnectionState>
}
