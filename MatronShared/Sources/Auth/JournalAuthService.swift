import Foundation
import MatronJournal
import MatronModels
import MatronStorage

/// AuthService against the matron-journal server: POST /login issues a
/// long-lived device token which maps onto UserSession.accessToken.
public final class JournalAuthService: AuthService, @unchecked Sendable {
    private let sessionStore: any SessionStore
    private let urlSession: URLSession
    private let sessionKey = "matron.journal.session"

    public init(sessionStore: any SessionStore, urlSession: URLSession = .shared) {
        self.sessionStore = sessionStore
        self.urlSession = urlSession
    }

    public func probe(_ rawURL: String) async throws -> ServerCapabilities {
        let url: URL
        do {
            url = try ServerURLValidator.normalize(rawURL)
        } catch let error as ServerURLValidator.ValidationError {
            throw AuthError.invalidServerURL(error)
        }
        let api = JournalAPI(serverURL: url, urlSession: urlSession)
        do {
            _ = try await api.snapshot() // unauthenticated on purpose
            throw AuthError.serverUnreachable // a journal server must 401 here
        } catch JournalAPIError.unauthenticated {
            return ServerCapabilities(supportsPasswordLogin: true, supportsSSO: false)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.serverUnreachable
        }
    }

    public func loginPassword(
        homeserverURL: URL, username: String, password: String, initialDeviceDisplayName: String
    ) async throws -> UserSession {
        let api = JournalAPI(serverURL: homeserverURL, urlSession: urlSession)
        do {
            let login = try await api.login(username: username, password: password,
                                            deviceName: initialDeviceDisplayName)
            return UserSession(
                userID: username,
                deviceID: String(login.deviceID),
                homeserverURL: homeserverURL,
                accessToken: login.token
            )
        } catch JournalAPIError.badCredentials {
            throw AuthError.invalidCredentials
        } catch let TwoFactorAPIError.codeRequired(ticket) {
            throw AuthError.twoFactorRequired(Self.challenge(ticket, homeserverURL, username))
        } catch let TwoFactorAPIError.enrolmentRequired(ticket) {
            throw AuthError.twoFactorEnrolmentRequired(Self.challenge(ticket, homeserverURL, username))
        } catch {
            throw Self.authError(error)
        }
    }

    public func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorSignIn {
        let api = JournalAPI(serverURL: challenge.homeserverURL, urlSession: urlSession)
        do {
            let answer = try await api.loginTwoFactor(ticket: challenge.ticket, code: code)
            return TwoFactorSignIn(session: Self.session(answer.login, challenge),
                                   usedRecoveryCode: answer.usedRecoveryCode,
                                   recoveryCodesLeft: answer.recoveryCodesLeft)
        } catch {
            throw Self.authError(error)
        }
    }

    public func startTwoFactorEnrolment(_ challenge: TwoFactorChallenge) async throws -> TwoFactorSetup {
        let api = JournalAPI(serverURL: challenge.homeserverURL, urlSession: urlSession)
        do {
            return try await api.loginTwoFactorSetup(ticket: challenge.ticket)
        } catch {
            throw Self.authError(error)
        }
    }

    public func finishTwoFactorEnrolment(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorEnrolment {
        let api = JournalAPI(serverURL: challenge.homeserverURL, urlSession: urlSession)
        do {
            let answer = try await api.loginTwoFactorEnable(ticket: challenge.ticket, code: code)
            return TwoFactorEnrolment(session: Self.session(answer.login, challenge),
                                      recoveryCodes: answer.recoveryCodes)
        } catch {
            throw Self.authError(error)
        }
    }

    public func passwordResetAvailable(_ rawURL: String) async -> Bool {
        guard let url = try? ServerURLValidator.normalize(rawURL) else { return false }
        let api = JournalAPI(serverURL: url, urlSession: urlSession)
        return (try? await api.passwordResetEnabled()) ?? false
    }

    public func requestPasswordReset(homeserverURL: URL, identifier: String) async throws {
        let api = JournalAPI(serverURL: homeserverURL, urlSession: urlSession)
        do {
            try await api.requestPasswordReset(identifier: identifier)
        } catch JournalAPIError.rateLimited {
            throw AuthError.rateLimited
        } catch JournalAPIError.http(status: 503, message: _) {
            throw AuthError.unexpected("Password reset isn't available on this server right now.")
        } catch {
            throw Self.authError(error)
        }
    }

    private static func challenge(_ ticket: TwoFactorTicket, _ url: URL, _ username: String) -> TwoFactorChallenge {
        TwoFactorChallenge(homeserverURL: url, username: username,
                           ticket: ticket.ticket, expiresIn: ticket.expiresIn)
    }

    /// The same session shape `loginPassword` returns.
    private static func session(_ login: LoginResponse, _ challenge: TwoFactorChallenge) -> UserSession {
        UserSession(userID: challenge.username, deviceID: String(login.deviceID),
                    homeserverURL: challenge.homeserverURL, accessToken: login.token)
    }

    /// The errors every sign-in step shares.
    private static func authError(_ error: Error) -> Error {
        switch error {
        case let error as AuthError:
            return error
        case let TwoFactorAPIError.badCode(ticketValid):
            return AuthError.wrongTwoFactorCode(canRetry: ticketValid)
        case TwoFactorAPIError.ticketInvalid:
            return AuthError.twoFactorExpired
        case TwoFactorAPIError.unavailable:
            return AuthError.twoFactorUnavailable
        case let error as TwoFactorAPIError:
            return AuthError.unexpected(error.localizedDescription)
        case let JournalAPIError.lockedOut(retryAfterSeconds):
            return AuthError.unexpected("Too many attempts — try again in \(retryAfterSeconds)s")
        case JournalAPIError.rateLimited:
            return AuthError.unexpected("Too many attempts — try again in a minute")
        case let error as JournalAPIError:
            // `localizedDescription` (LocalizedError conformance), never
            // `String(describing:)` — the raw form leaks enum internals
            // like "http(status: 502, message: \"\")" into the sign-in form.
            return AuthError.unexpected(error.localizedDescription)
        default:
            return error
        }
    }

    public func restoreSession() throws -> UserSession? {
        guard let json = try sessionStore.get(key: sessionKey) else { return nil }
        return try? JSONDecoder().decode(UserSession.self, from: Data(json.utf8))
    }

    public func persist(_ session: UserSession) throws {
        let data = try JSONEncoder().encode(session)
        try sessionStore.set(String(decoding: data, as: UTF8.self), forKey: sessionKey)
    }

    public func clearSession() throws {
        try sessionStore.delete(key: sessionKey)
    }
}
