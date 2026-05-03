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
    /// Keychain account name for the persisted recovery key. Stable across
    /// devices because the entry is iCloud-synced.
    public static let storageKey = "matron.recovery-key"

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
        try keychain.set(key, forKey: Self.storageKey)
        return key
    }

    /// Additional-device / restore path: feeds the user's recovery key to
    /// unlock backup + cross-signing on this device. Persists the key
    /// locally so subsequent reads via `currentKey()` succeed.
    public func restore(usingKey key: String) async throws {
        let client = try await provider.client(for: session)
        let encryption = client.encryption()
        try await encryption.recover(recoveryKey: key)
        try keychain.set(key, forKey: Self.storageKey)
    }

    /// Returns the locally-stored recovery key (synced from iCloud
    /// Keychain on additional devices) or `nil` if nothing has been
    /// stored. Powers the "show recovery key again" surface in Settings.
    public func currentKey() throws -> String? {
        try keychain.get(key: Self.storageKey)
    }
}

/// No-op listener for `Encryption.enableRecovery`. The SDK requires a
/// concrete listener; UI-side progress reporting will land with the
/// recovery-key view in a later task.
private final class NoopEnableRecoveryProgressListener: EnableRecoveryProgressListener {
    func onUpdate(status: EnableRecoveryProgress) {}
}
