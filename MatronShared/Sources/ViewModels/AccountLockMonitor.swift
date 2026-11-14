import Foundation
import Observation
import MatronJournal

/// Whether the journal says the whole account is locked, and whether this
/// device can unlock it.
///
/// A lock shows up three ways: a `panic` frame on the live socket just
/// before the journal closes it, a hello refused with `account_locked`,
/// and HTTP 423 on a request. Each says when the lock began and, with
/// `unlock: true`, that the journal froze this device instead of signing
/// it out, because it holds an approval key old enough: it keeps its token
/// and can unlock the account with Face ID or Touch ID.
///
/// A device without that is signed out by the lock: its token stops
/// working (401), which says nothing about the lock, and the sign-in
/// screen then says the account is locked (`lockedNotice`).
///
/// The journal does not announce that a lock was cleared from its host.
/// An answer the server could only give a signed-in device (anything but
/// 401, 423, a throttle or a server error) shows it has been, and so do
/// signing in and this device's own unlock.
@Observable @MainActor
public final class AccountLockMonitor {
    public private(set) var isLocked = false
    /// What the journal last said about the lock.
    public private(set) var lock: AccountLock?
    /// The journal froze this device: it can unlock the account.
    public var canUnlock: Bool { isLocked && lock?.canUnlock == true }
    /// Something the user must read once the lock has gone (the new
    /// sign-in an unlock gave could not be saved). Shown until dismissed.
    public private(set) var warning: String?
    @ObservationIgnored private var clearedHandlers: [() -> Void] = []
    /// The live socket said so. An HTTP answer cannot undo that: one sent
    /// before the lock can arrive after it. Only the socket being accepted
    /// again, a sign-in or an unlock does.
    @ObservationIgnored private var lockedBySocket = false
    /// When the lock now shown was last reported. An acceptance heard
    /// before then cannot clear it.
    @ObservationIgnored private var lockedAt: ContinuousClock.Instant?

    /// Shown on the sign-in screen after a lock signed this device out.
    public static let lockedNotice =
        "This device was signed out because the account was locked. Sign in again once the lock has been cleared."

    public init() {}

    /// Runs `handler` each time the lock is cleared: what waited behind it
    /// (the reply outbox) can go again.
    public func whenCleared(_ handler: @escaping () -> Void) {
        clearedHandlers.append(handler)
    }

    /// The status of an answered request that carried this device's token.
    /// Safe to call from any thread.
    public nonisolated func note(status: Int) {
        guard let locked = Self.verdict(status), !locked else { return }
        Task { @MainActor in
            // A frozen device's token can still fetch a nonce: that answer
            // says nothing about the lock.
            if self.lockedBySocket || self.lock?.canUnlock == true { return }
            self.set(false)
        }
    }

    /// A request was refused because the account is locked. Safe to call
    /// from any thread.
    public nonisolated func note(lock: AccountLock) {
        let at = ContinuousClock.now
        Task { @MainActor in self.locked(lock, at: at) }
    }

    /// The live socket said the account is locked. Safe to call from any
    /// thread.
    public nonisolated func noteLockedBySocket(_ lock: AccountLock) {
        let at = ContinuousClock.now
        Task { @MainActor in
            self.lockedBySocket = true
            self.locked(lock, at: at)
        }
    }

    /// The journal accepted this device's hello: the account is not
    /// locked. Safe to call from any thread.
    public nonisolated func noteSocketAccepted() {
        let at = ContinuousClock.now
        Task { @MainActor in
            // The journal says hello to no device of a locked account, so
            // this ends a lock however it was learned; but not one reported
            // after the hello was accepted (the lock came later).
            if let lockedAt = self.lockedAt, lockedAt > at { return }
            self.lockedBySocket = false
            self.set(false)
        }
    }

    /// Keeps `text` on screen after the lock goes, until dismissed.
    public func warn(_ text: String) { warning = text }
    public func dismissWarning() { warning = nil }

    /// A sign-in went through, or this device unlocked the account.
    public func cleared() {
        lockedBySocket = false
        set(false)
    }

    private func locked(_ lock: AccountLock, at: ContinuousClock.Instant) {
        if let lockedAt, lockedAt > at {} else { lockedAt = at }
        // A refusal that leaves `since` out keeps the one already known.
        self.lock = AccountLock(since: lock.since ?? self.lock?.since, canUnlock: lock.canUnlock)
        set(true)
    }

    private func set(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        if !locked {
            lock = nil
            lockedAt = nil
            clearedHandlers.forEach { $0() }
        }
    }

    /// What a status says about the lock: locked, not locked, or nothing.
    /// A 401 says nothing: a lock removes a device's sign-in, so the token
    /// is refused while the account is still locked.
    nonisolated static func verdict(_ status: Int) -> Bool? {
        switch status {
        case 423: return true
        case 401, 429, 500...: return nil
        default: return false
        }
    }
}
