import XCTest
import MatronModels
import MatronStorage
@testable import MatronJournal
@testable import MatronAuth

final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) throws { values[key] = value }
    func get(key: String) throws -> String? { values[key] }
    func delete(key: String) throws { values[key] = nil }
}

final class JournalAuthServiceTests: XCTestCase {
    private func makeService() -> (JournalAuthService, InMemorySessionStore) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAuthURLProtocol.self]
        let store = InMemorySessionStore()
        return (JournalAuthService(sessionStore: store, urlSession: URLSession(configuration: config)), store)
    }

    func testProbeRecognisesJournalServer() async throws {
        StubAuthURLProtocol.responses = ["/snapshot": (401, #"{"error":"unauthenticated"}"#)]
        let (service, _) = makeService()
        let caps = try await service.probe("chat.example.com")
        XCTAssertTrue(caps.supportsPasswordLogin)
        XCTAssertFalse(caps.supportsSSO)
    }

    func testLoginMapsToUserSessionAndPersistRoundTrips() async throws {
        StubAuthURLProtocol.responses = ["/login": (200, #"{"token":"tok1","device_id":7,"user_id":3}"#)]
        let (service, _) = makeService()
        let session = try await service.loginPassword(
            homeserverURL: URL(string: "https://chat.example.com")!,
            username: "alice", password: "pw", initialDeviceDisplayName: "Matron Mac")
        XCTAssertEqual(session.userID, "alice")
        XCTAssertEqual(session.deviceID, "7")
        XCTAssertEqual(session.accessToken, "tok1")

        try service.persist(session)
        XCTAssertEqual(try service.restoreSession(), session)
        try service.clearSession()
        XCTAssertNil(try service.restoreSession())
    }

    func testBadCredentialsMapsToAuthError() async {
        StubAuthURLProtocol.responses = ["/login": (403, #"{"error":"bad_credentials"}"#)]
        let (service, _) = makeService()
        do {
            _ = try await service.loginPassword(
                homeserverURL: URL(string: "https://chat.example.com")!,
                username: "alice", password: "wrong", initialDeviceDisplayName: "x")
            XCTFail("expected throw")
        } catch let error as AuthError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testProbeRejectsNonJournalServer() async {
        // A 200 from /snapshot means it is NOT a journal server (they 401 unauthenticated).
        StubAuthURLProtocol.responses = ["/snapshot": (200, #"{"whatever":"ok"}"#)]
        let (service, _) = makeService()
        do {
            _ = try await service.probe("chat.example.com")
            XCTFail("expected serverUnreachable")
        } catch let error as AuthError {
            XCTAssertEqual(error, .serverUnreachable)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLockedOutMapsToUnexpectedWithRetryMessage() async {
        StubAuthURLProtocol.responses = ["/login": (429, #"{"error":"locked_out","retry_after":90}"#)]
        let (service, _) = makeService()
        do {
            _ = try await service.loginPassword(
                homeserverURL: URL(string: "https://chat.example.com")!,
                username: "alice", password: "pw", initialDeviceDisplayName: "x")
            XCTFail("expected throw")
        } catch let AuthError.unexpected(message) {
            XCTAssertTrue(message.contains("90"), "retry seconds should surface: \(message)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

// MARK: Two-factor sign-in

extension JournalAuthServiceTests {
    private var server: URL { URL(string: "https://chat.example.com")! }

    private func challenge(_ ticket: String = "tkt1") -> TwoFactorChallenge {
        TwoFactorChallenge(homeserverURL: server, username: "alice", ticket: ticket, expiresIn: 300)
    }

    /// Runs `body` and returns the AuthError it threw.
    private func authError<T>(_ body: () async throws -> T) async -> AuthError? {
        do {
            _ = try await body()
            XCTFail("expected throw")
            return nil
        } catch let error as AuthError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    func testLoginWithTwoFactorOnAsksForACode() async {
        StubAuthURLProtocol.responses = ["/login": (401,
            #"{"error":"two_factor_required","two_factor_ticket":"tkt1","expires_in":300}"#)]
        let (service, _) = makeService()
        let error = await authError {
            try await service.loginPassword(homeserverURL: server, username: "alice", password: "pw",
                                            initialDeviceDisplayName: "x")
        }
        XCTAssertEqual(error, .twoFactorRequired(challenge()))
    }

    func testLoginWhenTwoFactorIsRequiredAsksForEnrolment() async {
        StubAuthURLProtocol.responses = ["/login": (401,
            #"{"error":"two_factor_enrolment_required","two_factor_ticket":"tkt2","expires_in":120}"#)]
        let (service, _) = makeService()
        let error = await authError {
            try await service.loginPassword(homeserverURL: server, username: "alice", password: "pw",
                                            initialDeviceDisplayName: "x")
        }
        XCTAssertEqual(error, .twoFactorEnrolmentRequired(
            TwoFactorChallenge(homeserverURL: server, username: "alice", ticket: "tkt2", expiresIn: 120)))
    }

    func testPlain401WithoutATicketIsStillAFailedSignIn() async {
        StubAuthURLProtocol.responses = ["/login": (401, #"{"error":"unauthenticated"}"#)]
        let (service, _) = makeService()
        let error = await authError {
            try await service.loginPassword(homeserverURL: server, username: "alice", password: "pw",
                                            initialDeviceDisplayName: "x")
        }
        guard case .unexpected = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testCodeStepReturnsASessionShapedLikeLogin() async throws {
        StubAuthURLProtocol.responses = ["/login/2fa": (200,
            #"{"token":"tok2","device_id":9,"user_id":3,"used_recovery_code":false,"recovery_codes_left":10}"#)]
        let (service, _) = makeService()
        let result = try await service.verifyTwoFactor(challenge(), code: "123 456")
        XCTAssertEqual(result.session, UserSession(userID: "alice", deviceID: "9",
                                                   homeserverURL: server, accessToken: "tok2"))
        XCTAssertFalse(result.usedRecoveryCode)
        XCTAssertEqual(StubAuthURLProtocol.bodies["/login/2fa"]?["ticket"] as? String, "tkt1")
        XCTAssertEqual(StubAuthURLProtocol.bodies["/login/2fa"]?["code"] as? String, "123 456")
    }

    func testCodeStepReportsARecoveryCodeSpent() async throws {
        StubAuthURLProtocol.responses = ["/login/2fa": (200,
            #"{"token":"tok2","device_id":9,"user_id":3,"used_recovery_code":true,"recovery_codes_left":4}"#)]
        let (service, _) = makeService()
        let result = try await service.verifyTwoFactor(challenge(), code: "abcd-efgh-ijkl-mnop")
        XCTAssertTrue(result.usedRecoveryCode)
        XCTAssertEqual(result.recoveryCodesLeft, 4)
    }

    func testWrongCodeWithTriesLeftCanRetry() async {
        StubAuthURLProtocol.responses = ["/login/2fa": (403, #"{"error":"bad_code","ticket_valid":true}"#)]
        let (service, _) = makeService()
        let error = await authError { try await service.verifyTwoFactor(challenge(), code: "000000") }
        XCTAssertEqual(error, .wrongTwoFactorCode(canRetry: true))
    }

    func testWrongCodeWithTheTicketSpentCannotRetry() async {
        StubAuthURLProtocol.responses = ["/login/2fa": (403, #"{"error":"bad_code","ticket_valid":false}"#)]
        let (service, _) = makeService()
        let error = await authError { try await service.verifyTwoFactor(challenge(), code: "000000") }
        XCTAssertEqual(error, .wrongTwoFactorCode(canRetry: false))
    }

    func testExpiredTicketMapsToExpired() async {
        StubAuthURLProtocol.responses = ["/login/2fa": (401, #"{"error":"two_factor_ticket_invalid"}"#)]
        let (service, _) = makeService()
        let error = await authError { try await service.verifyTwoFactor(challenge(), code: "123456") }
        XCTAssertEqual(error, .twoFactorExpired)
    }

    func testCodeStepLockoutSurfacesRetryAfter() async {
        StubAuthURLProtocol.responses = ["/login/2fa": (429, #"{"error":"locked_out","retry_after":240}"#)]
        let (service, _) = makeService()
        let error = await authError { try await service.verifyTwoFactor(challenge(), code: "123456") }
        guard case .unexpected(let message) = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertTrue(message.contains("240"), "retry seconds should surface: \(message)")
    }

    func testEnrolmentFetchesTheSecret() async throws {
        StubAuthURLProtocol.responses = ["/login/2fa/setup": (200, #"""
            {"secret":"JBSWY3DPEHPK3PXP","otpauth_uri":"otpauth://totp/Matron:alice@chat.example.com?secret=JBSWY3DPEHPK3PXP&issuer=Matron","issuer":"Matron","account":"alice@chat.example.com"}
            """#)]
        let (service, _) = makeService()
        let setup = try await service.startTwoFactorEnrolment(challenge())
        XCTAssertEqual(setup.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertTrue(setup.otpauthURI.hasPrefix("otpauth://totp/"))
        XCTAssertEqual(setup.account, "alice@chat.example.com")
        XCTAssertEqual(StubAuthURLProtocol.bodies["/login/2fa/setup"]?["ticket"] as? String, "tkt1")
    }

    func testEnrolmentUnavailableMapsToUnavailable() async {
        StubAuthURLProtocol.responses = ["/login/2fa/setup": (503, #"{"error":"two_factor_unavailable"}"#)]
        let (service, _) = makeService()
        let error = await authError { try await service.startTwoFactorEnrolment(challenge()) }
        XCTAssertEqual(error, .twoFactorUnavailable)
    }

    func testEnableReturnsTheSessionAndRecoveryCodes() async throws {
        StubAuthURLProtocol.responses = ["/login/2fa/enable": (200,
            #"{"token":"tok3","device_id":11,"user_id":3,"recovery_codes":["aaaa-bbbb-cccc-dddd","eeee-ffff-gggg-hhhh"]}"#)]
        let (service, _) = makeService()
        let enrolment = try await service.finishTwoFactorEnrolment(challenge(), code: "654321")
        XCTAssertEqual(enrolment.session.accessToken, "tok3")
        XCTAssertEqual(enrolment.session.deviceID, "11")
        XCTAssertEqual(enrolment.recoveryCodes, ["aaaa-bbbb-cccc-dddd", "eeee-ffff-gggg-hhhh"])
        XCTAssertEqual(StubAuthURLProtocol.bodies["/login/2fa/enable"]?["code"] as? String, "654321")
    }

    func testStatusDecodes() async throws {
        StubAuthURLProtocol.responses = ["/2fa": (200,
            #"{"enabled":true,"enabled_at":1760000000000,"recovery_codes_left":8,"required":false,"available":true}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAuthURLProtocol.self]
        let api = JournalAPI(serverURL: server, urlSession: URLSession(configuration: config), token: "tok")
        let status = try await api.twoFactorStatus()
        XCTAssertEqual(status, TwoFactorStatus(enabled: true, enabledAt: 1_760_000_000_000,
                                               recoveryCodesLeft: 8, required: false, available: true))
    }
}

final class StubAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    /// The JSON body of the last request to each path.
    nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let data = Self.bodyData(of: request),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            Self.bodies[request.url!.path] = obj
        }
        let (status, body) = Self.responses[request.url!.path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
