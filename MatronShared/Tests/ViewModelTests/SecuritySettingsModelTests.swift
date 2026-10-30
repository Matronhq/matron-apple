import XCTest
import MatronJournal
@testable import MatronViewModels

private final class StubPassword: PasswordChanging, @unchecked Sendable {
    func changePassword(oldPassword: String, newPassword: String,
                        signOutOthers: Bool) async throws -> PasswordChangeResult {
        PasswordChangeResult(signedOut: 0)
    }
}

private final class StubEmail: AccountEmailProviding, @unchecked Sendable {
    func accountEmail() async throws -> AccountEmail { AccountEmail(email: "alice@example.com", resetByEmail: true) }
    func setAccountEmail(password: String, email: String?) async throws -> String? { email }
}

final class SecuritySettingsModelTests: XCTestCase {
    @MainActor
    private func model(twoFactor: FakeTwoFactorSettings = FakeTwoFactorSettings()) async -> SecuritySettingsModel {
        let model = SecuritySettingsModel(twoFactorAPI: twoFactor, passwordAPI: StubPassword(), emailAPI: StubEmail())
        await model.refresh()
        return model
    }

    @MainActor
    func test_refresh_readsTheAddressAndTheTwoFactorStatus() async {
        let model = await model()
        XCTAssertEqual(model.email?.valueText, "alice@example.com")
        XCTAssertEqual(model.twoFactor.actions, [.setUp])
        XCTAssertTrue(model.isShown)
    }

    @MainActor
    func test_eachRowOpensItsOwnSheet_oneAtATime() async {
        let model = await model()
        model.open(.email)
        XCTAssertEqual(model.sheet, .email)
        XCTAssertEqual(model.email?.email, "alice@example.com", "Edit starts from the address on file")
        model.open(.password)
        XCTAssertEqual(model.sheet, .password)
        model.open(.twoFactor(.setUp))
        XCTAssertEqual(model.sheet, .twoFactor(.setUp))
    }

    @MainActor
    func test_closingTheEmailSheet_dropsThePassword() async {
        let model = await model()
        model.open(.email)
        model.email?.password = "secret"
        model.close()
        XCTAssertNil(model.sheet)
        await model.sheetClosed()
        XCTAssertEqual(model.email?.password, "")
    }

    @MainActor
    func test_closingThePasswordSheet_dropsWhatWasTyped() async {
        let model = await model()
        model.open(.password)
        model.password?.currentPassword = "old-secret"
        model.close()
        await model.sheetClosed()
        XCTAssertEqual(model.password?.currentPassword, "")
    }

    @MainActor
    func test_closingATwoFactorSheet_rereadsTheStatus() async {
        let fake = FakeTwoFactorSettings()
        let model = await model(twoFactor: fake)
        model.open(.twoFactor(.setUp))
        fake.status = .success(TwoFactorStatus(enabled: true))
        model.close()
        await model.sheetClosed()
        XCTAssertTrue(model.twoFactor.actions.contains(.turnOff))
    }

    @MainActor
    func test_theTwoFactorFlow_isOwnedByTheModel_untilItsSheetCloses() async {
        let model = await model()
        model.open(.twoFactor(.setUp))
        let flow = model.twoFactorFlow
        XCTAssertEqual(flow?.action, .setUp)
        flow?.password = "secret"
        await flow?.submit()
        guard case .scan = model.twoFactorFlow?.step else { return XCTFail("the scan step after the password") }
        // A re-read of the status (as on coming back to the app) keeps the flow.
        await model.refresh()
        XCTAssertTrue(model.twoFactorFlow === flow, "the same flow, still on the scan step")
        guard case .scan = model.twoFactorFlow?.step else { return XCTFail("still the scan step") }
        model.close()
        await model.sheetClosed()
        XCTAssertNil(model.twoFactorFlow)
        model.open(.twoFactor(.setUp))
        XCTAssertFalse(model.twoFactorFlow === flow, "opening it again starts afresh")
        XCTAssertEqual(model.twoFactorFlow?.step, .confirm)
    }

    @MainActor
    func test_sheetIDs_areDistinct() {
        let sheets: [SecuritySettingsModel.Sheet] = [.email, .password, .twoFactor(.setUp), .twoFactor(.turnOff)]
        XCTAssertEqual(Set(sheets.map(\.id)).count, sheets.count)
    }
}
