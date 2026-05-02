import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage

public actor ClientProvider {
    private var cached: Client?
    private let basePath: URL

    public init(basePath: URL) {
        self.basePath = basePath
    }

    /// Restores or builds a fully authenticated Client for the given session.
    public func client(for session: UserSession) async throws -> Client {
        if let cached { return cached }
        let client = try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: session.homeserverURL.absoluteString)
            .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .build()
        let sdkSession = Session(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userID,
            deviceId: session.deviceID,
            homeserverUrl: session.homeserverURL.absoluteString,
            oidcData: nil,
            slidingSyncVersion: .native
        )
        try await client.restoreSession(session: sdkSession)
        cached = client
        return client
    }

    public func reset() {
        cached = nil
    }
}
