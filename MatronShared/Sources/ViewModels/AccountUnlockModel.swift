import Foundation
import Observation
import MatronJournal

/// Unlocking a locked account from this device, with Face ID or Touch ID.
///
/// The journal froze this device instead of signing it out, because it
/// holds an approval key old enough. Unlocking signs a statement over the
/// lock's start, sends it, and swaps in the new token the journal answers
/// with: the old one stops working the moment the account is unlocked,
/// and every other device of the account is signed out.
///
/// If the answer is lost, the account may be unlocked while this device
/// still holds the dead token: its next request is refused (401) and the
/// app signs out. `pendingUnlock` remembers the try until then, so the
/// sign-in screen can say what happened and which old device entry to
/// remove afterwards.
@Observable @MainActor
public final class AccountUnlockModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case unlocking
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private let monitor: AccountLockMonitor
    private let api: any AccountUnlocking
    private let sign: (Int64) async throws -> SignedApproval
    private let adoptToken: (String) async throws -> Void
    private let pending: PendingUnlockStore

    /// - Parameters:
    ///   - sign: the confirm sheet, then the signature (`ApprovalCenter.signUnlock`).
    ///   - adoptToken: stores the new token and starts using it, in place
    ///     of the old one, before anything else is sent.
    public init(monitor: AccountLockMonitor, api: any AccountUnlocking,
                sign: @escaping (Int64) async throws -> SignedApproval,
                adoptToken: @escaping (String) async throws -> Void,
                pending: PendingUnlockStore) {
        self.monitor = monitor
        self.api = api
        self.sign = sign
        self.adoptToken = adoptToken
        self.pending = pending
    }

    public var isUnlocking: Bool { phase == .unlocking }

    public var errorText: String? {
        if case .failed(let text) = phase { return text }
        return nil
    }

    public func unlock() async {
        guard phase != .unlocking else { return }
        guard let since = monitor.lock?.since else {
            phase = .failed("The app doesn't know yet when the lock began. Wait a moment and try again.")
            return
        }
        phase = .unlocking
        let approval: SignedApproval
        do {
            approval = try await sign(since)
        } catch ApprovalKeyFailure.cancelled {
            phase = .idle
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        // From here the journal may unlock without this device hearing it.
        pending.markStarted()
        let result: AccountUnlockResult
        do {
            result = try await api.unlockAccount(approval: approval)
        } catch AccountUnlockError.notLocked {
            pending.clear()
            phase = .idle
            monitor.cleared()
            return
        } catch {
            phase = .failed(Self.text(for: error))
            return
        }
        do {
            try await adoptToken(result.token)
        } catch {
            // The new token is in use for this run but could not be saved:
            // the next launch would find the old, dead one. The locked
            // screen goes with the lock, so the warning outlives it.
            phase = .idle
            pending.clear()
            monitor.cleared()
            monitor.warn(Self.unsavedTokenWarning)
            return
        }
        pending.clear()
        phase = .idle
        monitor.cleared()
    }

    public static let unsavedTokenWarning =
        "The account is unlocked, but this device couldn't save its new sign-in. The next time the app opens it may ask you to sign in again: do so."

    static func text(for error: Error) -> String {
        switch error {
        case JournalAPIError.accountLocked:
            return "This device can't unlock the account. Unlock it from another device, or ask whoever manages the server."
        case JournalAPIError.unauthenticated:
            return "This device has been signed out."
        case JournalAPIError.transport:
            return "Couldn't reach the server. Try again."
        default:
            return error.localizedDescription
        }
    }
}

/// Remembers that this device sent an unlock and had no answer yet. Kept
/// on disk: a lost answer is followed by a sign-out, and the sign-in
/// screen after it reads this.
public struct PendingUnlockStore: Sendable {
    private let key: String
    private let defaults: @Sendable () -> UserDefaults

    public init(user: String, host: String, defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
        self.key = "approval.unlockPending." + host.lowercased() + "." + user
        self.defaults = defaults
    }

    public var isPending: Bool { defaults().bool(forKey: key) }
    public func markStarted() { defaults().set(true, forKey: key) }
    public func clear() { defaults().removeObject(forKey: key) }

    /// Shown on the sign-in screen when the answer to an unlock was lost.
    public static let lostAnswerNotice =
        "The account was probably unlocked, but this device didn't get the server's answer, so it was signed out. Sign in again. Then, in Settings ▸ Devices, remove the old entry for this device."
}
