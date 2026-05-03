import Foundation

/// Errors surfaced by `KeychainProbe.run(keychain:)`. Distinct cases let
/// callers (the Mac app's bootstrap path) tell apart the three failure modes
/// the probe is guarding against:
///
/// - `setFailed`: the initial write failed. Almost always means
///   `errSecMissingEntitlement (-34018)` — the bundle is missing the
///   `keychain-access-groups` entitlement, or the access-group string in
///   the entitlement doesn't resolve (no signing team).
/// - `roundTripMismatch`: the probe wrote a value, the read succeeded, but
///   the bytes came back wrong. This indicates an entitlement-group
///   collision with another bundle, or a system Keychain bug. Either way
///   the recovery-key path can't be trusted.
/// - `getFailed` / `deleteFailed`: read or cleanup failed mid-cycle. The
///   probe always tries to delete on the way out so a flaky
///   `errSecItemNotFound` from a prior run can't poison the next launch.
public enum KeychainProbeError: Error, LocalizedError {
    case setFailed(underlying: Error)
    case getFailed(underlying: Error)
    case roundTripMismatch(expected: String, got: String?)
    case deleteFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .setFailed(let underlying):
            return "Keychain probe set failed: \(underlying.localizedDescription)"
        case .getFailed(let underlying):
            return "Keychain probe get failed: \(underlying.localizedDescription)"
        case .roundTripMismatch(let expected, let got):
            return "Keychain probe round-trip mismatch: expected \(expected), got \(got ?? "nil")"
        case .deleteFailed(let underlying):
            return "Keychain probe delete failed: \(underlying.localizedDescription)"
        }
    }
}

/// Setup-time probe that round-trips a value through a `SessionStore`
/// (typically a synchronizable `KeychainStore`) to assert that Keychain
/// access is wired up correctly before the app reaches the recovery-key
/// flow.
///
/// The Mac bundle's `keychain-access-groups` entitlement (`project.yml`
/// → `MatronMac` target) is the load-bearing piece — without it,
/// `RecoveryKeyManager.persistKey` calls into `KeychainStore.set` look
/// successful from the SDK's point of view but the actual `SecItemAdd`
/// returns `errSecMissingEntitlement`. The user signs in, generates a
/// recovery key, dismisses the onboarding sheet, and only discovers the
/// failure on a fresh install when iCloud Keychain doesn't restore the key.
///
/// Bugbot caught the equivalent on iOS in Phase 1 (`FileSessionStore`
/// fallback for the post-login session blob); the Mac probe is the
/// regression guard for the recovery-key half.
///
/// Accepts `SessionStore` (not `KeychainStore` directly) so unit tests can
/// drive a deliberately-failing in-memory double without standing up a
/// real Keychain entry.
public enum KeychainProbe {
    /// Static probe key. Constant so a half-completed prior run's leftover
    /// item is overwritten on the next launch (rather than accumulating).
    public static let probeKey = "matron.keychain-probe.v1"

    /// Round-trips a value through `keychain` and tears it down.
    ///
    /// Always attempts the final delete (even on a successful round-trip)
    /// so the probe leaves no residue. A delete failure after a successful
    /// round-trip surfaces as `.deleteFailed` — the entitlement is fine,
    /// but the next launch will see a leftover entry, which is worth
    /// surfacing.
    public static func run(keychain: any SessionStore) throws {
        let expected = "matron-probe-\(UUID().uuidString)"

        do {
            try keychain.set(expected, forKey: probeKey)
        } catch {
            throw KeychainProbeError.setFailed(underlying: error)
        }

        let actual: String?
        do {
            actual = try keychain.get(key: probeKey)
        } catch {
            // Best-effort cleanup before surfacing the read failure —
            // `set` already wrote, leaving an entry behind would be worse
            // than a noisy delete error.
            try? keychain.delete(key: probeKey)
            throw KeychainProbeError.getFailed(underlying: error)
        }

        guard actual == expected else {
            try? keychain.delete(key: probeKey)
            throw KeychainProbeError.roundTripMismatch(expected: expected, got: actual)
        }

        do {
            try keychain.delete(key: probeKey)
        } catch {
            throw KeychainProbeError.deleteFailed(underlying: error)
        }
    }
}
