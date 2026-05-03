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

/// Tri-state result for the per-user trust check
/// (`VerificationService.isUserVerified(matrixID:)`). Tri-state distinguishes
/// "the SDK's local crypto store hasn't seen this identity yet" from "the
/// SDK has the identity and it's flagged unverified" — collapsing those
/// into a single `Bool` (the prior shape) was the M2 expert-QA bug:
/// cold-start users saw the per-bot banner flash "unverified" on every chat
/// they opened until sliding-sync warmed up the local crypto store, even
/// for already-verified bots.
///
/// Spec §7.5 trust posture: `.unknown` keeps the banner hidden — the UI
/// re-evaluates on the next sliding-sync tick rather than promoting an
/// unloaded identity to "unverified" prematurely. The banner only renders
/// for `.unverified`.
public enum UserVerificationResult: Equatable, Sendable {
    /// SDK's local crypto store has the user's identity and it's
    /// cross-signed by our master key.
    case verified
    /// SDK has the identity, but it's NOT cross-signed (or is signed by a
    /// key we don't trust). Banner renders; user is prompted to verify.
    case unverified
    /// SDK doesn't have the identity in its local crypto store yet — most
    /// likely the cold-start case where sliding-sync hasn't yet pulled
    /// the user's `/keys/query`. Banner hides; caller should re-evaluate
    /// on the next sync tick.
    case unknown
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
