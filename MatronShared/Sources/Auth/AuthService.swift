import Foundation
import MatronJournal
import MatronModels

public enum AuthError: Error, Equatable {
    case invalidServerURL(ServerURLValidator.ValidationError)
    case serverUnreachable
    case ssoNotSupported
    case invalidCredentials
    /// The password was right; the user must now enter an authenticator or
    /// recovery code (`verifyTwoFactor`).
    case twoFactorRequired(TwoFactorChallenge)
    /// The password was right; the server requires two-factor and the user
    /// must set it up before signing in (`startTwoFactorEnrolment`).
    case twoFactorEnrolmentRequired(TwoFactorChallenge)
    /// The code was wrong. `canRetry` false once the challenge's tries are
    /// spent and the user must enter their password again.
    case wrongTwoFactorCode(canRetry: Bool)
    /// The challenge expired or was already used: back to the password.
    case twoFactorExpired
    /// The server can't enrol anyone in two-factor right now.
    case twoFactorUnavailable
    /// Too many requests from here (a password-reset request): the server
    /// asks the user to wait a few minutes.
    case rateLimited
    case unexpected(String)
}

/// A password sign-in waiting on its second step. The ticket is good for a
/// few minutes and a handful of codes.
public struct TwoFactorChallenge: Equatable, Sendable {
    public let homeserverURL: URL
    public let username: String
    public let ticket: String
    public let expiresIn: Int

    public init(homeserverURL: URL, username: String, ticket: String, expiresIn: Int) {
        self.homeserverURL = homeserverURL
        self.username = username
        self.ticket = ticket
        self.expiresIn = expiresIn
    }
}

/// A sign-in finished with a code.
public struct TwoFactorSignIn: Equatable, Sendable {
    public let session: UserSession
    /// The user spent a recovery code; `recoveryCodesLeft` says how many remain.
    public let usedRecoveryCode: Bool
    public let recoveryCodesLeft: Int?

    public init(session: UserSession, usedRecoveryCode: Bool = false, recoveryCodesLeft: Int? = nil) {
        self.session = session
        self.usedRecoveryCode = usedRecoveryCode
        self.recoveryCodesLeft = recoveryCodesLeft
    }
}

/// A sign-in finished by setting up two-factor: the session, and the
/// recovery codes the server shows this once.
public struct TwoFactorEnrolment: Equatable, Sendable {
    public let session: UserSession
    public let recoveryCodes: [String]

    public init(session: UserSession, recoveryCodes: [String]) {
        self.session = session
        self.recoveryCodes = recoveryCodes
    }
}

public protocol AuthService: Sendable {
    /// Probes the server URL by hitting `/_matrix/client/versions`.
    /// Returns supported login flows.
    func probe(_ rawURL: String) async throws -> ServerCapabilities

    /// Logs in with username and password. Returns a `UserSession` on success.
    func loginPassword(
        homeserverURL: URL,
        username: String,
        password: String,
        initialDeviceDisplayName: String
    ) async throws -> UserSession

    /// Restores a previously persisted session. Returns nil if none stored.
    func restoreSession() async throws -> UserSession?

    /// Persists a session to Keychain.
    func persist(_ session: UserSession) throws

    /// Clears the persisted session (sign out).
    func clearSession() throws

    /// Finishes a `.twoFactorRequired` sign-in with an authenticator code
    /// or a recovery code.
    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorSignIn

    /// Starts setting up two-factor for a `.twoFactorEnrolmentRequired`
    /// sign-in: a new secret for the authenticator app.
    func startTwoFactorEnrolment(_ challenge: TwoFactorChallenge) async throws -> TwoFactorSetup

    /// Confirms the authenticator with its first code, finishing the sign-in.
    func finishTwoFactorEnrolment(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorEnrolment

    /// Whether the journal at `rawURL` mails password-reset links
    /// (`GET /password/forgot`). False for an address that isn't a server,
    /// a journal predating the route, or no answer.
    func passwordResetAvailable(_ rawURL: String) async -> Bool

    /// Asks the journal to mail a reset link to the account named by
    /// `identifier` (a username or an email address). Succeeds the same
    /// way whether or not the account exists.
    func requestPasswordReset(homeserverURL: URL, identifier: String) async throws
}

/// Services that cannot do two-factor or password reset (test fakes,
/// mostly) fail the step instead of having to implement it.
public extension AuthService {
    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorSignIn {
        throw AuthError.twoFactorUnavailable
    }

    func startTwoFactorEnrolment(_ challenge: TwoFactorChallenge) async throws -> TwoFactorSetup {
        throw AuthError.twoFactorUnavailable
    }

    func finishTwoFactorEnrolment(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorEnrolment {
        throw AuthError.twoFactorUnavailable
    }

    func passwordResetAvailable(_ rawURL: String) async -> Bool { false }

    func requestPasswordReset(homeserverURL: URL, identifier: String) async throws {
        throw AuthError.unexpected("Password reset isn't available.")
    }
}

public struct ServerCapabilities: Equatable, Sendable {
    public let supportsPasswordLogin: Bool
    public let supportsSSO: Bool

    public init(supportsPasswordLogin: Bool, supportsSSO: Bool) {
        self.supportsPasswordLogin = supportsPasswordLogin
        self.supportsSSO = supportsSSO
    }
}

// SSO redirect handling (constructing the IDP redirect URL,
// presenting it via ASWebAuthenticationSession, handling the callback) is
// deferred to a future spec — Phase 1 only surfaces whether the server advertises
// SSO so the SignInView can show/hide the (currently disabled) button.
