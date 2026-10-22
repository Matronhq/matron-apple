import XCTest
import MatronAuth
import MatronJournal
@testable import MatronViewModels

final class SignInForgotPasswordTests: XCTestCase {
    @MainActor
    private func checked(_ fake: FakeAuthForVM, server: String = "chat.example.com",
                         available: Bool = true) async -> SignInViewModel {
        fake.resetAvailable[server] = available
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        vm.serverURL = server
        await vm.checkPasswordReset()
        return vm
    }

    // MARK: When the link shows

    @MainActor
    func test_hiddenUntilTheServerSaysItIsOn() async {
        let fake = FakeAuthForVM()
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        XCTAssertFalse(vm.forgotPasswordAvailable)
        await vm.checkPasswordReset()
        XCTAssertFalse(vm.forgotPasswordAvailable, "no server typed")
        XCTAssertTrue(fake.resetChecks.isEmpty)

        let on = await checked(fake)
        XCTAssertTrue(on.forgotPasswordAvailable)
        let off = await checked(fake, server: "other.example.com", available: false)
        XCTAssertFalse(off.forgotPasswordAvailable)
    }

    @MainActor
    func test_editingTheServer_hidesTheLinkUntilReChecked() async {
        let fake = FakeAuthForVM()
        let vm = await checked(fake)
        vm.serverURL = "chat.example.co"
        XCTAssertFalse(vm.forgotPasswordAvailable)
        vm.openForgotPassword()
        XCTAssertFalse(vm.isShowingForgotPassword)

        vm.serverURL = "chat.example.com"
        XCTAssertFalse(vm.forgotPasswordAvailable, "off until asked again")
        await vm.checkPasswordReset()
        XCTAssertTrue(vm.forgotPasswordAvailable)
    }

    @MainActor
    func test_whitespaceOnlyEdits_keepTheAnswer() async {
        let vm = await checked(FakeAuthForVM())
        vm.serverURL = "chat.example.com "
        XCTAssertTrue(vm.forgotPasswordAvailable)
    }

    @MainActor
    func test_anAnswerForAServerSinceChanged_isDropped() async {
        let fake = FakeAuthForVM()
        fake.resetAvailable["chat.example.com"] = true
        let vm = SignInViewModel(auth: fake, deviceDisplayName: "Matron Tests")
        vm.serverURL = "chat.example.com"
        fake.duringResetCheck = { vm.serverURL = "elsewhere.example.com" }
        await vm.checkPasswordReset()
        XCTAssertFalse(vm.forgotPasswordAvailable)
    }

    // MARK: The form

    @MainActor
    func test_open_prefillsTheUsername() async {
        let vm = await checked(FakeAuthForVM())
        vm.username = " alice "
        vm.openForgotPassword()
        XCTAssertTrue(vm.isShowingForgotPassword)
        XCTAssertEqual(vm.forgotIdentifier, "alice")
        XCTAssertEqual(vm.forgotState, .editing)
        XCTAssertTrue(vm.canSendForgotPassword)
        vm.forgotIdentifier = "  "
        XCTAssertFalse(vm.canSendForgotPassword)
    }

    @MainActor
    func test_send_goesToTheCheckedServer_andAlwaysSaysTheSame() async {
        let fake = FakeAuthForVM()
        let vm = await checked(fake)
        vm.openForgotPassword()
        vm.forgotIdentifier = " alice@example.com "
        await vm.submitForgotPassword()
        XCTAssertEqual(fake.resetRequests.map { $0.identifier }, ["alice@example.com"])
        XCTAssertEqual(fake.resetRequests.first?.url, URL(string: "https://chat.example.com"))
        XCTAssertEqual(vm.forgotState, .sent)
        XCTAssertFalse(vm.canSendForgotPassword)
        XCTAssertEqual(SignInViewModel.forgotPasswordSent,
                       "If that account has an email address, we've sent a link to reset its password. It works once, for 30 minutes.")

        vm.closeForgotPassword()
        XCTAssertFalse(vm.isShowingForgotPassword)
        XCTAssertEqual(vm.forgotState, .editing)
        XCTAssertEqual(vm.forgotIdentifier, "")
    }

    @MainActor
    func test_neverSendsToAServerThatHasNotSaidItIsOn() async {
        let fake = FakeAuthForVM()
        let off = await checked(fake, available: false)
        off.forgotIdentifier = "alice"
        await off.submitForgotPassword()
        XCTAssertTrue(fake.resetRequests.isEmpty)

        // Opened for one server, then (somehow) the server changed.
        let vm = await checked(fake)
        vm.openForgotPassword()
        vm.forgotIdentifier = "alice"
        vm.serverURL = "elsewhere.example.com"
        await vm.submitForgotPassword()
        XCTAssertTrue(fake.resetRequests.isEmpty)
    }

    @MainActor
    func test_rateLimited_saysWaitAFewMinutes() async {
        let fake = FakeAuthForVM()
        fake.resetResult = .failure(AuthError.rateLimited)
        let vm = await checked(fake)
        vm.openForgotPassword()
        vm.forgotIdentifier = "alice"
        await vm.submitForgotPassword()
        XCTAssertEqual(vm.forgotState, .error("Too many requests. Try again in a few minutes."))
        XCTAssertTrue(vm.canSendForgotPassword, "can try again")
    }

    @MainActor
    func test_networkFailure_usesTheUsualText() async {
        let fake = FakeAuthForVM()
        fake.resetResult = .failure(AuthError.unexpected("Couldn't reach the server."))
        let vm = await checked(fake)
        vm.openForgotPassword()
        vm.forgotIdentifier = "alice"
        await vm.submitForgotPassword()
        XCTAssertEqual(vm.forgotState, .error("Couldn't reach the server."))
    }
}
