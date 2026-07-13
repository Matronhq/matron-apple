import Foundation

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
///
/// Lives in MatronModels (not MatronSync) so the design system and the
/// journal sync engine can both consume it without depending on the
/// MatrixRustSDK-backed sliding-sync implementation. `MatronSync` keeps a
/// `public typealias` so existing call sites there keep compiling.
public enum SyncConnectionState: Equatable, Sendable {
    case connecting
    case running
    case offline(reason: String?)
}
