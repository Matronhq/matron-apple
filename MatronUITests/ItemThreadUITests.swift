import XCTest

/// The native item thread in the real app, against the local rig seeded
/// with `seed-item.mjs` (see rig/README.md "Item thread rig"). Skips when
/// the rig isn't running, so normal scheme runs are unaffected.
final class ItemThreadUITests: XCTestCase {
    private var app: XCUIApplication!
    private let title = "Pick a replacement for the upload retry queue"

    private var outputDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/matron-item-thread",
            isDirectory: true)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("item thread rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launchArguments += ["-items.thread.native", "YES"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private var thread: XCUIElement { app.collectionViews["item.thread"] }

    private func save(_ name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func openItem() {
        let tab = app.tabBars.buttons["For you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded item is not listed")
        row.tap()
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "the native thread is not mounted")
    }

    private var reply: XCUIElement {
        app.textFields.firstMatch
    }

    private func prose(_ marker: String) -> XCUIElement {
        thread.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
    }

    func test_theThreadStartsBelowTheNavigationBar_andEndsAtTheReplyField() {
        openItem()
        let heading = app.staticTexts[title]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(heading.frame.minY, app.navigationBars.firstMatch.frame.maxY,
                                    "the title is clear of the navigation bar")
        XCTAssertLessThanOrEqual(thread.frame.maxY, reply.frame.minY, "the thread ends above the reply field")
    }

    func test_theKeyboardLiftsTheReplyField_andTheLatestCommentStaysReachable() {
        openItem()
        reply.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        reply.typeText("Starting on Monday")
        XCTAssertLessThanOrEqual(reply.frame.maxY, keyboard.frame.minY, "the reply field sits on the keyboard")
        XCTAssertLessThanOrEqual(thread.frame.maxY, reply.frame.minY, "the thread ends above the reply field")

        app.buttons["chat.jumpToBottom"].tap()
        let latest = prose("No schema change")
        XCTAssertTrue(latest.waitForExistence(timeout: 5), "the latest comment is drawn")
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(start.frame.maxY, reply.frame.minY, "its buttons are above the reply field")
        XCTAssertTrue(start.isHittable)
    }

    func test_aTappedPictureOpensOverTheThread() {
        openItem()
        let picture = thread.images.matching(NSPredicate(format: "identifier == ''")).firstMatch
        for _ in 0..<12 where !(picture.exists && picture.isHittable) {
            thread.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(picture.exists && picture.isHittable, "the body's picture is in the thread")
        picture.tap()
        XCTAssertTrue(app.buttons["Close image preview"].waitForExistence(timeout: 5),
                      "the picture opens over the thread")
    }

    /// Pictures of the same steps in both threads, to compare by eye.
    func test_captureBothThreads() throws {
        for native in [true, false] {
            let name = native ? "native" : "swiftui"
            app.terminate()
            app.launchArguments = ["-items.thread.native", native ? "YES" : "NO"]
            app.launch()
            let tab = app.tabBars.buttons["For you"]
            XCTAssertTrue(tab.waitForExistence(timeout: 15))
            tab.tap()
            let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
            sleep(3)
            XCTAssertEqual(thread.exists, native, "the switch picks the thread")
            try save("\(name)-1-open")
            let reply = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Reply'")).firstMatch
            reply.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            reply.typeText("Starting on Monday")
            sleep(1)
            try save("\(name)-2-keyboard")
            app.buttons["chat.jumpToBottom"].tap()
            sleep(2)
            try save("\(name)-3-latest-with-keyboard")
            app.swipeDown(velocity: .slow)
            sleep(1)
            try save("\(name)-4-after-drag")
            for step in 5...8 {
                app.swipeDown(velocity: .slow)
                sleep(1)
                try save("\(name)-\(step)-scrolled-up")
            }
        }
    }
}
