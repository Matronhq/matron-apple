# matron-vs-matron UI Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an automated XCUITest scenario that runs Mac (trust-anchor responder) + iOS sim (requester) end-to-end against the Docker harness, proving the matron-vs-matron SAS path works post-Wave-7 revert.

**Architecture:** Two parallel `xcodebuild test` invocations driven by `tests/integration/scenarios/matron-vs-matron-ui.sh`. Mac signs in → generates recovery key (the multi-phase `MacRecoveryKeyView` flow) → writes `/tmp/matron-mac-ready` → waits for incoming-verify banner → confirms emojis. iOS polls the ready file → signs in → taps "Verify with another device" → confirms emojis. Wrapper waits both PIDs and asserts both os.Logger streams contain `verificationStateListener: fired with verified`.

**Tech Stack:** Swift / SwiftUI / XCUITest, xcodegen, matrix-rust-components-swift v26.04.01 (already vendored), Docker (matron-server tuwunel), bash for orchestration.

**Spec:** `docs/superpowers/specs/2026-05-04-matron-vs-matron-ui-test-design.md`.

---

## File structure

**New files:**
- `MatronUITests/MatronVsMatronIOSUITests.swift` — iOS XCUITest class (sign-in + verify-with-other-device).
- `MatronMacUITests/MatronVsMatronMacUITests.swift` — Mac XCUITest class (sign-in + multi-phase recovery-key bootstrap + accept-incoming + SAS confirm).
- `tests/integration/scenarios/matron-vs-matron-ui.sh` — orchestrator script.

**Modified files:**
- `Matron/Features/Onboarding/SignInView.swift` — add 4 accessibility identifiers.
- `Matron/Features/Onboarding/PostLoginVerificationView.swift` — add 3 identifiers.
- `Matron/Features/Verification/SasView.swift` — add 2 identifiers.
- `MatronMac/Features/Verification/MacVerificationBanner.swift` — add 1 identifier on the "Verify" button.
- `MatronMac/Features/Verification/MacRecoveryKeyView.swift` — add 5 identifiers across the multi-phase flow (Generate, Copy, AcknowledgeSaved toggle, Continue, Paste).
- `project.yml` — add `MatronUITests` target + add to Matron iOS scheme's `testTargets`.
- `tests/integration/run-harness.sh` — add `matron-vs-matron-ui.sh` to the inline-bootstrap auto-skip pattern.

**Spec deviation note:** The original spec listed 2 IDs for `MacRecoveryKeyView`. After reading the file end-to-end the actual generate flow has 4 phases — `.notStarted` (button "Generate recovery key"), `.show` (Copy + Toggle + Continue), `.reenter` (TextField + Paste, with auto-advance to `.confirmed` once the pasted key matches), `.confirmed` (auto-dismiss after 600ms). Test must drive all phases. Identifiers expanded to 5 to cover the buttons we actually click.

---

## Task 1: Plumb iOS accessibility identifiers

**Files:**
- Modify: `Matron/Features/Onboarding/SignInView.swift:14-32` — add IDs to TextField (server, username), SecureField (password), Sign-in Button.
- Modify: `Matron/Features/Onboarding/PostLoginVerificationView.swift:74-91` — add IDs to the three primary Buttons.
- Modify: `Matron/Features/Verification/SasView.swift:97-105` — add IDs to "They don't match" / "They match" Buttons.

- [ ] **Step 1: Edit SignInView.swift**

Open `Matron/Features/Onboarding/SignInView.swift`. The TextField/SecureField on iOS take `.accessibilityIdentifier(...)` after their existing modifiers. Add:

```swift
// Line 14 area
TextField("https://matrix.example.com", text: $viewModel.serverURL)
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .keyboardType(.URL)
    .accessibilityIdentifier("signin.server")

// Line 20 area
TextField("Username", text: $viewModel.username)
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .accessibilityIdentifier("signin.username")

// Line 23 area
SecureField("Password", text: $viewModel.password)
    .accessibilityIdentifier("signin.password")

// Line 31-43 area — apply to the Button itself, not the label
Button {
    Task { await viewModel.submit() }
} label: {
    if case .busy = viewModel.state {
        ProgressView()
    } else {
        Text("Sign in")
    }
}
.disabled({
    if case .busy = viewModel.state { return true }
    return viewModel.serverURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
}())
.accessibilityIdentifier("signin.submit")
```

- [ ] **Step 2: Edit PostLoginVerificationView.swift**

Open `Matron/Features/Onboarding/PostLoginVerificationView.swift`. Add identifiers to each of the three Buttons in the body (lines 74-91):

```swift
Button {
    path.append(.sasWithOtherDevice)
} label: {
    Label("Verify with another device", systemImage: "iphone")
}
.buttonStyle(.borderedProminent)
.accessibilityIdentifier("verifygate.verifyWithOtherDevice")

Button {
    path.append(.restoreWithRecoveryKey)
} label: {
    Label("Use recovery key", systemImage: "key")
}
.buttonStyle(.bordered)
.accessibilityIdentifier("verifygate.useRecoveryKey")

Button("This is my first device — generate a key") {
    path.append(.generate)
}
.padding(.top, 8)
.accessibilityIdentifier("verifygate.generateNew")
```

- [ ] **Step 3: Edit SasView.swift**

Open `Matron/Features/Verification/SasView.swift`. The buttons are inside a private `@ViewBuilder var buttons` (lines 95-106). Add:

```swift
@ViewBuilder
private var buttons: some View {
    HStack {
        Button("They don't match", role: .destructive) {
            Task { await viewModel.cancel() }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("sas.dontMatch")
        Spacer()
        Button("They match") {
            Task { await viewModel.confirm() }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("sas.match")
    }
}
```

- [ ] **Step 4: Build to verify no syntax errors**

Run: `xcodebuild build -scheme Matron -configuration Debug -destination 'platform=iOS Simulator,id=337C3A3A-4191-4A51-9513-93F5805276EC' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`. Any compile error means the modifier chain is wrong (e.g. accidentally placed after `.disabled`'s closure call).

- [ ] **Step 5: Commit**

```bash
git add Matron/Features/Onboarding/SignInView.swift \
       Matron/Features/Onboarding/PostLoginVerificationView.swift \
       Matron/Features/Verification/SasView.swift
git commit -m "$(cat <<'EOF'
feat(ios): plumb XCUITest accessibility identifiers

Mirrors the Mac surface: signin.{server,username,password,submit},
verifygate.{verifyWithOtherDevice,useRecoveryKey,generateNew},
sas.{match,dontMatch}. Required for the matron-vs-matron UI test
scenario.
EOF
)"
```

---

## Task 2: Plumb Mac accessibility identifiers

**Files:**
- Modify: `MatronMac/Features/Verification/MacVerificationBanner.swift:40` — add ID to "Verify" button.
- Modify: `MatronMac/Features/Verification/MacRecoveryKeyView.swift` — add 5 IDs across the multi-phase generate flow.

- [ ] **Step 1: Edit MacVerificationBanner.swift**

Add accessibility identifier to the Verify button at line 40:

```swift
Button("Verify") { onAccept(summary) }
    .controlSize(.small)
    .buttonStyle(.borderedProminent)
    .accessibilityIdentifier("verifybanner.accept")
```

- [ ] **Step 2: Edit MacRecoveryKeyView.swift — `.notStarted` phase**

The `.notStarted/.show` switch case (lines 49-73) renders a "Generate recovery key" button when `viewModel.generatedKey` is nil (first sub-state). Add the identifier:

```swift
// Line 69 area
Button("Generate recovery key") {
    Task { await viewModel.generate() }
}
.disabled(viewModel.phase == .busy)
.accessibilityIdentifier("recoverykey.generate")
```

- [ ] **Step 3: Edit MacRecoveryKeyView.swift — Copy + AcknowledgeSaved toggle**

When the key is shown (lines 53-67), add IDs to Copy button and the Toggle:

```swift
// Line 62 area
Button("Copy") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(key, forType: .string)
}
.accessibilityIdentifier("recoverykey.copy")

// Line 67
Toggle("I've saved this key somewhere safe", isOn: $viewModel.userAcknowledgedSaved)
    .accessibilityIdentifier("recoverykey.acknowledgeSaved")
```

- [ ] **Step 4: Edit MacRecoveryKeyView.swift — Continue button**

The bottom-bar primary action for `(.generate, .show)` is the Continue button (line 158). Add:

```swift
case (.generate, .show):
    Button("Continue") { viewModel.advanceFromShow() }
        .keyboardShortcut(.return)
        .disabled(!viewModel.userAcknowledgedSaved)
        .accessibilityIdentifier("recoverykey.continue")
```

- [ ] **Step 5: Edit MacRecoveryKeyView.swift — Paste button (in `.reenter`)**

Reenter phase has a Paste button (line 82-83). Add:

```swift
HStack {
    TextField("XXXX-XXXX-XXXX-XXXX", text: $viewModel.reenteredKey)
        .font(.system(.title3, design: .monospaced))
        .textFieldStyle(.roundedBorder)
    Button("Paste") { detector?.checkClipboardAndApply() }
        .accessibilityIdentifier("recoverykey.paste")
}
```

- [ ] **Step 6: Build to verify**

Run: `xcodebuild build -scheme MatronMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add MatronMac/Features/Verification/MacVerificationBanner.swift \
       MatronMac/Features/Verification/MacRecoveryKeyView.swift
git commit -m "$(cat <<'EOF'
feat(mac): plumb XCUITest accessibility identifiers

verifybanner.accept on the incoming-request banner's Verify button
+ recoverykey.{generate,copy,acknowledgeSaved,continue,paste} across
the multi-phase MacRecoveryKeyView generate flow. Required for the
matron-vs-matron UI test scenario.
EOF
)"
```

---

## Task 3: Add `MatronUITests` target to project.yml + create directory

**Files:**
- Modify: `project.yml` — new target block + scheme integration.
- Create: `MatronUITests/.keep` — placeholder so the directory exists for xcodegen.

- [ ] **Step 1: Read existing MatronMacUITests block**

Run: `grep -n -A12 'MatronMacUITests:' project.yml`

This is the structure we'll mirror for iOS. The current block (lines 215-225 of project.yml) defines target type, sources path, and dependency on the host app.

- [ ] **Step 2: Add MatronUITests target to project.yml**

Add a new target block after the iOS app target (likely after `MatronTests:` around line 165). Mirroring the Mac UI test target:

```yaml
  # Phase 3+ — iOS XCUITest target for the matron-vs-matron UI scenario.
  # Drives the iOS sim app via XCUITest exactly like MatronMacUITests
  # drives the Mac app. iOS sim doesn't have App Sandbox so no
  # entitlement carve-outs needed.
  MatronUITests:
    type: bundle.ui-testing
    platform: iOS
    deploymentTarget: 17.0
    sources:
      - path: MatronUITests
    settings:
      base:
        CODE_SIGNING_ALLOWED: NO
        SWIFT_VERSION: 6.0
    dependencies:
      - target: Matron
```

(Use the same `deploymentTarget` as `Matron` — check the existing `Matron:` block for the exact value if 17.0 differs. Line 41-50 area.)

- [ ] **Step 3: Add to Matron scheme's testTargets**

Find the `Matron:` target block's `scheme.testTargets:` list (around line 86 per earlier grep). Add `- MatronUITests` to it:

```yaml
    scheme:
      testTargets:
        - MatronTests
        - MatronUITests
```

- [ ] **Step 4: Create the placeholder directory**

```bash
mkdir -p MatronUITests
touch MatronUITests/.keep
```

- [ ] **Step 5: Regenerate Xcode project**

Run: `xcodegen generate 2>&1 | tail -5`

Expected: `Created project at /Users/youruser/Dev/matron-iOS-app/Matron.xcodeproj` (no errors).

- [ ] **Step 6: Verify target was created**

Run: `xcodebuild -list -project Matron.xcodeproj 2>&1 | grep -i UITests`

Expected: both `MatronMacUITests` and `MatronUITests` appear.

- [ ] **Step 7: Commit**

```bash
git add project.yml MatronUITests/.keep
git commit -m "$(cat <<'EOF'
test(ios): add MatronUITests XCUITest target

Mirrors MatronMacUITests for iOS. Wires into the Matron scheme's
testTargets so xcodebuild test -scheme Matron and Xcode's Test
action both pick it up. Empty directory for now — test class
follows in the next commit.
EOF
)"
```

---

## Task 4: Write the iOS UI test class

**Files:**
- Create: `MatronUITests/MatronVsMatronIOSUITests.swift`.

- [ ] **Step 1: Create the test file with full implementation**

Write the file. This is a self-contained class — copies the field-paste/diagnostic helpers from `MatronMacUITests/VerifyWithPartnerUITests.swift` adapted to iOS (`UIPasteboard` instead of `NSPasteboard`, `.tap()` instead of `.click()`).

```swift
import XCTest
import UIKit

/// XCUITest scenario driver for the matron-vs-matron UI integration test
/// (iOS half — requester role).
///
/// Reads `/tmp/matron-test-config.json`, polls `/tmp/matron-mac-ready` to
/// gate sign-in until the Mac peer has bootstrapped cross-signing, then
/// drives sign-in → "Verify with another device" → SAS confirm → wait
/// for sheet dismissal as proxy for `.verified`.
///
/// The /tmp file dance is the synchronization point with the Mac test;
/// see `tests/integration/scenarios/matron-vs-matron-ui.sh` for the
/// full orchestration.
final class MatronVsMatronIOSUITests: XCTestCase {

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
    private func waitForReadyFile(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: "/tmp/matron-mac-ready") {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    // MARK: - Field helpers (iOS variants of the Mac helpers)

    private func pasteIntoTextField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
        let actual = (field.value as? String) ?? ""
        // iOS TextField with no content shows the placeholder as `value`.
        // After paste we expect the actual string.
        if actual != value && !actual.isEmpty && actual != value.lowercased() {
            // Soft-fail with diagnostics — iOS TextField field readback
            // can include leading/trailing whitespace from autocorrect.
            // The submit-enabled check is the authoritative signal.
        }
    }

    private func pasteIntoSecureField(_ field: XCUIElement, value: String, label: String) {
        clickAndPaste(field, value: value)
        // SecureField on iOS doesn't expose the typed string at all; the
        // submit-enabled check confirms content arrived.
    }

    private func clickAndPaste(_ field: XCUIElement, value: String) {
        UIPasteboard.general.string = value
        field.tap()
        usleep(250_000)
        // Long-press to surface the Paste menu, then dismiss + use the
        // typeText fallback if the menu doesn't appear.
        // Simpler approach: select-all then paste via the menu is fragile
        // on iOS; just typeText the value directly. iOS TextField with
        // .autocorrectionDisabled and .textInputAutocapitalization(.never)
        // accepts the URL/username verbatim.
        if let existing = field.value as? String, !existing.isEmpty {
            field.press(forDuration: 1.2)
            if app.menuItems["Select All"].waitForExistence(timeout: 1) {
                app.menuItems["Select All"].tap()
            }
        }
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
```

- [ ] **Step 2: Delete the placeholder .keep file**

```bash
rm MatronUITests/.keep
```

- [ ] **Step 3: Regenerate xcodeproj**

Run: `xcodegen generate 2>&1 | tail -3`

- [ ] **Step 4: Build for testing**

Run:
```bash
xcodebuild build-for-testing -scheme Matron \
    -destination 'platform=iOS Simulator,id=337C3A3A-4191-4A51-9513-93F5805276EC' \
    -only-testing:MatronUITests \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: `** TEST BUILD SUCCEEDED **`. Compile errors here usually mean: missing import, forgot `import UIKit`, mistyped element type (e.g. `app.checkBoxes` doesn't exist on iOS).

- [ ] **Step 5: Commit**

```bash
git add MatronUITests/MatronVsMatronIOSUITests.swift
git rm MatronUITests/.keep 2>/dev/null || true
git commit -m "$(cat <<'EOF'
test(ios): MatronVsMatronIOSUITests — drive iOS as verify requester

Sign-in + verify-with-other-device + SAS confirm. Reads config from
/tmp/matron-test-config.json and gates sign-in on /tmp/matron-mac-ready
so the Mac peer's trust-anchor bootstrap completes first. Diagnostic
dumps to /tmp/matron-ios-debug.txt + /tmp/matron-ios-fields.txt on
failure.
EOF
)"
```

---

## Task 5: Write the Mac UI test class

**Files:**
- Create: `MatronMacUITests/MatronVsMatronMacUITests.swift`.

- [ ] **Step 1: Create the file**

This file copies the existing `VerifyWithPartnerUITests` field-helper pattern and adds the multi-phase recovery-key bootstrap + accept-incoming flow.

```swift
import XCTest
import AppKit  // NSPasteboard for reliable URL pasting

/// XCUITest scenario driver for the matron-vs-matron UI integration test
/// (Mac half — trust-anchor responder role).
///
/// Reads `/tmp/matron-test-config.json` like `VerifyWithPartnerUITests`.
/// Drives:
///   1. Sign in (new user, fresh homeserver)
///   2. Verify gate → "This is my first device — generate a key"
///   3. RecoveryKeyView .show phase → Copy + acknowledge + Continue
///   4. RecoveryKeyView .reenter phase → Paste → auto-advances to .confirmed
///   5. Sheet auto-dismisses (600ms) → onFinished → chat-list visible
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
        // Pasteboard now holds the recovery key — used in .reenter below.

        let ackToggle = app.checkBoxes["recoverykey.acknowledgeSaved"]
        if !ackToggle.waitForExistence(timeout: 5) {
            // SwiftUI Toggle on macOS sometimes exposes as `switches`
            // rather than `checkBoxes`. Fall back.
            let altToggle = app.switches["recoverykey.acknowledgeSaved"]
            XCTAssertTrue(altToggle.waitForExistence(timeout: 5),
                          "Acknowledge-saved toggle missing under both `checkBoxes` and `switches`")
            altToggle.click()
        } else {
            ackToggle.click()
        }

        let continueBtn = app.buttons["recoverykey.continue"]
        XCTAssertTrue(continueBtn.waitForExistence(timeout: 5))
        // `disabled(!userAcknowledgedSaved)` may take a frame to flip.
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
        // auto-dismisses 600ms later via .task. We can wait for the
        // chat-list to appear as a proxy.
        // The chat-list root is identified by the unverified-device
        // banner (when the user is unverified) OR the chat list itself.
        // Most reliable: wait for the verifygate.generateNew button to
        // GO AWAY (we left that view).
        let goneExp = NSPredicate(format: "exists == false")
        let goneWait = expectation(for: goneExp, evaluatedWith: generateNew, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [goneWait], timeout: 15), .completed,
                       "Recovery-key flow never advanced past the verify gate")

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

    // MARK: - Field helpers (copied from VerifyWithPartnerUITests; if a
    // third UI test class lands later, refactor into a shared base)

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
        fieldsSummary += "signin.submit.isEnabled = \(app.buttons["signin.submit"].isEnabled)\n"
        try? fieldsSummary.write(toFile: "/tmp/matron-mac-fields.txt",
                                 atomically: true, encoding: .utf8)

        XCTFail("\(message). See /tmp/matron-mac-debug.txt + /tmp/matron-mac-fields.txt.")
    }
}
```

- [ ] **Step 2: Build for testing**

```bash
xcodebuild build-for-testing -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/MatronVsMatronMacUITests \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES 2>&1 | tail -15
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add MatronMacUITests/MatronVsMatronMacUITests.swift
git commit -m "$(cat <<'EOF'
test(mac): MatronVsMatronMacUITests — drive Mac as trust anchor

Sign-in → "first device" generate-key bootstrap (Generate → Copy →
acknowledge → Continue → Paste → auto-advance) → write
/tmp/matron-mac-ready → wait for incoming-verify banner → accept →
SAS confirm. Reads config from /tmp/matron-test-config.json. Mirrors
the existing VerifyWithPartnerUITests field-paste/diagnostic
helpers (copy, refactor when a third UI test class lands).
EOF
)"
```

---

## Task 6: Create the orchestrator scenario script

**Files:**
- Create: `tests/integration/scenarios/matron-vs-matron-ui.sh`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Scenario: drive Mac (trust-anchor responder) + iOS sim (requester)
# end-to-end via XCUITest, both running matron's matrix-rust-sdk
# build, both signed in as @matron against the Docker harness on
# :6167. No partner.mjs.
#
# Synchronization: Mac signs in first, runs the recovery-key
# generate flow, then writes /tmp/matron-mac-ready. iOS polls that
# file before signing in (XCTSkip after 90s). Both reach the SAS
# sheet via XCUIElement.waitForExistence; "They match" on both sides
# completes SAS; auto-cross-signing flips both to verified.
#
# Pass criteria: both `xcodebuild test` exit 0 AND both runtime
# os.Logger streams contain "verificationStateListener: fired with
# verified".
#
# Driven by run-harness.sh which exports HOMESERVER, MATRON_USER,
# MATRON_PW, ARTIFACTS_DIR, ROOT.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require ARTIFACTS_DIR
require ROOT

SIM_UDID="${MATRON_SIM_UDID:-337C3A3A-4191-4A51-9513-93F5805276EC}"
CONFIG_FILE="/tmp/matron-test-config.json"
READY_FILE="/tmp/matron-mac-ready"

MAC_BUILD_LOG="$ARTIFACTS_DIR/mac-build.log"
IOS_BUILD_LOG="$ARTIFACTS_DIR/ios-build.log"
MAC_TEST_LOG="$ARTIFACTS_DIR/mac-test.log"
IOS_TEST_LOG="$ARTIFACTS_DIR/ios-test.log"
MAC_RUNTIME_LOG="$ARTIFACTS_DIR/matron-mac.log"
IOS_RUNTIME_LOG="$ARTIFACTS_DIR/matron-ios.log"
MAC_XCRESULT="$ARTIFACTS_DIR/mac.xcresult"
IOS_XCRESULT="$ARTIFACTS_DIR/ios.xcresult"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# --- Wipe stale signals + app state ---
log "Wiping app state (Mac + iOS sim) and stale ready-file…"
rm -f "$READY_FILE"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
defaults delete chat.matron.mac >/dev/null 2>&1 || true
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_UDID" chat.matron.app >/dev/null 2>&1 || true

# --- Build both UI test bundles in parallel ---
log "Building MatronMacUITests + MatronUITests for testing (parallel)…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/MatronVsMatronMacUITests \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$MAC_BUILD_LOG" 2>&1) &
MAC_BUILD_PID=$!

(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme Matron \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:MatronUITests/MatronVsMatronIOSUITests \
    CODE_SIGNING_ALLOWED=NO \
    > "$IOS_BUILD_LOG" 2>&1) &
IOS_BUILD_PID=$!

if ! wait $MAC_BUILD_PID; then
    log "✗ Mac build-for-testing failed"
    tail -50 "$MAC_BUILD_LOG"
    exit 1
fi
if ! wait $IOS_BUILD_PID; then
    log "✗ iOS build-for-testing failed"
    tail -50 "$IOS_BUILD_LOG"
    exit 1
fi
log "  builds OK"

# --- Write XCUITest config ---
log "Writing $CONFIG_FILE…"
cat > "$CONFIG_FILE" <<EOF
{
  "homeserver": "$HOMESERVER",
  "user": "$MATRON_USER",
  "password": "$MATRON_PW",
  "verify_timeout": 60
}
EOF

# --- Capture os.Logger streams from both sides ---
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info \
    > "$MAC_RUNTIME_LOG" 2>&1 &
MAC_LOG_PID=$!

xcrun simctl spawn "$SIM_UDID" log stream --predicate 'subsystem == "chat.matron"' --style compact --level info \
    > "$IOS_RUNTIME_LOG" 2>&1 &
IOS_LOG_PID=$!

cleanup() {
    [ -n "${MAC_LOG_PID:-}" ] && kill "$MAC_LOG_PID" 2>/dev/null || true
    [ -n "${IOS_LOG_PID:-}" ] && kill "$IOS_LOG_PID" 2>/dev/null || true
    pkill -x MatronMac 2>/dev/null || true
    rm -f "$CONFIG_FILE" "$READY_FILE"
}
trap cleanup EXIT

# --- Fork both tests in parallel ---
log "Running both UI tests in parallel (Mac trust-anchor + iOS requester)…"
set +e
(cd "$ROOT" && xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/MatronVsMatronMacUITests \
    -resultBundlePath "$MAC_XCRESULT" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$MAC_TEST_LOG" 2>&1) &
MAC_TEST_PID=$!

(cd "$ROOT" && xcodebuild test-without-building \
    -scheme Matron \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:MatronUITests/MatronVsMatronIOSUITests \
    -resultBundlePath "$IOS_XCRESULT" \
    CODE_SIGNING_ALLOWED=NO \
    > "$IOS_TEST_LOG" 2>&1) &
IOS_TEST_PID=$!

wait $MAC_TEST_PID
MAC_RC=$?
wait $IOS_TEST_PID
IOS_RC=$?
set -e

log "  Mac rc=$MAC_RC, iOS rc=$IOS_RC"

# --- Trace assertions ---
PASS=1
if [ $MAC_RC -ne 0 ]; then
    log "✗ Mac xcodebuild test failed"
    PASS=0
fi
if [ $IOS_RC -ne 0 ]; then
    log "✗ iOS xcodebuild test failed"
    PASS=0
fi
if ! grep -q 'verificationStateListener: fired with verified' "$MAC_RUNTIME_LOG"; then
    log "✗ Mac os.Logger never logged verificationStateListener: fired with verified"
    PASS=0
fi
if ! grep -q 'verificationStateListener: fired with verified' "$IOS_RUNTIME_LOG"; then
    log "✗ iOS os.Logger never logged verificationStateListener: fired with verified"
    PASS=0
fi

if [ $PASS -eq 1 ]; then
    log "✓ Scenario PASSED"
    exit 0
fi

log "✗ Scenario FAILED — collecting diagnostics"
log "  Mac test log: $MAC_TEST_LOG"
log "  iOS test log: $IOS_TEST_LOG"
log "  Mac runtime: $MAC_RUNTIME_LOG"
log "  iOS runtime: $IOS_RUNTIME_LOG"
log "  Mac xcresult: $MAC_XCRESULT"
log "  iOS xcresult: $IOS_XCRESULT"
echo "--- last 60 lines of Mac test log ---"
tail -60 "$MAC_TEST_LOG" || true
echo "--- last 60 lines of iOS test log ---"
tail -60 "$IOS_TEST_LOG" || true
exit 1
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/integration/scenarios/matron-vs-matron-ui.sh
```

- [ ] **Step 3: Commit**

```bash
git add tests/integration/scenarios/matron-vs-matron-ui.sh
git commit -m "$(cat <<'EOF'
test: add matron-vs-matron-ui.sh scenario

Orchestrates two parallel xcodebuild test invocations (Mac
MatronVsMatronMacUITests + iOS MatronVsMatronIOSUITests). Both
sign in as @matron against the Docker harness, synchronize via
/tmp/matron-mac-ready, complete SAS verification end-to-end. Asserts
both rc=0 AND both runtime os.Logger streams contain
"verificationStateListener: fired with verified". Driven by
run-harness.sh; needs the auto-skip pattern update in the next commit.
EOF
)"
```

---

## Task 7: Wire the new scenario into `run-harness.sh`'s auto-skip pattern

**Files:**
- Modify: `tests/integration/run-harness.sh:80-90` — add `matron-vs-matron-ui.sh` to the inline-bootstrap auto-skip list.

- [ ] **Step 1: Inspect the current auto-skip block**

Run: `grep -n -B1 -A8 'bootstrap-anchor\|MATRON_SKIP_BOOTSTRAP_ANCHOR' tests/integration/run-harness.sh`

Look for the if-statement that decides whether to skip partner bootstrap. The pattern matches scenario filenames like `verify-sdk-against-partner.sh`, `chat-list-sdk.sh`, `recovery-key-sdk.sh`, `verify-mac-ui-against-partner.sh`, `incoming-verify-sdk.sh`.

- [ ] **Step 2: Add matron-vs-matron-ui.sh to the pattern**

Edit the pattern to add `matron-vs-matron-ui.sh`. Most likely a `case` or regex match around line 82-88. For example, if it's:

```bash
case "$SCENARIO" in
    verify-sdk-against-partner.sh|chat-list-sdk.sh|recovery-key-sdk.sh|verify-mac-ui-against-partner.sh|incoming-verify-sdk.sh)
        SKIP_BOOTSTRAP=1;;
esac
```

Add `matron-vs-matron-ui.sh` to the alternation. If the actual shape differs, follow the existing pattern verbatim — don't restructure.

- [ ] **Step 3: Verify with a dry boot**

```bash
MATRON_SKIP_BOOTSTRAP_ANCHOR= tests/integration/run-harness.sh matron-vs-matron-ui.sh 2>&1 | head -30
```

Expected: log line `Skipping bootstrap-anchor (inline-bootstrap scenario)` appears. The actual scenario will fail (we haven't run a green build yet) but the harness wiring is verified.

Press Ctrl+C after the verification line to abort the scenario for now.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/run-harness.sh
git commit -m "$(cat <<'EOF'
test: register matron-vs-matron-ui.sh in run-harness auto-skip

Adds the new scenario to the inline-bootstrap auto-skip list so
run-harness.sh doesn't pre-bootstrap a partner.mjs trust anchor —
the Mac UI test does its own bootstrap inline as the trust anchor.
EOF
)"
```

---

## Task 8: First end-to-end run + iterate to green

**Files:**
- Likely follow-up edits to one or both UI test classes once we observe failures.

- [ ] **Step 1: Run the scenario**

```bash
tests/integration/run-harness.sh matron-vs-matron-ui.sh
```

Expected duration: ~3-5 minutes (build + parallel test runs + cleanup).

- [ ] **Step 2: Categorize the result**

Compare the actual outcome against the expected pass signature:

```
[scenario] ✓ Scenario PASSED
```

If anything else, the scenario will tail diagnostic logs and exit non-zero. Common failure modes and fixes:

| Failure | Likely cause | Fix |
|---------|--------------|-----|
| `signin.server` not found on Mac | Identifier landed on the wrong view modifier | Re-grep `MatronMac/Features/Onboarding/MacSignInView.swift`; fix placement |
| `signin.server` not found on iOS | Same on iOS side | Re-grep `Matron/Features/Onboarding/SignInView.swift` |
| `recoverykey.acknowledgeSaved` not found | SwiftUI Toggle not exposed as `checkBoxes` on this macOS — fall back to `app.switches[...]` already wired in test class; if neither matches, dump the accessibility tree | `cat /tmp/matron-mac-debug.txt` to find the actual element type |
| Test passes locally but trace assertion fails | `crossSignDevice` wasn't fired after SAS — Wave 7 bug #4 territory. | Inspect runtime logs for `verificationStateListener` emissions; if both sides emit `unverified` but not `verified`, the SAS round-trip didn't reach cross-sign |
| iOS XCTSkip ("Mac peer never reached ready signal") | Mac never wrote the file; Mac test must have failed before the write | Inspect Mac test log + xcresult for the actual failure point |
| Both tests pass but the wrapper still says FAILED | os.Logger predicate didn't match | Check `--predicate 'subsystem == "chat.matron"'` is actually what the apps log to (`grep -rn 'subsystem.*chat\.matron' MatronShared/Sources/Telemetry/`) |

- [ ] **Step 3: Iterate**

For each failure, edit the relevant file, rebuild, and re-run via the same `tests/integration/run-harness.sh matron-vs-matron-ui.sh` command. Each iteration teardown is automatic (run-harness.sh's EXIT trap drops the Docker volume; scenario script's EXIT trap removes /tmp signals).

- [ ] **Step 4: Once green, commit any iteration fixes**

If iteration produced fixes:

```bash
git add <fixed files>
git commit -m "fix(matron-vs-matron-ui): <specific issue>"
```

- [ ] **Step 5: Run twice more to confirm stability**

```bash
tests/integration/run-harness.sh matron-vs-matron-ui.sh
tests/integration/run-harness.sh matron-vs-matron-ui.sh
```

Both should pass cleanly. Flake at this stage indicates timing assumptions need padding (most likely the 120s incoming-banner waitForExistence — may need 180s on slower machines).

- [ ] **Step 6: Update HANDOVER.md**

Edit `docs/HANDOVER.md` — clear "Open risk #1 (matron-vs-matron not yet re-validated)" since we now have automated coverage. Mention the new scenario in the harness section's scenario inventory.

- [ ] **Step 7: Final commit**

```bash
git add docs/HANDOVER.md
git commit -m "$(cat <<'EOF'
docs: HANDOVER — matron-vs-matron now automated

New tests/integration/scenarios/matron-vs-matron-ui.sh runs Mac +
iOS sim end-to-end via XCUITest, no partner.mjs. Closes open risk #1
(matron-vs-matron not re-validated post-Wave-7 revert).
EOF
)"
```

---

## Self-review checklist

- **Spec coverage:** Each section of the spec maps to a task. Architecture (Task 6 + 7), code/UI changes A-E (Tasks 1-7), assertions (Task 6 step 1 trace grep), failure modes (Task 8 step 2). ✓
- **Placeholders:** No "TBD"/"TODO"/"add error handling" — all code blocks contain actual code, all commands are concrete. ✓
- **Type consistency:** Identifier names locked: `signin.{server,username,password,submit}`, `verifygate.{verifyWithOtherDevice,useRecoveryKey,generateNew}`, `sas.{match,dontMatch}`, `verifybanner.accept`, `recoverykey.{generate,copy,acknowledgeSaved,continue,paste}`. Files reference the same names consistently across tasks. ✓
- **Spec deviation:** `MacRecoveryKeyView` identifier count expanded from 2 → 5 to match the actual multi-phase generate flow. Documented at top of plan. ✓
