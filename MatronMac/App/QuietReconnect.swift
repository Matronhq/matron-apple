import Foundation
import Observation

/// Tells the connection banner that the socket is being closed and reopened
/// on purpose (the Mac app drops it when nothing is visible and picks it up
/// again on return), as opposed to dropping on its own.
///
/// While quiet the banner stays away: a planned stop never shows "offline",
/// and a planned reconnect shows "Reconnecting…" only if it is still going
/// after `delay` (or has failed by then). Real drops are not quiet and show
/// at once, as they always did.
@MainActor
@Observable
final class QuietReconnect {
    static let shared = QuietReconnect()

    /// How long a planned reconnect may take before the banner appears.
    static let delay: Duration = .seconds(2)

    /// A planned stop or reconnect is under way.
    private(set) var isQuiet = false
    /// Identifies the running planned reconnect; 0 when none runs. The banner
    /// restarts its delay timer when this changes.
    private(set) var episode = 0
    private var counter = 0

    /// The socket was closed on purpose; the app is out of sight.
    func stopped() {
        isQuiet = true
        episode = 0
    }

    /// A reconnect started because the app is coming back.
    func reconnectStarted() {
        isQuiet = true
        counter += 1
        episode = counter
    }

    /// The engine is caught up again, or the lifecycle ended.
    func settled() {
        isQuiet = false
        episode = 0
    }
}
