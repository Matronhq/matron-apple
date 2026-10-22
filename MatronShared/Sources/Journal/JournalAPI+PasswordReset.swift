import Foundation

/// `GET /account/email`: the address a password-reset link goes to.
public struct AccountEmail: Equatable, Sendable {
    /// nil when the user has none on file.
    public let email: String?
    /// Whether the journal can send reset links at all (mail is set up).
    public let resetByEmail: Bool

    public init(email: String?, resetByEmail: Bool) {
        self.email = email
        self.resetByEmail = resetByEmail
    }
}

/// The answers of `PUT /account/email` that are not a plain HTTP failure.
/// Lockout still arrives as `JournalAPIError.lockedOut` (wrong passwords
/// count against the sign-in lockout).
public enum AccountEmailError: Error, Equatable, Sendable {
    /// 401 `bad_password`: the current password is wrong. The device's
    /// token was accepted, so this is never "signed out by the server".
    case badPassword
    /// 400 `bad_email`.
    case badEmail
    /// 409 `email_taken`: another account on the journal has it.
    case emailTaken
}

extension AccountEmailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badPassword: return "That password is incorrect."
        case .badEmail: return "Enter a valid email address."
        case .emailTaken: return "Another account already uses that address."
        }
    }
}

/// `GET`/`PUT /account/email`. A protocol so the Settings row tests fake it.
public protocol AccountEmailProviding: Sendable {
    func accountEmail() async throws -> AccountEmail
    /// Sets (or, with nil, removes) the address; returns it as stored.
    func setAccountEmail(password: String, email: String?) async throws -> String?
}

extension JournalAPI: AccountEmailProviding {
    /// `GET /password/forgot` (no auth): whether this journal mails reset
    /// links. A journal predating the route (404) does not.
    public func passwordResetEnabled() async throws -> Bool {
        do {
            let obj = try await request(path: "/password/forgot", authenticated: false)
            return obj["enabled"] as? Bool ?? false
        } catch JournalAPIError.notFound {
            return false
        }
    }

    /// `POST /password/forgot {identifier}` (no auth). Always 200 when the
    /// journal took it, whether or not the account exists or has an
    /// address. 429 arrives as `.rateLimited`.
    public func requestPasswordReset(identifier: String) async throws {
        _ = try await request(path: "/password/forgot", method: "POST",
                              body: ["identifier": identifier], authenticated: false)
    }

    /// `GET /account/email`. 404 (`.notFound`) on a journal predating it.
    public func accountEmail() async throws -> AccountEmail {
        let obj = try await request(path: "/account/email")
        return AccountEmail(email: Self.nonEmptyEmail(obj["email"]),
                            resetByEmail: obj["reset_by_email"] as? Bool ?? false)
    }

    /// `PUT /account/email {password, email}`; `email` nil removes it.
    public func setAccountEmail(password: String, email: String?) async throws -> String? {
        let body: [String: Any] = ["password": password, "email": email ?? NSNull()]
        let (data, response) = try await rawRequest(path: "/account/email", method: "PUT", body: body)
        let status = response.statusCode
        guard status == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch (status, obj?["error"] as? String) {
            // Mapped here, before the generic table, which would read any
            // 401 as `.unauthenticated`.
            case (401, "bad_password"): throw AccountEmailError.badPassword
            case (400, "bad_email"): throw AccountEmailError.badEmail
            case (409, "email_taken"): throw AccountEmailError.emailTaken
            default: throw Self.error(status: status, data: data)
            }
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Self.nonEmptyEmail(obj?["email"])
    }

    private static func nonEmptyEmail(_ raw: Any?) -> String? {
        guard let email = raw as? String, !email.isEmpty else { return nil }
        return email
    }
}
