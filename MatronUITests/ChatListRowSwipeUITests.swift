import XCTest

/// A row's swipe-to-archive against the swipe between tabs, on the
/// Conversations list of the local rig (see rig/README.md, any seed).
/// Skips when the rig isn't running, so normal scheme runs are unaffected.
/// The last test archives a row: rebuild the rig before running again.
final class ChatListRowSwipeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var port: String { ProcessInfo.processInfo.environment["RIG_PORT"] ?? "9810" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:\(port)/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("rig not running (127.0.0.1:\(port))")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let tab = app.tabBars.buttons["Conversations"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
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

    private func row(_ title: String) -> XCUIElement {
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chat titled \(title) — rig not seeded?")
        return row
    }

    /// A finger drag from `element`, `dx` points sideways.
    private func drag(from element: XCUIElement, dx: CGFloat, velocity: XCUIGestureVelocity = .default) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: velocity, thenHoldForDuration: 0.1)
    }

    private func expectSelected(_ tab: String, _ message: String) {
        let button = app.tabBars.buttons[tab]
        let selected = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: selected, evaluatedWith: button)], timeout: 3),
                       .completed, message)
    }

    /// Swiping a row left shows its Archive button and stays on the list.
    func test_a_rowSwipeRevealsArchive_andStaysOnTheList() {
        let target = row("Draft the 2.4 release notes")
        shot("01-list")
        drag(from: target, dx: -140)
        sleep(1)
        shot("02-after-row-swipe")
        XCTAssertTrue(app.buttons["Archive"].firstMatch.waitForExistence(timeout: 3), "the row's Archive button")
        expectSelected("Conversations", "a row swipe must not also switch tabs")
    }

    /// A drag right on a row (which has no leading action) still switches
    /// tabs, as does a drag left started off the rows.
    func test_b_pageSwipeStillWorksOutsideARowsSwipeAction() {
        drag(from: row("Draft the 2.4 release notes"), dx: 200)
        expectSelected("For you", "a right drag on a row goes to the previous tab")
        app.tabBars.buttons["Conversations"].tap()
        let header = app.staticTexts["Today"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        drag(from: header, dx: -200)
        expectSelected("Settings", "a left drag on a section header goes to the next tab")
    }

    /// Archiving from the swipe archives the row and stays on the list.
    /// (A row clear of the tab bar: a drag started on the bar slides
    /// between its tabs.)
    func test_c_rowSwipeArchive_archivesAndStaysOnTheList() {
        let target = row("Dark mode for settings screen")
        drag(from: target, dx: -140)
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3), "the row's Archive button")
        archive.tap()
        sleep(1)
        shot("03-after-archive")
        expectSelected("Conversations", "archiving from a row swipe must not also switch tabs")
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: target)], timeout: 5),
                       .completed, "the row archived")
    }
}
