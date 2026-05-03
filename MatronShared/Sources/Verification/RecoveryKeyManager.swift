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
    /// Test seam: override the SDK round-trip portion of `restore(usingKey:)`
    /// so unit tests can drive the error-translation logic without a live
    /// client. Defaults to a closure that performs the real SDK call;
    /// tests assign a closure that throws the error variant they want to
    /// translate. Wave 4 expert-QA #1 — the error-classification logic
    /// (RecoveryError → RestoreError) is exercised against fake SDK
    /// errors here; live SDK behaviour is integration-tested in Phase 7.
    var sdkRecoverOverride: ((String) async throws -> Void)?
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
    ///
    /// Translates SDK errors into user-facing `RestoreError` cases so the UI
    /// can render specific copy ("That recovery key didn't work — check for
    /// typos." vs "Couldn't reach the homeserver.") instead of leaking raw
    /// SDK strings via `localizedDescription`. The SDK's `RecoveryError`
    /// enum (verified against `matrix-rust-components-swift v26.04.01` at
    /// `MatronShared/.build/checkouts/matrix-rust-components-swift/Sources/MatrixRustSDK/matrix_sdk_ffi.swift`
    /// line 34704) has four cases:
    ///   * `.BackupExistsOnServer` — irrelevant on the restore path (only
    ///     `enableRecovery` can hit it); falls through to `.other`.
    ///   * `.Client(source:)` — wraps a generic `ClientError`. Network
    ///     failures from `URLError` / SDK transport surface here; we
    ///     classify by inspecting the wrapped error.
    ///   * `.SecretStorage(errorMessage:)` / `.Import(errorMessage:)` — the
    ///     key was rejected by the homeserver's secret-storage layer or
    ///     failed to decrypt. This is the "wrong recovery key" path.
    ///
    /// `Foundation.URLError` (NSURLError-bridged) catches the
    /// no-network / no-DNS / TLS shapes that bubble up when the SDK can't
    /// reach the homeserver before the `RecoveryError` mapping fires.
    /// Persistence failures after a successful SDK round-trip are
    /// classified as `.other` — losing the local copy is a degraded state
    /// but the SDK has already unlocked encryption so the restore itself
    /// succeeded.
    public func restore(usingKey key: String) async throws {
        do {
            if let sdkRecoverOverride {
                try await sdkRecoverOverride(key)
            } else {
                let client = try await provider.client(for: session)
                let encryption = client.encryption()
                try await encryption.recover(recoveryKey: key)
            }
        } catch let recoveryError as RecoveryError {
            switch recoveryError {
            case .SecretStorage, .Import:
                // Both surface when the key is wrong: SecretStorage when the
                // server-side store rejects the derived key; Import when the
                // local SDK can't decrypt the secret it just fetched. Either
                // way the user-facing meaning is "that key didn't work."
                throw RestoreError.invalidKey
            case .Client(let source):
                throw Self.classify(clientError: source)
            case .BackupExistsOnServer:
                // Can't actually fire on the restore path — the SDK only
                // checks for an existing backup during enableRecovery — but
                // surface as `.other` so a future SDK behaviour change
                // doesn't crash the call site on an unhandled case.
                throw RestoreError.other(underlying: recoveryError)
            }
        } catch let urlError as URLError {
            throw RestoreError.network(underlying: urlError)
        } catch {
            throw RestoreError.other(underlying: error)
        }
        do {
            try keychain.set(key, forKey: sessionStorageKey)
        } catch {
            // SDK round-trip succeeded — encryption is unlocked on this
            // device — but local persistence failed. The user's recovery
            // key is still valid; we just can't show it back to them in
            // Settings. Surface as `.other` so the UI doesn't tell them
            // the key was wrong.
            throw RestoreError.other(underlying: error)
        }
    }

    /// Classifies a `ClientError` from the SDK into the appropriate
    /// `RestoreError`. The SDK's `ClientError.Generic(msg:details:)` and
    /// `.MatrixApi(kind:code:msg:details:)` don't carry typed payloads we
    /// can dispatch on, so we substring-match for network-shape strings —
    /// the SDK's transport layer wraps `reqwest::Error` for all
    /// network-class failures and the resulting `msg` consistently
    /// contains one of these tokens. A miss falls through to `.other`,
    /// which surfaces a generic message; the alternative (claiming
    /// "couldn't reach the homeserver" for a non-network failure) would
    /// be misleading. Tested against the SDK's known message shapes in
    /// `RecoveryKeyManagerTests.test_restore_classifiesGenericNetworkError_asNetwork`.
    private static func classify(clientError: ClientError) -> RestoreError {
        let msg: String
        switch clientError {
        case .Generic(let m, _): msg = m.lowercased()
        case .MatrixApi(_, _, let m, _): msg = m.lowercased()
        }
        let networkTokens = ["network", "timeout", "timed out", "connection", "dns", "tls", "transport", "unreachable"]
        if networkTokens.contains(where: { msg.contains($0) }) {
            return .network(underlying: clientError)
        }
        return .other(underlying: clientError)
    }

    /// User-facing error cases for `restore(usingKey:)`. Each carries enough
    /// context for the UI to render specific copy without leaking raw SDK
    /// strings via `localizedDescription`. Conforms to `LocalizedError` so
    /// callers that DO render `error.localizedDescription` (e.g. the
    /// `RecoveryKeyViewModel.attemptRestore` fallback) get the human copy
    /// instead of the case name.
    public enum RestoreError: Error, LocalizedError {
        /// The SDK rejected the recovery key — either the server-side
        /// secret-storage layer refused the derived key, or the local SDK
        /// couldn't decrypt the secret it fetched. User-facing meaning:
        /// "that key didn't work — check for typos."
        case invalidKey
        /// The SDK couldn't reach the homeserver (transport failure, DNS,
        /// TLS, timeout). The key may or may not be valid; surface a
        /// network-specific message so the user retries instead of
        /// re-entering the key.
        case network(underlying: Error)
        /// Anything not classified above. Localised description carries the
        /// underlying error's description so debug logs aren't useless,
        /// but the UI shows a generic "couldn't restore" message.
        case other(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "That recovery key didn't work — check for typos and try again."
            case .network:
                return "Couldn't reach the homeserver. Check your connection and try again."
            case .other(let underlying):
                return "Couldn't restore: \(underlying.localizedDescription)"
            }
        }
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
