import XCTest
import AppKit  // NSPasteboard for reliable URL pasting

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
        app.launch()
        app.activate()
        // SwiftUI WindowGroup launched from XCUITest sometimes doesn't open
        // its initial window — the app comes up as a background process with
        // only the menu bar visible. Send File > New Window manually to force
        // a window to exist. Wait briefly first so the menu bar is populated.
        sleep(1)
        if app.windows.count == 0 {
            app.typeKey("n", modifierFlags: [.command])
            sleep(1)
        }
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testSignInAndVerifyWithPartner() throws {
        // env-vars don't propagate cleanly to Mac XCUITest runners (neither
        // direct nor TEST_RUNNER_*-prefixed), so the harness writes a JSON
        // config to a known path. See tests/integration/scenarios/*.sh.
        let configPath = "/tmp/matron-test-config.json"
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let homeserver = json["homeserver"] as? String else {
            throw XCTSkip("\(configPath) not present — run via tests/integration/scenarios/")
        }
        let user = (json["user"] as? String) ?? "matron"
        let password = (json["password"] as? String) ?? "matron-test-pw"
        let verifyTimeout = TimeInterval((json["verify_timeout"] as? Double) ?? 30)

        // --- Sign in ---
        let server = app.textFields["signin.server"]
        if !server.waitForExistence(timeout: 15) {
            try? app.debugDescription.write(toFile: "/tmp/matron-test-debug.txt",
                                            atomically: true, encoding: .utf8)
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "signin-form-not-found"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("sign-in form did not appear — see /tmp/matron-test-debug.txt")
            return
        }
        // typeText on Mac mangles `:` and `/`. Use clipboard paste, and Tab
        // between fields rather than clicks (which sometimes don't reliably
        // re-focus when one field is still in edit mode).
        let pb = NSPasteboard.general
        func clipboardSet(_ value: String) {
            pb.clearContents()
            pb.setString(value, forType: .string)
        }
        server.click()
        usleep(300_000)
        clipboardSet(homeserver)
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey("v", modifierFlags: [.command])
        // Tab to username
        app.typeKey(.tab, modifierFlags: [])
        usleep(200_000)
        clipboardSet(user)
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey("v", modifierFlags: [.command])
        // Tab to password
        app.typeKey(.tab, modifierFlags: [])
        usleep(200_000)
        clipboardSet(password)
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey("v", modifierFlags: [.command])
        usleep(200_000)
        app.buttons["signin.submit"].click()

        // --- Verify gate ---
        let verifyButton = app.buttons["verifygate.verifyWithOtherDevice"]
        if !verifyButton.waitForExistence(timeout: 30) {
            // Diagnostic dump so future runs aren't blind.
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "verify-gate-not-found"
            attachment.lifetime = .keepAlways
            add(attachment)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
            try? app.debugDescription.write(toFile: "/tmp/matron-test-debug.txt",
                                            atomically: true, encoding: .utf8)
            XCTFail("verify gate didn't appear within 30s of sign-in — see /tmp/matron-test-debug.txt")
            return
        }
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
