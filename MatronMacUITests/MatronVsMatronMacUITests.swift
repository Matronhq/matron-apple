import XCTest
import AppKit  // NSPasteboard for reliable URL pasting

/// XCUITest scenario driver for the matron-vs-matron UI integration test
/// (Mac half — trust-anchor responder role).
///
/// Reads `/tmp/matron-test-config.json` like `VerifyWithPartnerUITests`.
/// Drives:
///   1. Sign in (new user, fresh homeserver)
///   2. Verify gate → "This is my first device — generate a key"
///   3. RecoveryKeyView .notStarted → tap Generate
///   4. RecoveryKeyView .show → Copy + acknowledge + Continue
///   5. RecoveryKeyView .reenter → Paste → PasteDetector matches → auto-advances
///      to .confirmed → 600ms auto-dismiss → onFinished → chat list visible
///   6. Write `/tmp/matron-mac-ready` (signals iOS to sign in)
///   7. Wait up to 120s for incoming-verify banner from iOS peer
///   8. Tap Verify on banner → MacSasView sheet → "They match"
///   9. Wait for sheet dismissal as proxy for .verified
final class MatronVsMatronMacUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        app.activate()
        // SwiftUI WindowGroup launched from XCUITest sometimes doesn't open
        // its initial window — same workaround as VerifyWithPartnerUITests.
        sleep(1)
        if app.windows.count == 0 {
            app.typeKey("n", modifierFlags: [.command])
            sleep(1)
        }
        // Clean any prior ready-file from an earlier run so the iOS peer
        // doesn't see a stale signal.
        try? FileManager.default.removeItem(atPath: "/tmp/matron-mac-ready")
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testTrustAnchorAcceptsIncomingFromIOSPeer() throws {
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

        // --- Sign in ---
        let server = app.textFields["signin.server"]
        if !server.waitForExistence(timeout: 15) {
            failWithDiagnostics("sign-in form did not appear", screenshotName: "mac-signin-form-not-found")
            return
        }
        let username = app.textFields["signin.username"]
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))

        pasteIntoTextField(server, value: homeserver, label: "server")
        pasteIntoTextField(username, value: user, label: "username")
        pasteIntoSecureField(passwordField, value: password, label: "password")

        let submit = app.buttons["signin.submit"]
        XCTAssertTrue(submit.isEnabled, "submit button still disabled after paste")
        submit.click()

        // --- Verify gate → "This is my first device — generate a key" ---
        let generateNew = app.buttons["verifygate.generateNew"]
        if !generateNew.waitForExistence(timeout: 30) {
            failWithDiagnostics(
                "verify gate didn't appear within 30s",
                screenshotName: "mac-verify-gate-not-found"
            )
            return
        }
        generateNew.click()

        // --- RecoveryKeyView .notStarted → tap Generate ---
        let generateRecoveryKey = app.buttons["recoverykey.generate"]
        XCTAssertTrue(generateRecoveryKey.waitForExistence(timeout: 10),
                      "Generate recovery key button didn't appear")
        generateRecoveryKey.click()

        // --- .show phase: Copy → toggle → Continue ---
        let copyButton = app.buttons["recoverykey.copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 15),
                      "Recovery key Copy button didn't appear after Generate")
        copyButton.click()
        // NSPasteboard now holds the recovery key — used in .reenter via the Paste button.

        // SwiftUI Toggle on macOS may expose as `checkBoxes` or `switches`
        // depending on the macOS version's accessibility classification.
        // Try both.
        let ackToggleCheck = app.checkBoxes["recoverykey.acknowledgeSaved"]
        let ackToggleSwitch = app.switches["recoverykey.acknowledgeSaved"]
        if ackToggleCheck.waitForExistence(timeout: 5) {
            ackToggleCheck.click()
        } else if ackToggleSwitch.waitForExistence(timeout: 5) {
            ackToggleSwitch.click()
        } else {
            failWithDiagnostics(
                "Acknowledge-saved toggle missing under both `checkBoxes` and `switches`",
                screenshotName: "mac-ack-toggle-not-found"
            )
            return
        }

        let continueBtn = app.buttons["recoverykey.continue"]
        XCTAssertTrue(continueBtn.waitForExistence(timeout: 5))
        // `disabled(!userAcknowledgedSaved)` may take a frame to flip after the toggle click.
        let enabledExp = NSPredicate(format: "isEnabled == true")
        let waitEnabled = expectation(for: enabledExp, evaluatedWith: continueBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [waitEnabled], timeout: 5), .completed,
                       "Continue stayed disabled after acknowledging saved")
        continueBtn.click()

        // --- .reenter phase: tap Paste → PasteDetector matches → auto-advances ---
        let pasteBtn = app.buttons["recoverykey.paste"]
        XCTAssertTrue(pasteBtn.waitForExistence(timeout: 10),
                      "Paste button on .reenter didn't appear")
        pasteBtn.click()

        // After paste matches, view auto-advances to .confirmed which
        // auto-dismisses 600ms later via .task. Wait for the Paste button
        // to stop existing as proof the sheet has fully dismissed (not just
        // for the verify-gate to disappear — the gate left the screen the
        // moment the sheet *appeared* a few clicks ago, so that signal isn't
        // load-bearing).
        //
        // NOTE: this relies on MacRecoveryKeyView.swift's `.reenter` onChange
        // handler auto-advancing to `.confirmed` when canFinish flips. If
        // that auto-advance is ever removed, the test must be updated to
        // click the bottom-bar Confirm button explicitly.
        let pasteGone = NSPredicate(format: "exists == false")
        let pasteGoneWait = expectation(for: pasteGone, evaluatedWith: pasteBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [pasteGoneWait], timeout: 15), .completed,
                       "Recovery-key sheet never dismissed after Paste — auto-advance to .confirmed didn't fire")

        // --- Mac is now verified + bootstrapped. Signal iOS. ---
        try "ready".write(toFile: "/tmp/matron-mac-ready",
                          atomically: true,
                          encoding: .utf8)

        // --- Wait up to 120s for incoming-verify banner from iOS peer ---
        let acceptBtn = app.buttons["verifybanner.accept"]
        XCTAssertTrue(acceptBtn.waitForExistence(timeout: 120),
                      "Incoming verify banner never appeared from iOS peer")
        acceptBtn.click()

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

    // MARK: - Field helpers (copied from VerifyWithPartnerUITests)

    private func pasteIntoTextField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
        let actual = (field.value as? String) ?? ""
        if actual != value {
            failWithDiagnostics(
                "\(label) field readback mismatch — expected \(value.debugDescription), got \(actual.debugDescription)",
                screenshotName: "mac-field-mismatch-\(label)"
            )
        }
    }

    private func pasteIntoSecureField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
        if let visible = field.value as? String, !visible.isEmpty, visible.count != value.count {
            failWithDiagnostics(
                "\(label) field length mismatch — expected \(value.count), got \(visible.count)",
                screenshotName: "mac-field-length-\(label)"
            )
        }
    }

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
        tree.name = "mac-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        try? app.debugDescription.write(toFile: "/tmp/matron-mac-debug.txt",
                                        atomically: true, encoding: .utf8)

        var fieldsSummary = ""
        for id in ["signin.server", "signin.username"] {
            let v = (app.textFields[id].value as? String) ?? "<not present>"
            fieldsSummary += "\(id) = \(v.debugDescription)\n"
        }
        if let pw = app.secureTextFields["signin.password"].value as? String {
            fieldsSummary += "signin.password.value = \(pw.debugDescription) (count=\(pw.count))\n"
        }
        let pb = NSPasteboard.general.string(forType: .string) ?? "<nil>"
        fieldsSummary += "NSPasteboard.string = \(pb.debugDescription)\n"
        fieldsSummary += "signin.submit.isEnabled = \(app.buttons["signin.submit"].isEnabled)\n"
        try? fieldsSummary.write(toFile: "/tmp/matron-mac-fields.txt",
                                 atomically: true, encoding: .utf8)

        let fieldsAttachment = XCTAttachment(string: fieldsSummary)
        fieldsAttachment.name = "field-readbacks"
        fieldsAttachment.lifetime = .keepAlways
        add(fieldsAttachment)

        XCTFail("\(message). See /tmp/matron-mac-debug.txt + /tmp/matron-mac-fields.txt.")
    }
}
