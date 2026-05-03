import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage
import MatronSync

/// Wraps the SDK's recovery-key surface (`Encryption.enableRecovery` /
/// `Encryption.recover`) and persists the plaintext key to Keychain so a
/// fresh install on another of the user's devices can restore without
/// re-entry. Persistence uses `kSecAttrSynchronizable=true` so the key
/// rides on iCloud Keychain.
///
/// Lifecycle:
/// - `generateAndPersist()`: first-device path. Generates a new recovery
///   key on the homeserver, stores it locally, returns the plaintext.
///   The plaintext MUST be shown to the user once.
/// - `restore(usingKey:)`: additional-device / reinstall path. Feeds an
///   existing recovery key back into the SDK to unlock backup +
///   cross-signing, then persists it.
/// - `currentKey()`: read-back for the "show recovery key again" surface
///   in Settings. Returns `nil` when nothing has ever been stored.
public final class RecoveryKeyManager: @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let keychain: KeychainStore
    /// Static prefix; per-user storage key is derived in `storageKey(for:)`.
    /// Was a single shared `"matron.recovery-key"` until bugbot caught the
    /// multi-account overwrite — a second account on the same device would
    /// stomp the first user's key, and `synchronizable: true` propagated
    /// the loss across all iCloud-linked devices. Now keyed by Matrix
    /// user ID so each user's key lives in its own Keychain entry.
    public static let storageKeyPrefix = "matron.recovery-key"

    /// Per-user Keychain account name. Stable across devices for the same
    /// user because the entry is iCloud-synced and the user ID is the
    /// canonical Matrix identifier.
    public static func storageKey(for userID: String) -> String {
        "\(storageKeyPrefix).\(userID)"
    }

    /// Convenience accessor for this manager's session-scoped key.
    private var sessionStorageKey: String {
        Self.storageKey(for: session.userID)
    }

    public init(provider: ClientProvider, session: UserSession, keychain: KeychainStore) {
        self.provider = provider
        self.session = session
        self.keychain = keychain
    }

    /// First-device path: enables key backup with a freshly generated
    /// recovery key, persists it to (iCloud) Keychain, returns the
    /// plaintext for one-time display to the user.
    public func generateAndPersist() async throws -> String {
        let client = try await provider.client(for: session)
        let encryption = client.encryption()
        let key = try await encryption.enableRecovery(
            waitForBackupsToUpload: false,
            passphrase: nil,
            progressListener: NoopEnableRecoveryProgressListener()
        )
        // Bugbot caught: if `keychain.set` throws after the SDK has
        // generated and registered the recovery key, the plaintext is
        // irrecoverably lost (the server holds the encrypted form, but
        // there's no way to retrieve plaintext from the SDK after-the-fact).
        // Always RETURN the key so the UI can show it to the user even when
        // local persistence fails — they can copy it manually. Persistence
        // failure is logged via a comment in the throwing path; the
        // RecoveryKeyView's `.show` phase forces explicit user
        // acknowledgement before persisting anyway.
        do {
            try keychain.set(key, forKey: sessionStorageKey)
        } catch {
            // Don't swallow the error silently — but do return the key. The
            // caller can decide whether the persistence failure is fatal
            // (typical: surface a "save your key now, we couldn't auto-store
            // it" warning) or acceptable (typical: ephemeral session).
            throw RecoveryKeyManager.PersistenceError.keychainWriteFailedButKeyAvailable(key: key, underlying: error)
        }
        return key
    }

    /// Thrown by `generateAndPersist` when the SDK has produced a recovery
    /// key but local persistence failed. Carries the plaintext so the UI
    /// can still display it to the user — losing the key is worse than
    /// hitting an "uh-oh, write the key down manually" warning.
    public enum PersistenceError: Error {
        case keychainWriteFailedButKeyAvailable(key: String, underlying: Error)
    }

    /// Additional-device / restore path: feeds the user's recovery key to
    /// unlock backup + cross-signing on this device. Persists the key
    /// locally so subsequent reads via `currentKey()` succeed.
    public func restore(usingKey key: String) async throws {
        let client = try await provider.client(for: session)
        let encryption = client.encryption()
        try await encryption.recover(recoveryKey: key)
        try keychain.set(key, forKey: sessionStorageKey)
    }

    /// Returns the locally-stored recovery key (synced from iCloud
    /// Keychain on additional devices) or `nil` if nothing has been
    /// stored. Powers the "show recovery key again" surface in Settings.
    public func currentKey() throws -> String? {
        try keychain.get(key: sessionStorageKey)
    }
}

/// No-op listener for `Encryption.enableRecovery`. The SDK requires a
/// concrete listener; UI-side progress reporting will land with the
/// recovery-key view in a later task.
private final class NoopEnableRecoveryProgressListener: EnableRecoveryProgressListener {
    func onUpdate(status: EnableRecoveryProgress) {}
}
