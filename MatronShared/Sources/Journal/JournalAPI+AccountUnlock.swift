import Foundation

/// What `POST /panic/unlock` answers when it unlocks the account.
public struct AccountUnlockResult: Equatable, Sendable {
    /// This device's new token. The old one stopped working when the
    /// account was unlocked: store this one before anything else.
    public let token: String
    /// How many other devices the unlock signed out.
    public let devicesRevoked: Int

    public init(token: String, devicesRevoked: Int) {
        self.token = token
        self.devicesRevoked = devicesRevoked
    }
}

public enum AccountUnlockError: Error, Equatable, Sendable {
    /// 409 `not_locked`: the account is not locked (any more).
    case notLocked
}

extension AccountUnlockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notLocked: return "The account is not locked."
        }
    }
}

/// What unlocking a locked account needs from the journal. The only two
/// routes a frozen device's token can call.
public protocol AccountUnlocking: Sendable {
    func approvalNonce() async throws -> ApprovalNonce
    /// Unlocks the account with a `clear_panic` statement signed by this
    /// device's key. Every other device of the account is signed out, and
    /// this one gets a new token.
    func unlockAccount(approval: SignedApproval) async throws -> AccountUnlockResult
}

extension JournalAPI: AccountUnlocking {
    public func unlockAccount(approval: SignedApproval) async throws -> AccountUnlockResult {
        let (data, response) = try await rawRequest(path: "/panic/unlock", method: "POST",
                                                    body: ["approval": approval.json])
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch (response.statusCode, obj?["error"] as? String) {
        case (200, _):
            guard let token = obj?["token"] as? String, !token.isEmpty else {
                throw JournalAPIError.transport("malformed unlock response")
            }
            return AccountUnlockResult(token: token, devicesRevoked: (obj?["devices_revoked"] as? NSNumber)?.intValue ?? 0)
        case (409, "not_locked"):
            throw AccountUnlockError.notLocked
        default:
            throw Self.error(status: response.statusCode, data: data)
        }
    }
}
