import XCTest
import MatronModels
import MatronStorage
@testable import MatronAuth

final class AuthServiceLivePersistenceTests: XCTestCase {
    var service: AuthServiceLive!
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("matron-auth-test-\(UUID().uuidString)")

    override func setUp() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sessionStore = FileSessionStore(directory: tempDir.appendingPathComponent("sessions"))
        service = AuthServiceLive(sessionStore: sessionStore, basePath: tempDir)
    }

    override func tearDown() async throws {
        try service.clearSession()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_persistAndRestore_roundTrip() async throws {
        let session = UserSession(
            userID: "@alice:example.com",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.example.com")!,
            accessToken: "tok",
            refreshToken: "refresh"
        )
        try service.persist(session)
        let restored = try await service.restoreSession()
        XCTAssertEqual(restored, session)
    }

    func test_clearSession_removesPersistedSession() async throws {
        let session = UserSession(
            userID: "@alice:example.com",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.example.com")!,
            accessToken: "tok"
        )
        try service.persist(session)
        try service.clearSession()
        let restored = try await service.restoreSession()
        XCTAssertNil(restored)
    }
}
