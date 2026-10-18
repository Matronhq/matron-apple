import Foundation
import MatronAuth

/// How long the app may sit in the background before it locks again.
public enum AppLockTimeout: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 minute"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        }
    }
}

// The authenticator and the settings' home live in MatronAuth, so the
// share extension (which links no view models) checks the same lock.
public typealias BiometricAuthenticating = MatronAuth.BiometricAuthenticating
#if canImport(LocalAuthentication)
public typealias LocalBiometricAuthenticator = MatronAuth.LocalBiometricAuthenticator
#endif

/// App-wide biometric lock: opt-in, relocks after a configurable idle
/// period, and always locks on cold launch while enabled.
@Observable @MainActor
public final class AppLockController {
    public static let enabledKey = AppLockSettings.enabledKey
    public static let timeoutKey = AppLockSettings.timeoutKey

    public private(set) var isLocked: Bool
    public private(set) var isEnabled: Bool
    public private(set) var isUnlocking = false
    public private(set) var unlockError: String?
    /// When the most recent auth evaluation finished (success, failure, or
    /// cancel). Hosts use this to tell the auth dialog's own
    /// activate/resign churn apart from a genuine app switch when
    /// deciding whether to offer another automatic prompt.
    public private(set) var lastAuthEndedAt: Date?
    public var timeout: AppLockTimeout {
        didSet { defaults.set(timeout.rawValue, forKey: Self.timeoutKey) }
    }

    /// Nil when the device has neither biometry nor a passcode — the
    /// settings toggle disables itself off this.
    public var methodName: String? { auth.availableMethodName() }

    private let auth: any BiometricAuthenticating
    private let defaults: UserDefaults
    private let now: () -> Date
    private var resignedAt: Date?
    /// Monotonic intent counter: every `setEnabled` call supersedes any
    /// still-awaiting predecessor, so an enable whose auth prompt outlives
    /// the user's change of mind can't re-enable behind their back.
    private var enableGeneration = 0

    public init(
        auth: any BiometricAuthenticating,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.auth = auth
        self.defaults = defaults
        self.now = now
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        // integer(forKey:) can't distinguish "unset" from rawValue 0
        // (.immediately), so check presence before decoding.
        if defaults.object(forKey: Self.timeoutKey) != nil,
           let stored = AppLockTimeout(rawValue: defaults.integer(forKey: Self.timeoutKey)) {
            self.timeout = stored
        } else {
            self.timeout = .fiveMinutes
        }
        // A cold launch has no trusted "last active" moment, so an
        // enabled lock always engages at startup — unless the device can
        // no longer evaluate ANY auth (passcode removed since enabling):
        // a lock nothing can open is a permanent lockout, not security,
        // and whoever removed the passcode had to own the device to do it.
        self.isLocked = enabled && auth.availableMethodName() != nil
    }

    /// Enabling authenticates first — proving the method works before it
    /// stands between the user and their chats. Disabling from settings
    /// needs no auth: the app is already unlocked to reach the toggle.
    public func setEnabled(_ enabled: Bool) async {
        unlockError = nil
        // Bump BEFORE the no-op guard: a disable that matches current
        // state still expresses fresh intent that must invalidate an
        // enable suspended in its auth prompt.
        enableGeneration += 1
        let generation = enableGeneration
        guard enabled != isEnabled else { return }
        if enabled {
            guard await runAuth(reason: "Confirm you can unlock Matron") else { return }
            // The user may have reversed the toggle while the prompt was
            // up — a stale enable must not win over their later intent.
            guard generation == enableGeneration else { return }
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { isLocked = false }
    }

    /// Call when the app leaves the foreground.
    public func noteResignedActive() {
        guard isEnabled, !isLocked else { return }
        if resignedAt == nil { resignedAt = now() }
    }

    /// Call when the app returns to the foreground.
    public func noteBecameActive() {
        defer { resignedAt = nil }
        guard isEnabled, !isLocked, let resignedAt,
              auth.availableMethodName() != nil else { return }
        if now().timeIntervalSince(resignedAt) >= Double(timeout.rawValue) {
            isLocked = true
        }
    }

    public func unlock() async {
        guard isLocked, !isUnlocking else { return }
        // The auth method can vanish WHILE locked (passcode removed with
        // the app backgrounded and still resident). Same reasoning as the
        // init guard: an unopenable lock is a lockout, so stand down.
        guard auth.availableMethodName() != nil else {
            isLocked = false
            resignedAt = nil
            return
        }
        unlockError = nil
        if await runAuth(reason: "Unlock Matron") {
            isLocked = false
            resignedAt = nil
        }
    }

    private func runAuth(reason: String) async -> Bool {
        isUnlocking = true
        defer {
            isUnlocking = false
            lastAuthEndedAt = now()
        }
        do {
            if try await auth.authenticate(reason: reason) { return true }
            unlockError = "Authentication didn't complete — try again."
        } catch let error as LocalizedError where error.errorDescription != nil {
            unlockError = error.errorDescription
        } catch {
            unlockError = "Authentication failed — try again."
        }
        return false
    }
}
