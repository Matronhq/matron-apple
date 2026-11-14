import Foundation

/// One approval key of the account, as `GET /approval-keys` lists it.
public struct ApprovalKeyDTO: Equatable, Sendable, Identifiable {
    public enum EnrolledVia: String, Sendable {
        /// With the password and a two-factor code.
        case password
        /// Approved from a device that already had a key.
        case device
    }

    public let keyID: String
    public let publicKey: String
    public let name: String
    /// The client device that may sign with it; `nil` while it is attached
    /// to none (its device signed out).
    public let deviceID: Int64?
    public let enrolledVia: EnrolledVia?
    public let createdAt: Date
    public let revokedAt: Date?

    public var id: String { keyID }
    public var fingerprint: String { ApprovalKeyEncoding.fingerprint(keyID: keyID) }
    public var isLive: Bool { revokedAt == nil }

    public init(keyID: String, publicKey: String = "", name: String, deviceID: Int64?, enrolledVia: EnrolledVia? = .password,
                createdAt: Date = Date(), revokedAt: Date? = nil) {
        self.keyID = keyID; self.publicKey = publicKey; self.name = name; self.deviceID = deviceID
        self.enrolledVia = enrolledVia; self.createdAt = createdAt; self.revokedAt = revokedAt
    }

    init?(json: [String: Any]) {
        guard let keyID = json["key_id"] as? String else { return nil }
        self.init(keyID: keyID, publicKey: json["public_key"] as? String ?? "",
                  name: json["name"] as? String ?? "",
                  deviceID: (json["device_id"] as? NSNumber)?.int64Value,
                  enrolledVia: (json["enrolled_via"] as? String).flatMap(EnrolledVia.init(rawValue:)),
                  createdAt: Self.date(json["created_at"]) ?? Date(timeIntervalSince1970: 0),
                  revokedAt: Self.date(json["revoked_at"]))
    }

    static func date(_ raw: Any?) -> Date? {
        (raw as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}

/// A new device's request to have its key added, waiting (for ten
/// minutes) for a device that already has a key to approve it.
public struct ApprovalKeyRequestDTO: Equatable, Sendable, Identifiable {
    public let id: String
    public let keyID: String
    public let name: String
    public let createdAt: Date

    public var fingerprint: String { ApprovalKeyEncoding.fingerprint(keyID: keyID) }

    public init(id: String, keyID: String, name: String, createdAt: Date = Date()) {
        self.id = id; self.keyID = keyID; self.name = name; self.createdAt = createdAt
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let keyID = json["key_id"] as? String else { return nil }
        self.init(id: id, keyID: keyID, name: json["name"] as? String ?? "",
                  createdAt: ApprovalKeyDTO.date(json["created_at"]) ?? Date(timeIntervalSince1970: 0))
    }
}

/// `GET /approval-keys`.
public struct ApprovalKeysState: Equatable, Sendable {
    /// False while the journal has no public URL: keys cannot be used.
    public let enabled: Bool
    /// The host every statement must name; `nil` while not enabled.
    public let journal: String?
    /// Every key of the account, revoked ones included, oldest first.
    public let keys: [ApprovalKeyDTO]
    public let requests: [ApprovalKeyRequestDTO]

    public init(enabled: Bool, journal: String?, keys: [ApprovalKeyDTO], requests: [ApprovalKeyRequestDTO] = []) {
        self.enabled = enabled; self.journal = journal; self.keys = keys; self.requests = requests
    }

    /// The account has a key while one is not revoked, attached or not:
    /// from then on the guarded requests need a signature.
    public var hasActiveKey: Bool { keys.contains(where: \.isLive) }

    public func key(_ keyID: String) -> ApprovalKeyDTO? { keys.first { $0.keyID == keyID } }
}

/// A nonce from `POST /approvals/nonce`: good for one statement, for five
/// minutes, from the device it was issued to.
public struct ApprovalNonce: Equatable, Sendable {
    public let nonce: String
    public let expiresAt: Date

    public init(nonce: String, expiresAt: Date) { self.nonce = nonce; self.expiresAt = expiresAt }
}

/// The answers of the key routes that are not a plain HTTP failure.
public enum ApprovalKeyError: Error, Equatable, Sendable {
    /// 409 `approval_keys_disabled`: the journal has no public URL.
    case disabled
    /// 400 `bad_public_key`.
    case badPublicKey
    /// 429 `enrolment_locked`: too many wrong passwords or codes; the
    /// password-and-code path is shut until `retryAt`.
    case enrolmentLocked(retryAt: Date?)
    /// 409 `two_factor_required`: two-factor must be on to enrol a key
    /// with the password.
    case twoFactorRequired
    /// 400 `totp_required`: a recovery code was sent; only a code from the
    /// authenticator counts.
    case totpRequired
    /// 401 `bad_password`.
    case badPassword
    /// 403 `bad_code`.
    case badCode
    /// 409 `key_exists`: this key is, or was, enrolled. A removed key can
    /// never be added again: the device makes a new one.
    case keyExists
    /// 503 `two_factor_unavailable`.
    case twoFactorUnavailable
}

extension ApprovalKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .disabled: return "Approval keys are switched off on this server."
        case .badPublicKey: return "The server refused this device's key."
        case .enrolmentLocked(let retryAt):
            guard let retryAt else { return "Too many wrong passwords or codes. Try again later, or add this key from a device that already has one." }
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDateInToday(retryAt) ? .none : .medium
            formatter.timeStyle = .short
            return "Too many wrong passwords or codes. Try again after \(formatter.string(from: retryAt)), or add this key from a device that already has one."
        case .twoFactorRequired: return "Turn on two-factor authentication first: a key is set up with your password and a code."
        case .totpRequired: return "Use a code from your authenticator app. A recovery code can't set up a key."
        case .badPassword: return "That password is incorrect."
        case .badCode: return "That code is incorrect."
        case .keyExists: return "This key has already been added, or was removed. Create a new key."
        case .twoFactorUnavailable: return "Two-factor authentication is unavailable on the server right now."
        }
    }
}

/// The approval-key routes. A protocol so `ApprovalCenter`'s tests fake it.
public protocol ApprovalKeysProviding: Sendable {
    func approvalKeys() async throws -> ApprovalKeysState
    func approvalNonce() async throws -> ApprovalNonce
    /// Enrols the calling device's key with the password and a TOTP code:
    /// the first key on an account, and the way back when no enrolled
    /// device is left.
    func enrolApprovalKey(publicKey: String, name: String, password: String, code: String) async throws -> ApprovalKeyDTO
    /// Asks for the calling device's key to be added; a device that has a
    /// key approves it within ten minutes. Returns the request's id.
    func requestApprovalKey(publicKey: String, name: String) async throws -> String
    func approveApprovalKeyRequest(id: String, approval: SignedApproval) async throws -> ApprovalKeyDTO
    func revokeApprovalKey(keyID: String, approval: SignedApproval) async throws
    func revokeApprovalKey(keyID: String, password: String, code: String) async throws
    func attachApprovalKey(approval: SignedApproval) async throws -> ApprovalKeyDTO
}

extension JournalAPI: ApprovalKeysProviding {
    public func approvalKeys() async throws -> ApprovalKeysState {
        let obj = try await request(path: "/approval-keys")
        return ApprovalKeysState(
            enabled: obj["enabled"] as? Bool ?? false,
            journal: obj["journal"] as? String,
            keys: (obj["keys"] as? [[String: Any]] ?? []).compactMap(ApprovalKeyDTO.init(json:)),
            requests: (obj["requests"] as? [[String: Any]] ?? []).compactMap(ApprovalKeyRequestDTO.init(json:)))
    }

    public func approvalNonce() async throws -> ApprovalNonce {
        let obj = try await approvalKeyRequest(path: "/approvals/nonce", body: [:])
        guard let nonce = obj["nonce"] as? String, !nonce.isEmpty else {
            throw JournalAPIError.transport("malformed nonce response")
        }
        return ApprovalNonce(nonce: nonce, expiresAt: ApprovalKeyDTO.date(obj["expires_at"]) ?? Date().addingTimeInterval(300))
    }

    public func enrolApprovalKey(publicKey: String, name: String, password: String, code: String) async throws -> ApprovalKeyDTO {
        try Self.key(from: try await approvalKeyRequest(
            path: "/approval-keys",
            body: ["public_key": publicKey, "name": name, "password": password, "code": code]))
    }

    public func requestApprovalKey(publicKey: String, name: String) async throws -> String {
        let obj = try await approvalKeyRequest(path: "/approval-keys/requests", body: ["public_key": publicKey, "name": name])
        guard let id = obj["id"] as? String else { throw JournalAPIError.transport("malformed key request response") }
        return id
    }

    public func approveApprovalKeyRequest(id: String, approval: SignedApproval) async throws -> ApprovalKeyDTO {
        try Self.key(from: try await approvalKeyRequest(
            path: "/approval-keys/requests/\(Self.pathSegment(id))/approve", body: ["approval": approval.json]))
    }

    public func revokeApprovalKey(keyID: String, approval: SignedApproval) async throws {
        _ = try await approvalKeyRequest(path: "/approval-keys/\(Self.pathSegment(keyID))/revoke",
                                         body: ["approval": approval.json])
    }

    public func revokeApprovalKey(keyID: String, password: String, code: String) async throws {
        _ = try await approvalKeyRequest(path: "/approval-keys/\(Self.pathSegment(keyID))/revoke",
                                         body: ["password": password, "code": code])
    }

    public func attachApprovalKey(approval: SignedApproval) async throws -> ApprovalKeyDTO {
        try Self.key(from: try await approvalKeyRequest(path: "/approval-keys/attach", body: ["approval": approval.json]))
    }

    private static func key(from obj: [String: Any]) throws -> ApprovalKeyDTO {
        guard let key = (obj["key"] as? [String: Any]).flatMap(ApprovalKeyDTO.init(json:)) else {
            throw JournalAPIError.transport("malformed approval key response")
        }
        return key
    }

    private func approvalKeyRequest(path: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: "POST", body: body)
        let status = response.statusCode
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 || status == 201 else {
            switch (status, obj?["error"] as? String) {
            case (409, "approval_keys_disabled"): throw ApprovalKeyError.disabled
            case (400, "bad_public_key"): throw ApprovalKeyError.badPublicKey
            case (429, "enrolment_locked"):
                throw ApprovalKeyError.enrolmentLocked(retryAt: ApprovalKeyDTO.date(obj?["retry_at"]))
            case (409, "two_factor_required"): throw ApprovalKeyError.twoFactorRequired
            case (400, "totp_required"): throw ApprovalKeyError.totpRequired
            // Before the generic table, which would read any 401 as
            // "signed out".
            case (401, "bad_password"): throw ApprovalKeyError.badPassword
            case (403, "bad_code"): throw ApprovalKeyError.badCode
            case (409, "key_exists"): throw ApprovalKeyError.keyExists
            case (503, "two_factor_unavailable"): throw ApprovalKeyError.twoFactorUnavailable
            default: throw Self.error(status: status, data: data)
            }
        }
        guard let obj else { throw JournalAPIError.transport("non-JSON response for \(path)") }
        return obj
    }
}
