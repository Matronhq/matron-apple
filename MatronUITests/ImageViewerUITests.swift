import XCTest

/// The fullscreen image viewer opened from a chat picture, against the
/// local rig seeded with `seed-photos.mjs` (see rig/README.md "Image
/// viewer rig"). Skips when the rig isn't running, so normal scheme runs
/// are unaffected.
final class ImageViewerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("image viewer rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// Opens the seeded chat, taps a picture and returns where the viewer
    /// opened (1-based). The viewer pages through all four, oldest first;
    /// which one is tapped depends on how much of the chat is on screen.
    @discardableResult
    private func openAPicture() -> Int {
        let tab = app.tabBars.buttons["Conversations"]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Photo swipe check")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chat titled Photo swipe check — seed-photos.mjs not run?")
        row.tap()
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let first = timeline.images.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the chat's pictures loaded")
        for _ in 0..<6 where !first.isHittable { timeline.swipeDown() }
        first.tap()
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'Image [0-9] of 4'")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "a chat picture opens on every picture in the chat")
        let position = Int(counter.label.split(separator: " ")[1]) ?? 0
        XCTAssertTrue((1...4).contains(position))
        return position
    }

    private func expectCounter(_ label: String, _ message: String) {
        XCTAssertTrue(app.staticTexts["Image \(label)"].waitForExistence(timeout: 5), message)
    }

    /// A finger drag from the middle of the screen, `dx` points sideways,
    /// released at `velocity` — closer to a thumb than `swipeLeft()`,
    /// which always travels half the screen.
    private func drag(dx: CGFloat, velocity: XCUIGestureVelocity) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: velocity, thenHoldForDuration: 0)
    }

    /// A short, quick flick pages, as in Photos. With a distance-only rule
    /// it travelled under the 100pt threshold and sprang back.
    func test_aShortQuickFlickStepsToTheNeighbour() {
        var position = openAPicture()
        if position == 4 {
            app.swipeRight()
            position = 3
            expectCounter("3 of 4", "a long swipe steps back")
        }
        drag(dx: -70, velocity: .fast)
        expectCounter("\(position + 1) of 4", "a 70pt flick left steps forward")
        drag(dx: 70, velocity: .fast)
        expectCounter("\(position) of 4", "a 70pt flick right steps back")
        app.swipeLeft()
        expectCounter("\(position + 1) of 4", "a long swipe still steps forward")
    }

    /// A short drag released at rest is not a swipe: the picture springs
    /// back and the viewer stays put.
    func test_aShortSlowDragStaysOnThePicture() {
        var position = openAPicture()
        if position == 4 {
            app.swipeRight()
            position = 3
            expectCounter("3 of 4", "a long swipe steps back")
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Drag 60pt, then hold still before lifting so no momentum is left.
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertFalse(app.staticTexts["Image \(position + 1) of 4"].waitForExistence(timeout: 2),
                       "a slow 60pt drag does not page")
        XCTAssertTrue(app.staticTexts["Image \(position) of 4"].exists)
    }
}
