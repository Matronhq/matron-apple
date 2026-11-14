import CryptoKit
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import MatronJournal
import MatronStorage

/// Whether this device can hold an approval key, and what unlocks it.
public enum ApprovalKeyAvailability: Equatable, Sendable {
    /// A Secure Enclave and an enrolled Face ID or Touch ID. `method` is
    /// "Face ID" or "Touch ID".
    case available(method: String)
    /// No Secure Enclave, or no Face ID or Touch ID set up. `advice` says
    /// what to do instead.
    case unavailable(advice: String)

    public var method: String? {
        if case .available(let method) = self { return method }
        return nil
    }

    public var isAvailable: Bool { method != nil }
}

/// The device's key as it is kept between launches: the Secure Enclave's
/// opaque blob (usable only on this device, after a biometric check) and
/// what is needed to recognise it.
public struct StoredApprovalKey: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case secureEnclave
        /// Debug builds only: a key in memory, with no biometric check.
        case software
    }

    public var kind: Kind
    /// The Secure Enclave blob, or a software key's raw scalar.
    public var blob: Data
    /// The 65-byte uncompressed public point.
    public var publicKey: Data
    /// The device's biometric set when the key was made. A different one
    /// now means the key was destroyed with the old set.
    public var biometryState: Data?
    public var createdAt: Date

    public init(kind: Kind, blob: Data, publicKey: Data, biometryState: Data?, createdAt: Date) {
        self.kind = kind; self.blob = blob; self.publicKey = publicKey
        self.biometryState = biometryState; self.createdAt = createdAt
    }

    public var keyID: String { ApprovalKeyEncoding.keyID(publicKey: publicKey) }
}

/// Where a device keeps its approval key. One per journal account: the key
/// belongs to the account, not to a sign-in, so signing out leaves it and
/// signing in again finds it. Only "Remove" deletes it.
public struct ApprovalKeyStore: Sendable {
    private let store: any SessionStore
    private let name: String

    /// - Parameters:
    ///   - host: the journal's host, as the session's server URL has it.
    ///   - user: the account's name.
    public init(store: any SessionStore, host: String, user: String) {
        self.store = store
        self.name = "approval-key-" + ApprovalSubjects.sha256(host.lowercased() + "\n" + user).prefix(32)
    }

    /// The store the apps use: the Keychain (this device only, readable
    /// while unlocked), with a file beside the session's as the fallback
    /// for builds that cannot use the Keychain. The blob is useless off
    /// this device's Secure Enclave either way.
    public static func live(directory: URL, host: String, user: String) -> ApprovalKeyStore {
        let file = FileSessionStore(directory: directory)
        #if os(macOS)
        let dataProtection = true
        #else
        let dataProtection = false
        #endif
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let fileOnly = NSClassFromString("XCTestCase") != nil
            || !(environment["MATRON_APP_SUPPORT_OVERRIDE"] ?? "").isEmpty
            || ProcessInfo.processInfo.arguments.contains(SessionStores.fileOnlyLaunchArgument)
        if fileOnly { return ApprovalKeyStore(store: file, host: host, user: user) }
        #endif
        let keychain = KeychainStore(service: "chat.matron.approval-key", synchronizable: false,
                                     accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                     useDataProtectionKeychain: dataProtection)
        return ApprovalKeyStore(store: MigratingSessionStore(keychain: keychain, file: file), host: host, user: user)
    }

    public func load() -> StoredApprovalKey? {
        guard let text = try? store.get(key: name), let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder().decode(StoredApprovalKey.self, from: data)
    }

    public func save(_ key: StoredApprovalKey) throws {
        try store.set(try JSONEncoder().encode(key).base64EncodedString(), forKey: name)
    }

    public func delete() {
        try? store.delete(key: name)
    }
}

/// Makes and loads the device's key. A seam so the approval centre's tests
/// run without a Secure Enclave.
public protocol ApprovalKeyProviding: Sendable {
    var availability: ApprovalKeyAvailability { get }
    /// A new key, in the Secure Enclave, behind Face ID or Touch ID.
    func create() throws -> StoredApprovalKey
    /// The signing key for a stored one; throws
    /// `ApprovalKeyFailure.invalidated` when the device's biometric set
    /// changed since it was made.
    func signingKey(for stored: StoredApprovalKey) throws -> any ApprovalSigningKey
}

#if canImport(LocalAuthentication)
/// The real thing: P-256 in the Secure Enclave, with an access control of
/// "biometry, current set". There is no passcode fallback, and adding or
/// removing a fingerprint or a face destroys the key.
public struct SecureEnclaveKeyProvider: ApprovalKeyProviding {
    public init() {}

    public var availability: ApprovalKeyAvailability {
        #if os(macOS)
        let elsewhere = "Do it on your iPhone."
        #else
        let elsewhere = "Set up Face ID or Touch ID in Settings first."
        #endif
        guard SecureEnclave.isAvailable else {
            return .unavailable(advice: "This device has no secure hardware to hold an approval key. " + elsewhere)
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            #if os(macOS)
            return .unavailable(advice: "This Mac has no Touch ID, so it can't hold an approval key. " + elsewhere)
            #else
            return .unavailable(advice: "An approval key needs Face ID or Touch ID. " + elsewhere)
            #endif
        }
        switch context.biometryType {
        case .faceID: return .available(method: "Face ID")
        case .touchID: return .available(method: "Touch ID")
        case .opticID: return .available(method: "Optic ID")
        default: return .unavailable(advice: "An approval key needs Face ID or Touch ID. " + elsewhere)
        }
    }

    public func create() throws -> StoredApprovalKey {
        guard availability.isAvailable else { throw ApprovalKeyFailure.unavailable }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfError)
        else {
            throw ApprovalKeyFailure.other((cfError?.takeRetainedValue()).map { "\($0)" } ?? "Couldn't create the key.")
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
        } catch {
            throw ApprovalKeyFailure.other("Couldn't create the key: \(error.localizedDescription)")
        }
        return StoredApprovalKey(kind: .secureEnclave, blob: key.dataRepresentation,
                                 publicKey: key.publicKey.x963Representation,
                                 biometryState: Self.biometryState(), createdAt: Date())
    }

    public func signingKey(for stored: StoredApprovalKey) throws -> any ApprovalSigningKey {
        switch stored.kind {
        case .software:
            #if DEBUG
            return try SoftwareApprovalKey(rawRepresentation: stored.blob)
            #else
            // A shipped app never signs with a key that asks for no
            // biometric check.
            throw ApprovalKeyFailure.invalidated
            #endif
        case .secureEnclave:
            if let made = stored.biometryState, let now = Self.biometryState(), made != now {
                throw ApprovalKeyFailure.invalidated
            }
            return SecureEnclaveApprovalKey(blob: stored.blob, publicKey: stored.publicKey)
        }
    }

    /// The device's current biometric set, opaque; nil when biometry
    /// cannot be evaluated right now.
    static func biometryState() -> Data? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.domainState.biometry.stateHash
    }
}

/// A key in the Secure Enclave. Signing shows the system's Face ID or
/// Touch ID prompt; the private half never leaves the hardware.
public struct SecureEnclaveApprovalKey: ApprovalSigningKey {
    private let blob: Data
    public let publicKey: Data

    init(blob: Data, publicKey: Data) {
        self.blob = blob
        self.publicKey = publicKey
    }

    public func signature(for data: Data, reason: String) async throws -> Data {
        let blob = self.blob
        // The Secure Enclave call blocks while the system prompt is up.
        return try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            // No "Enter Password" button: there is no passcode fallback.
            context.localizedFallbackTitle = ""
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
                return try key.signature(for: data).derRepresentation
            } catch {
                throw Self.failure(for: error)
            }
        }.value
    }

    static func failure(for error: Error) -> ApprovalKeyFailure {
        if let failure = error as? ApprovalKeyFailure { return failure }
        let ns = error as NSError
        if ns.domain == LAError.errorDomain, let code = LAError.Code(rawValue: ns.code) {
            switch code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            case .biometryLockout:
                return .biometryFailed("Face ID or Touch ID is locked after too many tries. Unlock this device with its passcode, then approve again.")
            case .authenticationFailed, .userFallback:
                return .biometryFailed("Face ID or Touch ID did not recognise you.")
            case .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet:
                return .unavailable
            default:
                return .other(ns.localizedDescription)
            }
        }
        // Anything else from the Secure Enclave on a key that used to
        // work: the key is gone (the biometric set changed).
        if SecureEnclaveKeyProvider.biometryState() == nil { return .unavailable }
        return .invalidated
    }
}
#endif

/// Makes software keys: unit tests, the integration tests and Debug
/// screenshot runs. Never the provider of a shipped app.
public struct SoftwareKeyProvider: ApprovalKeyProviding {
    public let availability: ApprovalKeyAvailability

    public init(method: String = "Face ID") {
        availability = .available(method: method)
    }

    public init(availability: ApprovalKeyAvailability) {
        self.availability = availability
    }

    public func create() throws -> StoredApprovalKey {
        guard availability.isAvailable else { throw ApprovalKeyFailure.unavailable }
        let key = SoftwareApprovalKey()
        return StoredApprovalKey(kind: .software, blob: key.rawRepresentation, publicKey: key.publicKey,
                                 biometryState: nil, createdAt: Date())
    }

    public func signingKey(for stored: StoredApprovalKey) throws -> any ApprovalSigningKey {
        try SoftwareApprovalKey(rawRepresentation: stored.blob)
    }
}
