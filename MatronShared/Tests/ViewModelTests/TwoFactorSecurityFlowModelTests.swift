import XCTest
import MatronJournal
@testable import MatronViewModels

/// Settings → Security's sheets: Set Up…, Change App…, New Recovery Codes…
/// and Turn Off…, against a fake of the `/2fa` routes.
final class TwoFactorSecurityFlowModelTests: XCTestCase {
    @MainActor
    func test_setUp_passwordThenScanThenRecoveryCodes() async {
        let fake = FakeTwoFactorSettings()
        fake.enable = .success(TwoFactorEnableResult(recoveryCodes: ["aaaa-bbbb-cccc-dddd"], signedOut: 2))
        let flow = TwoFactorSecurityFlowModel(action: .setUp, api: fake)
        XCTAssertEqual(flow.title, "Set Up Two-Factor")
        XCTAssertNil(flow.currentCodeLabel, "setting up needs only the password")
        XCTAssertFalse(flow.canSubmit)

        flow.password = "pw"
        XCTAssertEqual(flow.submitTitle, "Continue")
        await flow.submit()
        guard case .scan(let setup) = flow.step else { return XCTFail("expected the scan step, got \(flow.step)") }
        XCTAssertEqual(setup.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(flow.password, "", "the password is not kept once used")
        XCTAssertEqual(flow.submitTitle, "Turn On")

        flow.newCode = "12345"
        XCTAssertFalse(flow.canSubmit)
        flow.newCode = "123 456"
        flow.signOutOthers = true
        await flow.submit()
        XCTAssertEqual(flow.step, .recoveryCodes(["aaaa-bbbb-cccc-dddd"]))
        XCTAssertEqual(flow.successText, "Two-factor sign-in is on. Signed out 2 other devices.")
        XCTAssertEqual(fake.calls, ["setup pw -", "enable 123 456 true"])

        // The codes are shown once: Done and swiping away wait for the check.
        XCTAssertTrue(flow.blocksDismissal)
        XCTAssertFalse(flow.canSubmit)
        flow.savedCodes = true
        XCTAssertFalse(flow.blocksDismissal)
        await flow.submit()
        XCTAssertEqual(flow.step, .finished)
    }

    @MainActor
    func test_setUp_signingOutNoOne_saysOnlyThatItIsOn() async {
        let flow = TwoFactorSecurityFlowModel(action: .setUp, api: FakeTwoFactorSettings())
        flow.password = "pw"
        await flow.submit()
        flow.newCode = "123456"
        await flow.submit()
        XCTAssertEqual(flow.successText, "Two-factor sign-in is on.")
    }

    @MainActor
    func test_changeApp_sendsTheCurrentCode() async {
        let fake = FakeTwoFactorSettings()
        let flow = TwoFactorSecurityFlowModel(action: .changeApp, api: fake)
        XCTAssertEqual(flow.currentCodeLabel, "Code from your current app")
        flow.password = "pw"
        XCTAssertFalse(flow.canSubmit, "changing app needs a code from the current one")
        flow.currentCode = "abcd-efgh-ijkl-mnop"
        await flow.submit()
        flow.newCode = "654321"
        await flow.submit()
        XCTAssertEqual(fake.calls, ["setup pw abcd-efgh-ijkl-mnop", "enable 654321 false"])
        XCTAssertEqual(flow.successText, "Your new app is set up.")
    }

    @MainActor
    func test_wrongPassword_saysSo_andKeepsTheStep() async {
        let fake = FakeTwoFactorSettings()
        fake.setup = .failure(TwoFactorSettingsError.badPassword)
        let flow = TwoFactorSecurityFlowModel(action: .setUp, api: fake)
        flow.password = "wrong"
        await flow.submit()
        XCTAssertEqual(flow.step, .confirm)
        XCTAssertEqual(flow.error, "That password is incorrect.")
        XCTAssertFalse(flow.isBusy)
    }

    @MainActor
    func test_wrongFirstCode_clearsIt_andStaysOnTheScan() async {
        let fake = FakeTwoFactorSettings()
        fake.enable = .failure(TwoFactorSettingsError.badCode)
        let flow = TwoFactorSecurityFlowModel(action: .setUp, api: fake)
        flow.password = "pw"
        await flow.submit()
        flow.newCode = "000000"
        await flow.submit()
        guard case .scan = flow.step else { return XCTFail("expected to stay on the scan step") }
        XCTAssertEqual(flow.newCode, "")
        XCTAssertEqual(flow.error, "That code didn't work. Check your authenticator app and try again.")
    }

    @MainActor
    func test_expiredSetup_goesBackToThePassword() async {
        let fake = FakeTwoFactorSettings()
        fake.enable = .failure(TwoFactorSettingsError.noPendingSetup)
        let flow = TwoFactorSecurityFlowModel(action: .setUp, api: fake)
        flow.password = "pw"
        await flow.submit()
        flow.newCode = "123456"
        await flow.submit()
        XCTAssertEqual(flow.step, .confirm)
        XCTAssertEqual(flow.error, "That setup expired. Start again.")
    }

    @MainActor
    func test_newRecoveryCodes_needPasswordAndCode_thenShowTheNewSet() async {
        let fake = FakeTwoFactorSettings()
        let flow = TwoFactorSecurityFlowModel(action: .newRecoveryCodes, api: fake)
        XCTAssertEqual(flow.intro, "Your old recovery codes stop working as soon as the new set is made.")
        XCTAssertEqual(flow.submitTitle, "Make New Codes")
        flow.password = "pw"
        flow.currentCode = "12345"
        XCTAssertFalse(flow.canSubmit)
        flow.currentCode = "123456"
        await flow.submit()
        XCTAssertEqual(flow.step, .recoveryCodes(["iiii-jjjj-kkkk-llll"]))
        XCTAssertNil(flow.successText)
        XCTAssertEqual(fake.calls, ["recovery-codes pw 123456"])
    }

    @MainActor
    func test_turnOff_closesTheSheet() async {
        let fake = FakeTwoFactorSettings()
        let flow = TwoFactorSecurityFlowModel(action: .turnOff, api: fake)
        XCTAssertEqual(flow.submitTitle, "Turn Off")
        XCTAssertTrue(flow.isDestructive)
        flow.password = "pw"
        flow.currentCode = "123456"
        await flow.submit()
        XCTAssertEqual(flow.step, .finished)
        XCTAssertEqual(fake.calls, ["disable pw 123456"])
    }

    @MainActor
    func test_turnOffWhileRequired_saysWhy() async {
        let fake = FakeTwoFactorSettings()
        fake.disable = .failure(TwoFactorSettingsError.requiredByServer)
        let flow = TwoFactorSecurityFlowModel(action: .turnOff, api: fake)
        flow.password = "pw"
        flow.currentCode = "123456"
        await flow.submit()
        XCTAssertEqual(flow.step, .confirm)
        XCTAssertEqual(flow.error, "This server requires two-factor sign-in, so it can't be turned off.")
        XCTAssertEqual(flow.currentCode, "")
    }

    func test_codes() {
        XCTAssertTrue(TwoFactorSecurityFlowModel.isCode("123 456", allowsRecoveryCode: false))
        XCTAssertFalse(TwoFactorSecurityFlowModel.isCode("12345a", allowsRecoveryCode: false))
        XCTAssertFalse(TwoFactorSecurityFlowModel.isCode("abcd-efgh-ijkl-mnop", allowsRecoveryCode: false))
        XCTAssertTrue(TwoFactorSecurityFlowModel.isCode("abcd-efgh-ijkl-mnop", allowsRecoveryCode: true))
        XCTAssertFalse(TwoFactorSecurityFlowModel.isCode("abcd-efgh", allowsRecoveryCode: true))
    }
}
