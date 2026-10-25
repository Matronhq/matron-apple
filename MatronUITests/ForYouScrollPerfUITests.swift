import XCTest

/// How smoothly For you scrolls, on the local rig seeded with
/// `RIG_FORYOU=1` (see rig/README.md): flicks up and down the Needs you
/// list and the Done list, with the system's scroll hitch metrics.
/// Skips when the rig isn't running, so normal scheme runs are unaffected.
///
/// The simulator reports no hitch metrics, so the app's own
/// `ScrollFramesProbe` counts them: build Release with `MATRON_PERF_PROBE`,
/// run one test at a time, and read `tmp/scroll-frames.json` in the app's
/// data container afterwards.
final class ForYouScrollPerfUITests: XCTestCase {
    private var app: XCUIApplication!
    private var port: String { ProcessInfo.processInfo.environment["RIG_PORT"] ?? "9810" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:\(port)/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("rig not running (127.0.0.1:\(port))")
        }
        app = XCUIApplication()
        app.launchEnvironment["MATRON_PERF_SCROLL_FRAMES"] = "1"
        if name.contains("InApp") {
            app.launchEnvironment["MATRON_PERF_FLICKS"] = "\(Self.flicks)"
            app.launchEnvironment["MATRON_PERF_FLICK_AFTER_S"] = "20"
        }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let tab = app.tabBars.buttons["For you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "(80)")).firstMatch
            .waitForExistence(timeout: 30), "no seeded For you items — rig not seeded with RIG_FORYOU=1?")
    }

    private var list: XCUIElement { app.collectionViews.firstMatch }

    /// Flicks down the list and back up again.
    private func flick(_ times: Int) {
        for _ in 0..<times { list.swipeUp(velocity: .fast) }
        for _ in 0..<times { list.swipeDown(velocity: .fast) }
    }

    /// Flicks each way, from `FORYOU_FLICKS` (default 10); for the in-app
    /// flicks, end-to-end passes each way.
    private static var flicks: Int {
        ProcessInfo.processInfo.environment["FORYOU_FLICKS"].flatMap(Int.init) ?? 10
    }

    func test_needsYouScroll() {
        flick(Self.flicks)
    }

    /// The app flicks the list itself (`MATRON_PERF_FLICKS`) while the
    /// runner sleeps, so no element query stalls the frames measured.
    func test_needsYouFlicksInApp() {
        // About 12 s for each end-to-end pass of the seeded list.
        sleep(UInt32(25 + Self.flicks * 2 * 12))
    }

    /// Pictures of both tabs, written to `SHOT_DIR` (default /tmp).
    func test_shots() throws {
        let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? "/tmp"
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/foryou-needs-you.png"))
        app.buttons["Done"].firstMatch.tap()
        sleep(2)
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/foryou-done.png"))
    }

    func test_doneScroll() {
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Settled")).firstMatch
            .waitForExistence(timeout: 10))
        flick(Self.flicks)
    }
}
