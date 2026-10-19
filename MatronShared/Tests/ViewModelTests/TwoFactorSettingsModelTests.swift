import XCTest
import MatronJournal
@testable import MatronViewModels

private final class FakeTwoFactorStatus: TwoFactorStatusProviding, @unchecked Sendable {
    var result: Result<TwoFactorStatus, Error>
    init(_ result: Result<TwoFactorStatus, Error>) { self.result = result }
    func twoFactorStatus() async throws -> TwoFactorStatus { try result.get() }
}

final class TwoFactorSettingsModelTests: XCTestCase {
    @MainActor
    func test_on_showsOnWithRecoveryCodesLeft_andTheWebNote() async {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorStatus(
            .success(TwoFactorStatus(enabled: true, recoveryCodesLeft: 7))))
        await model.refresh()
        XCTAssertEqual(model.statusText, "On")
        XCTAssertEqual(model.detailText, "7 recovery codes left. Manage two-factor in Matron Web.")
        XCTAssertTrue(model.isShown)
    }

    @MainActor
    func test_off_showsOff() async {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorStatus(.success(TwoFactorStatus(enabled: false))))
        await model.refresh()
        XCTAssertEqual(model.statusText, "Off")
        XCTAssertEqual(model.detailText, TwoFactorSettingsModel.manageNote)
    }

    @MainActor
    func test_required_saysSo() async {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorStatus(
            .success(TwoFactorStatus(enabled: true, recoveryCodesLeft: 1, required: true))))
        await model.refresh()
        XCTAssertEqual(model.detailText,
                       "1 recovery code left. This server requires two-factor for everyone. Manage two-factor in Matron Web.")
    }

    @MainActor
    func test_journalWithoutTheRoute_hidesTheSection() async {
        let model = TwoFactorSettingsModel(api: FakeTwoFactorStatus(.failure(JournalAPIError.notFound)))
        await model.refresh()
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertFalse(model.isShown)
    }

    @MainActor
    func test_failedRefresh_keepsTheLastStatus() async {
        let fake = FakeTwoFactorStatus(.success(TwoFactorStatus(enabled: true)))
        let model = TwoFactorSettingsModel(api: fake)
        await model.refresh()
        fake.result = .failure(JournalAPIError.transport("offline"))
        await model.refresh()
        XCTAssertEqual(model.statusText, "On")
    }

    func test_setupKey_isGroupedInFours() {
        XCTAssertEqual(TwoFactorSecretFormat.grouped("JBSWY3DPEHPK3PXP"), "JBSW Y3DP EHPK 3PXP")
        XCTAssertEqual(TwoFactorSecretFormat.grouped("ABCDEF"), "ABCD EF")
    }
}
