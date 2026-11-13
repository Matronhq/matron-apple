import CryptoKit
import Foundation

/// Opens the sealed `box` a push carries. The journal seals with HPKE
/// (RFC 9180) in base mode: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
/// ChaCha20-Poly1305, `info` = `matron-push-v1`. The box is the 32-byte
/// encapsulated key followed by the ciphertext and tag, as unpadded
/// base64url. Neither the push relay nor Apple holds a key that opens it.
public enum PushBox {
    static let info = Data("matron-push-v1".utf8)
    static let encapsulatedKeyBytes = 32
    /// The journal never sends more than this (1536 padded bytes of JSON).
    static let maxCharacters = 2112

    /// The plaintext, or nil when the box is malformed, was sealed for
    /// another key, or has been altered.
    public static func open(_ box: String, with privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard box.count <= maxCharacters, let raw = Data(base64URLEncoded: box),
              raw.count > encapsulatedKeyBytes + 16
        else { return nil }
        do {
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: info,
                encapsulatedKey: raw.prefix(encapsulatedKeyBytes))
            return try recipient.open(raw.dropFirst(encapsulatedKeyBytes))
        } catch {
            return nil
        }
    }

    /// Opens and decodes in one step.
    public static func content(of box: String, with privateKey: Curve25519.KeyAgreement.PrivateKey) -> PushContent? {
        open(box, with: privateKey).flatMap(PushContent.init(plaintext:))
    }
}

public extension Data {
    /// Unpadded base64url, the encoding keys and boxes travel in.
    init?(base64URLEncoded string: String) {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !text.contains("=") else { return nil }
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
