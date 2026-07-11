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
        } catch let JournalAPIError.lockedOut(retryAfterSeconds) {
            throw AuthError.unexpected("Too many attempts — try again in \(retryAfterSeconds)s")
        } catch JournalAPIError.rateLimited {
            throw AuthError.unexpected("Too many attempts — try again in a minute")
        } catch let error as JournalAPIError {
            throw AuthError.unexpected(String(describing: error))
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
