import Foundation
import Observation

/// Whether the journal says the whole account is locked.
///
/// A lock shows up three ways: a `panic` frame on the live socket just
/// before the journal closes it, a hello refused with `account_locked`,
/// and HTTP 423 on a request. A lock also signs every device out, so the
/// token usually stops working (401) straight after: that says nothing
/// about the lock, and the sign-in screen then says the account is locked
/// (`lockedNotice`) instead of "signed out from another device".
///
/// The journal does not announce that a lock was cleared. An answer the
/// server could only give a signed-in device (anything but 401, 423, a
/// throttle or a server error) shows it has been, and so does signing in.
@Observable @MainActor
public final class AccountLockMonitor {
    public private(set) var isLocked = false
    /// The live socket said so. An HTTP answer cannot undo that: one sent
    /// before the lock can arrive after it. Only the socket being accepted
    /// again, or a sign-in, does.
    @ObservationIgnored private var lockedBySocket = false
    @ObservationIgnored private var clearedHandlers: [() -> Void] = []

    /// Shown on the sign-in screen after a lock signed this device out.
    public static let lockedNotice =
        "This account is locked. You can sign in again once the lock has been cleared."

    public init() {}

    /// Runs `handler` each time the lock is cleared: what waited behind it
    /// (the reply outbox) can go again.
    public func whenCleared(_ handler: @escaping () -> Void) {
        clearedHandlers.append(handler)
    }

    /// The status of an answered request that carried this device's token.
    /// Safe to call from any thread.
    public nonisolated func note(status: Int) {
        guard let locked = Self.verdict(status) else { return }
        Task { @MainActor in
            if !locked, self.lockedBySocket { return }
            self.set(locked)
        }
    }

    /// The live socket said the account is locked. Safe to call from any
    /// thread.
    public nonisolated func noteLockedBySocket() {
        Task { @MainActor in
            self.lockedBySocket = true
            self.set(true)
        }
    }

    /// The journal accepted this device's hello: the account is not
    /// locked. Safe to call from any thread.
    public nonisolated func noteSocketAccepted() {
        Task { @MainActor in
            guard self.lockedBySocket else { return }
            self.lockedBySocket = false
            self.set(false)
        }
    }

    /// A sign-in went through: the account is not locked.
    public func signedIn() {
        lockedBySocket = false
        set(false)
    }

    private func set(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        if !locked { clearedHandlers.forEach { $0() } }
    }

    /// What a status says about the lock: locked, not locked, or nothing.
    /// A 401 says nothing: a lock removes this device's sign-in, so the
    /// token is refused while the account is still locked.
    nonisolated static func verdict(_ status: Int) -> Bool? {
        switch status {
        case 423: return true
        case 401, 429, 500...: return nil
        default: return false
        }
    }
}
