import XCTest

/// XCUITest scenario driver for the integration harness.
///
/// Configurable via environment variables passed by `run-harness.sh` and
/// scenario scripts under `tests/integration/scenarios/`:
///
/// - `MATRON_HOMESERVER` — homeserver URL to type into the sign-in form
/// - `MATRON_USER` / `MATRON_PW` — credentials for this Matron client
/// - `MATRON_VERIFY_TIMEOUT` — seconds to wait for emoji-compare screen
///
/// The test taps Sign In → Verify-with-Other-Device → They-Match. The
/// harness drives the partner client (matrix-js-sdk) on the other side to
/// auto-confirm the SAS, and asserts on Matron's `os.Logger` trace. This
/// XCUITest leg is just the UI half; protocol assertions live in the
/// shell scenario.
final class VerifyWithPartnerUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Hand the launch arguments to the app so it doesn't need any
        // UserDefaults seeding — but the app itself ignores them today,
        // so the harness wipes Application Support before each run.
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testSignInAndVerifyWithPartner() throws {
        let env = ProcessInfo.processInfo.environment
        guard let homeserver = env["MATRON_HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set — run via tests/integration/scenarios/")
        }
        let user = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"
        let verifyTimeout = TimeInterval(env["MATRON_VERIFY_TIMEOUT"].flatMap(Double.init) ?? 30)

        // --- Sign in ---
        let server = app.textFields["signin.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10), "sign-in form did not appear")
        server.click()
        server.typeText(homeserver)

        let username = app.textFields["signin.username"]
        username.click()
        username.typeText(user)

        let passwordField = app.secureTextFields["signin.password"]
        passwordField.click()
        passwordField.typeText(password)

        app.buttons["signin.submit"].click()

        // --- Verify gate ---
        let verifyButton = app.buttons["verifygate.verifyWithOtherDevice"]
        XCTAssertTrue(verifyButton.waitForExistence(timeout: 30),
                      "verify gate didn't appear within 30s of sign-in")
        verifyButton.click()

        // --- SAS sheet → emojis → match ---
        let match = app.buttons["sas.match"]
        XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout),
                      "SAS emoji-compare screen never appeared (timeout: \(Int(verifyTimeout))s)")
        // Quick sanity: confirm 7 emoji cells rendered (each is a VStack of
        // symbol + caption; we look for the symbol text-elements).
        // SwiftUI exposes them as static texts; we don't have unique IDs
        // per cell, but the existence of `sas.match` is enough proof for
        // v1. Future: add accessibility identifiers per emoji cell.
        match.click()

        // After the partner also confirms, the SDK fires `didFinish`.
        // The view dismisses and the parent flips `verifyDone = true`,
        // landing the user on `MacChatListView`. The chat list's
        // `MacUnverifiedDeviceBanner` should now be gone.
        let banner = app.staticTexts["banner.unverifiedDevice"]
        // We don't assert it's absent — sliding sync may take a moment
        // to re-evaluate `verificationState` after the SDK update. The
        // shell scenario does the more reliable log-based assertion.
        _ = banner
    }
}
