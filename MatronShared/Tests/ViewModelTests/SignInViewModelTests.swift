import XCTest
import MatronAuth
import MatronModels
@testable import MatronViewModels

final class FakeAuthForVM: AuthService, @unchecked Sendable {
    var probeResult: Result<ServerCapabilities, Error> = .success(.init(supportsPasswordLogin: true, supportsSSO: false))
    var loginResult: Result<UserSession, Error>!
    var persistedSessions: [UserSession] = []

    func probe(_ rawURL: String) async throws -> ServerCapabilities {
        try probeResult.get()
    }
    func loginPassword(homeserverURL: URL, username: String, password: String, initialDeviceDisplayName: String) async throws -> UserSession {
        try loginResult.get()
    }
    func restoreSession() async throws -> UserSession? { nil }
    func persist(_ session: UserSession) throws { persistedSessions.append(session) }
    func clearSession() throws {}
}

final class SignInViewModelTests: XCTestCase {
    @MainActor
    func test_submit_setsBusyAndCallsLogin_onSuccess() async {
        let fake = FakeAuthForVM()
        let session = UserSession(
            userID: "@a:s", deviceID: "D", homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        fake.loginResult = .success(session)
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        vm.serverURL = "https://matrix.example.com"
        vm.username = "alice"
        vm.password = "hunter2"

        await vm.submit()

        XCTAssertEqual(vm.state, .signedIn(session))
        XCTAssertEqual(fake.persistedSessions, [session])
    }

    @MainActor
    func test_submit_showsError_onInvalidCredentials() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.invalidCredentials)
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        vm.serverURL = "https://matrix.example.com"
        vm.username = "alice"
        vm.password = "wrong"

        await vm.submit()

        if case .error(let message) = vm.state {
            XCTAssertTrue(message.lowercased().contains("credentials") || message.lowercased().contains("invalid"))
        } else {
            XCTFail("Expected .error state, got \(vm.state)")
        }
    }

    @MainActor
    func test_submit_isNoOp_whenInputsEmpty() async {
        let fake = FakeAuthForVM()
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        await vm.submit()
        XCTAssertEqual(vm.state, .idle)
    }
}
