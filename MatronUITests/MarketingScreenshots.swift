import XCTest

/// Marketing/App Store screenshot harness — NOT a correctness test.
///
/// Drives the real app against a seeded local matron-journal (see the
/// screenshot rig in /tmp/matron-demo: local server on 127.0.0.1:9810, demo
/// account, scripted conversations) and writes full-resolution PNGs to
/// `SCREENSHOT_DIR` (falls back to /tmp/matron-screenshots). Skips itself
/// when the rig isn't running so a normal full-scheme test run is unaffected.
final class MarketingScreenshots: XCTestCase {
    private var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
            ?? "/tmp/matron-screenshots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func save(_ name: String) throws {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func dismissNotificationAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    func testCaptureScreenshots() throws {
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"),
              (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("screenshot rig not running (127.0.0.1:9810)")
        }

        let app = XCUIApplication()
        app.launch()
        dismissNotificationAlert()

        // Chat list — wait for the seeded conversations to sync in.
        let hero = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20), "chat list never showed seeded convo")
        sleep(2) // let the rest of the list + unread badges settle
        try save("ios-01-chat-list")

        // Hero chat — tool cards, diff, and the ask-user prompt.
        hero.tap()
        let prompt = app.staticTexts["Push the fix and open a PR?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "hero chat never rendered prompt card")
        sleep(2) // scroll settle + session header populate
        try save("ios-02-agent-chat")

        // Back to the list, open the dark-mode convo for a diff-card shot.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let darkMode = app.staticTexts["Dark mode for settings screen"]
        XCTAssertTrue(darkMode.waitForExistence(timeout: 10))
        darkMode.tap()
        let diff = app.staticTexts["SettingsView.swift"]
        _ = diff.waitForExistence(timeout: 10)
        sleep(2)
        try save("ios-03-diff-chat")
    }

    /// New Chat flow — needs the rig's responder.mjs running (two connected
    /// agents answering `recent_folders`).
    func testCaptureNewChatFlow() throws {
        let app = try launchAgainstRig()

        XCTAssertTrue(app.staticTexts["Fix the flaky upload test"].waitForExistence(timeout: 20))
        app.buttons["New chat"].tap()
        let agentRow = app.staticTexts["homelab"]
        XCTAssertTrue(agentRow.waitForExistence(timeout: 10), "agent picker never listed homelab")
        sleep(1)
        try save("ios-04-new-chat-agents")

        app.staticTexts["mac-studio"].tap()
        let folder = app.staticTexts["~/dev/api-server"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "recent_folders answer never rendered")
        sleep(1)
        try save("ios-05-new-chat-folders")
    }

    /// Session-status sheet — model, context gauge, usage bars.
    func testCaptureSessionStatus() throws {
        let app = try launchAgainstRig()

        let hero = app.staticTexts["Fix the flaky upload test"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        hero.tap()
        let info = app.buttons["Session status"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        sleep(2) // let the status frame replay on viewing
        info.tap()
        let model = app.staticTexts["claude-fable-5"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), "status sheet never showed model")
        sleep(1)
        try save("ios-06-session-status")
    }

    /// Parent chat with a running subagent — the sub-chat strip.
    func testCaptureSubChat() throws {
        let app = try launchAgainstRig()

        let parent = app.staticTexts["Refactor auth middleware"]
        XCTAssertTrue(parent.waitForExistence(timeout: 20))
        parent.tap()
        let child = app.staticTexts["Explore: auth call sites"]
        XCTAssertTrue(child.waitForExistence(timeout: 10), "sub-chat strip never appeared")
        sleep(2)
        try save("ios-07-subchat")
    }

    private func launchAgainstRig() throws -> XCUIApplication {
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"),
              (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("screenshot rig not running (127.0.0.1:9810)")
        }
        let app = XCUIApplication()
        app.launch()
        dismissNotificationAlert()
        return app
    }
}
