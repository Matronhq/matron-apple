import XCTest

/// Settings → Security: the Email address row's Edit and the Password
/// row's Change Password each open their sheet, and so does a two-factor
/// action. Runs against the local rig (see rig/README.md "Security
/// settings rig"); with the rig down it skips. `RIG_PORT` (the runner
/// strips the `TEST_RUNNER_` prefix) points it at another port.
final class SecuritySettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var port: String { ProcessInfo.processInfo.environment["RIG_PORT"] ?? "9810" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:\(port)/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("rig not running (127.0.0.1:\(port))")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// Kept on the result bundle; also written to `SHOT_DIR` when set.
    private func shot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    private func openSettings() {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let settings = app.buttons["more.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
    }

    /// Scrolls the Settings form until `element` is hittable.
    private func scrollTo(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) on Settings")
        var tries = 0
        while !element.isHittable && tries < 6 {
            app.swipeUp()
            tries += 1
        }
    }

    /// Taps `button`, expects the sheet's `field`, then cancels it.
    private func expectSheet(from button: String, showing field: String, cancel: String = "Cancel",
                             shotName: String) {
        let row = app.buttons[button].firstMatch
        scrollTo(row)
        shot("\(shotName)-before")
        row.tap()
        let sheetField = app.descendants(matching: .any)[field].firstMatch
        XCTAssertTrue(sheetField.waitForExistence(timeout: 5), "tapping \(button) opens a sheet with \(field)")
        shot("\(shotName)-sheet")
        app.buttons[cancel].firstMatch.tap()
        XCTAssertTrue(app.buttons[button].firstMatch.waitForExistence(timeout: 5), "the sheet closes on \(cancel)")
    }

    func test_changePassword_opensItsSheet() {
        openSettings()
        expectSheet(from: "settings.changePassword", showing: "changePassword.current", shotName: "password")
    }

    func test_editAccountEmail_opensItsSheet() {
        openSettings()
        expectSheet(from: "settings.accountEmail.edit", showing: "accountEmail.email", shotName: "email")
    }

    func test_twoFactorSetUp_opensItsSheet() {
        openSettings()
        expectSheet(from: "settings.twoFactor.setUp", showing: "twoFactor.password", shotName: "two-factor")
    }

    /// All three in a row: one sheet closing must not stop the next opening.
    func test_eachSheetOpensAfterAnother() {
        openSettings()
        expectSheet(from: "settings.twoFactor.setUp", showing: "twoFactor.password", shotName: "seq-two-factor")
        expectSheet(from: "settings.changePassword", showing: "changePassword.current", shotName: "seq-password")
        expectSheet(from: "settings.accountEmail.edit", showing: "accountEmail.email", shotName: "seq-email")
    }

    /// Set Up…: the scan step (QR code, setup key, code field) is still
    /// there after a trip to another app, as when copying the key into an
    /// authenticator app. Starts setup on the rig's demo account only; it
    /// never turns two-factor on.
    func test_twoFactorSetUp_keepsTheScanStepAcrossABackgroundTrip() {
        openSettings()
        let setUp = app.buttons["settings.twoFactor.setUp"].firstMatch
        scrollTo(setUp)
        setUp.tap()
        let password = app.secureTextFields["twoFactor.password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText(ProcessInfo.processInfo.environment["RIG_PASSWORD"] ?? "matron-demo-2026")
        app.buttons["twoFactor.submit"].firstMatch.tap()
        let code = app.textFields["twoFactor.newCode"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the scan step after the password")
        shot("scan-before-background")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 5))
        sleep(3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        shot("scan-after-background")
        XCTAssertTrue(code.waitForExistence(timeout: 5), "the scan step survives the trip out of the app")
        XCTAssertFalse(app.secureTextFields["twoFactor.password"].exists, "not back at the password step")
    }
}
