import CryptoKit
import Foundation
import MatronStorage
import Security

/// This device's key for sealed notification content. The app makes it and
/// registers the public half with the journal; the notification extension
/// reads the private half to open what arrives.
///
/// The key is a Keychain item in the app's default access group, which the
/// extension shares. It stays on this device (never iCloud Keychain, never a
/// backup restored elsewhere) and is readable once the device has been
/// unlocked after a restart, because a notification has to be opened while
/// the device is locked.
public struct PushKeyStore: Sendable {
    private let store: any SessionStore
    private static let account = "notification-content-key"

    public init(store: any SessionStore) {
        self.store = store
    }

    public static func live() -> PushKeyStore {
        PushKeyStore(store: KeychainStore(
            service: "chat.matron.push",
            synchronizable: false,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
    }

    /// The key, if this device has one.
    public func privateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        guard let text = try? store.get(key: Self.account), let raw = Data(base64URLEncoded: text) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    /// The public half to register, making the key first if there is none.
    /// Nil when the Keychain cannot hold it: the device then registers
    /// without a key and its notifications keep their fixed text.
    public func publicKeyForRegistration() -> String? {
        if let existing = privateKey() { return existing.publicKey.rawRepresentation.base64URLEncodedString() }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        do {
            try store.set(fresh.rawRepresentation.base64URLEncodedString(), forKey: Self.account)
        } catch {
            return nil
        }
        // Read back: what gets registered must be what the extension will find.
        return privateKey()?.publicKey.rawRepresentation.base64URLEncodedString()
    }

    /// Sign-out: the next session registers a new key.
    public func delete() {
        try? store.delete(key: Self.account)
    }
}
