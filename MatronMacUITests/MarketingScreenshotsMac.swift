import XCTest

/// Marketing/App Store screenshot harness for the Mac app — NOT a
/// correctness test. Mirrors MatronUITests/MarketingScreenshots.swift:
/// requires the screenshot rig (seeded local matron-journal on
/// 127.0.0.1:9810 + demo session under /tmp/matron-demo-home) and skips
/// itself when the rig isn't running.
///
/// The app under test launches with `MATRON_APP_SUPPORT_OVERRIDE` pointed at
/// a throwaway container (holding the pre-written demo session), so it
/// restores the demo account instead of touching the real user's
/// `~/Library/Application Support/chat.matron.app`. A `$HOME` override does
/// NOT achieve this — the unsandboxed Mac app resolves Application Support
/// from the login account, not `$HOME`, so it would open the real data.
final class MarketingScreenshotsMac: XCTestCase {
    private var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
            ?? "/tmp/matron-screenshots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Persist a screenshot two ways: as an `XCTAttachment` (survives the
    /// UI-test runner's sandbox — it lands in the `.xcresult`) and, best
    /// effort, as a PNG on disk (works only when the runner isn't sandboxed;
    /// ignored otherwise). The attachment is the reliable path — extract it
    /// from the result bundle with `xcrun xcresulttool`.
    private func capture(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(data: shot.pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    /// Find a `StaticText` whose text contains `substring`. The Mac sidebar
    /// (and chat cards) expose their text through the accessibility `value`,
    /// TRUNCATED with an ellipsis (`value: Fix the flaky uplo…`), and leave
    /// `label` empty — so the iOS harness's `staticTexts["<exact title>"]`
    /// (an exact `label` match) never matches here. Matching a short,
    /// unique substring against `value` (falling back to `label`) sidesteps
    /// both the truncation and the label/value split.
    private func text(_ app: XCUIApplication, containing substring: String) -> XCUIElement {
        app.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                  substring, substring))
            .firstMatch
    }

    /// Drag the bottom-right corner so the window frame lands on `size`
    /// (App Store Mac screenshots must be exactly 1280x800 / 1440x900 /
    /// 2560x1600 / 2880x1800 — a 2x window capture of 1280x800 is 2560x1600).
    private func resize(_ window: XCUIElement, to size: CGSize) {
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = corner.withOffset(CGVector(dx: size.width - frame.width,
                                                dy: size.height - frame.height))
        corner.click(forDuration: 0.3, thenDragTo: target)
    }

    func testCaptureScreenshots() throws {
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"),
              (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("screenshot rig not running (127.0.0.1:9810)")
        }

        let app = XCUIApplication()
        let container = ProcessInfo.processInfo.environment["MATRON_APP_SUPPORT_OVERRIDE"]
            ?? "/tmp/matron-demo-mac/chat.matron.app"
        app.launchEnvironment["MATRON_APP_SUPPORT_OVERRIDE"] = container
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no main window")
        resize(window, to: CGSize(width: 1280, height: 800))

        // Sidebar synced in from the local journal.
        let hero = text(app, containing: "Fix the flaky")
        XCTAssertTrue(hero.waitForExistence(timeout: 20), "chat list never showed seeded convo")
        sleep(2) // let unread badges + previews settle

        // Hero chat: tool cards + diff + ask-user prompt.
        hero.click()
        let prompt = text(app, containing: "open a PR")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "hero chat never rendered prompt card")
        sleep(2)
        capture(window.screenshot(), "mac-01-agent-chat")

        // A second conversation for variety (running migration).
        let running = text(app, containing: "Migrate database")
        if running.exists {
            running.click()
            sleep(3)
            capture(window.screenshot(), "mac-02-running-chat")
        }
    }
}
