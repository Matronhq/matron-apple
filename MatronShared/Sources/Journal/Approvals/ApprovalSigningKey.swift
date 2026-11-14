import CryptoKit
import Foundation

/// A device's approval key: a P-256 key whose private half signs
/// statements. The apps hold it in the Secure Enclave, behind Face ID or
/// Touch ID (`SecureEnclaveApprovalKey`); `SoftwareApprovalKey` is for
/// tests and Debug runs only.
public protocol ApprovalSigningKey: Sendable {
    /// The 65-byte uncompressed point, `0x04 ‖ X ‖ Y`.
    var publicKey: Data { get }
    /// The ASN.1 DER ECDSA signature over SHA-256 of `data`. `reason` is
    /// what the system's biometric prompt says. Throws
    /// `ApprovalKeyFailure.cancelled` when the user backs out.
    func signature(for data: Data, reason: String) async throws -> Data
}

public extension ApprovalSigningKey {
    var keyID: String { ApprovalKeyEncoding.keyID(publicKey: publicKey) }
    var fingerprint: String { ApprovalKeyEncoding.fingerprint(keyID: keyID) }
    /// `public_key` as the journal takes it.
    var publicKeyBase64URL: String { ApprovalKeyEncoding.base64URL(publicKey) }
}

/// Why a device's key could not sign.
public enum ApprovalKeyFailure: Error, Equatable, Sendable {
    /// The user cancelled the Face ID or Touch ID prompt.
    case cancelled
    /// Face ID or Touch ID did not recognise the user, or is locked out
    /// until the device is unlocked with its passcode.
    case biometryFailed(String)
    /// The key no longer works: the device's fingerprints or face changed
    /// since it was made, which destroys it by design.
    case invalidated
    /// This device cannot hold an approval key (no Secure Enclave, or no
    /// Face ID or Touch ID set up).
    case unavailable
    case other(String)
}

extension ApprovalKeyFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled."
        case .biometryFailed(let detail):
            return detail.isEmpty ? "Face ID or Touch ID did not recognise you." : detail
        case .invalidated:
            return "This device's approval key no longer works because its Face ID or Touch ID set-up changed. Set up a new key."
        case .unavailable:
            return "This device can't hold an approval key."
        case .other(let detail): return detail
        }
    }
}

/// A P-256 key held in memory. For tests, the integration tests and Debug
/// screenshot runs: it asks for no biometric check, so it must never be
/// what a shipped app enrols.
public struct SoftwareApprovalKey: ApprovalSigningKey {
    private let key: P256.Signing.PrivateKey

    public init() { key = P256.Signing.PrivateKey() }

    public init(pem: String) throws { key = try P256.Signing.PrivateKey(pemRepresentation: pem) }

    public init(rawRepresentation: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) }

    public var rawRepresentation: Data { key.rawRepresentation }

    public var publicKey: Data { key.publicKey.x963Representation }

    public func signature(for data: Data, reason: String) async throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}
