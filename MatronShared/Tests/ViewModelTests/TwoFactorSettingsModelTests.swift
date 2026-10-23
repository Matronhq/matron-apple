import XCTest
import MatronJournal
@testable import MatronViewModels

/// A fake of the `/2fa` routes. Each call is recorded so the flow tests can
/// check what was sent.
final class FakeTwoFactorSettings: TwoFactorSettingsProviding, @unchecked Sendable {
    var status: Result<TwoFactorStatus, Error>
    var setup: Result<TwoFactorSetup, Error> = .success(
        TwoFactorSetup(secret: "JBSWY3DPEHPK3PXP", otpauthURI: "otpauth://totp/Matron:alice@example.com?secret=JBSWY3DPEHPK3PXP",
                       issuer: "Matron", account: "alice@example.com"))
    var enable: Result<TwoFactorEnableResult, Error> = .success(
        TwoFactorEnableResult(recoveryCodes: ["aaaa-bbbb-cccc-dddd", "eeee-ffff-gggg-hhhh"], signedOut: 0))
    var recoveryCodes: Result<[String], Error> = .success(["iiii-jjjj-kkkk-llll"])
    var disable: Result<Void, Error> = .success(())
    private(set) var calls: [String] = []

    init(_ status: Result<TwoFactorStatus, Error> = .success(TwoFactorStatus(enabled: false))) {
        self.status = status
    }

    func twoFactorStatus() async throws -> TwoFactorStatus { try status.get() }
    func beginTwoFactorSetup(password: String, code: String?) async throws -> TwoFactorSetup {
        calls.append("setup \(password) \(code ?? "-")")
        return try setup.get()
    }
    func enableTwoFactor(code: String, signOutOthers: Bool) async throws -> TwoFactorEnableResult {
        calls.append("enable \(code) \(signOutOthers)")
        return try enable.get()
    }
    func newTwoFactorRecoveryCodes(password: String, code: String) async throws -> [String] {
        calls.append("recovery-codes \(password) \(code)")
        return try recoveryCodes.get()
    }
    func disableTwoFactor(password: String, code: String) async throws {
        calls.append("disable \(password) \(code)")
        try disable.get()
    }
}

final class TwoFactorSettingsModelTests: XCTestCase {
    @MainActor
    private func model(_ status: TwoFactorStatus) async -> TwoFactorSettingsModel {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorSettings(.success(status)),
                                           locale: Locale(identifier: "en_GB"),
                                           timeZone: TimeZone(identifier: "UTC")!)
        await model.refresh()
        return model
    }

    @MainActor
    func test_on_showsTheDateAndRecoveryCodesLeft_andItsButtons() async {
        // 3 Oct 2026, 12:00 UTC.
        let model = await model(TwoFactorStatus(enabled: true, enabledAt: 1_791_028_800_000, recoveryCodesLeft: 7))
        XCTAssertEqual(model.statusText, "On")
        XCTAssertEqual(model.detailText, "On since 3 Oct 2026 · 7 recovery codes left")
        XCTAssertEqual(model.actions, [.newRecoveryCodes, .changeApp, .turnOff])
        XCTAssertFalse(model.showsLowRecoveryCodesWarning)
        XCTAssertNil(model.footerText)
        XCTAssertTrue(model.isShown)
    }

    @MainActor
    func test_off_offersSetUp() async {
        let model = await model(TwoFactorStatus(enabled: false))
        XCTAssertEqual(model.statusText, "Off")
        XCTAssertEqual(model.detailText, "Off. Signing in takes only your password.")
        XCTAssertEqual(model.actions, [.setUp])
        XCTAssertEqual(TwoFactorSettingsModel.title(for: .setUp), "Set Up…")
    }

    @MainActor
    func test_serverThatCannotStoreSecrets_offersNothing() async {
        let model = await model(TwoFactorStatus(enabled: false, available: false))
        XCTAssertEqual(model.detailText, "This server isn't set up for two-factor sign-in.")
        XCTAssertEqual(model.actions, [])
    }

    @MainActor
    func test_required_hidesTurnOff_andSaysSo() async {
        let model = await model(TwoFactorStatus(enabled: true, recoveryCodesLeft: 1, required: true))
        XCTAssertEqual(model.detailText, "1 recovery code left")
        XCTAssertEqual(model.actions, [.newRecoveryCodes, .changeApp])
        XCTAssertEqual(model.footerText, "This server requires two-factor sign-in for everyone.")
    }

    @MainActor
    func test_fewerThanThreeCodesLeft_warns() async {
        let low = await model(TwoFactorStatus(enabled: true, recoveryCodesLeft: 2))
        XCTAssertTrue(low.showsLowRecoveryCodesWarning)
        let enough = await model(TwoFactorStatus(enabled: true, recoveryCodesLeft: 3))
        XCTAssertFalse(enough.showsLowRecoveryCodesWarning)
    }

    @MainActor
    func test_journalWithoutTheRoute_hidesTheSection() async {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorSettings(.failure(JournalAPIError.notFound)))
        await model.refresh()
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertFalse(model.isShown)
    }

    @MainActor
    func test_failedFirstLoad_saysWhy_andOffersNothing() async {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorSettings(.failure(JournalAPIError.transport(""))))
        await model.refresh()
        XCTAssertEqual(model.footerText, "Couldn't load two-factor settings: Couldn't reach the server.")
        XCTAssertEqual(model.actions, [])
    }

    @MainActor
    func test_failedRefresh_keepsTheLastStatus_markedStale() async {
        let fake = FakeTwoFactorSettings(.success(TwoFactorStatus(enabled: true)))
        let model = TwoFactorSettingsModel(api: fake)
        await model.refresh()
        fake.status = .failure(JournalAPIError.transport("offline"))
        await model.refresh()
        XCTAssertEqual(model.statusText, "On")
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.footerText, "Couldn't check for changes, so this may be out of date.")

        fake.status = .success(TwoFactorStatus(enabled: false))
        await model.refresh()
        XCTAssertFalse(model.isStale)
        XCTAssertEqual(model.statusText, "Off")
    }

    func test_setupKey_isGroupedInFours() {
        XCTAssertEqual(TwoFactorSecretFormat.grouped("JBSWY3DPEHPK3PXP"), "JBSW Y3DP EHPK 3PXP")
        XCTAssertEqual(TwoFactorSecretFormat.grouped("ABCDEF"), "ABCD EF")
    }
}
