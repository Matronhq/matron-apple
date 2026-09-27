import XCTest

/// Spec §4 UI tests for the UIKit timeline, against the local rig seeded
/// with `perf-timeline` (see rig/README.md "Timeline rig"). Skips when the
/// rig isn't running, so normal scheme runs are unaffected.
final class ChatTimelineUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let url = URL(string: "http://127.0.0.1:9810/snapshot"), (try? Data(contentsOf: url)) != nil else {
            throw XCTSkip("timeline rig not running (127.0.0.1:9810)")
        }
        app = XCUIApplication()
        app.launchArguments += ["-chat.timeline.uikit", "YES"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    // MARK: Helpers

    private var timeline: XCUIElement { app.collectionViews["chat.timeline"] }

    private func openChat(titled title: String) {
        let tab = app.tabBars.buttons["Conversations"]
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let row = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no chat titled \(title)")
        row.tap()
    }

    private func openPerfChat() {
        openChat(titled: "Timeline perf rig")
        XCTAssertTrue(timeline.waitForExistence(timeout: 10), "UIKit timeline not mounted — flag argument ignored?")
    }

    private func message(_ marker: String) -> XCUIElement {
        timeline.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
    }

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        element.exists && timeline.frame.intersects(element.frame)
    }

    /// PERF numbers of the message text views intersecting the timeline.
    /// One snapshot round trip: per-element queries cost ~1 s a swipe.
    private func visibleMarkers() -> [Int] {
        guard let root = try? timeline.snapshot() else { return [] }
        let bounds = root.frame
        var markers: [Int] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .textView, bounds.intersects(node.frame),
               let value = node.value as? String,
               let range = value.range(of: #"PERF-\d{3}"#, options: .regularExpression),
               let number = Int(value[range].dropFirst(5)) {
                markers.append(number)
            }
            node.children.forEach(walk)
        }
        walk(root)
        return markers
    }

    /// `visibleMarkers()` once two consecutive reads agree — the fling has
    /// come to rest. `nil` if it is still moving after `timeout`.
    private func settledMarkers(timeout: TimeInterval = 5) -> [Int]? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = visibleMarkers()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = visibleMarkers()
            if !current.isEmpty, current == previous { return current }
            previous = current
        }
        return nil
    }

    /// Drags the timeline down (towards older rows) a screenful at a time,
    /// holding at the end so there is no fling to overshoot, until
    /// `element` sits wholly inside the timeline.
    private func scrollUp(toReveal element: XCUIElement, maxDrags: Int = 20) {
        for _ in 0..<maxDrags {
            if element.exists, timeline.frame.contains(element.frame) { return }
            let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25))
            let to = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    // MARK: Tests

    func test_opensAtTheBottom() {
        openPerfChat()
        let last = message("PERF-220")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertTrue(isOnScreen(last))
        XCTAssertFalse(app.buttons["chat.jumpToBottom"].exists)
    }

    func test_sendKeepsTheTailVisible() {
        openPerfChat()
        timeline.swipeDown()
        XCTAssertTrue(app.buttons["chat.jumpToBottom"].waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        let text = "uitest-\(UUID().uuidString.prefix(8))"
        field.typeText(text)
        app.buttons["composer.send"].tap()
        let sent = message(text)
        XCTAssertTrue(sent.waitForExistence(timeout: 10))
        XCTAssertTrue(isOnScreen(sent), "your own send returns to the tail")
    }

    func test_streamingReplyStaysPinned() throws {
        guard let agent = RigAgent() else { throw XCTSkip("RIG_AGENT_TOKEN not set") }
        openPerfChat()
        let ref = "uitest-\(UUID().uuidString.prefix(8))"
        let chunks = (1...12).map { " STREAM-\(String(format: "%02d", $0)) " + String(repeating: "more words ", count: 8) }
        let done = expectation(description: "streamed")
        Task.detached {
            do {
                try await agent.connect()
                try await agent.streamReply(convo: "perf-timeline", ref: ref, chunks: chunks)
                try await agent.finalize(convo: "perf-timeline", ref: ref, body: chunks.joined())
                agent.close()
            } catch {
                XCTFail("rig agent: \(error)")
            }
            done.fulfill()
        }
        for index in [4, 8, 12] {
            let marker = message(String(format: "STREAM-%02d", index))
            XCTAssertTrue(marker.waitForExistence(timeout: 10), "chunk \(index) never rendered")
            XCTAssertTrue(isOnScreen(marker), "chunk \(index) streamed below the fold — follow-tail lost")
        }
        wait(for: [done], timeout: 30)
        XCTAssertFalse(app.buttons["chat.jumpToBottom"].exists)
    }

    func test_scrollingToTheTopPagesInWithoutAJump() {
        openPerfChat()
        var lowest = Int.max
        for _ in 0..<80 {
            if visibleMarkers().contains(1) { break }
            timeline.swipeDown(velocity: XCUIGestureVelocity(6000))
            guard let low = visibleMarkers().min() else { continue }
            XCTAssertLessThanOrEqual(low, lowest, "the timeline jumped forward (\(lowest) → \(low))")
            lowest = low
            XCTAssertTrue(app.buttons["chat.jumpToBottom"].exists, "reading history must never re-pin the tail")
        }
        XCTAssertTrue(visibleMarkers().contains(1), "never reached the first message (lowest \(lowest))")
    }

    func test_jumpToMyLastMessageLandsTheRowAtTheTop() {
        openPerfChat()
        timeline.swipeDown()
        let jump = app.buttons["chat.jumpToLastOwnMessage"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        let own = message("PERF-180")
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        let landed = expectation(for: NSPredicate { _, _ in
            abs(own.frame.minY - self.timeline.frame.minY) < 24
        }, evaluatedWith: nil)
        wait(for: [landed], timeout: 5)
    }

    func test_keyboardUpAndDownKeepsTheConversationVisible() {
        openPerfChat()
        let last = message("PERF-220")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(isOnScreen(last), "the tail stays visible above the keyboard")
        XCTAssertLessThanOrEqual(last.frame.maxY, field.frame.minY + 1)
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6)))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [gone], timeout: 5)
        XCTAssertFalse(visibleMarkers().isEmpty, "the timeline must not go blank when the keyboard leaves")
    }

    func test_roomSwitchRestoresPosition() throws {
        openPerfChat()
        for _ in 0..<6 { timeline.swipeDown() }
        let marker = try XCTUnwrap(settledMarkers()?.min(), "the timeline never stopped moving")
        app.navigationBars.buttons.firstMatch.tap()
        openChat(titled: "Fix the flaky upload test")
        app.navigationBars.buttons.firstMatch.tap()
        openPerfChat()
        let restored = message(String(format: "PERF-%03d", marker))
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertTrue(isOnScreen(restored))
    }

    func test_conversationLinkOpensTheConversation() {
        openPerfChat()
        XCTAssertTrue(message("PERF-220").waitForExistence(timeout: 10))
        let link = message("PERF-215").links["Dark mode"]
        scrollUp(toReveal: link)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        // The navigation bar, not a static text: this chat's own link pill
        // under PERF-215 carries the same title.
        let pushed = app.navigationBars.matching(NSPredicate(format: "identifier ENDSWITH %@",
                                                             "Dark mode for settings screen")).firstMatch
        XCTAssertTrue(pushed.waitForExistence(timeout: 10), "the conversation link did not open Dark mode")
    }

    func test_itemLinkReachesTheItemHandler() {
        openPerfChat()
        XCTAssertTrue(message("PERF-220").waitForExistence(timeout: 10))
        let link = message("PERF-216").links["#1"]
        scrollUp(toReveal: link)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        // The journal mints tracker #1 for the seeded agent-chat consent
        // ask, so the link opens its item page ("#1 · Question"). An
        // older journal without it explains the miss in the Tracker alert
        // instead. Either proves the tap stayed in-app rather than going
        // to iOS.
        let itemHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "#1 ·")).firstMatch
        let tracker = app.alerts["Tracker"]
        let handled = expectation(for: NSPredicate { _, _ in itemHeader.exists || tracker.exists }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [handled], timeout: 10), .completed,
                       "the item link opened neither the item nor the Tracker alert")
        if tracker.exists { tracker.buttons["OK"].tap() }
    }

    // MARK: Task 21 smoke carry-over, F9 and the Copy menus (Task 26)

    func test_jumpToBottomReturnsToTheTail() {
        openPerfChat()
        let last = message("PERF-220")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        for _ in 0..<3 { timeline.swipeDown() }
        let jump = app.buttons["chat.jumpToBottom"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "scrolling up shows the jump button")
        XCTAssertFalse(isOnScreen(last), "three swipes up still show the tail")
        jump.tap()
        let back = expectation(for: NSPredicate { _, _ in self.isOnScreen(last) }, evaluatedWith: nil)
        wait(for: [back], timeout: 5)
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: jump)
        wait(for: [hidden], timeout: 5)
    }

    /// Opens Find in chat (ⓘ sheet → "Find in chat" row → the bar, field
    /// focused) and submits `query` from the keyboard.
    private func findInChat(_ query: String) {
        XCTAssertTrue(message("PERF-220").waitForExistence(timeout: 10))
        app.buttons["Session info"].tap()
        let find = app.descendants(matching: .any)["session-find-in-chat-row"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "no Find in chat row — search index unavailable?")
        find.tap()
        let field = app.textFields["Search in chat"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        wait(for: [focused], timeout: 5)
        field.typeText(query + "\n")
    }

    /// Waits for `marker`'s text to sit at the timeline's top edge (the
    /// text view is inset ~12 pt into its row), then checks it stays there
    /// once the keyboard is gone.
    private func assertLandsAtTop(_ marker: String, file: StaticString = #filePath, line: UInt = #line) {
        let hit = message(marker)
        XCTAssertTrue(hit.waitForExistence(timeout: 15), "\(marker) never paged in", file: file, line: line)
        let landed = expectation(for: NSPredicate { _, _ in
            !self.app.keyboards.firstMatch.exists && abs(hit.frame.minY - self.timeline.frame.minY) < 24
        }, evaluatedWith: nil)
        let result = XCTWaiter().wait(for: [landed], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "\(marker) text at y=\(hit.frame.minY), timeline top y=\(timeline.frame.minY), "
                       + "keyboard up: \(app.keyboards.firstMatch.exists)", file: file, line: line)
    }

    /// Spec §4 "search/milestone jump lands the row at the top" (review F9),
    /// submitted from the search field. PERF-100 sits outside the opening
    /// window, so this is a deep jump that has to page in — and the
    /// keyboard drops while it lands.
    func test_findInChatLandsTheMatchAtTheTop() {
        openPerfChat()
        findInChat("PERF-100")
        assertLandsAtTop("PERF-100")
    }

    /// The same jump from the bar's chevron, with no keyboard in play:
    /// "PERF-10" matches 010 and 100…109, newest first; ∧ steps older.
    func test_findInChatChevronLandsTheMatchAtTheTop() {
        openPerfChat()
        findInChat("PERF-10")
        XCTAssertTrue(message("PERF-109").waitForExistence(timeout: 15))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [gone], timeout: 5)
        app.buttons["Older match"].tap()
        assertLandsAtTop("PERF-108")
    }

    func test_selectionMenuOffersCopyMessage() {
        openPerfChat()
        let last = message("PERF-220")
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        last.press(forDuration: 1.0)
        // The edit menu pages: Copy, Look Up, Translate, then "Forward" to
        // the rest — Copy Message is appended after the suggested actions.
        // "Forward" (›) expands it into a vertical menu whose rows are
        // buttons, not menu items — match the label on any element.
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy Message")).firstMatch
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5), "no selection edit menu")
        let forward = app.buttons["Forward"]
        if !copy.exists, forward.exists { forward.tap() }
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "the selection's edit menu lacks Copy Message")
        copy.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: copy)
        wait(for: [gone], timeout: 5)
    }

    /// A press outside the text (the timestamp strip under it) belongs to
    /// the row: the collection view's context menu offers Copy.
    func test_pressOutsideTheTextOffersTheRowCopyMenu() {
        openPerfChat()
        // 219 has no code block, so no code-copy button also labelled Copy.
        let row = message("PERF-219")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        scrollUp(toReveal: row)
        let below = row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: row.frame.width - 12, dy: row.frame.height + 6))
        below.press(forDuration: 1.2)
        // The code-copy glyph is also labelled Copy but is 15 pt wide.
        let copies = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
        let menu = expectation(for: NSPredicate { _, _ in
            copies.allElementsBoundByIndex.contains { $0.frame.width > 40 }
        }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [menu], timeout: 5), .completed, "no row context menu with Copy")
        XCTAssertFalse(app.menuItems["Look Up"].exists, "the press selected text instead of opening the row menu")
    }
}
