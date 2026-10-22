import XCTest
import MatronModels
@testable import MatronJournal

final class PasswordAPITests: XCTestCase {
    private func makeStubbedAPI(status: Int, body: [String: Any],
                                authResponses: (@Sendable (Int) -> Void)? = nil) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t",
                          authResponses: authResponses)
    }

    private var lastBodyJSON: [String: Any]? {
        ItemsStubURLProtocol.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func changeError(status: Int, body: [String: Any]) async -> Error? {
        let api = makeStubbedAPI(status: status, body: body)
        do {
            _ = try await api.changePassword(oldPassword: "old-secret", newPassword: "new-secret",
                                             signOutOthers: true)
            XCTFail("expected a throw")
            return nil
        } catch {
            return error
        }
    }

    // MARK: Request and response

    func testPostsBothPasswordsAndTheFlag() async throws {
        let api = makeStubbedAPI(status: 200, body: ["ok": true, "signed_out": 2])
        let result = try await api.changePassword(oldPassword: "old-secret", newPassword: "new-secret",
                                                  signOutOthers: true)
        XCTAssertEqual(result, PasswordChangeResult(signedOut: 2))
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/password")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let body = try XCTUnwrap(lastBodyJSON)
        XCTAssertEqual(body["old_password"] as? String, "old-secret")
        XCTAssertEqual(body["new_password"] as? String, "new-secret")
        XCTAssertEqual(body["sign_out_others"] as? Bool, true)
    }

    func testKeepingOtherDevicesSendsFalse() async throws {
        let api = makeStubbedAPI(status: 200, body: ["ok": true, "signed_out": 0])
        let result = try await api.changePassword(oldPassword: "old-secret", newPassword: "new-secret",
                                                  signOutOthers: false)
        XCTAssertEqual(result.signedOut, 0)
        XCTAssertEqual(lastBodyJSON?["sign_out_others"] as? Bool, false)
    }

    /// An older journal answers `{ok: true}` without the count.
    func testAnOlderJournalWithoutTheCountReadsAsNone() async throws {
        let api = makeStubbedAPI(status: 200, body: ["ok": true])
        let result = try await api.changePassword(oldPassword: "old-secret", newPassword: "new-secret",
                                                  signOutOthers: true)
        XCTAssertEqual(result.signedOut, 0)
    }

    // MARK: Errors

    func testWrongCurrentPasswordIsBadPassword_notSignedOut() async {
        let error = await changeError(status: 401, body: ["error": "bad_password"])
        XCTAssertEqual(error as? PasswordChangeError, .badPassword)
        XCTAssertNil(error as? JournalAPIError, "must not read as .unauthenticated")
        XCTAssertEqual(error?.localizedDescription, "That password is incorrect.")
    }

    func testShortNewPasswordIsWeakPassword() async {
        let error = await changeError(status: 400, body: ["error": "weak_password"])
        XCTAssertEqual(error as? PasswordChangeError, .weakPassword)
        XCTAssertEqual(error?.localizedDescription, "Use at least 8 characters.")
    }

    func testLockoutCarriesRetryAfter() async {
        let error = await changeError(status: 429, body: ["error": "locked_out", "retry_after": 125])
        XCTAssertEqual(error as? JournalAPIError, .lockedOut(retryAfterSeconds: 125))
    }

    func testOtherFailuresUseTheGenericMapping() async {
        let badRequest = await changeError(status: 400, body: ["error": "bad_request"])
        XCTAssertEqual(badRequest as? JournalAPIError, .http(status: 400, message: "bad_request"))
        let forbidden = await changeError(status: 403, body: ["error": "forbidden"])
        XCTAssertEqual(forbidden as? JournalAPIError, .forbidden)
        // A token the journal no longer accepts is still a sign-in problem.
        let unauthenticated = await changeError(status: 401, body: ["error": "unauthenticated"])
        XCTAssertEqual(unauthenticated as? JournalAPIError, .unauthenticated)
    }

    // MARK: Credential monitoring

    func testBadPasswordIsReportedAsAnAuthenticatedRefusal() {
        let badPassword = Data(#"{"error":"bad_password"}"#.utf8)
        XCTAssertEqual(JournalAPI.credentialStatus(401, data: badPassword), 403)
        XCTAssertEqual(JournalAPI.credentialStatus(401, data: Data(#"{"error":"unauthenticated"}"#.utf8)), 401)
        XCTAssertEqual(JournalAPI.credentialStatus(401, data: Data()), 401)
        XCTAssertEqual(JournalAPI.credentialStatus(400, data: badPassword), 400)
        XCTAssertEqual(JournalAPI.credentialStatus(200, data: Data()), 200)
    }

    /// Wrong current passwords, however many, never sign this device out.
    func testRepeatedWrongPasswordsNeverTriggerTheRevocationSignOut() async {
        let fired = LockedFlag()
        let monitor = CredentialRevocationMonitor(rejectionThreshold: 1, minimumSpan: .zero,
                                                  onRevoked: { fired.set() })
        let api = makeStubbedAPI(status: 401, body: ["error": "bad_password"],
                                 authResponses: { monitor.noteResponse(status: $0) })
        for _ in 0..<5 {
            _ = try? await api.changePassword(oldPassword: "wrong-one", newPassword: "new-secret",
                                              signOutOthers: true)
        }
        XCTAssertFalse(fired.value)
        XCTAssertFalse(monitor.hasFired)
    }

    func testErrorsAreHumanReadable() {
        for error in [PasswordChangeError.badPassword, .weakPassword] {
            XCTAssertFalse(error.localizedDescription.contains("PasswordChangeError"))
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
