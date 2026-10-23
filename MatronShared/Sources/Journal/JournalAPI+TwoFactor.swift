import Foundation

/// The short-lived ticket `POST /login` hands back, instead of a token,
/// when a password sign-in needs a second step (protocol "Two-factor
/// sign-in"). It lives on the journal for `expiresIn` seconds.
public struct TwoFactorTicket: Equatable, Sendable {
    public let ticket: String
    public let expiresIn: Int

    public init(ticket: String, expiresIn: Int) {
        self.ticket = ticket
        self.expiresIn = expiresIn
    }
}

/// The answers of the two-factor routes that are not a plain HTTP failure.
/// Lockout and rate limiting still arrive as `JournalAPIError.lockedOut` /
/// `.rateLimited`, the same as from `/login`.
public enum TwoFactorAPIError: Error, Equatable, Sendable {
    /// 401 from `/login`: the password was right and the user has two-factor
    /// on. Send a code to `/login/2fa` with this ticket.
    case codeRequired(TwoFactorTicket)
    /// 401 from `/login`: the journal requires two-factor and this user has
    /// not set it up. Enrol through `/login/2fa/setup` and `/enable`.
    case enrolmentRequired(TwoFactorTicket)
    /// 403 `bad_code`. `ticketValid` false once the ticket's tries are spent.
    case badCode(ticketValid: Bool)
    /// 401 `two_factor_ticket_invalid`: unknown, expired or already used.
    case ticketInvalid
    /// 503 `two_factor_unavailable`: the journal cannot enrol anyone.
    case unavailable
}

extension TwoFactorAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .codeRequired: return "Enter the code from your authenticator app."
        case .enrolmentRequired: return "This server requires two-factor sign-in."
        case .badCode: return "Wrong code."
        case .ticketInvalid: return "This sign-in has expired. Enter your password again."
        case .unavailable: return "Two-factor sign-in isn't available on this server."
        }
    }
}

/// `POST /login/2fa`'s answer.
public struct TwoFactorLoginResponse: Equatable, Sendable {
    public let login: LoginResponse
    public let usedRecoveryCode: Bool
    public let recoveryCodesLeft: Int?
}

/// A new authenticator secret: `POST /login/2fa/setup` (and `/2fa/setup`).
public struct TwoFactorSetup: Equatable, Sendable {
    /// Base32, for typing into an authenticator by hand.
    public let secret: String
    /// `otpauth://totp/…`, for the QR code and "Open in authenticator".
    public let otpauthURI: String
    public let issuer: String
    public let account: String

    public init(secret: String, otpauthURI: String, issuer: String, account: String) {
        self.secret = secret
        self.otpauthURI = otpauthURI
        self.issuer = issuer
        self.account = account
    }
}

/// `POST /login/2fa/enable`'s answer: a token, and the recovery codes the
/// user sees this once.
public struct TwoFactorEnableResponse: Equatable, Sendable {
    public let login: LoginResponse
    public let recoveryCodes: [String]
}

/// `GET /2fa`: the signed-in user's two-factor state.
public struct TwoFactorStatus: Equatable, Sendable {
    public let enabled: Bool
    /// Epoch ms, when known.
    public let enabledAt: Int64?
    public let recoveryCodesLeft: Int?
    /// The journal requires two-factor for everyone.
    public let required: Bool
    /// The journal can enrol (its token key is set).
    public let available: Bool

    public init(enabled: Bool, enabledAt: Int64? = nil, recoveryCodesLeft: Int? = nil,
                required: Bool = false, available: Bool = true) {
        self.enabled = enabled
        self.enabledAt = enabledAt
        self.recoveryCodesLeft = recoveryCodesLeft
        self.required = required
        self.available = available
    }
}

/// `GET /2fa`. A protocol so the Settings section tests fake it.
public protocol TwoFactorStatusProviding: Sendable {
    func twoFactorStatus() async throws -> TwoFactorStatus
}

extension JournalAPI: TwoFactorStatusProviding {
    /// `POST /login/2fa {ticket, code}` → a token, stored exactly as
    /// `/login`'s. Unauthenticated: the ticket is the credential.
    public func loginTwoFactor(ticket: String, code: String) async throws -> TwoFactorLoginResponse {
        let obj = try await twoFactorRequest(path: "/login/2fa", body: ["ticket": ticket, "code": code])
        let login = try Self.loginResponse(from: obj)
        setToken(login.token)
        return TwoFactorLoginResponse(
            login: login,
            usedRecoveryCode: obj["used_recovery_code"] as? Bool ?? false,
            recoveryCodesLeft: (obj["recovery_codes_left"] as? NSNumber)?.intValue)
    }

    /// `POST /login/2fa/setup {ticket}` — enrolment at sign-in.
    public func loginTwoFactorSetup(ticket: String) async throws -> TwoFactorSetup {
        try Self.setup(from: try await twoFactorRequest(path: "/login/2fa/setup", body: ["ticket": ticket]))
    }

    /// `POST /login/2fa/enable {ticket, code}` → a token and recovery codes.
    public func loginTwoFactorEnable(ticket: String, code: String) async throws -> TwoFactorEnableResponse {
        let obj = try await twoFactorRequest(path: "/login/2fa/enable", body: ["ticket": ticket, "code": code])
        let login = try Self.loginResponse(from: obj)
        setToken(login.token)
        return TwoFactorEnableResponse(login: login, recoveryCodes: obj["recovery_codes"] as? [String] ?? [])
    }

    public func twoFactorStatus() async throws -> TwoFactorStatus {
        let obj = try await request(path: "/2fa")
        return TwoFactorStatus(
            enabled: obj["enabled"] as? Bool ?? false,
            enabledAt: (obj["enabled_at"] as? NSNumber)?.int64Value,
            recoveryCodesLeft: (obj["recovery_codes_left"] as? NSNumber)?.intValue,
            required: obj["required"] as? Bool ?? false,
            available: obj["available"] as? Bool ?? true)
    }

    // MARK: Internals

    static func loginResponse(from obj: [String: Any]) throws -> LoginResponse {
        guard let token = obj["token"] as? String,
              let deviceID = (obj["device_id"] as? NSNumber)?.int64Value,
              let userID = (obj["user_id"] as? NSNumber)?.int64Value
        else { throw JournalAPIError.transport("malformed login response") }
        return LoginResponse(token: token, deviceID: deviceID, userID: userID)
    }

    /// The two-factor answers `/login` can give instead of a token, or nil.
    static func twoFactorChallenge(status: Int, data: Data) -> TwoFactorAPIError? {
        guard status == 401,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ticket = obj["two_factor_ticket"] as? String
        else { return nil }
        let challenge = TwoFactorTicket(ticket: ticket,
                                        expiresIn: (obj["expires_in"] as? NSNumber)?.intValue ?? 300)
        switch obj["error"] as? String {
        case "two_factor_required": return .codeRequired(challenge)
        case "two_factor_enrolment_required": return .enrolmentRequired(challenge)
        default: return nil
        }
    }

    /// An unauthenticated POST to one of the `/login/2fa` routes, mapping
    /// their own error codes before the generic ones.
    private func twoFactorRequest(path: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: "POST", body: body, authenticated: false)
        let status = response.statusCode
        guard status == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch (status, obj?["error"] as? String) {
            case (403, "bad_code"):
                throw TwoFactorAPIError.badCode(ticketValid: obj?["ticket_valid"] as? Bool ?? true)
            case (401, "two_factor_ticket_invalid"): throw TwoFactorAPIError.ticketInvalid
            case (503, _): throw TwoFactorAPIError.unavailable
            default: throw Self.error(status: status, data: data)
            }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JournalAPIError.transport("non-JSON response for \(path)")
        }
        return obj
    }
}

// MARK: Settings → Security

/// The answers of the authenticated `/2fa` routes that are not a plain HTTP
/// failure. Lockout and rate limiting still arrive as
/// `JournalAPIError.lockedOut` / `.rateLimited`.
public enum TwoFactorSettingsError: Error, Equatable, Sendable {
    /// 401 `bad_password`. The device's token is fine; only the password
    /// typed to confirm the change was wrong.
    case badPassword
    /// 403 `bad_code`.
    case badCode
    /// 409 `no_pending_setup`: the setup expired (15 minutes) or was never
    /// started. Start again from the password.
    case noPendingSetup
    /// 409 `not_enabled`: two-factor was turned off meanwhile.
    case notEnabled
    /// 409 `two_factor_required`: the server requires it, so it stays on.
    case requiredByServer
    /// 503 `two_factor_unavailable`.
    case unavailable
}

extension TwoFactorSettingsError: LocalizedError {
    /// Matron Web's sentences for the same codes.
    public var errorDescription: String? {
        switch self {
        case .badPassword: return "That password is incorrect."
        case .badCode: return "That code didn't work. Check your authenticator app and try again."
        case .noPendingSetup: return "That setup expired. Start again."
        case .notEnabled: return "Two-factor sign-in is already off."
        case .requiredByServer: return "This server requires two-factor sign-in, so it can't be turned off."
        case .unavailable: return "This server isn't set up for two-factor sign-in."
        }
    }
}

/// `POST /2fa/enable`'s answer.
public struct TwoFactorEnableResult: Equatable, Sendable {
    /// Shown this once.
    public let recoveryCodes: [String]
    /// How many of the user's other apps and browsers were signed out.
    public let signedOut: Int

    public init(recoveryCodes: [String], signedOut: Int) {
        self.recoveryCodes = recoveryCodes
        self.signedOut = signedOut
    }
}

/// Settings → Security's routes. A protocol so the settings tests fake it.
public protocol TwoFactorSettingsProviding: TwoFactorStatusProviding {
    /// `POST /2fa/setup`. `code` (from the current app, or a recovery code)
    /// only when two-factor is already on and the user is moving to a new
    /// app; the current app keeps working until the new one is confirmed.
    func beginTwoFactorSetup(password: String, code: String?) async throws -> TwoFactorSetup
    /// `POST /2fa/enable`: confirms the pending setup with its first code.
    func enableTwoFactor(code: String, signOutOthers: Bool) async throws -> TwoFactorEnableResult
    /// `POST /2fa/recovery-codes`: a new set replaces the old.
    func newTwoFactorRecoveryCodes(password: String, code: String) async throws -> [String]
    /// `POST /2fa/disable`.
    func disableTwoFactor(password: String, code: String) async throws
}

extension JournalAPI: TwoFactorSettingsProviding {
    public func beginTwoFactorSetup(password: String, code: String?) async throws -> TwoFactorSetup {
        var body: [String: Any] = ["password": password]
        if let code { body["code"] = code }
        let obj = try await twoFactorSettingsRequest(path: "/2fa/setup", body: body)
        return try Self.setup(from: obj)
    }

    public func enableTwoFactor(code: String, signOutOthers: Bool) async throws -> TwoFactorEnableResult {
        let obj = try await twoFactorSettingsRequest(path: "/2fa/enable",
                                                     body: ["code": code, "sign_out_others": signOutOthers])
        return TwoFactorEnableResult(recoveryCodes: try Self.recoveryCodes(from: obj),
                                     signedOut: (obj["signed_out"] as? NSNumber)?.intValue ?? 0)
    }

    public func newTwoFactorRecoveryCodes(password: String, code: String) async throws -> [String] {
        let obj = try await twoFactorSettingsRequest(path: "/2fa/recovery-codes",
                                                     body: ["password": password, "code": code])
        return try Self.recoveryCodes(from: obj)
    }

    public func disableTwoFactor(password: String, code: String) async throws {
        _ = try await twoFactorSettingsRequest(path: "/2fa/disable", body: ["password": password, "code": code])
    }

    /// The codes are shown only once, so a reply without them is an error,
    /// never an empty list.
    static func recoveryCodes(from obj: [String: Any]) throws -> [String] {
        guard let codes = obj["recovery_codes"] as? [String], !codes.isEmpty else {
            throw JournalAPIError.transport("malformed two-factor recovery codes response")
        }
        return codes
    }

    static func setup(from obj: [String: Any]) throws -> TwoFactorSetup {
        guard let secret = obj["secret"] as? String, let uri = obj["otpauth_uri"] as? String else {
            throw JournalAPIError.transport("malformed two-factor setup response")
        }
        return TwoFactorSetup(secret: secret, otpauthURI: uri,
                              issuer: obj["issuer"] as? String ?? "Matron",
                              account: obj["account"] as? String ?? "")
    }

    /// An authenticated POST to one of the `/2fa` settings routes, mapping
    /// their own error codes before the generic ones.
    private func twoFactorSettingsRequest(path: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: "POST", body: body)
        let status = response.statusCode
        guard status == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch (status, obj?["error"] as? String) {
            case (401, "bad_password"): throw TwoFactorSettingsError.badPassword
            case (403, "bad_code"): throw TwoFactorSettingsError.badCode
            case (409, "no_pending_setup"): throw TwoFactorSettingsError.noPendingSetup
            case (409, "not_enabled"): throw TwoFactorSettingsError.notEnabled
            case (409, "two_factor_required"): throw TwoFactorSettingsError.requiredByServer
            case (503, "two_factor_unavailable"): throw TwoFactorSettingsError.unavailable
            default: throw Self.error(status: status, data: data)
            }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JournalAPIError.transport("non-JSON response for \(path)")
        }
        return obj
    }
}
