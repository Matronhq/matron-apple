import XCTest

/// Marketing / App Store screenshot harness — NOT a correctness test.
///
/// Drives the real app against the marketing rig (MatronUITests/rig/marketing:
/// a throwaway local matron-journal on 127.0.0.1:9810 seeded with invented
/// work for a demo user) and writes full-resolution PNGs to `SCREENSHOT_DIR`
/// (default /tmp/shots-out), one per screen, plus a `.txt` of the visible
/// accessibility labels next to each so selector drift can be read instead of
/// guessed. Skips itself when the rig isn't running, so a normal full-scheme
/// test run is unaffected.
///
///   xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
///     -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-shots-dd \
///     -only-testing:MatronUITests/MarketingScreenshots
final class MarketingScreenshots: XCTestCase {
    var app: XCUIApplication!
    let out = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/shots-out"

    override func setUpWithError() throws {
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"),
              (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("marketing rig not running (127.0.0.1:9810)")
        }
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        app = XCUIApplication(); app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.tabBars.buttons["Conversations"].waitForExistence(timeout: 20))
        wait(2)
    }

    func wait(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    func shot(_ name: String) {
        wait(1.2)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        let labels = app.descendants(matching: .any).matching(NSPredicate(format: "label != ''"))
            .allElementsBoundByIndex.prefix(60).map { "\($0.elementType.rawValue):\($0.label.prefix(40))" }
        try? labels.joined(separator: "\n").write(toFile: "\(out)/\(name).txt", atomically: true, encoding: .utf8)
    }

    func tab(_ n: String) { app.tabBars.buttons[n].tap(); wait(1.5) }

    /// Chat-list rows prefix the title with the box tag letter, so match by suffix.
    func openChat(_ title: String) {
        tab("Conversations")
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no chat \(title)"); row.tap(); wait(2.5)
    }

    func text(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch
    }

    func test01Coordinator() { tab("Coordinator"); wait(2); shot("01-coordinator") }
    func test02LongChat() { openChat("Release checklist for 2.4"); shot("02-chat-pills-table") }
    func test03Projects() { tab("Projects"); wait(1.5); shot("03-projects") }
    func test04ProjectPage() {
        tab("Projects")
        // Cards expose "projects.card.<num>"; the first seeded project is #1.
        let card = app.descendants(matching: .any)["projects.card.1"]; XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap(); wait(2.5)
        shot("04-project-page"); app.swipeUp(); wait(1); shot("04b-project-page-lower")
        // The missions section sits below the roll-up; the row opens the mission page.
        let m = text("Ship release 2.4")
        if m.waitForExistence(timeout: 5) { m.tap(); wait(2.5); shot("04c-mission-page") }
    }
    func test05ItemThread() {
        tab("Decisions"); wait(1.5); shot("05a-decisions-list")
        let q = text("Which retry policy"); XCTAssertTrue(q.waitForExistence(timeout: 8)); q.tap(); wait(2.5)
        shot("05-item-thread")
    }
    func test06Memories() {
        tab("Projects")
        let b = app.descendants(matching: .any)["missions.memories"]; XCTAssertTrue(b.waitForExistence(timeout: 8)); b.tap(); wait(2)
        shot("06-memories")
    }
    func test07Find() {
        openChat("Release checklist for 2.4")
        app.buttons["Session info"].tap()
        let row = app.descendants(matching: .any)["session-find-in-chat-row"]; XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap(); wait(1.5)
        let f = app.textFields["Search in chat"]; XCTAssertTrue(f.waitForExistence(timeout: 5)); f.tap(); app.typeText("backoff\n"); wait(3)
        shot("07-find-in-chat")
    }
    func test08ModelPicker() {
        openChat("Release checklist for 2.4")
        app.buttons["Session info"].tap(); wait(1.5); shot("08a-session-sheet")
        let row = app.descendants(matching: .any)["session-model-row"]
        if row.waitForExistence(timeout: 5) { row.tap(); wait(1.5); shot("08-model-picker") }
        let eff = app.descendants(matching: .any)["session-effort-row"]
        if eff.exists { eff.tap(); wait(1.5); shot("08c-effort-picker") }
    }
    func test09SubChat() {
        openChat("Tidy up the sign-in code"); shot("09a-parent-with-strip")
        let b = app.buttons["Open subagent Find every sign-in call"]; XCTAssertTrue(b.waitForExistence(timeout: 8)); b.tap(); wait(2.5)
        shot("09-sub-chat")
    }
    func test10NewChat() {
        tab("Conversations"); shot("10a-conversations")
        app.buttons["New chat"].tap(); wait(3); shot("10-new-chat")
    }

    /// Debug helper — dumps the element tree. Not part of the capture set.
    func testDumpHierarchy() throws {
        wait(5)
        try app.debugDescription.write(toFile: "\(out)/hierarchy.txt", atomically: true, encoding: .utf8)
    }
}
