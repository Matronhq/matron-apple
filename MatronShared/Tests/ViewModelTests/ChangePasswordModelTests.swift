import XCTest
import MatronJournal
@testable import MatronViewModels

private final class FakePasswordChanger: PasswordChanging, @unchecked Sendable {
    struct Call: Equatable {
        let oldPassword: String
        let newPassword: String
        let signOutOthers: Bool
    }
    var result: Result<PasswordChangeResult, Error>
    private(set) var calls: [Call] = []
    init(_ result: Result<PasswordChangeResult, Error> = .success(PasswordChangeResult(signedOut: 0))) {
        self.result = result
    }
    func changePassword(oldPassword: String, newPassword: String,
                        signOutOthers: Bool) async throws -> PasswordChangeResult {
        calls.append(Call(oldPassword: oldPassword, newPassword: newPassword, signOutOthers: signOutOthers))
        return try result.get()
    }
}

final class ChangePasswordModelTests: XCTestCase {
    @MainActor
    private func filled(_ fake: FakePasswordChanger, current: String = "old-secret",
                        new: String = "new-secret", confirm: String? = nil) -> ChangePasswordModel {
        let model = ChangePasswordModel(api: fake)
        model.begin()
        model.currentPassword = current
        model.newPassword = new
        model.confirmPassword = confirm ?? new
        return model
    }

    // MARK: Validation

    @MainActor
    func test_wording_matchesTheOtherClients() {
        XCTAssertEqual(ChangePasswordModel.rowTitle, "Password")
        XCTAssertEqual(ChangePasswordModel.rowHelp, "Used to sign in on a new device.")
        XCTAssertEqual(ChangePasswordModel.title, "Change Password")
        XCTAssertEqual(ChangePasswordModel.signOutOthersHelp, "Your agent boxes stay connected.")
    }

    @MainActor
    func test_startsEmpty_withSignOutOthersOn_andCannotSubmit() {
        let model = ChangePasswordModel(api: FakePasswordChanger())
        XCTAssertTrue(model.signOutOthers)
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.successMessage)
    }

    @MainActor
    func test_anEmptyField_disablesTheButton() {
        let model = filled(FakePasswordChanger())
        XCTAssertTrue(model.canSubmit)
        model.confirmPassword = ""
        XCTAssertFalse(model.canSubmit)
        model.confirmPassword = "new-secret"
        model.currentPassword = ""
        XCTAssertFalse(model.canSubmit)
    }

    @MainActor
    func test_shortNewPassword_isCaughtBeforeSending() async {
        let fake = FakePasswordChanger()
        let model = filled(fake, new: "short")
        let changed = await model.submit()
        XCTAssertFalse(changed)
        XCTAssertEqual(model.errorMessage, "Use at least 8 characters.")
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(model.newPassword, "short", "a failed check keeps what was typed")
    }

    @MainActor
    func test_mismatchedConfirmation_isCaughtBeforeSending() async {
        let fake = FakePasswordChanger()
        let model = filled(fake, new: "new-secret", confirm: "new-secrex")
        await model.submit()
        XCTAssertEqual(model.errorMessage, "The new passwords don't match.")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    @MainActor
    func test_sameAsCurrent_isCaughtBeforeSending() async {
        let fake = FakePasswordChanger()
        let model = filled(fake, current: "same-secret", new: "same-secret")
        await model.submit()
        XCTAssertEqual(model.errorMessage, "Choose a password different from your current one.")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: Sending

    @MainActor
    func test_success_sendsTheFields_clearsThem_andSaysSo() async {
        let fake = FakePasswordChanger(.success(PasswordChangeResult(signedOut: 0)))
        let model = filled(fake)
        model.signOutOthers = false
        let changed = await model.submit()
        XCTAssertTrue(changed)
        XCTAssertEqual(fake.calls, [.init(oldPassword: "old-secret", newPassword: "new-secret", signOutOthers: false)])
        XCTAssertEqual(model.successMessage, "Password changed.")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.currentPassword, "")
        XCTAssertEqual(model.newPassword, "")
        XCTAssertEqual(model.confirmPassword, "")
    }

    @MainActor
    func test_success_countsTheDevicesSignedOut() async {
        let fake = FakePasswordChanger(.success(PasswordChangeResult(signedOut: 1)))
        let model = filled(fake)
        await model.submit()
        XCTAssertEqual(fake.calls.first?.signOutOthers, true, "on by default")
        XCTAssertEqual(model.successMessage, "Password changed. Signed out of 1 other device.")
        XCTAssertEqual(ChangePasswordModel.successText(signedOut: 3),
                       "Password changed. Signed out of 3 other devices.")
    }

    @MainActor
    func test_wrongCurrentPassword_saysSo_clearsOnlyTheCurrentPassword() async {
        let model = filled(FakePasswordChanger(.failure(PasswordChangeError.badPassword)))
        let changed = await model.submit()
        XCTAssertFalse(changed)
        XCTAssertEqual(model.errorMessage, "That password is incorrect.")
        XCTAssertNil(model.successMessage)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.currentPassword, "")
        XCTAssertEqual(model.newPassword, "new-secret")
        XCTAssertEqual(model.confirmPassword, "new-secret")
        XCTAssertFalse(model.canSubmit, "the current password is typed again")
    }

    @MainActor
    func test_weakPassword_fromTheServer() async {
        let model = filled(FakePasswordChanger(.failure(PasswordChangeError.weakPassword)))
        await model.submit()
        XCTAssertEqual(model.errorMessage, "Use at least 8 characters.")
        XCTAssertEqual(model.currentPassword, "")
        XCTAssertEqual(model.newPassword, "new-secret")
    }

    @MainActor
    func test_retryAfterARefusal_sendsTheRetypedPassword() async {
        let fake = FakePasswordChanger(.failure(PasswordChangeError.badPassword))
        let model = filled(fake, current: "wrong-one")
        await model.submit()
        fake.result = .success(PasswordChangeResult(signedOut: 0))
        model.currentPassword = "old-secret"
        let changed = await model.submit()
        XCTAssertTrue(changed)
        XCTAssertEqual(fake.calls.map(\.oldPassword), ["wrong-one", "old-secret"])
        XCTAssertEqual(fake.calls.last?.newPassword, "new-secret")
        XCTAssertEqual(model.newPassword, "")
        XCTAssertEqual(model.confirmPassword, "")
    }

    @MainActor
    func test_lockout_roundsUpToMinutes() async {
        let model = filled(FakePasswordChanger(.failure(JournalAPIError.lockedOut(retryAfterSeconds: 61))))
        await model.submit()
        XCTAssertEqual(model.errorMessage, "Too many attempts. Try again in 2 minutes.")
        XCTAssertEqual(ChangePasswordModel.message(for: JournalAPIError.lockedOut(retryAfterSeconds: 5)),
                       "Too many attempts. Try again in 1 minute.")
        XCTAssertEqual(ChangePasswordModel.message(for: JournalAPIError.lockedOut(retryAfterSeconds: 0)),
                       "Too many attempts. Try again in 1 minute.")
        XCTAssertEqual(ChangePasswordModel.message(for: JournalAPIError.lockedOut(retryAfterSeconds: 900)),
                       "Too many attempts. Try again in 15 minutes.")
    }

    @MainActor
    func test_otherFailures_useTheUsualErrorText_andKeepTheNewPassword() async {
        let error = JournalAPIError.transport("")
        let model = filled(FakePasswordChanger(.failure(error)))
        await model.submit()
        XCTAssertEqual(model.errorMessage, error.localizedDescription)
        XCTAssertEqual(model.currentPassword, "")
        XCTAssertEqual(model.newPassword, "new-secret")
    }

    // MARK: Opening and closing

    @MainActor
    func test_begin_startsAFreshForm() async {
        let model = filled(FakePasswordChanger(.success(PasswordChangeResult(signedOut: 0))))
        model.signOutOthers = false
        await model.submit()
        XCTAssertNotNil(model.successMessage)
        model.begin()
        XCTAssertNil(model.successMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.signOutOthers)
    }

    @MainActor
    func test_end_dropsWhatWasTyped_butKeepsTheConfirmation() async {
        let fake = FakePasswordChanger(.success(PasswordChangeResult(signedOut: 2)))
        let model = filled(fake)
        await model.submit()
        model.end()
        XCTAssertEqual(model.successMessage, "Password changed. Signed out of 2 other devices.")

        let cancelled = filled(FakePasswordChanger(.failure(PasswordChangeError.badPassword)))
        await cancelled.submit()
        cancelled.end()
        XCTAssertEqual(cancelled.currentPassword, "")
        XCTAssertEqual(cancelled.newPassword, "")
        XCTAssertEqual(cancelled.confirmPassword, "")
        XCTAssertNil(cancelled.errorMessage)
    }
}
