import XCTest

/// Text selection and whole-message copy in the UIKit timeline, against the
/// local rig's "Selection rig" conversation (rig/README.md "Timeline rig").
/// Skips when the rig isn't running.
final class ChatSelectionUITests: XCTestCase {
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

    private var timeline: XCUIElement { app.collectionViews["chat.timeline"] }

    private func message(_ marker: String) -> XCUIElement {
        timeline.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
    }

    private func openSelectionChat() {
        let tab = app.tabBars.buttons["Conversations"]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Selection rig")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Selection rig chat")
        row.tap()
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertTrue(message("SEL-AFTER").waitForExistence(timeout: 10))
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Taps the selection edit menu's Copy (the menu item, not the row
    /// menu's or a code block's button).
    private func copySelection(file: StaticString = #filePath, line: UInt = #line) {
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no selection edit menu", file: file, line: line)
        copy.tap()
    }

    /// Pastes the pasteboard into the composer after a fresh marker, sends
    /// it, and returns the sent message's text. (The composer field reports
    /// only its first line as its value.)
    private func pastedText(file: StaticString = #filePath, line: UInt = #line) -> String {
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
        let marker = "PASTE-\(UUID().uuidString.prefix(6))"
        field.typeText(marker + " ")
        field.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the composer's menu", file: file, line: line)
        paste.tap()
        attach("pasted")
        app.buttons["composer.send"].tap()
        let sent = message(marker)
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the pasted message never arrived", file: file, line: line)
        return ((sent.value as? String) ?? "").replacingOccurrences(of: marker + " ", with: "")
    }

    /// A drag from the paragraph above a code block carries on into the
    /// paragraph below it, and the copy has the code in between. The code
    /// block used to be a separate text view the selection stopped at.
    func test_selectionDragCrossesACodeBlock() {
        openSelectionChat()
        let message = message("SEL-CODE-A")
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        // From "SEL-CODE-A" on the first line down to the last line of the
        // paragraph after the code block (its own element before the fix).
        // Mostly downward: a sideways drag is the system's back swipe.
        let below = self.message("SEL-CODE-B")
        let start = point(message.frame.minX + 30, message.frame.minY + 10)
        // UIKit keeps a dragged selection end about a line above the finger.
        let end = point(below.frame.minX + 150, below.frame.maxY + 20)
        start.press(forDuration: 1.0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        attach("dragged across the code block")
        copySelection()
        let copied = pastedText()
        XCTAssertTrue(copied.contains("queue.start()"), "the copy stopped before the code block: \(copied)")
        XCTAssertTrue(copied.contains("after the code block"), "the copy stopped before the last paragraph: \(copied)")
        XCTAssertFalse(copied.contains("\u{FFFC}"), "a placeholder leaked into the copy: \(copied)")
    }

    /// Holding the drag at the bottom edge scrolls the chat on and carries
    /// the selection to the end of a message taller than the screen.
    func test_selectionDragScrollsOnAtTheEdge() {
        openSelectionChat()
        let long = message("SEL-P01")
        // Earlier tests may have sent messages under it.
        for _ in 0..<8 where !long.exists {
            timeline.swipeDown(velocity: .slow)
            sleep(1)
        }
        XCTAssertTrue(long.waitForExistence(timeout: 10))
        // The reply's top on screen; its end is then below the fold.
        for _ in 0..<8 where long.frame.minY < timeline.frame.minY + 40 {
            timeline.swipeDown(velocity: .slow)
            sleep(1)
        }
        XCTAssertGreaterThan(long.frame.maxY, timeline.frame.maxY, "the long reply fits on screen")
        let frame = long.frame
        let start = point(frame.minX + 40, max(frame.minY, timeline.frame.minY) + 150)
        let edge = point(frame.minX + 120, timeline.frame.maxY - 6)
        start.press(forDuration: 1.0, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 5.0)
        attach("held at the bottom edge")
        copySelection()
        let copied = pastedText()
        XCTAssertTrue(copied.contains("SEL-P14"), "the selection stopped at the screen edge: \(copied.suffix(120))")
    }

    /// A long-press on the blank space past a short last line opens the
    /// row's menu, whose Copy copies the whole message.
    func test_pressBesideTheTextCopiesTheWholeMessage() {
        openSelectionChat()
        let message = message("SEL-CODE-B")
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let frame = message.frame
        // Right of "lines.", the last line's only word.
        point(frame.maxX - 30, frame.maxY - 10).press(forDuration: 1.2)
        let copies = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
        let menu = expectation(for: NSPredicate { _, _ in
            copies.allElementsBoundByIndex.contains { $0.frame.width > 40 }
        }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [menu], timeout: 5), .completed, "no row menu with Copy")
        attach("row menu")
        XCTAssertFalse(app.menuItems["Look Up"].exists, "the press selected text instead of opening the row menu")
        copies.allElementsBoundByIndex.first { $0.frame.width > 40 }?.tap()
        let copied = pastedText()
        XCTAssertTrue(copied.hasPrefix("SEL-CODE-A"), "not the whole message: \(copied)")
        XCTAssertTrue(copied.contains("SEL-CODE-B"), "not the whole message: \(copied)")
    }
}
