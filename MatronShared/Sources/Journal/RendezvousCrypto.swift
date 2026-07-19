import CryptoKit
import Foundation

/// base64url (RFC 4648 §5), no padding — the wire encoding for the QR key
/// and the offer box. Android's `Base64.URL_SAFE | NO_WRAP | NO_PADDING`
/// and this agree byte-for-byte.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

/// End-to-end encryption for the rendezvous offer (rendezvous-offer-encryption
/// spec). The signed-out desktop generates the key and shows it in the QR; the
/// scanning phone seals `{server, code}` under it; the desktop opens locally.
/// The relay only ever holds the opaque box. AES-256-GCM, random 96-bit nonce,
/// framing `nonce(12) ‖ ciphertext ‖ tag(16)` — CryptoKit's `.combined`.
public enum RendezvousCrypto {
    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func seal(_ plaintext: Data, key: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = sealed.combined else {
            // Only nil for a non-12-byte nonce; seal() always uses 12 here.
            throw CryptoKitError.incorrectParameterSize
        }
        return combined
    }

    public static func open(_ box: Data, key: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: box)
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
    }
}
