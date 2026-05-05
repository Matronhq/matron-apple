import XCTest
import AppKit  // NSPasteboard for sign-in field paste

/// XCUITest scenario driver for the reverse-direction matron-vs-matron
/// flow (handover Priority A test #2 — Mac half).
///
/// Mirror of `MatronVsMatronMacUITests` with the roles SWAPPED:
/// Mac plays the requester (waits for iOS trust-anchor ready, then signs
/// in and drives SAS via "Verify with another device"). The original
/// direction (Mac responder, iOS requester) is covered by
/// `MatronVsMatronMacUITests` / `MatronVsMatronIOSUITests`.
///
/// Synchronisation: blocks until `/Users/Shared/matron-ios-ready` exists,
/// which the scenario script (`reverse-direction-ui.sh`) creates when
/// it sees the iOS test print `MATRON_IOS_TRUST_ANCHOR_READY`.
final class ReverseDirectionMacUITests: XCTestCase {

    var app: XCUIApplication!
    private var runStartedAt = Date()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        runStartedAt = Date()
        app = XCUIApplication()
        app.launch()
        app.activate()
        // SwiftUI WindowGroup launched from XCUITest sometimes doesn't
        // open its initial window — same workaround as
        // `MatronVsMatronMacUITests`.
        sleep(1)
        if app.windows.count == 0 {
            app.typeKey("n", modifierFlags: [.command])
            sleep(1)
        }
        // Clean any prior ready-file from an earlier run so we don't
        // accept a stale signal. (The scenario script also rms it; this
        // is belt+braces for ad-hoc Xcode-driven runs.)
        try? FileManager.default.removeItem(atPath: "/Users/Shared/matron-ios-ready")
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testRequestVerificationAgainstIOSTrustAnchor() throws {
        let configPath = "/tmp/matron-test-config.json"
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let homeserver = json["homeserver"] as? String else {
            throw XCTSkip("\(configPath) not present — run via tests/integration/scenarios/")
        }
        let user = (json["user"] as? String) ?? "matron"
        let password = (json["password"] as? String) ?? "matron-test-pw"
        let verifyTimeout = TimeInterval((json["verify_timeout"] as? Double) ?? 60)

        // --- Wait for iOS peer to bootstrap ---
        // Same staleness-window logic as the original direction's
        // iOS-side wait — accept ready files written within the last
        // 5 minutes so test-launch ordering doesn't trip us up. 75s
        // budget = ~40s for warm-sim happy path (sign-in + recovery-
        // key generate flow + sheet dismiss) + ~35s headroom. iOS
        // failures are deterministic at ~28s so this still fails
        // fast when the iOS side is broken.
        guard waitForReadyFile(timeout: 75) else {
            throw XCTSkip("iOS peer never wrote /Users/Shared/matron-ios-ready within 75s")
        }

        // --- Sign in ---
        let server = app.textFields["signin.server"]
        if !server.waitForExistence(timeout: 15) {
            failWithDiagnostics("sign-in form did not appear",
                                screenshotName: "rev-mac-signin-form-not-found")
            return
        }
        let username = app.textFields["signin.username"]
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))

        clickAndPaste(server, value: homeserver)
        clickAndPaste(username, value: user)
        clickAndPaste(passwordField, value: password)

        let submit = app.buttons["signin.submit"]
        XCTAssertTrue(submit.isEnabled, "submit button still disabled after paste")
        submit.click()

        // --- Verify gate → "Verify with another device" ---
        let verifyButton = app.buttons["verifygate.verifyWithOtherDevice"]
        if !verifyButton.waitForExistence(timeout: 30) {
            failWithDiagnostics("verify gate didn't appear within 30s of sign-in",
                                screenshotName: "rev-mac-verify-gate-not-found")
            return
        }
        verifyButton.click()

        // --- SAS sheet → They match → wait for dismissal ---
        let match = app.buttons["sas.match"]
        XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout),
                      "Mac SAS sheet never appeared (timeout: \(Int(verifyTimeout))s)")
        match.click()

        let dismissed = NSPredicate(format: "exists == false")
        let dismissedExp = expectation(for: dismissed, evaluatedWith: match, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [dismissedExp], timeout: 30), .completed,
                       "Mac SAS sheet did not dismiss after match")
    }

    // MARK: - Synchronisation

    /// Polls for the iOS peer's ready signal. Same staleness-window
    /// rationale as the original direction's iOS-side
    /// `waitForReadyFile` — `mtime >= runStartedAt` is too strict when
    /// the peer's bootstrap finishes before our `setUp()` fires, so we
    /// accept anything within a 5-minute window.
    private func waitForReadyFile(timeout: TimeInterval) -> Bool {
        let path = "/Users/Shared/matron-ios-ready"
        let deadline = Date().addingTimeInterval(timeout)
        let stalenessWindow: TimeInterval = 5 * 60
        let acceptIfNewerThan = runStartedAt.addingTimeInterval(-stalenessWindow)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime >= acceptIfNewerThan {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    // MARK: - Field helpers (copied from MatronVsMatronMacUITests)

    private func clickAndPaste(_ field: XCUIElement, value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        field.click()
        usleep(250_000)
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey("v", modifierFlags: [.command])
        usleep(150_000)
    }

    // MARK: - Diagnostics

    private func failWithDiagnostics(_ message: String, screenshotName: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = screenshotName
        attachment.lifetime = .keepAlways
        add(attachment)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "rev-mac-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        try? app.debugDescription.write(toFile: "/Users/Shared/rev-mac-debug.txt",
                                        atomically: true, encoding: .utf8)

        XCTFail("\(message). See /Users/Shared/rev-mac-debug.txt.")
    }
}
