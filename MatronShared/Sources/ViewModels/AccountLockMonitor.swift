import Foundation
import Observation

/// Whether the journal says the whole account is locked. It answers every
/// request with HTTP 423 while it is; the first answer that is not 423
/// (and not a failure of the server or the network) means the lock has
/// been cleared.
@Observable @MainActor
public final class AccountLockMonitor {
    public private(set) var isLocked = false

    public init() {}

    /// The status of an answered request that carried this device's token.
    /// Safe to call from any thread.
    public nonisolated func note(status: Int) {
        guard let locked = Self.verdict(status) else { return }
        Task { @MainActor in
            if self.isLocked != locked { self.isLocked = locked }
        }
    }

    /// What a status says about the lock: locked, not locked, or nothing
    /// (a server error or a throttle proves neither).
    nonisolated static func verdict(_ status: Int) -> Bool? {
        switch status {
        case 423: return true
        case 429, 500...: return nil
        default: return false
        }
    }
}
