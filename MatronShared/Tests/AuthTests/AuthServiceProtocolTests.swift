import XCTest
import MatronModels
@testable import MatronAuth

final class AuthServiceProtocolTests: XCTestCase {
    func test_fake_canProbe() async throws {
        let fake = FakeAuthService()
        fake.stubbedProbe = .success(.init(supportsPasswordLogin: true, supportsSSO: false))
        let caps = try await fake.probe("https://matrix.example.com")
        XCTAssertTrue(caps.supportsPasswordLogin)
        XCTAssertFalse(caps.supportsSSO)
    }

    func test_fake_capturesSsoFlag_asBoolean() async throws {
        let fake = FakeAuthService()
        fake.stubbedProbe = .success(.init(supportsPasswordLogin: true, supportsSSO: true))
        let caps = try await fake.probe("https://matrix.example.com")
        XCTAssertTrue(caps.supportsSSO)
    }

    func test_fake_persistRetainsSessions() throws {
        let fake = FakeAuthService()
        let session = UserSession(
            userID: "@alice:example.com",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.example.com")!,
            accessToken: "tok"
        )
        try fake.persist(session)
        XCTAssertEqual(fake.persistedSessions, [session])
    }
}
