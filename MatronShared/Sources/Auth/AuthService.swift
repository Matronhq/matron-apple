import Foundation
import MatronModels

public enum AuthError: Error, Equatable {
    case invalidServerURL(ServerURLValidator.ValidationError)
    case serverUnreachable
    case ssoNotSupported
    case invalidCredentials
    case unexpected(String)
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
