import XCTest
import UIKit

/// An item reply that hasn't been sent stays in the reply box when you
/// leave the item and come back, and when the app restarts. Runs against
/// the item thread rig (rig/README.md "Item thread rig"); skips when the
/// rig isn't running. Writes a picture of each step to `SCREENSHOT_DIR`
/// (default /tmp/matron-unsent-reply).
final class UnsentReplyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let typed = "Draft I haven't sent yet"

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("item thread rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// The item's reply field, not the chat composer under the item page.
    private var reply: XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@ OR value == %@", "Reply…", typed)).firstMatch
    }
    private var attachmentChip: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove ")).firstMatch
    }

    /// Opens the seeded question from For you. The rig's seed leaves it
    /// waiting on the agent: set it to wait on the user first
    /// (`UPDATE items SET awaiting='user' WHERE num=4` on the rig's database).
    private func openItem() {
        let tab = app.tabBars.buttons["For you"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Pick a replacement for the upload retry queue")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded item is not listed")
        row.tap()
        XCTAssertTrue(app.collectionViews["item.thread"].waitForExistence(timeout: 15), "the item didn't open")
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        sleep(1)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/matron-unsent-reply"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// A small picture on the pasteboard, as a screenshot copied elsewhere.
    private func putPictureOnThePasteboard() {
        let size = CGSize(width: 120, height: 80)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        UIPasteboard.general.image = image
    }

    func test_anUnsentReplySurvivesLeavingTheItemAndARestart() {
        openItem()
        // A reply an earlier run left in the box goes first.
        while attachmentChip.exists { attachmentChip.tap() }
        reply.tap()
        if let left = reply.value as? String, left == typed {
            reply.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left.count))
        }
        reply.typeText(typed)
        putPictureOnThePasteboard()
        reply.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the reply field's menu")
        paste.tap()
        XCTAssertTrue(attachmentChip.waitForExistence(timeout: 5), "the picture didn't join the reply")
        capture("1-before-leaving")

        app.navigationBars.buttons.firstMatch.tap()
        openItem()
        capture("2-after-coming-back")
        XCTAssertEqual(reply.value as? String, typed, "the typed text is gone")
        XCTAssertTrue(attachmentChip.exists, "the picture is gone")

        app.terminate()
        app.launch()
        openItem()
        capture("3-after-restart")
        XCTAssertEqual(reply.value as? String, typed, "the typed text is gone after a restart")
        XCTAssertTrue(attachmentChip.exists, "the picture is gone after a restart")
    }
}
