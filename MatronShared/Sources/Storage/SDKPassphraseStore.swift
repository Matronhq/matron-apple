import Foundation

/// Per-userID passphrase used to encrypt the matrix-rust-sdk's
/// SQLite stores at rest via SQLCipher (`SqliteStoreBuilder.passphrase`).
///
/// Without this, the SDK's `dataPath`/`cachePath` are plaintext SQLite
/// — every received event (decrypted megolm content cached for fast
/// renders, room state, member info, account data) sits on disk in
/// the clear, protected only by iOS/Mac filesystem encryption (i.e.
/// the device unlock gate). Adding a passphrase swaps the SQLite
/// driver for SQLCipher, so a forensic dump of an unlocked device
/// produces ciphertext instead of plaintext. Standard E2EE-client
/// posture (Element X iOS, Signal, iMessage all do equivalent).
///
/// The passphrase itself is a 256-bit random value, hex-encoded, kept
/// device-local in the Keychain (`synchronizable: false`). One
/// passphrase per `userID`; sign-out deletes it. iCloud Keychain
/// sync is deliberately off — each device's SDK store is its own
/// container, independent of other devices the same user is signed
/// into.
public struct SDKPassphraseStore: Sendable {
    private let keychain: KeychainStore
    /// 32 bytes (256 bits) hex-encoded → 64 ASCII chars. SQLCipher
    /// derives its key from the passphrase via PBKDF2; passphrase
    /// length doesn't bound the key strength but matching the AES
    /// key size keeps the brute-force frontier at the cipher
    /// rather than at the passphrase.
    public static let passphraseByteCount: Int = 32

    public init(keychain: KeychainStore = .sdkPassphraseStore()) {
        self.keychain = keychain
    }

    /// Generates a fresh random hex-encoded passphrase. Caller is
    /// responsible for storing it BEFORE handing it to the SDK — if
    /// we hand a passphrase to SQLCipher and then fail to persist
    /// it, the store becomes unreadable on the next launch.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: passphraseByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func store(passphrase: String, for userID: String) throws {
        try keychain.set(passphrase, forKey: userID)
    }

    public func retrieve(for userID: String) throws -> String? {
        try keychain.get(key: userID)
    }

    public func delete(for userID: String) throws {
        try keychain.delete(key: userID)
    }
}

public extension KeychainStore {
    /// Factory for the SDK-passphrase Keychain partition. Service
    /// scopes the stored items to a separate row from the recovery-
    /// key store (`chat.matron.recovery`). `synchronizable: false`
    /// because each device's local SQLCipher store is independent —
    /// a passphrase that landed on another device via iCloud
    /// Keychain wouldn't be useful there (different `dataPath`,
    /// different DB) and would be one more secret to manage.
    static func sdkPassphraseStore() -> KeychainStore {
        return KeychainStore(
            service: "chat.matron.sdk-passphrase",
            synchronizable: false
        )
    }
}
