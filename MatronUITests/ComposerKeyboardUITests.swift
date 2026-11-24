import XCTest

/// The chat composer's pull-down hides the keyboard, from the row's
/// margins and from the text itself, but drags the text takes for itself
/// (moving the caret, dragging a selection handle) keep it up. Runs
/// against the local rig's "Selection rig" conversation (rig/README.md
/// "Timeline rig"); skips when the rig isn't running.
final class ComposerKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("timeline rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    /// Opens the Selection rig chat and types a draft into the composer.
    private func composerWithDraft() -> XCUIElement {
        let tab = app.tabBars.buttons["Conversations"]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Selection rig")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Selection rig chat")
        row.tap()
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        field.typeText("Hi there")
        // The simulator's keyboard now and then drops on its own just
        // after typing; start from a settled, visible keyboard.
        Thread.sleep(forTimeInterval: 1)
        if !keyboard.exists { field.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        return field
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func assertKeyboardStays(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        // Give a dismissal time to happen before checking it didn't.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(keyboard.exists, "\(step) hid the keyboard", file: file, line: line)
    }

    /// Long-press the draft and drag the caret down past the composer.
    func test_movingTheCaretDownKeepsTheKeyboard() {
        let field = composerWithDraft()
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 200)))
        attach("after caret drag")
        assertKeyboardStays("moving the caret down")
    }

    /// Select the draft, then drag the end handle (just under the end of
    /// the text) down past the composer.
    func test_draggingASelectionHandleDownKeepsTheKeyboard() {
        let field = composerWithDraft()
        field.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "no Select All in the composer's menu")
        selectAll.tap()
        // Let the selection and its handles settle before grabbing one.
        Thread.sleep(forTimeInterval: 0.5)
        attach("selected")
        let handle = field.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 72, dy: field.frame.height - 6))
        handle.press(forDuration: 0.3, thenDragTo: handle.withOffset(CGVector(dx: 10, dy: 220)))
        attach("after handle drag")
        assertKeyboardStays("dragging a selection handle down")
    }

    /// A pull-down that starts on the row's margin, beside the field,
    /// still hides the keyboard.
    func test_pullingDownBesideTheFieldHidesTheKeyboard() {
        let field = composerWithDraft()
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 4, dy: field.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keyboard)
        wait(for: [gone], timeout: 5)
        assertKeyboardStaysHidden()
    }

    /// A swipe down that starts on the text itself hides the keyboard,
    /// as in Messages: only drags the text takes for itself keep it up.
    func test_swipingDownOnTheFieldHidesTheKeyboard() {
        let field = composerWithDraft()
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)),
                    withVelocity: .default, thenHoldForDuration: 0.3)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keyboard)
        wait(for: [gone], timeout: 5)
        assertKeyboardStaysHidden()
    }

    /// Opens the rig's seeded item (rig/README.md "Item thread rig") and
    /// types a draft into its reply field.
    private func itemReplyWithDraft() throws -> XCUIElement {
        let tab = app.tabBars.buttons["For you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let title = "Pick a replacement for the upload retry queue"
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        guard row.waitForExistence(timeout: 10) else { throw XCTSkip("item thread rig not seeded") }
        row.tap()
        XCTAssertTrue(app.collectionViews["item.thread"].waitForExistence(timeout: 10))
        let field = app.textFields["item.reply.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no reply field")
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        field.typeText("Hi there")
        Thread.sleep(forTimeInterval: 1)
        if !keyboard.exists { field.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        return field
    }

    /// The item reply field: a swipe down on the text hides the keyboard.
    func test_itemReply_swipingDownOnTheFieldHidesTheKeyboard() throws {
        let field = try itemReplyWithDraft()
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)),
                    withVelocity: .default, thenHoldForDuration: 0.3)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keyboard)
        wait(for: [gone], timeout: 5)
        assertKeyboardStaysHidden()
    }

    /// The item reply field: moving the caret down keeps the keyboard.
    func test_itemReply_movingTheCaretDownKeepsTheKeyboard() throws {
        let field = try itemReplyWithDraft()
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 200)))
        attach("after item caret drag")
        assertKeyboardStays("moving the caret down in an item reply")
    }

    private func assertKeyboardStaysHidden(file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(keyboard.exists, "the keyboard came back", file: file, line: line)
    }
}
