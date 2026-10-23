import XCTest
import MatronModels
@testable import MatronJournal

final class PasswordResetAPITests: XCTestCase {
    private func makeStubbedAPI(status: Int, body: [String: Any], token: String? = "t",
                                authResponses: (@Sendable (Int) -> Void)? = nil) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: token,
                          authResponses: authResponses)
    }

    private var lastBodyJSON: [String: Any]? {
        ItemsStubURLProtocol.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func setEmailError(status: Int, body: [String: Any]) async -> Error? {
        let api = makeStubbedAPI(status: status, body: body)
        do {
            _ = try await api.setAccountEmail(password: "secret-pw", email: "alice@example.com")
            XCTFail("expected a throw")
            return nil
        } catch {
            return error
        }
    }

    // MARK: Forgot password

    func testForgotEnabledReadsTheFlag_withoutAToken() async throws {
        let api = makeStubbedAPI(status: 200, body: ["enabled": true])
        let enabled = try await api.passwordResetEnabled()
        XCTAssertTrue(enabled)
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/password/forgot")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testForgotDisabled() async throws {
        let enabled = try await makeStubbedAPI(status: 200, body: ["enabled": false]).passwordResetEnabled()
        XCTAssertFalse(enabled)
    }

    /// A journal predating the route.
    func testForgotOnAnOlderJournalIsOff() async throws {
        let enabled = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).passwordResetEnabled()
        XCTAssertFalse(enabled)
    }

    func testRequestResetPostsTheIdentifier_withoutAToken() async throws {
        let api = makeStubbedAPI(status: 200, body: ["ok": true])
        try await api.requestPasswordReset(identifier: "alice@example.com")
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/password/forgot")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(lastBodyJSON?["identifier"] as? String, "alice@example.com")
    }

    func testRequestResetRateLimited() async {
        let api = makeStubbedAPI(status: 429, body: ["error": "rate_limited"])
        do {
            try await api.requestPasswordReset(identifier: "alice")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .rateLimited)
        }
    }

    // MARK: Account email

    func testAccountEmailReadsTheAddressAndTheMailFlag() async throws {
        let api = makeStubbedAPI(status: 200, body: ["email": "alice@example.com", "reset_by_email": true])
        let account = try await api.accountEmail()
        XCTAssertEqual(account, AccountEmail(email: "alice@example.com", resetByEmail: true))
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/account/email")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testAccountEmailNotSet() async throws {
        let api = makeStubbedAPI(status: 200, body: ["email": NSNull(), "reset_by_email": false])
        let account = try await api.accountEmail()
        XCTAssertEqual(account, AccountEmail(email: nil, resetByEmail: false))
    }

    func testAccountEmailOnAnOlderJournalIsNotFound() async {
        let api = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do {
            _ = try await api.accountEmail()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }

    func testSetEmailPutsThePasswordAndTheAddress() async throws {
        let api = makeStubbedAPI(status: 200, body: ["email": "alice@example.com"])
        let stored = try await api.setAccountEmail(password: "secret-pw", email: "alice@example.com")
        XCTAssertEqual(stored, "alice@example.com")
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/account/email")
        XCTAssertEqual(lastBodyJSON?["password"] as? String, "secret-pw")
        XCTAssertEqual(lastBodyJSON?["email"] as? String, "alice@example.com")
    }

    func testRemovingTheEmailSendsNull() async throws {
        let api = makeStubbedAPI(status: 200, body: ["email": NSNull()])
        let stored = try await api.setAccountEmail(password: "secret-pw", email: nil)
        XCTAssertNil(stored)
        let body = try XCTUnwrap(lastBodyJSON)
        XCTAssertTrue(body["email"] is NSNull, "the key is sent, as null")
    }

    func testSetEmailErrors() async {
        let badPassword = await setEmailError(status: 401, body: ["error": "bad_password"])
        XCTAssertEqual(badPassword as? AccountEmailError, .badPassword)
        XCTAssertNil(badPassword as? JournalAPIError, "must not read as .unauthenticated")
        XCTAssertEqual(badPassword?.localizedDescription, "That password is incorrect.")

        let badEmail = await setEmailError(status: 400, body: ["error": "bad_email"])
        XCTAssertEqual(badEmail as? AccountEmailError, .badEmail)
        XCTAssertEqual(badEmail?.localizedDescription, "Enter a valid email address.")

        let taken = await setEmailError(status: 409, body: ["error": "email_taken"])
        XCTAssertEqual(taken as? AccountEmailError, .emailTaken)
        XCTAssertEqual(taken?.localizedDescription, "Another account already uses that address.")

        let locked = await setEmailError(status: 429, body: ["error": "locked_out", "retry_after": 300])
        XCTAssertEqual(locked as? JournalAPIError, .lockedOut(retryAfterSeconds: 300))

        let unauthenticated = await setEmailError(status: 401, body: ["error": "unauthenticated"])
        XCTAssertEqual(unauthenticated as? JournalAPIError, .unauthenticated)
    }

    /// Wrong passwords on the email form never sign this device out.
    func testRepeatedWrongPasswordsNeverTriggerTheRevocationSignOut() async {
        let monitor = CredentialRevocationMonitor(rejectionThreshold: 1, minimumSpan: .zero, onRevoked: {})
        let api = makeStubbedAPI(status: 401, body: ["error": "bad_password"],
                                 authResponses: { monitor.noteResponse(status: $0) })
        for _ in 0..<5 {
            _ = try? await api.setAccountEmail(password: "wrong-one", email: "alice@example.com")
        }
        XCTAssertFalse(monitor.hasFired)
    }
}
