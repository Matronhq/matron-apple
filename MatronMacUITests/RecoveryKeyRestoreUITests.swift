import XCTest
import AppKit  // NSPasteboard

/// XCUITest scenario covering the recovery-key restore path via the
/// post-login verification gate (handover Priority A test #1 — manual
/// journey bullet 5: "Recovery-key restore via verify-gate").
///
/// Self-contained on Mac — no iOS sim, no partner.mjs trust anchor.
/// The recovery-key generate flow itself bootstraps cross-signing for
/// `@matron`; the restore flow then pulls those keys back from
/// server-side secret storage.
///
/// Reads `/tmp/matron-test-config.json` like `MatronVsMatronMacUITests`.
///
/// Flow:
///   1. Sign in (fresh user, fresh homeserver)
///   2. Verify gate → "First device — generate a key"
///   3. Generate flow → captures the recovery key off `NSPasteboard`
///      and into a local variable so subsequent paste-into-field
///      operations that overwrite the pasteboard don't lose it
///   4. Acknowledge → Continue → Paste-back → tap Confirm → sheet dismisses
///   5. File → Sign Out…  (clears `verifyDone` + drops session)
///   6. Sign in again with the same credentials
///   7. Verify gate now offers "Use recovery key"
///   8. Tap → restore form → re-prime pasteboard → Paste → Restore
///      → sheet dismisses (proxy for `.verified`)
final class RecoveryKeyRestoreUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
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
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testRecoveryKeyRestoreViaVerifyGate() throws {
        let configPath = "/tmp/matron-test-config.json"
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let homeserver = json["homeserver"] as? String else {
            throw XCTSkip("\(configPath) not present — run via tests/integration/scenarios/")
        }
        let user = (json["user"] as? String) ?? "matron"
        let password = (json["password"] as? String) ?? "matron-test-pw"

        // ---- Phase 1: fresh sign-in + recovery-key generate ----

        signIn(homeserver: homeserver, user: user, password: password)

        let generateNew = app.buttons["verifygate.generateNew"]
        if !generateNew.waitForExistence(timeout: 30) {
            failWithDiagnostics(
                "verify gate didn't appear within 30s",
                screenshotName: "rkr-verify-gate-not-found"
            )
            return
        }
        generateNew.click()

        let generate = app.buttons["recoverykey.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10),
                      "Generate recovery key button didn't appear")
        generate.click()

        let copyButton = app.buttons["recoverykey.copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 15),
                      "Recovery key Copy button didn't appear after Generate")
        copyButton.click()

        // Snapshot the key off the system pasteboard now: subsequent
        // `clickAndPaste` calls (sign-in fields after Sign Out, then the
        // paste-back step on the .reenter form) overwrite it, so we'd
        // lose the key without a local copy.
        guard let recoveryKey = NSPasteboard.general.string(forType: .string),
              !recoveryKey.isEmpty else {
            failWithDiagnostics(
                "NSPasteboard empty after Copy — recovery key not captured",
                screenshotName: "rkr-pasteboard-empty"
            )
            return
        }

        toggleAcknowledge()

        let continueBtn = app.buttons["recoverykey.continue"]
        XCTAssertTrue(continueBtn.waitForExistence(timeout: 5))
        // `disabled(!userAcknowledgedSaved)` may take a frame to flip
        // after the toggle click — same race as `MatronVsMatronMacUITests`.
        let enabledExp = NSPredicate(format: "isEnabled == true")
        let waitEnabled = expectation(for: enabledExp, evaluatedWith: continueBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [waitEnabled], timeout: 5), .completed,
                       "Continue stayed disabled after acknowledging saved")
        continueBtn.click()

        let pasteBtn = app.buttons["recoverykey.paste"]
        XCTAssertTrue(pasteBtn.waitForExistence(timeout: 10),
                      "Paste button on .reenter didn't appear")
        pasteBtn.click()

        // Paste populates `reenteredKey`; Confirm is the explicit dismissal
        // trigger (PR review fixes #1/#14 dropped the onChange auto-advance
        // and the 600ms `.task` auto-dismiss to match iOS RecoveryKeyView).
        let confirmBtn = app.buttons["recoverykey.confirm"]
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 5),
                      "Confirm button on .reenter didn't appear after Paste")
        let confirmEnabled = expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: confirmBtn,
            handler: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [confirmEnabled], timeout: 5), .completed,
                       "Confirm stayed disabled after Paste — reenteredKey didn't match generatedKey")
        confirmBtn.click()

        // Wait for the Paste button to stop existing as proof the sheet
        // has fully torn down (same proxy as `MatronVsMatronMacUITests`).
        let pasteGone = NSPredicate(format: "exists == false")
        let pasteGoneWait = expectation(for: pasteGone, evaluatedWith: pasteBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [pasteGoneWait], timeout: 15), .completed,
                       "Recovery-key sheet never dismissed after Confirm")

        // ---- Phase 2: sign out via File menu ----

        // Menu-item title carries the Unicode horizontal ellipsis
        // ("Sign Out…", U+2026) exactly as declared in `Commands.swift`.
        // macOS XCUITest can address menu items by their visible title
        // through the recursive `menuItems` query without needing to
        // open the parent menu first.
        let signOutItem = app.menuBars.menuItems["Sign Out\u{2026}"]
        if !signOutItem.waitForExistence(timeout: 5) {
            failWithDiagnostics(
                "File → Sign Out menu item not found",
                screenshotName: "rkr-signout-menu-missing"
            )
            return
        }
        signOutItem.click()

        // ---- Phase 3: sign back in, expect verify gate with "Use recovery key" ----

        // Sign-in form re-renders after signOut clears session. Wait for
        // the server field to come back before driving it.
        signIn(homeserver: homeserver, user: user, password: password)

        let useRecoveryKey = app.buttons["verifygate.useRecoveryKey"]
        if !useRecoveryKey.waitForExistence(timeout: 30) {
            failWithDiagnostics(
                "verify-gate did not present 'Use recovery key' after re-sign-in",
                screenshotName: "rkr-recovery-key-button-missing"
            )
            return
        }
        useRecoveryKey.click()

        // ---- Phase 4: restore using the captured key ----

        let restorePaste = app.buttons["recoverykey.restorePaste"]
        XCTAssertTrue(restorePaste.waitForExistence(timeout: 10),
                      "Restore-mode Paste button didn't appear")

        // Re-prime the pasteboard with the captured key. The intervening
        // sign-in `clickAndPaste`s overwrote whatever the Copy step put
        // there. The Paste button reads `NSPasteboard.general` directly
        // and writes it into the `enteredKey` field.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recoveryKey, forType: .string)
        restorePaste.click()

        let restoreBtn = app.buttons["recoverykey.restore"]
        XCTAssertTrue(restoreBtn.waitForExistence(timeout: 5),
                      "Restore primary-action button didn't appear")
        // Restore is `.disabled(enteredKey.isEmpty || phase == .busy)`,
        // so we wait for the paste to populate the field.
        let restoreEnabled = expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: restoreBtn,
            handler: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [restoreEnabled], timeout: 5), .completed,
                       "Restore button stayed disabled after paste")
        restoreBtn.click()

        // The Restore action runs `attemptRestore()`; the button label
        // swaps to a ProgressView while the SDK round-trips, then
        // `onFinished` fires and the gate's `recoveryKeyViewModel` flips
        // back to nil — the sheet view leaves the screen entirely.
        // Wait for the Restore button to disappear as the proxy for
        // "verified + sheet dismissed". 60s tolerates a slow first
        // `recoverAndFixBackup` round-trip on a cold homeserver.
        let restoreGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: restoreBtn,
            handler: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [restoreGone], timeout: 60), .completed,
                       "Restore sheet never dismissed — restore likely failed")
    }

    // MARK: - Helpers

    private func signIn(homeserver: String, user: String, password: String) {
        let server = app.textFields["signin.server"]
        if !server.waitForExistence(timeout: 30) {
            failWithDiagnostics(
                "sign-in form did not appear",
                screenshotName: "rkr-signin-form-not-found"
            )
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
    }

    private func toggleAcknowledge() {
        // SwiftUI Toggle on macOS may expose as `checkBoxes` or
        // `switches` depending on the macOS version's accessibility
        // classification — try both, mirroring `MatronVsMatronMacUITests`.
        let ackToggleCheck = app.checkBoxes["recoverykey.acknowledgeSaved"]
        let ackToggleSwitch = app.switches["recoverykey.acknowledgeSaved"]
        if ackToggleCheck.waitForExistence(timeout: 5) {
            ackToggleCheck.click()
        } else if ackToggleSwitch.waitForExistence(timeout: 5) {
            ackToggleSwitch.click()
        } else {
            failWithDiagnostics(
                "Acknowledge-saved toggle missing under both `checkBoxes` and `switches`",
                screenshotName: "rkr-ack-toggle-not-found"
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
        tree.name = "rkr-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        // /Users/Shared rather than /tmp — sandbox blocks /tmp writes
        // from the Mac UI test runner.
        try? app.debugDescription.write(toFile: "/Users/Shared/rkr-mac-debug.txt",
                                        atomically: true, encoding: .utf8)

        XCTFail("\(message). See /Users/Shared/rkr-mac-debug.txt.")
    }
}
