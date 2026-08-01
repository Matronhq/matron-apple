import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

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

/// Seam over `LAContext` so lock logic is testable without real biometrics.
public protocol BiometricAuthenticating: Sendable {
    /// The user-facing name of the strongest available method
    /// ("Face ID" / "Touch ID"), or nil when neither biometry nor a
    /// device passcode is available.
    func availableMethodName() -> String?
    func authenticate(reason: String) async throws -> Bool
}

#if canImport(LocalAuthentication)
/// Real implementation. A fresh `LAContext` per call — contexts cache
/// evaluation state, and a stale success would defeat the lock.
public struct LocalBiometricAuthenticator: BiometricAuthenticating {
    public init() {}

    public func availableMethodName() -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default:
            #if os(macOS)
            return "your password"
            #else
            return "your passcode"
            #endif
        }
    }

    public func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        // .deviceOwnerAuthentication = biometry with passcode/password
        // fallback, so a failed Face ID scan never strands the user.
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
#endif

/// App-wide biometric lock: opt-in, relocks after a configurable idle
/// period, and always locks on cold launch while enabled.
@Observable @MainActor
public final class AppLockController {
    public static let enabledKey = "AppLock.enabled"
    public static let timeoutKey = "AppLock.timeout"

    public private(set) var isLocked: Bool
    public private(set) var isEnabled: Bool
    public private(set) var isUnlocking = false
    public private(set) var unlockError: String?
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
        // enabled lock always engages at startup.
        self.isLocked = enabled
    }

    /// Enabling authenticates first — proving the method works before it
    /// stands between the user and their chats. Disabling from settings
    /// needs no auth: the app is already unlocked to reach the toggle.
    public func setEnabled(_ enabled: Bool) async {
        unlockError = nil
        guard enabled != isEnabled else { return }
        if enabled {
            guard await runAuth(reason: "Confirm you can unlock Matron") else { return }
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
        guard isEnabled, !isLocked, let resignedAt else { return }
        if now().timeIntervalSince(resignedAt) >= Double(timeout.rawValue) {
            isLocked = true
        }
    }

    public func unlock() async {
        guard isLocked, !isUnlocking else { return }
        unlockError = nil
        if await runAuth(reason: "Unlock Matron") {
            isLocked = false
            resignedAt = nil
        }
    }

    private func runAuth(reason: String) async -> Bool {
        isUnlocking = true
        defer { isUnlocking = false }
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
