import Foundation

public struct BotIdentity: Equatable, Hashable, Sendable {
    public let matrixID: String
    public let displayName: String
    public let avatarURL: URL?

    public init(matrixID: String, displayName: String, avatarURL: URL?) {
        self.matrixID = matrixID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
