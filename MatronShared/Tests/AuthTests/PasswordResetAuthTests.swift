import XCTest
import MatronModels
@testable import MatronJournal
@testable import MatronAuth

final class PasswordResetAuthTests: XCTestCase {
    private func makeService() -> JournalAuthService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAuthURLProtocol.self]
        return JournalAuthService(sessionStore: InMemorySessionStore(),
                                  urlSession: URLSession(configuration: config))
    }

    private var server: URL { URL(string: "https://chat.example.com")! }

    func testAvailableWhenTheJournalSaysSo() async {
        StubAuthURLProtocol.responses = ["/password/forgot": (200, #"{"enabled":true}"#)]
        let available = await makeService().passwordResetAvailable("chat.example.com")
        XCTAssertTrue(available)
    }

    func testUnavailableWhenOff_onAnOlderJournal_orForAnAddressThatIsNotAServer() async {
        StubAuthURLProtocol.responses = ["/password/forgot": (200, #"{"enabled":false}"#)]
        let off = await makeService().passwordResetAvailable("chat.example.com")
        XCTAssertFalse(off)

        StubAuthURLProtocol.responses = [:] // 404 everywhere
        let older = await makeService().passwordResetAvailable("chat.example.com")
        XCTAssertFalse(older)

        let blank = await makeService().passwordResetAvailable("   ")
        XCTAssertFalse(blank)
    }

    func testRequestSendsTheIdentifier() async throws {
        StubAuthURLProtocol.responses = ["/password/forgot": (200, #"{"ok":true}"#)]
        try await makeService().requestPasswordReset(homeserverURL: server, identifier: "alice")
        XCTAssertEqual(StubAuthURLProtocol.bodies["/password/forgot"]?["identifier"] as? String, "alice")
    }

    func testRequestRateLimited() async {
        StubAuthURLProtocol.responses = ["/password/forgot": (429, #"{"error":"rate_limited"}"#)]
        do {
            try await makeService().requestPasswordReset(homeserverURL: server, identifier: "alice")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .rateLimited)
        }
    }

    func testRequestWhenMailIsOff() async {
        StubAuthURLProtocol.responses = ["/password/forgot": (503, #"{"error":"unavailable"}"#)]
        do {
            try await makeService().requestPasswordReset(homeserverURL: server, identifier: "alice")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError,
                           .unexpected("Password reset isn't available on this server right now."))
        }
    }
}
