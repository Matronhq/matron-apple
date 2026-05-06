import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage

public actor ClientProvider {
    private var cached: Client?
    private let basePath: URL
    private let passphraseStore: SDKPassphraseStore

    public init(
        basePath: URL,
        passphraseStore: SDKPassphraseStore = SDKPassphraseStore()
    ) {
        self.basePath = basePath
        self.passphraseStore = passphraseStore
    }

    /// Restores or builds a fully authenticated Client for the given session.
    public func client(for session: UserSession) async throws -> Client {
        if let cached { return cached }
        // SQLCipher passphrase recovered from Keychain (set by
        // `AuthServiceLive.loginPassword` on the original sign-in).
        // Missing for sessions that pre-date the SQLCipher rollout —
        // those keep working in plaintext-SQLite mode until the user
        // signs out + back in. Going forward every fresh login
        // produces an encrypted store; this branch is a one-shot
        // upgrade-path concession, not a permanent fallback.
        let storedPassphrase = try? passphraseStore.retrieve(for: session.userID)
        let storeConfig = SqliteStoreBuilder(
            dataPath: basePath.path,
            cachePath: basePath.path
        ).passphrase(passphrase: storedPassphrase)
        // `.autoEnableCrossSigning(true)` must be set on every
        // ClientBuilder — the flag affects how the rust-side
        // identity-handling subsystem treats the local crypto store
        // when an existing session is resumed. Without it the resumed
        // client sees only the "empty cross signing identity stub" and
        // `getSessionVerificationController()` throws "Failed retrieving
        // user identity" indefinitely. See AuthServiceLive's
        // `loginPassword` for the full rationale.
        let client = try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: session.homeserverURL.absoluteString)
            .sqliteStore(config: storeConfig)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            // Auto-fetch the missing megolm session from the server-side
            // key backup whenever an event fails to decrypt. Without
            // this, historical messages on this device stay as
            // [unsupported event: m.room.encrypted] forever — the SDK
            // has the backup decryption key (received via secret
            // gossiping after SAS verification or via recovery key
            // restore), but won't *use* it to recover individual events
            // unless the strategy is set. Mirrors Element X iOS
            // (`ElementX/Sources/Other/Extensions/ClientBuilder.swift`).
            // Pairs with `RecoveryKeyManager.restore()` calling
            // `recoverAndFixBackup` — that step makes the backup
            // decryption key *available* on this device; this builder
            // step makes the SDK *use* it on demand.
            .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
            .build()
        let sdkSession = Session(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userID,
            deviceId: session.deviceID,
            homeserverUrl: session.homeserverURL.absoluteString,
            oidcData: nil,
            slidingSyncVersion: .native
        )
        try await client.restoreSession(session: sdkSession)
        cached = client
        return client
    }

    public func reset() {
        cached = nil
    }
}
