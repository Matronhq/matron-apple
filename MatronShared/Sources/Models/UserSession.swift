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
