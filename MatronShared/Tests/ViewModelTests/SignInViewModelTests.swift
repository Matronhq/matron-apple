import XCTest
import MatronAuth
import MatronJournal
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

    var verifyResults: [Result<TwoFactorSignIn, Error>] = []
    var setupResult: Result<TwoFactorSetup, Error> = .failure(AuthError.twoFactorUnavailable)
    var enableResult: Result<TwoFactorEnrolment, Error> = .failure(AuthError.twoFactorUnavailable)
    var sentCodes: [String] = []

    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorSignIn {
        sentCodes.append(code)
        return try verifyResults.removeFirst().get()
    }
    func startTwoFactorEnrolment(_ challenge: TwoFactorChallenge) async throws -> TwoFactorSetup {
        try setupResult.get()
    }
    func finishTwoFactorEnrolment(_ challenge: TwoFactorChallenge, code: String) async throws -> TwoFactorEnrolment {
        sentCodes.append(code)
        return try enableResult.get()
    }
}

final class SignInViewModelTests: XCTestCase {
    @MainActor
    func test_plainSignIn_hasNoNotice() {
        let vm = SignInViewModel(auth: FakeAuthForVM(), deviceDisplayName: "Matron Tests")
        XCTAssertNil(vm.notice)
        XCTAssertEqual(vm.serverURL, "")
        XCTAssertEqual(vm.username, "")
    }

    @MainActor
    func test_signedOutRemotely_showsTheReason_andPrefillsTheAccount() {
        let revoked = UserSession(userID: "alice", deviceID: "7",
                                  homeserverURL: URL(string: "https://chat.example.com")!, accessToken: "t")
        let vm = SignInViewModel(auth: FakeAuthForVM(), deviceDisplayName: "Matron Tests",
                                 signedOutRemotely: revoked)
        XCTAssertEqual(vm.notice, SignInViewModel.signedOutRemotelyNotice)
        XCTAssertEqual(vm.serverURL, "https://chat.example.com")
        XCTAssertEqual(vm.username, "alice")
        XCTAssertEqual(vm.password, "")
        XCTAssertEqual(vm.state, .idle)
    }

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

    // App Review rejected 1.0 (350) because the Server field shipped
    // pre-filled with a dead host: the reviewer saw a filled field, typed
    // only the demo credentials, and got "Couldn't reach that server."
    // The field must start empty so the user has to supply their server.
    @MainActor
    func test_serverURL_defaultsToEmpty() {
        let vm = SignInViewModel(auth: FakeAuthForVM(), deviceDisplayName: "Matron Tests")
        XCTAssertEqual(vm.serverURL, "")
    }

    // MARK: Two-factor

    private static let server = URL(string: "https://chat.example.com")!
    private static let challenge = TwoFactorChallenge(homeserverURL: server, username: "alice",
                                                      ticket: "tkt1", expiresIn: 300)
    private static let session = UserSession(userID: "alice", deviceID: "9", homeserverURL: server,
                                             accessToken: "tok2")
    private static let setup = TwoFactorSetup(
        secret: "JBSWY3DPEHPK3PXP",
        otpauthURI: "otpauth://totp/Matron:alice@chat.example.com?secret=JBSWY3DPEHPK3PXP&issuer=Matron",
        issuer: "Matron", account: "alice@chat.example.com")

    @MainActor
    private func signIn(_ fake: FakeAuthForVM) async -> SignInViewModel {
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        vm.serverURL = "https://chat.example.com"
        vm.username = "alice"
        vm.password = "hunter2"
        await vm.submit()
        return vm
    }

    @MainActor
    func test_twoFactorRequired_showsTheCodeStep() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        let vm = await signIn(fake)
        XCTAssertEqual(vm.step, .code(Self.challenge))
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(fake.persistedSessions.isEmpty)
    }

    @MainActor
    func test_codeStep_onlySendsACompleteCode() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        let vm = await signIn(fake)
        vm.code = "12345"
        XCTAssertFalse(vm.codeIsComplete)
        await vm.submitCode()
        XCTAssertTrue(fake.sentCodes.isEmpty)
        vm.code = "123 456"
        XCTAssertTrue(vm.codeIsComplete)
        vm.usesRecoveryCode = true
        XCTAssertFalse(vm.codeIsComplete, "six digits is not a recovery code")
        vm.code = "abcd-efgh-ijkl-mnop"
        XCTAssertTrue(vm.codeIsComplete)
    }

    @MainActor
    func test_rightCode_persistsAndSignsIn() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        fake.verifyResults = [.success(TwoFactorSignIn(session: Self.session))]
        let vm = await signIn(fake)
        vm.code = "123456"
        await vm.submitCode()
        XCTAssertEqual(fake.sentCodes, ["123456"])
        XCTAssertEqual(vm.state, .signedIn(Self.session))
        XCTAssertEqual(fake.persistedSessions, [Self.session])
    }

    @MainActor
    func test_wrongCode_staysOnTheCodeStepToRetry() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        fake.verifyResults = [.failure(AuthError.wrongTwoFactorCode(canRetry: true)),
                              .success(TwoFactorSignIn(session: Self.session))]
        let vm = await signIn(fake)
        vm.code = "000000"
        await vm.submitCode()
        XCTAssertEqual(vm.step, .code(Self.challenge))
        XCTAssertEqual(vm.state, .error("Wrong code. Try again."))
        XCTAssertEqual(vm.code, "", "the field clears for the next try")

        vm.code = "123456"
        await vm.submitCode()
        XCTAssertEqual(vm.state, .signedIn(Self.session))
    }

    @MainActor
    func test_spentTicket_goesBackToThePassword() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        fake.verifyResults = [.failure(AuthError.wrongTwoFactorCode(canRetry: false))]
        let vm = await signIn(fake)
        vm.code = "000000"
        await vm.submitCode()
        XCTAssertEqual(vm.step, .password)
        XCTAssertEqual(vm.password, "")
        XCTAssertEqual(vm.username, "alice")
        guard case .error(let message) = vm.state else { return XCTFail("got \(vm.state)") }
        XCTAssertTrue(message.contains("password"))
    }

    @MainActor
    func test_expiredTicket_goesBackToThePassword() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        fake.verifyResults = [.failure(AuthError.twoFactorExpired)]
        let vm = await signIn(fake)
        vm.code = "123456"
        await vm.submitCode()
        XCTAssertEqual(vm.step, .password)
        XCTAssertEqual(vm.state, .error("That sign-in timed out. Enter your password again."))
    }

    @MainActor
    func test_lockedOut_staysOnTheCodeStepWithTheWait() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        fake.verifyResults = [.failure(AuthError.unexpected("Too many attempts — try again in 240s"))]
        let vm = await signIn(fake)
        vm.code = "123456"
        await vm.submitCode()
        XCTAssertEqual(vm.step, .code(Self.challenge))
        XCTAssertEqual(vm.state, .error("Too many attempts — try again in 240s"))
    }

    @MainActor
    func test_recoveryCode_warnsHowManyAreLeft_beforeSigningIn() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        fake.verifyResults = [.success(TwoFactorSignIn(session: Self.session, usedRecoveryCode: true,
                                                        recoveryCodesLeft: 3))]
        let vm = await signIn(fake)
        vm.usesRecoveryCode = true
        vm.code = "abcd-efgh-ijkl-mnop"
        await vm.submitCode()
        XCTAssertEqual(vm.step, .usedRecoveryCode(Self.session, left: 3))
        XCTAssertTrue(fake.persistedSessions.isEmpty)
        XCTAssertTrue(SignInViewModel.recoveryCodeWarning(left: 3).contains("3 left"))

        vm.continueSignedIn()
        XCTAssertEqual(vm.state, .signedIn(Self.session))
        XCTAssertEqual(fake.persistedSessions, [Self.session])
    }

    @MainActor
    func test_cancel_returnsToThePasswordForm() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorRequired(Self.challenge))
        let vm = await signIn(fake)
        vm.code = "12"
        vm.cancelTwoFactor()
        XCTAssertEqual(vm.step, .password)
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.code, "")
    }

    @MainActor
    func test_enrolmentRequired_loadsTheSecret() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorEnrolmentRequired(Self.challenge))
        fake.setupResult = .success(Self.setup)
        let vm = await signIn(fake)
        XCTAssertEqual(vm.step, .enrol(Self.challenge, setup: Self.setup))
        XCTAssertEqual(vm.state, .idle)
    }

    @MainActor
    func test_enrolmentSetupFailure_canBeRetried() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorEnrolmentRequired(Self.challenge))
        let vm = await signIn(fake)
        XCTAssertEqual(vm.step, .enrol(Self.challenge, setup: nil))
        guard case .error = vm.state else { return XCTFail("got \(vm.state)") }

        fake.setupResult = .success(Self.setup)
        await vm.retryEnrolment()
        XCTAssertEqual(vm.step, .enrol(Self.challenge, setup: Self.setup))
    }

    @MainActor
    func test_enrolment_showsRecoveryCodesOnce_thenSignsIn() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorEnrolmentRequired(Self.challenge))
        fake.setupResult = .success(Self.setup)
        let codes = ["aaaa-bbbb-cccc-dddd", "eeee-ffff-gggg-hhhh"]
        fake.enableResult = .success(TwoFactorEnrolment(session: Self.session, recoveryCodes: codes))
        let vm = await signIn(fake)
        vm.code = "654321"
        await vm.submitCode()
        XCTAssertEqual(fake.sentCodes, ["654321"])
        XCTAssertEqual(vm.step, .recoveryCodes(Self.session, codes: codes))
        XCTAssertTrue(fake.persistedSessions.isEmpty, "not signed in until the codes are saved")
        XCTAssertTrue(SignInViewModel.recoveryCodesText(codes).contains("eeee-ffff-gggg-hhhh"))

        vm.continueSignedIn()
        XCTAssertEqual(vm.state, .signedIn(Self.session))
        XCTAssertEqual(fake.persistedSessions, [Self.session])
    }

    @MainActor
    func test_enrolmentWrongCode_staysToRetry() async {
        let fake = FakeAuthForVM()
        fake.loginResult = .failure(AuthError.twoFactorEnrolmentRequired(Self.challenge))
        fake.setupResult = .success(Self.setup)
        fake.enableResult = .failure(AuthError.wrongTwoFactorCode(canRetry: true))
        let vm = await signIn(fake)
        vm.code = "000000"
        await vm.submitCode()
        XCTAssertEqual(vm.step, .enrol(Self.challenge, setup: Self.setup))
        XCTAssertEqual(vm.state, .error("Wrong code. Try again."))
    }
}
