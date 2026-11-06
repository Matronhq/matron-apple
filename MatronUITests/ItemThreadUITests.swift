import XCTest

/// The item thread in the real app, against the local rig seeded
/// with `seed-item.mjs` (see rig/README.md "Item thread rig"). Skips when
/// the rig isn't running, so normal scheme runs are unaffected.
final class ItemThreadUITests: XCTestCase {
    private var app: XCUIApplication!
    private let title = "Pick a replacement for the upload retry queue"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("item thread rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private var thread: XCUIElement { app.collectionViews["item.thread"] }

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

    func test_theJumpArrowShowsOnOpening_andAfterReturning() {
        openItem()
        let arrow = app.buttons["chat.jumpToBottom"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 5), "a long thread opened at the top offers the jump")

        // The comments are in the store now, so they are there at first layout.
        thread.swipeUp(velocity: .slow)
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        XCTAssertTrue(arrow.waitForExistence(timeout: 5), "reopened, it offers the jump again")
    }

    func test_aThreadReadToTheEnd_reopensAtTheEnd_withoutTheJump() {
        openItem()
        let arrow = app.buttons["chat.jumpToBottom"]
        arrow.tap()
        XCTAssertTrue(prose("No schema change").waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        // The bar settles after the push; nothing may move the reader off
        // the end then.
        XCTAssertFalse(arrow.waitForExistence(timeout: 3), "reopened at the end, it offers no jump")

        // The app remembers, on leaving, a thread left at its end and opens
        // it there next time; the other tests start at the top.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }

    func test_tappingTheNavigationBar_goesToTheTop() {
        openItem()
        app.buttons["chat.jumpToBottom"].tap()
        let heading = app.staticTexts[title]
        let gone = NSPredicate(format: "isHittable == false OR exists == false")
        expectation(for: gone, evaluatedWith: heading)
        waitForExpectations(timeout: 5)

        let bar = app.navigationBars.firstMatch
        XCTAssertLessThan(bar.frame.height, 70, "the bar is one row: no empty large-title row under it")
        let target = app.descendants(matching: .any)["item.scrollToTop"]
        XCTAssertGreaterThan(target.frame.width, bar.frame.width / 2, "most of the bar's middle answers the tap")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: heading)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThanOrEqual(heading.frame.minY, bar.frame.maxY, "the top of the thread is in view")
        XCTAssertTrue(app.buttons["chat.jumpToBottom"].waitForExistence(timeout: 5), "and the jump is offered")
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

    /// The viewer pages through every picture in the thread — the item's
    /// own, then the comments' — with a sideways swipe, as ←/→ do on Mac.
    /// The seed has four: the body's and one on comments 4, 8 and 12.
    func test_aSidewaysSwipeStepsThroughTheThreadsPictures() {
        openItem()
        let picture = thread.images.matching(NSPredicate(format: "identifier == ''")).firstMatch
        for _ in 0..<12 where !(picture.exists && picture.isHittable) {
            thread.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(picture.exists && picture.isHittable, "the body's picture is in the thread")
        picture.tap()
        XCTAssertTrue(app.staticTexts["Image 1 of 4"].waitForExistence(timeout: 5),
                      "the viewer counts every picture in the thread")
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Image 2 of 4"].waitForExistence(timeout: 5), "a left swipe steps forward")
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Image 3 of 4"].waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["Image 2 of 4"].waitForExistence(timeout: 5), "a right swipe steps back")
    }
}

