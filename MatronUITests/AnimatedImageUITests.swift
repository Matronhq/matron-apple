import XCTest

/// Animated GIFs play in the chat timeline, the fullscreen viewer and the
/// item thread, against the local rig seeded with `seed-gifs.mjs` (see
/// rig/README.md "Animated GIF rig"). Skips when the rig isn't running, so
/// normal scheme runs are unaffected.
///
/// "Plays" is checked the only way a UI test can see it: two captures of
/// the same picture a moment apart differ. A still frame never would.
final class AnimatedImageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("GIF rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// Whether `element` shows something different `interval` later.
    private func isMoving(_ element: XCUIElement, interval: TimeInterval = 0.35) -> Bool {
        let before = element.screenshot().pngRepresentation
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: interval)
            if element.screenshot().pngRepresentation != before { return true }
        }
        return false
    }

    private func openChat() -> XCUIElement {
        let tab = app.tabBars.buttons["Conversations"]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Loading spinner options")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chat titled Loading spinner options — seed-gifs.mjs not run?")
        row.tap()
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        return timeline
    }

    func test_aGIFPlaysInTheChat_andInTheViewer() {
        let timeline = openChat()
        let gif = timeline.images.matching(NSPredicate(format: "label == %@", "Animated image")).firstMatch
        XCTAssertTrue(gif.waitForExistence(timeout: 10), "the chat's GIFs loaded as animations")
        for _ in 0..<6 where !gif.isHittable { timeline.swipeDown() }
        XCTAssertTrue(isMoving(gif), "the GIF plays in the timeline")

        gif.tap()
        let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Image '")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "the viewer opened")
        let viewerGIF = app.images.matching(NSPredicate(format: "label == %@", "Animated image")).firstMatch
        XCTAssertTrue(viewerGIF.waitForExistence(timeout: 5))
        XCTAssertTrue(isMoving(viewerGIF), "the GIF plays in the fullscreen viewer")
    }

    func test_aGIFPlaysInTheItemThread() {
        let tab = app.tabBars.buttons["For you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Which loading animation")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no item — seed-gifs.mjs not run?")
        row.tap()
        let gif = app.images.matching(NSPredicate(format: "label == %@", "Animated image")).firstMatch
        XCTAssertTrue(gif.waitForExistence(timeout: 15), "the item's GIFs loaded as animations")
        XCTAssertTrue(isMoving(gif), "the GIF plays in the item thread")
    }
}
