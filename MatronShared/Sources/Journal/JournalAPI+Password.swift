import Foundation

/// `POST /password`'s answer.
public struct PasswordChangeResult: Equatable, Sendable {
    /// How many of the user's OTHER client devices the journal signed out.
    /// 0 when the user kept them signed in, and from a journal predating
    /// the count. Agent boxes are never signed out.
    public let signedOut: Int

    public init(signedOut: Int) {
        self.signedOut = signedOut
    }
}

/// The answers of `/password` that are not a plain HTTP failure. Lockout
/// still arrives as `JournalAPIError.lockedOut`, the same as from `/login`
/// (wrong current passwords count against the sign-in lockout).
public enum PasswordChangeError: Error, Equatable, Sendable {
    /// 401 `bad_password`: the current password is wrong. The device's
    /// token was accepted, so this is never "signed out by the server".
    case badPassword
    /// 400 `weak_password`: the new password is under 8 characters.
    case weakPassword
}

extension PasswordChangeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badPassword: return "That password is incorrect."
        case .weakPassword: return "Use at least 8 characters."
        }
    }
}

/// `POST /password`. A protocol so the Settings form tests fake it.
public protocol PasswordChanging: Sendable {
    func changePassword(oldPassword: String, newPassword: String,
                        signOutOthers: Bool) async throws -> PasswordChangeResult
}

extension JournalAPI: PasswordChanging {
    /// `POST /password {old_password, new_password, sign_out_others}`.
    /// Client devices only (an agent gets `.forbidden`). This device stays
    /// signed in either way.
    public func changePassword(oldPassword: String, newPassword: String,
                               signOutOthers: Bool) async throws -> PasswordChangeResult {
        let body: [String: Any] = [
            "old_password": oldPassword,
            "new_password": newPassword,
            "sign_out_others": signOutOthers,
        ]
        let (data, response) = try await rawRequest(path: "/password", method: "POST", body: body)
        let status = response.statusCode
        guard status == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch (status, obj?["error"] as? String) {
            // Mapped here, before the generic table, which would read any
            // 401 as `.unauthenticated`.
            case (401, "bad_password"): throw PasswordChangeError.badPassword
            case (400, "weak_password"): throw PasswordChangeError.weakPassword
            default: throw Self.error(status: status, data: data)
            }
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return PasswordChangeResult(signedOut: (obj?["signed_out"] as? NSNumber)?.intValue ?? 0)
    }
}
