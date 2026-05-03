import Foundation

/// Cryptographic trust level of a single device, as reported by the SDK.
public enum DeviceTrustLevel: Equatable, Sendable {
    case verified
    case unverified
    case blacklisted
}

/// A snapshot of a device the current user (or another user) owns.
/// `id` is the device ID; `userID` is the Matrix user ID that owns the device.
public struct DeviceInfo: Equatable, Identifiable, Sendable {
    public let id: String
    public let userID: String
    public let displayName: String?
    public let trust: DeviceTrustLevel
    public let lastSeenAt: Date?

    public init(
        id: String,
        userID: String,
        displayName: String?,
        trust: DeviceTrustLevel,
        lastSeenAt: Date?
    ) {
        self.id = id
        self.userID = userID
        self.displayName = displayName
        self.trust = trust
        self.lastSeenAt = lastSeenAt
    }
}

/// A single emoji + label in the SAS short-authentication-string set.
public struct SasEmoji: Equatable, Sendable {
    public let symbol: String
    public let description: String

    public init(symbol: String, description: String) {
        self.symbol = symbol
        self.description = description
    }
}

/// State machine for a single SAS verification flow. The `VerificationService`
/// emits these on the stream returned from `startSAS` / `acceptIncoming`.
public enum SasFlowState: Equatable, Sendable {
    case idle
    case requested
    case readyForEmoji([SasEmoji])
    case awaitingConfirmation
    case verified
    case cancelled(reason: String)
}

/// A pending verification request from another device or bot.
public struct VerificationRequestSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let otherUserID: String
    public let otherDeviceID: String?
    public let createdAt: Date

    public init(
        id: String,
        otherUserID: String,
        otherDeviceID: String?,
        createdAt: Date
    ) {
        self.id = id
        self.otherUserID = otherUserID
        self.otherDeviceID = otherDeviceID
        self.createdAt = createdAt
    }
}
