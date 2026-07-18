import XCTest
import MatronAuth
import MatronModels
import MatronViewModels
@testable import Matron

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

final class SignInViewBindingTests: XCTestCase {

    @MainActor
    func test_onSignedInClosure_isInvoked_whenViewModelTransitionsToSignedIn() async {
        let fake = FakeAuthForVM()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        fake.loginResult = .success(session)

        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron iOS")
        vm.serverURL = "https://matrix.example.com"
        vm.username = "alice"
        vm.password = "hunter2"
        let linkVM = LinkSignInViewModel(auth: fake, deviceDisplayName: "Matron iOS")

        var captured: UserSession?
        let _ = SignInView(viewModel: vm, linkViewModel: linkVM) { captured = $0 }

        await vm.submit()

        if case .signedIn(let s) = vm.state {
            captured = s
        }
        XCTAssertEqual(captured, session)
    }
}
