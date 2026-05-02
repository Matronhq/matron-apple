import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage

public final class AuthServiceLive: AuthService, @unchecked Sendable {
    private let sessionKey = "matron.session"
    private let keychain: KeychainStore
    private let basePath: URL

    public init(keychain: KeychainStore, basePath: URL) {
        self.keychain = keychain
        self.basePath = basePath
    }

    public func probe(_ rawURL: String) async throws -> ServerCapabilities {
        let url: URL
        do {
            url = try ServerURLValidator.normalize(rawURL)
        } catch let error as ServerURLValidator.ValidationError {
            throw AuthError.invalidServerURL(error)
        }

        do {
            let client = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: url.absoluteString)
                .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
                .build()
            let loginTypes = await client.homeserverLoginDetails()
            return ServerCapabilities(
                supportsPasswordLogin: loginTypes.supportsPasswordLogin(),
                supportsSSO: loginTypes.supportsSsoLogin()
            )
        } catch {
            throw AuthError.serverUnreachable
        }
    }

    public func loginPassword(
        homeserverURL: URL,
        username: String,
        password: String,
        initialDeviceDisplayName: String
    ) async throws -> UserSession {
        do {
            let client = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: homeserverURL.absoluteString)
                .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
                .build()
            try await client.login(
                username: username,
                password: password,
                initialDeviceName: initialDeviceDisplayName,
                deviceId: nil
            )
            let session = try client.session()
            return UserSession(
                userID: session.userId,
                deviceID: session.deviceId,
                homeserverURL: homeserverURL,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken
            )
        } catch {
            throw AuthError.invalidCredentials
        }
    }

    public func restoreSession() async throws -> UserSession? {
        guard let json = try keychain.get(key: sessionKey),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(UserSession.self, from: data)
    }

    public func persist(_ session: UserSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthError.unexpected("encode")
        }
        try keychain.set(json, forKey: sessionKey)
    }

    public func clearSession() throws {
        try keychain.delete(key: sessionKey)
    }
}
