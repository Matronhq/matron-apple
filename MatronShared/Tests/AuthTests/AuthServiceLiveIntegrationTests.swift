import XCTest
import MatronStorage
@testable import MatronAuth

/// Run with:
///   MATRON_TEST_HOMESERVER=https://matrix.example.com \
///   MATRON_TEST_USERNAME=alice \
///   MATRON_TEST_PASSWORD=… \
///   swift test --filter AuthServiceLiveIntegrationTests
final class AuthServiceLiveIntegrationTests: XCTestCase {
    func test_probeAndLogin_againstLiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MATRON_TEST_HOMESERVER"],
              let username = env["MATRON_TEST_USERNAME"],
              let password = env["MATRON_TEST_PASSWORD"] else {
            throw XCTSkip("MATRON_TEST_HOMESERVER/USERNAME/PASSWORD not set; skipping integration test")
        }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matron-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sdkStore = tempDir.appendingPathComponent("sdk-store")
        let sessionsDir = tempDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sdkStore, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let service = AuthServiceLive(
            sessionStore: FileSessionStore(directory: sessionsDir),
            basePath: sdkStore
        )

        let caps = try await service.probe(server)
        XCTAssertTrue(caps.supportsPasswordLogin, "Test server must support password login")

        let url = URL(string: server)!
        let session = try await service.loginPassword(
            homeserverURL: url,
            username: username,
            password: password,
            initialDeviceDisplayName: "Matron Test"
        )
        XCTAssertFalse(session.accessToken.isEmpty)
        XCTAssertTrue(session.userID.hasPrefix("@"))
    }
}
