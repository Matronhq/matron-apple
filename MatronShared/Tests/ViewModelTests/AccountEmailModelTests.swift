import XCTest
import MatronJournal
@testable import MatronViewModels

private final class FakeAccountEmail: AccountEmailProviding, @unchecked Sendable {
    var readResult: Result<AccountEmail, Error>
    var writeResult: Result<String?, Error> = .success(nil)
    private(set) var writes: [(password: String, email: String?)] = []

    init(_ readResult: Result<AccountEmail, Error>) { self.readResult = readResult }

    func accountEmail() async throws -> AccountEmail { try readResult.get() }
    func setAccountEmail(password: String, email: String?) async throws -> String? {
        writes.append((password, email))
        return try writeResult.get()
    }
}

final class AccountEmailModelTests: XCTestCase {
    @MainActor
    private func loaded(_ fake: FakeAccountEmail) async -> AccountEmailModel {
        let model = AccountEmailModel(api: fake)
        await model.refresh()
        return model
    }

    // MARK: The row

    @MainActor
    func test_showsTheAddress_andTheHelp() async {
        let model = await loaded(FakeAccountEmail(.success(AccountEmail(email: "alice@example.com", resetByEmail: true))))
        XCTAssertTrue(model.isShown)
        XCTAssertEqual(model.valueText, "alice@example.com")
        XCTAssertEqual(model.helpText, "Used to reset your password if you forget it.")
        XCTAssertTrue(model.hasEmail)
        XCTAssertTrue(model.canEdit)
    }

    @MainActor
    func test_notSet_andAJournalThatCannotSendMail() async {
        let model = await loaded(FakeAccountEmail(.success(AccountEmail(email: nil, resetByEmail: false))))
        XCTAssertEqual(model.valueText, "Not set")
        XCTAssertFalse(model.hasEmail)
        XCTAssertEqual(model.helpText,
                       "Used to reset your password if you forget it. This journal can't send email yet.")
    }

    @MainActor
    func test_olderJournal_hidesTheRow() async {
        let model = await loaded(FakeAccountEmail(.failure(JournalAPIError.notFound)))
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertFalse(model.isShown)
    }

    @MainActor
    func test_failedLoad_saysSo_andOffersNoEdit() async {
        let model = await loaded(FakeAccountEmail(.failure(JournalAPIError.transport("offline"))))
        XCTAssertTrue(model.isShown)
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(model.helpText, "Couldn't load your email address.")
    }

    @MainActor
    func test_aLaterFailedRefresh_keepsTheAddress() async {
        let fake = FakeAccountEmail(.success(AccountEmail(email: "alice@example.com", resetByEmail: true)))
        let model = await loaded(fake)
        fake.readResult = .failure(JournalAPIError.transport("offline"))
        await model.refresh()
        XCTAssertEqual(model.valueText, "alice@example.com")
    }

    // MARK: The form

    @MainActor
    func test_edit_startsFromTheAddress_andNeedsThePassword() async {
        let model = await loaded(FakeAccountEmail(.success(AccountEmail(email: "alice@example.com", resetByEmail: true))))
        model.beginEdit()
        XCTAssertEqual(model.email, "alice@example.com")
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.canRemove)
        model.password = "secret-pw"
        XCTAssertTrue(model.canSave)
        XCTAssertTrue(model.canRemove)
        model.email = "  "
        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func test_save_sendsTheTrimmedAddress_andShowsWhatWasStored() async {
        let fake = FakeAccountEmail(.success(AccountEmail(email: nil, resetByEmail: true)))
        fake.writeResult = .success("alice@example.com")
        let model = await loaded(fake)
        model.beginEdit()
        XCTAssertFalse(model.canRemove, "nothing to remove")
        model.email = " alice@example.com "
        model.password = "secret-pw"
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(fake.writes.first?.password, "secret-pw")
        XCTAssertEqual(fake.writes.first?.email, "alice@example.com")
        XCTAssertEqual(model.valueText, "alice@example.com")
        XCTAssertEqual(model.password, "", "the password is not kept")
        XCTAssertFalse(model.isSaving)
    }

    @MainActor
    func test_remove_sendsNull() async {
        let fake = FakeAccountEmail(.success(AccountEmail(email: "alice@example.com", resetByEmail: true)))
        fake.writeResult = .success(nil)
        let model = await loaded(fake)
        model.beginEdit()
        model.password = "secret-pw"
        let removed = await model.remove()
        XCTAssertTrue(removed)
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertNil(fake.writes.first?.email)
        XCTAssertEqual(model.valueText, "Not set")
    }

    @MainActor
    func test_errors_clearThePassword_andKeepTheAddress() async {
        let fake = FakeAccountEmail(.success(AccountEmail(email: nil, resetByEmail: true)))
        let model = await loaded(fake)
        let cases: [(Error, String)] = [
            (AccountEmailError.badPassword, "That password is incorrect."),
            (AccountEmailError.badEmail, "Enter a valid email address."),
            (AccountEmailError.emailTaken, "Another account already uses that address."),
            (JournalAPIError.lockedOut(retryAfterSeconds: 60), "Too many attempts. Try again in 1 minute."),
            (JournalAPIError.lockedOut(retryAfterSeconds: 150), "Too many attempts. Try again in 3 minutes."),
        ]
        for (error, message) in cases {
            fake.writeResult = .failure(error)
            model.beginEdit()
            model.email = "alice@example.com"
            model.password = "secret-pw"
            let saved = await model.save()
            XCTAssertFalse(saved)
            XCTAssertEqual(model.errorMessage, message)
            XCTAssertEqual(model.password, "")
            XCTAssertEqual(model.email, "alice@example.com")
            XCTAssertEqual(model.valueText, "Not set", "nothing changed")
        }
    }

    @MainActor
    func test_endEdit_dropsThePasswordAndTheError() async {
        let fake = FakeAccountEmail(.success(AccountEmail(email: nil, resetByEmail: true)))
        fake.writeResult = .failure(AccountEmailError.badEmail)
        let model = await loaded(fake)
        model.beginEdit()
        model.email = "not-an-address"
        model.password = "secret-pw"
        await model.save()
        model.password = "typed-again"
        model.endEdit()
        XCTAssertEqual(model.password, "")
        XCTAssertNil(model.errorMessage)
    }
}
