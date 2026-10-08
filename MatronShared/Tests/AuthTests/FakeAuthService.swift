import Foundation
import MatronModels
@testable import MatronAuth

final class FakeAuthService: AuthService, @unchecked Sendable {
    var stubbedProbe: Result<ServerCapabilities, Error> = .failure(AuthError.unexpected("not stubbed"))
    var stubbedLogin: Result<UserSession, Error> = .failure(AuthError.unexpected("not stubbed"))
    var stubbedRestore: Result<UserSession?, Error> = .success(nil)
    var persistedSessions: [UserSession] = []
    var clearCallCount = 0

    func probe(_ rawURL: String) async throws -> ServerCapabilities {
        try stubbedProbe.get()
    }

    func loginPassword(
        homeserverURL: URL,
        username: String,
        password: String,
        initialDeviceDisplayName: String
    ) async throws -> UserSession {
        try stubbedLogin.get()
    }

    func restoreSession() async throws -> UserSession? {
        try stubbedRestore.get()
    }

    func persist(_ session: UserSession) throws {
        persistedSessions.append(session)
    }

    func clearSession() throws {
        clearCallCount += 1
    }
}
