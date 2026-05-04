import XCTest

/// XCUITest scenario driver for the matron-vs-matron UI integration test
/// (iOS half — requester role).
///
/// Reads `/tmp/matron-test-config.json` like the Mac counterpart. Polls
/// `/tmp/matron-mac-ready` to gate sign-in until the Mac peer has
/// bootstrapped cross-signing, then drives sign-in → "Verify with another
/// device" → SAS confirm → wait for sheet dismissal as proxy for
/// `.verified`.
///
/// The /tmp file dance is the synchronization point with the Mac test;
/// see `tests/integration/scenarios/matron-vs-matron-ui.sh` for the
/// full orchestration.
final class MatronVsMatronIOSUITests: XCTestCase {

    var app: XCUIApplication!
    private var runStartedAt = Date()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        runStartedAt = Date()
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testRequestVerificationAgainstMacTrustAnchor() throws {
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

        // --- Wait for Mac peer to bootstrap ---
        guard waitForReadyFile(timeout: 90) else {
            throw XCTSkip("Mac peer never wrote /tmp/matron-mac-ready within 90s")
        }

        // --- Sign in ---
        let server = app.textFields["signin.server"]
        if !server.waitForExistence(timeout: 15) {
            failWithDiagnostics("sign-in form did not appear", screenshotName: "ios-signin-form-not-found")
            return
        }

        let username = app.textFields["signin.username"]
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(username.waitForExistence(timeout: 5), "username field missing")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "password field missing")

        pasteIntoTextField(server, value: homeserver, label: "server")
        pasteIntoTextField(username, value: user, label: "username")
        pasteIntoSecureField(passwordField, value: password, label: "password")

        let submit = app.buttons["signin.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "submit button missing")
        if !submit.isEnabled {
            failWithDiagnostics(
                "submit button still disabled after pasting all three fields",
                screenshotName: "ios-submit-disabled"
            )
            return
        }
        submit.tap()

        // --- Verify gate ---
        let verifyButton = app.buttons["verifygate.verifyWithOtherDevice"]
        if !verifyButton.waitForExistence(timeout: 30) {
            failWithDiagnostics(
                "verify gate didn't appear within 30s of sign-in",
                screenshotName: "ios-verify-gate-not-found"
            )
            return
        }
        verifyButton.tap()

        // --- SAS sheet → confirm ---
        let match = app.buttons["sas.match"]
        XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout),
                      "SAS emoji-compare screen never appeared (timeout: \(Int(verifyTimeout))s)")
        match.tap()

        // --- Wait for the sheet to dismiss as proxy for .verified ---
        let dismissed = NSPredicate(format: "exists == false")
        let dismissedExp = expectation(for: dismissed, evaluatedWith: match, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [dismissedExp], timeout: 30), .completed,
                       "SAS sheet did not dismiss after match — likely SAS didn't reach .verified")
    }

    // MARK: - Synchronization

    /// Polls for the Mac peer's ready signal at `/tmp/matron-mac-ready`.
    /// Rejects the file if its mtime predates this test run — guards
    /// against a stale signal from a prior failed run when the iOS test
    /// is invoked standalone (the harness wrapper wipes the file but
    /// standalone-iteration runs from Xcode UI may not).
    private func waitForReadyFile(timeout: TimeInterval) -> Bool {
        let path = "/tmp/matron-mac-ready"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime >= runStartedAt {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    // MARK: - Field helpers (iOS variants of the Mac helpers)

    private func pasteIntoTextField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
    }

    private func pasteIntoSecureField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
    }

    private func clickAndPaste(_ field: XCUIElement, value: String) {
        field.tap()
        usleep(250_000)  // let the field settle as first responder
        field.typeText(value)
        usleep(150_000)  // let the binding update propagate
    }

    // MARK: - Diagnostics

    private func failWithDiagnostics(_ message: String, screenshotName: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = screenshotName
        attachment.lifetime = .keepAlways
        add(attachment)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ios-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        try? app.debugDescription.write(toFile: "/tmp/matron-ios-debug.txt",
                                        atomically: true, encoding: .utf8)

        var fieldsSummary = ""
        for id in ["signin.server", "signin.username"] {
            let v = (app.textFields[id].value as? String) ?? "<not present>"
            fieldsSummary += "\(id) = \(v.debugDescription)\n"
        }
        fieldsSummary += "signin.submit.isEnabled = \(app.buttons["signin.submit"].isEnabled)\n"
        try? fieldsSummary.write(toFile: "/tmp/matron-ios-fields.txt",
                                 atomically: true, encoding: .utf8)

        XCTFail("\(message). See /tmp/matron-ios-debug.txt + /tmp/matron-ios-fields.txt and the test result bundle.")
    }
}
