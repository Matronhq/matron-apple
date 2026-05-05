import XCTest

/// XCUITest scenario driver for the reverse-direction matron-vs-matron
/// flow (handover Priority A test #2 — iOS half).
///
/// Mirror of `MatronVsMatronIOSUITests` with the roles SWAPPED:
/// iOS plays the trust-anchor responder (signs in first, generates the
/// recovery key, waits for an incoming request), Mac plays the requester.
/// The original direction (Mac responder, iOS requester) is covered by
/// `MatronVsMatronIOSUITests` / `MatronVsMatronMacUITests`.
///
/// Synchronisation: iOS prints `MATRON_IOS_TRUST_ANCHOR_READY` to stdout
/// after the recovery-key bootstrap completes. The scenario script
/// (`reverse-direction-ui.sh`) tails the iOS test log for the marker
/// and touches `/Users/Shared/matron-ios-ready` on the host. Mac then
/// proceeds with sign-in.
///
/// We have to print + host-watch (rather than the test writing the file
/// directly) for the same reason the Mac side does it in the original
/// flow: the iOS UI test runner is sandboxed and cannot write to
/// `/Users/Shared`.
final class ReverseDirectionIOSUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testTrustAnchorAcceptsIncomingFromMacPeer() throws {
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
            failWithDiagnostics("sign-in form did not appear", screenshotName: "rev-ios-signin-form-not-found")
            return
        }
        let username = app.textFields["signin.username"]
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(username.waitForExistence(timeout: 5), "username field missing")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "password field missing")

        clickAndType(server, value: homeserver)
        clickAndType(username, value: user)
        clickAndType(passwordField, value: password)

        let submit = app.buttons["signin.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "submit button missing")
        if !submit.isEnabled {
            failWithDiagnostics("submit button still disabled after typing all three fields",
                                screenshotName: "rev-ios-submit-disabled")
            return
        }
        submit.tap()

        // --- Verify gate → "First device — generate a key" ---
        let generateNew = app.buttons["verifygate.generateNew"]
        if !generateNew.waitForExistence(timeout: 30) {
            failWithDiagnostics("verify gate didn't appear within 30s",
                                screenshotName: "rev-ios-verify-gate-not-found")
            return
        }
        generateNew.tap()

        // --- RecoveryKeyView .notStarted → tap Generate ---
        let generate = app.buttons["recoverykey.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10),
                      "Generate recovery key button didn't appear")
        generate.tap()

        // --- .show phase: capture the key from the on-screen Text ---
        // We deliberately do NOT tap the Copy button or read UIPasteboard.
        // iOS shows a "MatronUI Tests would like to paste" permission
        // prompt the first time the runner reads the system pasteboard,
        // which hangs unattended runs (the prompt is system-modal and
        // there's no clean XCUITest API to dismiss it without
        // XCUIInterruptionMonitor coupling). Reading the key from the
        // displayed Text view's accessibility label avoids the prompt
        // entirely.
        let keyText = app.staticTexts["recoverykey.generatedKey"]
        XCTAssertTrue(keyText.waitForExistence(timeout: 15),
                      "Generated recovery key Text didn't appear")
        let recoveryKey = keyText.label
        guard !recoveryKey.isEmpty else {
            failWithDiagnostics("Generated key Text was empty — capture failed",
                                screenshotName: "rev-ios-key-empty")
            return
        }

        // SwiftUI Toggle on iOS exposes as `switches`. iOS 26 simulator
        // XCUITest sometimes drops `.tap()` events on the toggle thumb;
        // a coordinate-anchored tap on the right edge (where the switch
        // control sits inside the row) is more reliable, and we re-check
        // the value afterwards as belt-and-braces.
        let ackToggle = app.switches["recoverykey.acknowledgeSaved"]
        XCTAssertTrue(ackToggle.waitForExistence(timeout: 5),
                      "Acknowledge-saved toggle missing")
        if (ackToggle.value as? String) != "1" {
            ackToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            usleep(150_000)
        }
        if (ackToggle.value as? String) != "1" {
            // Fallback: swipeRight which always flips off→on regardless
            // of where the SwiftUI runtime placed the hit-target.
            ackToggle.swipeRight()
            usleep(150_000)
        }
        XCTAssertEqual(ackToggle.value as? String, "1",
                       "Acknowledge toggle didn't flip on after both tap + swipe attempts")

        let continueBtn = app.buttons["recoverykey.continue"]
        XCTAssertTrue(continueBtn.waitForExistence(timeout: 5))
        let enabledExp = NSPredicate(format: "isEnabled == true")
        let waitEnabled = expectation(for: enabledExp, evaluatedWith: continueBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [waitEnabled], timeout: 5), .completed,
                       "Continue stayed disabled after acknowledging saved")
        continueBtn.tap()

        // --- .reenter: type the key back, then Confirm ---
        let reenterField = app.textFields["recoverykey.reenterField"]
        XCTAssertTrue(reenterField.waitForExistence(timeout: 10),
                      "Re-enter recovery key field didn't appear")
        // Tap to focus, then typeText character-by-character. iOS doesn't
        // have a Paste button on this view (Mac does); typing is the only
        // input path. Recovery keys are ~50 chars of base58 — slow but
        // deterministic.
        reenterField.tap()
        usleep(250_000)
        reenterField.typeText(recoveryKey)
        usleep(150_000)

        let confirmBtn = app.buttons["recoverykey.confirm"]
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 5),
                      "Confirm button didn't appear after re-entry")
        let confirmEnabled = expectation(for: enabledExp, evaluatedWith: confirmBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [confirmEnabled], timeout: 5), .completed,
                       "Confirm stayed disabled after typing matching key")
        confirmBtn.tap()

        // Wait for the recovery-key sheet to disappear as proof the
        // chat-list mounted (Confirm fires `onFinished` which flips
        // verifyDone → chat list branch).
        let confirmGone = NSPredicate(format: "exists == false")
        let confirmGoneWait = expectation(for: confirmGone, evaluatedWith: confirmBtn, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [confirmGoneWait], timeout: 15), .completed,
                       "Recovery-key sheet never dismissed after Confirm")

        // --- iOS is now verified + bootstrapped. Signal Mac. ---
        // Same shape as the Mac trust-anchor's marker — host-side
        // watcher tails the test log for this string and creates
        // /Users/Shared/matron-ios-ready (the iOS sim sandbox can't
        // write there directly).
        print("MATRON_IOS_TRUST_ANCHOR_READY")
        fflush(stdout)

        // --- Wait up to 240s for incoming-verify banner from Mac peer ---
        // 240s for the same parallel-launch-skew rationale as the
        // original direction's Mac-side wait — Mac's xcodebuild can
        // start before iOS is ready, but iOS sim cold-boot is the
        // slow path. The reverse direction inverts who waits but the
        // skew envelope is similar.
        let acceptBtn = app.buttons["verifybanner.accept"]
        XCTAssertTrue(acceptBtn.waitForExistence(timeout: 240),
                      "Incoming verify banner never appeared from Mac peer")
        acceptBtn.tap()

        // --- SAS sheet → They match → wait for dismissal ---
        let match = app.buttons["sas.match"]
        XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout),
                      "iOS SAS sheet never appeared (timeout: \(Int(verifyTimeout))s)")
        match.tap()

        let dismissed = NSPredicate(format: "exists == false")
        let dismissedExp = expectation(for: dismissed, evaluatedWith: match, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [dismissedExp], timeout: 30), .completed,
                       "iOS SAS sheet did not dismiss after match")
    }

    // MARK: - Helpers

    private func clickAndType(_ field: XCUIElement, value: String) {
        field.tap()
        usleep(250_000)
        field.typeText(value)
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
        tree.name = "rev-ios-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        try? app.debugDescription.write(toFile: "/tmp/rev-ios-debug.txt",
                                        atomically: true, encoding: .utf8)

        XCTFail("\(message). See /tmp/rev-ios-debug.txt and the test result bundle.")
    }
}
