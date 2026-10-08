import Foundation

public struct UserSession: Equatable, Codable, Sendable {
    public let userID: String
    public let deviceID: String
    public let homeserverURL: URL
    public let accessToken: String
    public let refreshToken: String?

    public init(
        userID: String,
        deviceID: String,
        homeserverURL: URL,
        accessToken: String,
        refreshToken: String? = nil
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.homeserverURL = homeserverURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

public extension UserSession {
    /// Per-user `UserDefaults` key for the persisted "this user has
    /// completed the post-login verification gate" flag (spec §5.2).
    /// Scoped by `userID` so multi-account on the same device re-runs
    /// the gate per account. Lives here so iOS and Mac can't drift on
    /// the key shape — a silent mismatch would leave gated users
    /// staring at the verify gate forever.
    var verifyDoneKey: String {
        "matron.verify-done.\(userID)"
    }
}
