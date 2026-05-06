import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage
import MatronSync
import os

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

    /// Maximum time `restore(usingKey:)` will wait for the SDK's
    /// `verificationState()` to flip to `.verified` after
    /// `recoverAndFixBackup` returns. 30s mirrors
    /// `SyncServiceLive.readyTimeout` and is generous enough for the
    /// SDK to download cross-signing private keys + sign this device
    /// against the master key on a slow link, but tight enough that a
    /// genuinely-stuck restore surfaces a `crossSigningTimeout` error
    /// rather than dropping the user into a half-trusted state.
    public static let crossSigningSettleTimeout: TimeInterval = 30
    /// Poll cadence inside `waitForVerifiedState`. 250ms is small
    /// enough to react quickly when the listener fires, big enough
    /// to avoid hammering the SDK's encryption layer.
    public static let crossSigningSettlePollInterval: TimeInterval = 0.25

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

    /// Polls `encryption.verificationState()` until it flips to
    /// `.verified`, or throws `RestoreError.crossSigningTimeout` after
    /// `timeout`. Internal, but `static` + `nonisolated` so unit tests
    /// can exercise the timeout path against a stubbed clock without
    /// constructing the full `RecoveryKeyManager`.
    static func waitForVerifiedState(
        encryption: Encryption,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if encryption.verificationState() == .verified { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        // Final check — last poll might have settled in the gap
        // between the loop exit and the throw.
        if encryption.verificationState() == .verified { return }
        Self.logger.error("waitForVerifiedState: timed out after \(timeout, privacy: .public)s with state=\(String(describing: encryption.verificationState()), privacy: .public)")
        throw RestoreError.crossSigningTimeout
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
        Self.logger.notice("generate: enter")
        Self.logger.notice("generate: fetching client")
        let client = try await provider.client(for: session)
        let encryption = client.encryption()
        // Branch on `recoveryState()` — mirrors Element X's
        // `SecureBackupController.generateRecoveryKey`
        // (`ElementX/Sources/Services/SecureBackup/SecureBackupController.swift:113-145`).
        // With `ClientBuilder.autoEnableCrossSigning(true)` set in
        // `AuthServiceLive` / `ClientProvider`, the SDK auto-bootstraps
        // cross-signing on first sign-in. After that bootstrap the
        // recovery state is no longer `.disabled` and calling the
        // bootstrap-shaped `enableRecovery` against a non-`.disabled`
        // state hangs (the SDK's recovery state machine assumes
        // `enableRecovery` is the first call into the subsystem).
        // `resetRecoveryKey` is the right API once cross-signing exists
        // — it issues a fresh recovery key against the existing
        // identity instead of trying to bootstrap one.
        let state = encryption.recoveryState()
        Self.logger.notice("generate: recoveryState=\(String(describing: state), privacy: .public)")
        let key: String
        switch state {
        case .disabled:
            Self.logger.notice("generate: state=.disabled — calling encryption().enableRecovery(waitForBackupsToUpload: false)")
            key = try await encryption.enableRecovery(
                waitForBackupsToUpload: false,
                passphrase: nil,
                progressListener: NoopEnableRecoveryProgressListener()
            )
            Self.logger.notice("generate: enableRecovery returned (keyLength=\(key.count, privacy: .public))")
        case .enabled, .incomplete, .unknown:
            // Element X uses the same fallthrough-to-reset for both
            // `.enabled` (recovery already set up; user is regenerating
            // a fresh key) and `.incomplete` (cross-signing exists but
            // recovery flow was interrupted partway through). `.unknown`
            // is the SDK's transient pre-listener-fire state; calling
            // resetRecoveryKey from `.unknown` is still safe — the SDK
            // serialises the call against its internal state machine.
            Self.logger.notice("generate: state != .disabled — calling encryption().resetRecoveryKey()")
            key = try await encryption.resetRecoveryKey()
            Self.logger.notice("generate: resetRecoveryKey returned (keyLength=\(key.count, privacy: .public))")
        }
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
            Self.logger.notice("generate: keychain.set OK — exit")
        } catch {
            Self.logger.error("generate: keychain.set threw: \(error.localizedDescription, privacy: .public)")
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
        Self.logger.notice("restore: enter (key length=\(key.count, privacy: .public))")
        do {
            if let sdkRecoverOverride {
                Self.logger.notice("restore: using sdkRecoverOverride (test seam)")
                try await sdkRecoverOverride(key)
            } else {
                Self.logger.notice("restore: fetching client")
                let client = try await provider.client(for: session)
                // Wave 7 bug #4 fix: switch from `recover(recoveryKey:)`
                // to `recoverAndFixBackup(recoveryKey:)`. From the SDK
                // docstring (verified at
                // `MatronShared/.build/checkouts/matrix-rust-components-swift/Sources/MatrixRustSDK/matrix_sdk_ffi.swift`
                // line 4068+):
                //
                //   "Download identity and key backup information from
                //    Recovery, and, if the key backup information is
                //    inconsistent, create a new key backup. This will
                //    create a new key backup if: key backup is enabled
                //    and the backup decryption key is missing from
                //    Recovery, or key backup is enabled and the backup
                //    decryption key does not match the public key."
                //
                // The plain `recover()` left a previously-installed
                // recovery key in a state where historical UTDs would
                // not auto-fetch their keys from the server backup —
                // the user observed "recovery key restore looks like
                // it succeeds but historical messages don't decrypt."
                // `recoverAndFixBackup` fixes the inconsistent backup
                // pointer so the SDK's UTD recovery path can find and
                // decrypt the historical room keys.
                //
                // (Element X iOS additionally configures
                // `backupDownloadStrategy(.afterDecryptionFailure)` on
                // their ClientBuilder — see
                // `ElementX/Sources/Other/Extensions/ClientBuilder.swift`
                // line 43 — which makes UTD-driven backup downloads
                // automatic. That's a separate ClientBuilder change we
                // are deliberately NOT bundling into this Wave;
                // `recoverAndFixBackup` is the more conservative half
                // and matches the spec's guidance for restore.)
                Self.logger.notice("restore: calling encryption().recoverAndFixBackup(recoveryKey:)")
                let encryption = client.encryption()
                try await encryption.recoverAndFixBackup(recoveryKey: key)
                Self.logger.notice("restore: SDK recoverAndFixBackup() returned OK — verificationState now: \(String(describing: encryption.verificationState()), privacy: .public)")
                // Block until cross-signing actually settles to
                // `.verified`. `recoverAndFixBackup` returns once
                // secret-storage is unlocked but cross-signing finalisation
                // (downloading the master/self-signing/user-signing
                // private keys, then signing this device against its
                // own master key) is async and can take several seconds
                // even on a fast network. Without this gate the caller
                // flips `verifyDone = true` immediately and the user
                // lands on a chat list with a device that other clients
                // see as "not verified by owner" + a
                // `SessionVerificationController` cached at the
                // pre-cross-sign state that no longer dispatches
                // delegate callbacks for subsequent SAS attempts.
                // 30s timeout matches `SyncServiceLive.readyTimeout` —
                // generous enough for slow homeservers, tight enough
                // that an unreachable backup surfaces a real error
                // instead of stranding the user.
                try await Self.waitForVerifiedState(
                    encryption: encryption,
                    timeout: Self.crossSigningSettleTimeout,
                    pollInterval: Self.crossSigningSettlePollInterval
                )
                Self.logger.notice("restore: cross-signing settled to .verified")
            }
        } catch let recoveryError as RecoveryError {
            Self.logger.error("restore: SDK threw RecoveryError: \(String(describing: recoveryError), privacy: .public)")
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
            // Settings. Don't throw: the meaningful work succeeded, and
            // throwing here would tell the user the restore failed when
            // it didn't. Common dev-build cause: unsigned local builds
            // have no `keychain-access-groups` entitlement loaded so
            // `SecItemAdd` returns `errSecMissingEntitlement (-34018)`.
            // Production builds with proper signing should never hit
            // this. Logged at error level so it's visible in Console.app
            // / xcrun simctl spawn ... log if it does.
            Self.logger.error("RecoveryKeyManager.restore: SDK recovery succeeded but local persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let logger = os.Logger(subsystem: "chat.matron", category: "recovery-key")

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
        /// `recoverAndFixBackup` returned successfully but the SDK's
        /// `verificationState()` never flipped to `.verified` within
        /// the cross-signing settle timeout. Surfacing this as a
        /// distinct case stops the UI from waving the user past the
        /// post-login gate into a half-trusted state — the device's
        /// own messages would render as "from a device not verified
        /// by its owner" on every other client and SAS verification
        /// flows wouldn't dispatch their delegate callbacks (the
        /// SessionVerificationController gets pinned to whatever the
        /// state was at first build, so cached-against-`.unverified`
        /// silently breaks the SAS protocol later).
        case crossSigningTimeout

        public var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "That recovery key didn't work — check for typos and try again."
            case .network:
                return "Couldn't reach the homeserver. Check your connection and try again."
            case .other(let underlying):
                return "Couldn't restore: \(underlying.localizedDescription)"
            case .crossSigningTimeout:
                return "Couldn't finalize verification on this device. Sign out and try again — if this keeps happening, your other device may need to be online."
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
