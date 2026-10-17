import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import MatronStorage

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
/// evaluation state, and a stale success would defeat the lock. Shared by
/// the app and its share extension, so both ask for the same thing.
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

/// Where the app lock's settings are kept. On iOS they live in the app
/// group's defaults, so the share extension sees the same switch the app
/// does; elsewhere in the standard defaults.
public enum AppLockSettings {
    public static let enabledKey = "AppLock.enabled"
    public static let timeoutKey = "AppLock.timeout"

    /// The defaults the settings are read from and written to.
    public static var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: StoragePaths.appGroupIdentifier) ?? .standard
        #else
        return .standard
        #endif
    }

    /// For the app at launch: `defaults`, with any settings saved before
    /// they moved there carried over first, so a lock that was on stays on.
    public static func preparedDefaults() -> UserDefaults {
        let shared = defaults
        migrate(from: .standard, to: shared)
        return shared
    }

    /// Copies each setting `legacy` holds that `shared` does not yet. A
    /// value already in `shared` is newer and wins.
    public static func migrate(from legacy: UserDefaults, to shared: UserDefaults) {
        guard legacy !== shared else { return }
        for key in [enabledKey, timeoutKey] where shared.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { shared.set(value, forKey: key) }
        }
    }

    /// Whether someone has to authenticate before anything is shown: the
    /// lock is on and the device can still check who is holding it. With
    /// neither biometry nor a passcode left, the app stands its lock down
    /// too (a lock nothing can open is a lockout).
    public static func requiresUnlock(in defaults: UserDefaults, auth: any BiometricAuthenticating) -> Bool {
        defaults.bool(forKey: enabledKey) && auth.availableMethodName() != nil
    }
}
