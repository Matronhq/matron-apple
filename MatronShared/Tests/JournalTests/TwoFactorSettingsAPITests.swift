import XCTest
@testable import MatronJournal

/// Settings → Security's routes (journal protocol "Two-factor sign-in",
/// Settings): what each sends, and how their own errors map.
final class TwoFactorSettingsAPITests: XCTestCase {
    private func makeStubbedAPI(status: Int, body: String) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = Data(body.utf8)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private var sent: [String: AnyHashable] {
        let data = ItemsStubURLProtocol.lastBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: AnyHashable] ?? [:]
    }

    private var path: String? { ItemsStubURLProtocol.lastRequest?.url?.path }

    func testSetupSendsThePassword_andTheCodeOnlyWhenGiven() async throws {
        let api = makeStubbedAPI(status: 200, body: #"{"secret":"JBSWY3DPEHPK3PXP","otpauth_uri":"otpauth://totp/x","issuer":"Matron","account":"alice@example.com"}"#)
        let setup = try await api.beginTwoFactorSetup(password: "pw", code: nil)
        XCTAssertEqual(path, "/2fa/setup")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(sent, ["password": "pw"])
        XCTAssertEqual(setup, TwoFactorSetup(secret: "JBSWY3DPEHPK3PXP", otpauthURI: "otpauth://totp/x",
                                             issuer: "Matron", account: "alice@example.com"))

        _ = try await api.beginTwoFactorSetup(password: "pw", code: "123456")
        XCTAssertEqual(sent, ["password": "pw", "code": "123456"])
    }

    func testEnableSendsSignOutOthers_andReadsTheCodes() async throws {
        let api = makeStubbedAPI(status: 200, body: #"{"recovery_codes":["aaaa-bbbb-cccc-dddd"],"signed_out":3}"#)
        let result = try await api.enableTwoFactor(code: "123456", signOutOthers: true)
        XCTAssertEqual(path, "/2fa/enable")
        XCTAssertEqual(sent, ["code": "123456", "sign_out_others": true])
        XCTAssertEqual(result, TwoFactorEnableResult(recoveryCodes: ["aaaa-bbbb-cccc-dddd"], signedOut: 3))
    }

    func testNewRecoveryCodesAndDisable() async throws {
        var api = makeStubbedAPI(status: 200, body: #"{"recovery_codes":["iiii-jjjj-kkkk-llll"]}"#)
        let codes = try await api.newTwoFactorRecoveryCodes(password: "pw", code: "123456")
        XCTAssertEqual(path, "/2fa/recovery-codes")
        XCTAssertEqual(sent, ["password": "pw", "code": "123456"])
        XCTAssertEqual(codes, ["iiii-jjjj-kkkk-llll"])

        api = makeStubbedAPI(status: 200, body: #"{"ok":true}"#)
        try await api.disableTwoFactor(password: "pw", code: "123456")
        XCTAssertEqual(path, "/2fa/disable")
    }

    func testErrorsMap() async {
        let cases: [(Int, String, Error)] = [
            (401, #"{"error":"bad_password"}"#, TwoFactorSettingsError.badPassword),
            (403, #"{"error":"bad_code"}"#, TwoFactorSettingsError.badCode),
            (409, #"{"error":"no_pending_setup"}"#, TwoFactorSettingsError.noPendingSetup),
            (409, #"{"error":"not_enabled"}"#, TwoFactorSettingsError.notEnabled),
            (409, #"{"error":"two_factor_required"}"#, TwoFactorSettingsError.requiredByServer),
            (503, #"{"error":"two_factor_unavailable"}"#, TwoFactorSettingsError.unavailable),
            (429, #"{"error":"locked_out","retry_after":30}"#, JournalAPIError.lockedOut(retryAfterSeconds: 30)),
            (401, #"{"error":"unauthenticated"}"#, JournalAPIError.unauthenticated),
        ]
        for (status, body, expected) in cases {
            let api = makeStubbedAPI(status: status, body: body)
            do {
                try await api.disableTwoFactor(password: "pw", code: "123456")
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription, body)
                XCTAssertEqual(String(describing: error), String(describing: expected), body)
            }
        }
    }
}
