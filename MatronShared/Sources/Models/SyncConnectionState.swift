import Foundation

/// User-facing state of the journal sync engine's connection
/// (`JournalSyncEngine.stateStream()`), a small set the chat-list banner
/// can switch on.
///
/// `.connecting` covers the "no signal yet" window before the first
/// `.running`, so the user sees a banner instead of a silently empty list
/// while the first sync runs. `.catchingUp` means the
/// connection is established and the server is replaying missed history —
/// data IS flowing, so the UI says "loading", not "connecting" (a long
/// post-offline catch-up read as a stuck connection).
/// `.running` is the steady-state (banner hides). `.offline` is anything
/// that means "we're not currently exchanging data with the server", so
/// the banner can render a red strip with a reason while reconnect is in
/// flight.
///
/// Lives in MatronModels so the design system and the journal sync engine
/// can both consume it without depending on each other. `MatronSync` keeps
/// a `public typealias` so existing call sites there keep compiling.
public enum SyncConnectionState: Equatable, Sendable {
    case connecting
    case catchingUp
    case running
    case offline(reason: String?)
}
