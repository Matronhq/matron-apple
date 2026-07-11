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
            username: "dan", password: "pw", initialDeviceDisplayName: "Matron Mac")
        XCTAssertEqual(session.userID, "dan")
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
                username: "dan", password: "wrong", initialDeviceDisplayName: "x")
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
                username: "dan", password: "pw", initialDeviceDisplayName: "x")
            XCTFail("expected throw")
        } catch let AuthError.unexpected(message) {
            XCTAssertTrue(message.contains("90"), "retry seconds should surface: \(message)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class StubAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.responses[request.url!.path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
