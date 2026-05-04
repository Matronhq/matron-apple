import XCTest
import AppKit  // NSPasteboard for reliable URL pasting

/// XCUITest scenario driver for the integration harness.
///
/// Configurable via `/tmp/matron-test-config.json`, written by the harness
/// before launch (env vars don't propagate cleanly to Mac UI test runners,
/// even with `TEST_RUNNER_*` prefixes). Format:
///
///     { "homeserver": "http://localhost:6167",
///       "user": "matron", "password": "matron-test-pw",
///       "verify_timeout": 60 }
///
/// The test taps Sign In → Verify-with-Other-Device → They-Match. The
/// harness drives the partner client (matrix-js-sdk, running as a second
/// device of @matron) on the other side to auto-confirm the SAS, and
/// asserts on Matron's `os.Logger` trace. This XCUITest leg is just the
/// UI half; protocol assertions live in the shell scenario.
///
/// Form-fill diagnostics: each paste reads back the field value and
/// dumps both the readback and a screenshot if it doesn't match what we
/// pasted. The previous diagnosis (binding-update-on-paste failing
/// across Tab navigation) was wrong — the live attempt got "Invalid
/// credentials" back from the homeserver, which means all three fields
/// had content but one of them was wrong. The readback identifies
/// which field is wrong instead of guessing.
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
            failWithDiagnostics("sign-in form did not appear", screenshotName: "signin-form-not-found")
            return
        }

        // Switched from Tab-based to click-based field focus. The previous
        // version used Tab between fields and got "Invalid credentials" from
        // the server — meaning all fields had content but one was wrong. The
        // most plausible cause: Tab on macOS without explicit `@FocusState`
        // doesn't reliably move between SwiftUI TextFields, so the second or
        // third paste was landing in the previous field, overwriting its
        // value and leaving a field empty (or doubled). Clicking each field
        // directly removes that ambiguity.
        let username = app.textFields["signin.username"]
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(username.waitForExistence(timeout: 5), "username field missing")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "password field missing")

        pasteIntoTextField(server, value: homeserver, label: "server")
        pasteIntoTextField(username, value: user, label: "username")
        pasteIntoSecureField(passwordField, value: password, label: "password")

        // Submit-enabled is the last sanity check — `.disabled` on the
        // button checks `serverURL.isEmpty || username.isEmpty || password.isEmpty`,
        // so an enabled button proves all three fields have content.
        let submit = app.buttons["signin.submit"]
        if !submit.isEnabled {
            failWithDiagnostics(
                "submit button still disabled after pasting all three fields — at least one is empty",
                screenshotName: "submit-disabled"
            )
            return
        }
        submit.click()

        // --- Verify gate ---
        let verifyButton = app.buttons["verifygate.verifyWithOtherDevice"]
        if !verifyButton.waitForExistence(timeout: 30) {
            // Surface the in-form error text, if any, so we don't have to
            // guess whether the homeserver rejected us.
            let errorText = inFormErrorMessage()
            failWithDiagnostics(
                "verify gate didn't appear within 30s of sign-in. In-form error: \(errorText ?? "<none>")",
                screenshotName: "verify-gate-not-found"
            )
            return
        }
        verifyButton.click()

        // --- SAS sheet → emojis → match ---
        let match = app.buttons["sas.match"]
        XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout),
                      "SAS emoji-compare screen never appeared (timeout: \(Int(verifyTimeout))s)")
        match.click()

        // After the partner also confirms, the SDK fires `didFinish`. The
        // view dismisses and the parent flips `verifyDone = true`, landing
        // on `MacChatListView`. Don't assert on the unverified-banner being
        // gone here — sliding sync may take a moment to re-evaluate
        // `verificationState` after the SDK update; the shell scenario does
        // the more reliable log-based assertion.
        _ = app.staticTexts["banner.unverifiedDevice"]
    }

    // MARK: - Field helpers

    /// Clicks the field, selects-all, pastes the clipboard, reads back the
    /// field's value, and fails (with diagnostics) on mismatch.
    private func pasteIntoTextField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
        let actual = (field.value as? String) ?? ""
        if actual != value {
            failWithDiagnostics(
                "\(label) field readback mismatch — expected \(value.debugDescription), got \(actual.debugDescription)",
                screenshotName: "field-mismatch-\(label)"
            )
        }
    }

    /// Same as `pasteIntoTextField` but for SecureField. SecureField's
    /// `value` on macOS doesn't reliably return the typed string (some
    /// macOS versions return an obfuscated bullet string of the right
    /// length, others return empty). We can't readback exactly, so the
    /// real check happens via the submit button's `.isEnabled` state in
    /// the caller.
    private func pasteIntoSecureField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
        // Best-effort length check: if the SecureField returns bullets, the
        // count should match. If it returns "" we silently skip — caller
        // checks submit-enabled.
        if let visible = field.value as? String, !visible.isEmpty, visible.count != value.count {
            failWithDiagnostics(
                "\(label) field length mismatch — expected \(value.count) chars, got \(visible.count) (\"\(visible)\")",
                screenshotName: "field-length-\(label)"
            )
        }
    }

    private func clickAndPaste(_ field: XCUIElement, value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        field.click()
        usleep(250_000)  // let the field settle as first responder
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey("v", modifierFlags: [.command])
        usleep(150_000)  // let the binding update propagate
    }

    /// Best-effort scrape of the form's red error text, used when the
    /// verify gate fails to appear so we know whether the homeserver
    /// rejected us. Matches whatever `SignInViewModel.message(for:)`
    /// produced — currently one of "Invalid credentials.",
    /// "Couldn't reach that server.", "SSO is not supported by this server.",
    /// or "That doesn't look like a valid server URL.".
    private func inFormErrorMessage() -> String? {
        let candidates = [
            "Invalid credentials.",
            "Couldn't reach that server.",
            "SSO is not supported by this server.",
            "That doesn't look like a valid server URL.",
        ]
        for needle in candidates {
            if app.staticTexts[needle].exists { return needle }
        }
        // Fallback — any static text under the form that starts with
        // "Unexpected error:".
        for st in app.staticTexts.allElementsBoundByIndex {
            if let s = st.value as? String, s.hasPrefix("Unexpected error:") { return s }
            if st.label.hasPrefix("Unexpected error:") { return st.label }
        }
        return nil
    }

    // MARK: - Diagnostics

    private func failWithDiagnostics(_ message: String, screenshotName: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = screenshotName
        attachment.lifetime = .keepAlways
        add(attachment)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        // Mirror the tree to /tmp so iteration without xcresult parsing works.
        try? app.debugDescription.write(toFile: "/tmp/matron-test-debug.txt",
                                        atomically: true, encoding: .utf8)

        // Snapshot field readbacks too, so the next iteration sees what was
        // actually in each field at the moment of failure.
        var fieldsSummary = ""
        for id in ["signin.server", "signin.username"] {
            let v = (app.textFields[id].value as? String) ?? "<not present>"
            fieldsSummary += "\(id) = \(v.debugDescription)\n"
        }
        if let pw = app.secureTextFields["signin.password"].value as? String {
            fieldsSummary += "signin.password.value = \(pw.debugDescription) (count=\(pw.count))\n"
        }
        fieldsSummary += "signin.submit.isEnabled = \(app.buttons["signin.submit"].isEnabled)\n"
        let fieldsAttachment = XCTAttachment(string: fieldsSummary)
        fieldsAttachment.name = "field-readbacks"
        fieldsAttachment.lifetime = .keepAlways
        add(fieldsAttachment)
        try? fieldsSummary.write(toFile: "/tmp/matron-test-fields.txt",
                                 atomically: true, encoding: .utf8)

        XCTFail("\(message). See /tmp/matron-test-debug.txt + /tmp/matron-test-fields.txt and the test result bundle.")
    }
}
