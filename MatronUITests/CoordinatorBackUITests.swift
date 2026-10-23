import XCTest

/// Back out of the Coordinator conversation, against the local rig seeded
/// with `seed-coordinator.mjs` (see rig/README.md "Coordinator rig").
/// Runs only with `TEST_RUNNER_RIG_COORDINATOR=1` and the rig up, so
/// normal scheme runs and the other rigs are unaffected. `RIG_PORT` (the
/// runner strips the `TEST_RUNNER_` prefix) points it at another port.
final class CoordinatorBackUITests: XCTestCase {
    private var app: XCUIApplication!
    private var port: String { ProcessInfo.processInfo.environment["RIG_PORT"] ?? "9810" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Other rigs serve the same port without the Coordinator seed.
        guard ProcessInfo.processInfo.environment["RIG_COORDINATOR"] == "1" else {
            throw XCTSkip("coordinator rig not requested (TEST_RUNNER_RIG_COORDINATOR=1)")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("coordinator rig not running (127.0.0.1:\(port))")
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

    /// Opens the seeded chat that links to the Coordinator and taps the link.
    private func openTheCoordinatorFromALink() {
        let tab = app.tabBars.buttons["Conversations"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Fix the flaky upload test")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let link = app.links["Coordinator"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the seeded matron://convo link to the Coordinator — seed-coordinator.mjs not run?")
        link.tap()
    }

    /// The Coordinator opened from a link in another chat has a Back
    /// button that returns to that chat.
    func test_coordinatorOpenedFromALink_backReturnsToTheChat() {
        openTheCoordinatorFromALink()
        sleep(2)
        shot("02-coordinator-from-link")
        let back = app.navigationBars.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "a Back button on the Coordinator opened from a link")
        back.tap()
        XCTAssertTrue(app.links["Coordinator"].firstMatch.waitForExistence(timeout: 5), "Back returns to the chat with the link")
        shot("03-after-back")
    }

    /// The same, by a swipe from the left edge.
    func test_coordinatorOpenedFromALink_edgeSwipeReturnsToTheChat() {
        openTheCoordinatorFromALink()
        sleep(2)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 250, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.links["Coordinator"].firstMatch.waitForExistence(timeout: 5), "an edge swipe returns to the chat with the link")
        shot("04-after-edge-swipe")
    }

    /// Reached through its own tab, the Coordinator is a tab root: no
    /// Back, the tab bar showing.
    func test_coordinatorTab_isARootWithTheTabBar() {
        let tab = app.tabBars.buttons["Coordinator"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        sleep(2)
        shot("01-coordinator-tab")
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "the tab bar shows at the Coordinator root")
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists, "a tab root has nothing to go back to")
    }
}
