import XCTest
@testable import MatronJournal

/// The `/settings` contract: `GET` → `{notices}`, `PATCH {notices}` →
/// `{notices}`, the `{kind:"control", op:"settings", settings}` live frame,
/// and `true` for anything the journal leaves out.
final class UserSettingsTests: XCTestCase {
    private func makeStubbedAPI(status: Int = 200, body: [String: Any]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    func testGetDecodesTheSettings() async throws {
        let settings = try await makeStubbedAPI(body: ["notices": false]).userSettings()
        XCTAssertEqual(settings, UserSettings(notices: false))
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/settings")
    }

    func testPatchSendsNoticesAndDecodesTheAnswer() async throws {
        let settings = try await makeStubbedAPI(body: ["notices": true]).updateUserSettings(notices: true)
        XCTAssertEqual(settings.notices, true)
        let request = try XCTUnwrap(ItemsStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/settings")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(sent as NSDictionary, ["notices": true] as NSDictionary)
    }

    func testNoticesDefaultsToOn() {
        XCTAssertEqual(UserSettings.decode([String: Any]())?.notices, true, "a missing key reads as the default")
        XCTAssertEqual(UserSettings.decode(["notices": "yes"])?.notices, true, "so does a malformed one")
        XCTAssertEqual(UserSettings.decode(["notices": false])?.notices, false)
        XCTAssertNil(UserSettings.decode(nil))
        XCTAssertNil(UserSettings.decode("notices"))
        XCTAssertEqual(UserSettings.defaults.notices, true)
    }

    /// A journal predating the route: the settings screens hide the switch.
    func testOldJournalIsNotFound() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).userSettings()
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }

    func testDecodesSettingsControlFrame() {
        let frame = ServerFrame.decode(#"{"kind":"control","op":"settings","settings":{"notices":false}}"#)
        guard case .settings(let settings) = frame else {
            return XCTFail("expected a settings frame, got \(String(describing: frame))")
        }
        XCTAssertEqual(settings, UserSettings(notices: false))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"control","op":"settings"}"#), "no settings object: skipped")
    }
}
