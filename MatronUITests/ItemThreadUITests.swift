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

    /// A tap on the bar's top line, the item's kind, number and status,
    /// which leave the tap to the bar; the mission line under them opens
    /// the mission instead.
    private func scrollToTopTap() {
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
    }

    private var reply: XCUIElement {
        app.textFields.firstMatch
    }

    private func prose(_ marker: String) -> XCUIElement {
        thread.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
    }

    /// The paperclip's Photo / File choice opens from the paperclip, at the
    /// bottom of the screen. It was a confirmation dialog on the whole
    /// page, which iOS 26 shows as a popover from the page's top.
    func test_theAttachChoiceOpensFromThePaperclip() {
        openItem()
        let paperclip = app.buttons["Attach"]
        XCTAssertTrue(paperclip.waitForExistence(timeout: 5))
        paperclip.tap()
        // "Photo" now; "Photo Library" in the dialog it replaces.
        let photo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "no attach choice")
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                                    "File", "Choose File")).firstMatch
        XCTAssertTrue(file.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "attach choice"
        shot.lifetime = .keepAlways
        add(shot)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(photo.frame.minY, screen.midY,
                             "the choice opened at the top (\(photo.frame)), not by the paperclip (\(paperclip.frame))")
        XCTAssertLessThan(paperclip.frame.minY - max(photo.frame.maxY, file.frame.maxY), 120,
                          "the choice is not next to the paperclip")
        file.tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", "Recents"))
                        .firstMatch.waitForExistence(timeout: 5)
                      || app.buttons["Cancel"].waitForExistence(timeout: 5), "File didn't open the file picker")
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Taps the selection edit menu's Copy, pastes into the reply field and
    /// returns what landed there.
    private func copySelectionAndPaste(file: StaticString = #filePath, line: UInt = #line) -> String {
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no selection edit menu", file: file, line: line)
        copy.tap()
        reply.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
        reply.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the reply field's menu", file: file, line: line)
        paste.tap()
        return (reply.value as? String) ?? ""
    }

    /// A drag from the item's first paragraph runs on through its list
    /// into the paragraphs after it. Long text used to be cut into runs of
    /// a few paragraphs, each a text view the selection stopped at.
    func test_aSelectionDragRunsOnThroughParagraphs() {
        openItem()
        let body = prose("The ask:")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let start = point(body.frame.minX + 30, body.frame.minY + 8)
        // Down to the list's last lines, clear of the edge that scrolls.
        // Mostly downward: a sideways drag is the system's back swipe.
        let end = point(body.frame.minX + 120, thread.frame.minY + thread.frame.height * 0.62)
        start.press(forDuration: 1.0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        attach("dragged through the list")
        let copied = copySelectionAndPaste()
        XCTAssertTrue(copied.contains("Survive the app being closed"), "the copy stopped before the list: \(copied)")
        XCTAssertFalse(copied.contains("\u{FFFC}"), "a placeholder leaked into the copy: \(copied)")
    }

    /// Holding the drag at the bottom edge scrolls the thread on and
    /// carries the selection to the end of an item taller than the screen.
    func test_aSelectionDragScrollsOnAtTheEdge() {
        openItem()
        let body = prose("The ask:")
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        let start = point(body.frame.minX + 30, body.frame.minY + 8)
        let edge = point(body.frame.minX + 120, thread.frame.maxY - 6)
        start.press(forDuration: 1.0, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 6.0)
        attach("held at the bottom edge")
        let copied = copySelectionAndPaste()
        XCTAssertTrue(copied.contains("My recommendation"), "the selection stopped at the screen edge: \(copied.suffix(160))")
        XCTAssertTrue(copied.contains("min(60, 1 << attempt)"), "the code block is missing from the copy: \(copied)")
    }

    /// A code block lies under the card's text, on one of its lines, and
    /// still takes its own taps: its copy button copies the code.
    func test_aCodeBlocksCopyButton_copiesTheCode() {
        openItem()
        let button = thread.buttons["Copy code"].firstMatch
        func onScreen() -> Bool {
            button.exists && button.frame.minY > thread.frame.minY + 120 && button.frame.maxY < thread.frame.maxY - 120
        }
        for _ in 0..<12 where !onScreen() {
            thread.swipeUp(velocity: .slow)
            sleep(1)
        }
        XCTAssertTrue(onScreen(), "no code block in the thread")
        // Where it is drawn: XCTest's hit-test finds the card's text over
        // it, as in the chat, but a finger reaches the button.
        point(button.frame.midX, button.frame.midY).tap()
        reply.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reply.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the reply field's menu")
        paste.tap()
        let pasted = (reply.value as? String) ?? ""
        XCTAssertTrue(pasted.contains("min(60, 1 << attempt)"), "not the code: \(pasted)")
    }

    /// A long-press inside a comment's card, beside its text, offers Copy,
    /// which copies the whole comment.
    func test_aPressBesideACommentsText_copiesTheWholeComment() {
        openItem()
        app.buttons["chat.jumpToBottom"].tap()
        let latest = prose("No schema change")
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        // Above the text, by the caption's right end: inside the card,
        // on no piece of it that has a menu of its own.
        let frame = latest.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 12, dy: frame.minY - 10))
            .press(forDuration: 1.2)
        let copy = app.buttons.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no Copy for the comment")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "card menu"
        shot.lifetime = .keepAlways
        add(shot)
        copy.tap()
        reply.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reply.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the reply field's menu")
        paste.tap()
        let pasted = (reply.value as? String) ?? ""
        XCTAssertTrue(pasted.hasPrefix("No schema change"), "not the comment: \(pasted)")
        XCTAssertTrue(pasted.hasSuffix("Shall I start on the endpoint?"), "not the whole comment: \(pasted)")
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
        scrollToTopTap()
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }

    func test_theNavigationBar_showsTheItem_andItsMissionOpensTheMission() {
        openItem()
        let summary = app.descendants(matching: .any)["item.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Needs you"), "the status is in the bar: \(summary.label)")
        let mission = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Upload reliability")).firstMatch
        XCTAssertTrue(mission.waitForExistence(timeout: 5), "the mission is in the bar")
        XCTAssertFalse(prose("Upload reliability").exists, "and not repeated under the title")
        mission.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Needs you ·")).firstMatch
            .waitForExistence(timeout: 10), "the mission page opens")
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
        scrollToTopTap()
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

