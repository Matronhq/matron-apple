import XCTest

/// Marketing/App Store screenshot harness for the Mac app — NOT a
/// correctness test. Mirrors MatronUITests/MarketingScreenshots.swift:
/// requires the screenshot rig (seeded local matron-journal on
/// 127.0.0.1:9810 + demo session under /tmp/matron-demo-home) and skips
/// itself when the rig isn't running.
///
/// The app under test launches with $HOME pointed at the rig's fake home,
/// so it restores the demo session instead of touching the real user's
/// `~/Library/Application Support/chat.matron.app`.
final class MarketingScreenshotsMac: XCTestCase {
    private var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
            ?? "/tmp/matron-screenshots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func save(_ shot: XCUIScreenshot, _ name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
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
        app.launchEnvironment["HOME"] = "/tmp/matron-demo-home"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no main window")
        resize(window, to: CGSize(width: 1280, height: 800))

        // Sidebar synced in from the local journal.
        let hero = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20), "chat list never showed seeded convo")

        // Hero chat: tool cards + diff + ask-user prompt.
        hero.click()
        let prompt = app.staticTexts["Push the fix and open a PR?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "hero chat never rendered prompt card")
        sleep(2)
        try save(window.screenshot(), "mac-01-agent-chat")

        // A second conversation for variety (running migration).
        let running = app.staticTexts["Migrate database to Postgres 16"]
        if running.exists {
            running.click()
            sleep(3)
            try save(window.screenshot(), "mac-02-running-chat")
        }
    }
}
