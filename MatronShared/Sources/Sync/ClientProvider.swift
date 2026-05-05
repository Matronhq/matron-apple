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
        // `.autoEnableCrossSigning(true)` must be set on every
        // ClientBuilder — the flag affects how the rust-side
        // identity-handling subsystem treats the local crypto store
        // when an existing session is resumed. Without it the resumed
        // client sees only the "empty cross signing identity stub" and
        // `getSessionVerificationController()` throws "Failed retrieving
        // user identity" indefinitely. See AuthServiceLive's
        // `loginPassword` for the full rationale.
        let client = try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: session.homeserverURL.absoluteString)
            .sessionPaths(dataPath: basePath.path, cachePath: basePath.path)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
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
