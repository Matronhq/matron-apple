import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage

public final class AuthServiceLive: AuthService, @unchecked Sendable {
    private let sessionKey = "matron.session"
    private let sessionStore: any SessionStore
    private let basePath: URL

    public init(sessionStore: any SessionStore, basePath: URL) {
        self.sessionStore = sessionStore
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
                .slidingSyncVersionBuilder(versionBuilder: .native)
                .autoEnableCrossSigning(autoEnableCrossSigning: true)
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
        // Phase 1 simplification: each fresh login starts with a clean SDK
        // store. Otherwise the SDK remembers the previous device_id and
        // rejects the new login with "account in the store doesn't match the
        // account in the constructor". Callers must scope `basePath` to a
        // directory that contains *only* the SDK's SQLite + crypto store —
        // never the persisted UserSession JSON, which lives in a sibling
        // directory owned by SessionStore. Phase 3 will reuse the existing
        // store via restoreSession when the same user re-logs in.
        try? FileManager.default.removeItem(at: basePath)
        try? FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)

        let client: Client
        do {
            // `.autoEnableCrossSigning(true)` makes the SDK upload cross-
            // signing keys (master, self-signing, user-signing) the first
            // time it sees a fresh login. Without it, the local crypto
            // store carries only an "empty cross signing identity stub"
            // and `client.getSessionVerificationController()` throws
            // `ClientError.Generic("Failed retrieving user identity")`
            // until the user manually triggers cross-signing — which
            // strands every verification flow including the matron-vs-
            // matron responder path. Mirrors Element X iOS
            // (`ElementX/Sources/Other/Extensions/ClientBuilder.swift:42`).
            // Pairs with `RecoveryKeyManager.generateAndPersist`'s
            // recoveryState branching: once cross-signing is auto-
            // bootstrapped, calling the bootstrap-shaped `enableRecovery`
            // on a non-`.disabled` state hangs, so the recovery-key path
            // calls `resetRecoveryKey` instead in that branch.
            client = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: homeserverURL.absoluteString)
                .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
                .slidingSyncVersionBuilder(versionBuilder: .native)
                .autoEnableCrossSigning(autoEnableCrossSigning: true)
                .build()
        } catch {
            throw AuthError.unexpected("ClientBuilder.build failed: \(error)")
        }
        do {
            try await client.login(
                username: username,
                password: password,
                initialDeviceName: initialDeviceDisplayName,
                deviceId: nil
            )
        } catch let clientError as ClientError {
            // Match on the typed ErrorKind rather than substring-matching the
            // description. .forbidden = M_FORBIDDEN (wrong password / no
            // permission); .userDeactivated = M_USER_DEACTIVATED (account
            // locked). Anything else propagates verbatim so the UI shows the
            // real cause instead of a generic "Invalid credentials".
            switch clientError {
            case .MatrixApi(kind: .forbidden, _, _, _),
                 .MatrixApi(kind: .userDeactivated, _, _, _):
                throw AuthError.invalidCredentials
            default:
                throw AuthError.unexpected("login failed: \(clientError)")
            }
        } catch {
            throw AuthError.unexpected("login failed: \(error)")
        }
        do {
            let session = try client.session()
            return UserSession(
                userID: session.userId,
                deviceID: session.deviceId,
                homeserverURL: homeserverURL,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken
            )
        } catch {
            throw AuthError.unexpected("session() failed after login: \(error)")
        }
    }

    public func restoreSession() async throws -> UserSession? {
        guard let json = try sessionStore.get(key: sessionKey),
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
        try sessionStore.set(json, forKey: sessionKey)
    }

    public func clearSession() throws {
        try sessionStore.delete(key: sessionKey)
    }
}
