import XCTest
import AppKit
import SwiftUI
import Observation
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineControllerTests: XCTestCase {
    func test_tableRowRectsEqualTheModelAndOnlyVisibleRowsHaveViews() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(200))
        let model = h.controller.session.scrollModel
        for i in 0..<model.rows.count {
            // +1: table row 0 is the top spacer (see Step 3 geometry mapping).
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        var mounted = 0
        h.controller.tableView.enumerateAvailableRowViews { _, _ in mounted += 1 }
        XCTAssertLessThan(mounted, 40)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)          // opened at the bottom, following
    }

    func test_streamingGrowthPinnedWhileFollowingAndStillWhileReading() async throws {
        let h = MacTimelineHarness()
        var items = h.texts(100)
        try await h.start(with: items)
        // Following: the eph row grows, the viewport stays at the bottom.
        for n in stride(from: 50, through: 2000, by: 150) {
            let eph = JournalTimelineMapper.streamingItem(messageRef: "r", text: String(repeating: "word ", count: n / 5), convoTS: Date())
            try await h.emit(items + [eph])
            XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
        }
        // Reading: the user scrolls up; further growth must not move the rows on screen.
        h.controller.session.userDragBegan()
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: h.clipY - 1500))
        h.controller.session.userScrolled(toOffset: h.controller.scrollView.contentView.bounds.origin.y)
        let anchor = h.controller.session.scrollModel.topAnchor()
        let eph = JournalTimelineMapper.streamingItem(messageRef: "r", text: String(repeating: "word ", count: 900), convoTS: Date())
        items.append(eph)
        try await h.emit(items)
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor(), anchor)
    }

    func test_streamDeltaReconfiguresOneRowOnly() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(50)
        // One turn, one timestamp: a fresh `Date()` per delta would also
        // change the day separator above the streaming row (its content is
        // the exact date), a second, legitimate reconfigure.
        let turnTS = Date()
        try await h.start(with: items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a", convoTS: turnTS)])
        h.controller.resetCountersForTesting()
        try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a b c", convoTS: turnTS)])
        XCTAssertEqual(h.controller.reconfiguredRowCountForTesting, 1)
        XCTAssertEqual(h.controller.reloadDataCountForTesting, 0)
    }

    func test_ownSendReturnsToBottom() async throws {
        let h = MacTimelineHarness()
        var items = h.texts(100)
        try await h.start(with: items)
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 0)
        items.append(TimelineItem(id: "own1", sender: "@me:s", timestamp: Date(), kind: .text(body: "mine", formattedHTML: nil),
                                  isOwn: true, sendState: .sent))
        try await h.emit(items)
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
    }

    /// Task 7 review: prove a hosted SwiftUI state change re-runs the cell's
    /// `layout()`, reaches `onHeightChange` → `session.updateHeight` →
    /// `noteHeightOfRows`, so the model row and the table rect both follow.
    func test_hostedStateChangeResizesItsRowInTheModelAndTheTable() async throws {
        let h = MacTimelineHarness()
        let box = HostedHeightBox()
        h.controller.hostedRowOverrideForTesting = { content in
            guard case .separator = content.row else { return nil }
            return AnyView(HostedHeightBoxView(box: box))
        }
        try await h.start(with: h.texts(3))
        let separator = try XCTUnwrap(h.controller.session.scrollModel.rows.firstIndex { $0.id.hasPrefix("sep:") })
        let spacing = MacTimelineController.rowSpacing
        XCTAssertEqual(h.controller.session.scrollModel.rows[separator].height, 40 + spacing, accuracy: 0.5)
        XCTAssertEqual(h.controller.tableView.rect(ofRow: separator + 1).height, 40 + spacing, accuracy: 0.5)

        box.height = 120
        try await waitUntil {
            abs(h.controller.session.scrollModel.rows[separator].height - (120 + spacing)) < 0.5
        }
        h.controller.view.layoutSubtreeIfNeeded()
        let model = h.controller.session.scrollModel
        XCTAssertEqual(h.controller.tableView.rect(ofRow: separator + 1).height, 120 + spacing, accuracy: 0.5)
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
    }

    /// Fix round 1: a non-live width change (a split-view divider step)
    /// measures the on-screen rows on main and the rest in the background,
    /// keeping the top anchor and the table/model parity.
    func test_widthChangeMeasuresVisibleRowsOnMainAndTheRestInTheBackground() async throws {
        let h = MacTimelineHarness()
        let long = String(repeating: "A longer message body that wraps across several lines at any width. ", count: 4)
        try await h.start(with: h.texts(150) { "Message \($0). " + long })
        // Read from the middle of the window, so the top anchor is a real row.
        h.controller.session.userDragBegan()
        let midY = h.controller.session.scrollModel.rowMinY(at: h.controller.session.scrollModel.rows.count / 2) + 5
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: midY))
        h.controller.session.userScrolled(toOffset: h.controller.scrollView.contentView.bounds.origin.y)
        h.controller.session.userScrollSettled()
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())
        let rowCount = h.controller.session.scrollModel.rows.count
        let before = h.controller.session.scrollModel.height(of: anchor.rowID)

        h.controller.resetCountersForTesting()
        h.window.setContentSize(CGSize(width: 520, height: 600))
        h.controller.view.layoutSubtreeIfNeeded()
        try await h.settle()

        let model = h.controller.session.scrollModel
        XCTAssertNotEqual(model.height(of: anchor.rowID), before)                // really re-wrapped
        XCTAssertEqual(model.topAnchor()?.rowID, anchor.rowID)                    // (a)
        for i in 0..<model.rows.count {                                           // (b)
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        XCTAssertEqual(h.clipY, model.contentOffsetY, accuracy: 0.5)              // (c)
        XCTAssertGreaterThan(h.controller.syncMeasuredRowCountForTesting, 0)      // (d)
        XCTAssertLessThan(h.controller.syncMeasuredRowCountForTesting, rowCount / 2)
    }

    /// Final review Important 1: momentum after the lift, Page Up / Home /
    /// space and drag-select autoscroll move the clip with no gesture
    /// callbacks. Leaving the bottom that way releases follow (so the next
    /// stream delta leaves the reader alone); arriving back re-arms it.
    func test_nonGestureMoveOffTheBottomReleasesFollowAndBackAtTheTailRearms() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(100)
        let turnTS = Date()
        try await h.start(with: items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a", convoTS: turnTS)])
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertTrue(h.bridge.isFollowingTail)

        // A programmatic clip move, as momentum / a keyboard scroll makes it.
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: h.maxY - 1500))
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertFalse(h.bridge.isFollowingTail)

        let anchor = h.controller.session.scrollModel.topAnchor()
        let clip = h.clipY
        try await h.emit(items + [JournalTimelineMapper.streamingItem(
            messageRef: "r", text: String(repeating: "word ", count: 400), convoTS: turnTS)])
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor(), anchor)
        XCTAssertEqual(h.clipY, clip, accuracy: 0.5)
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)

        // Back at the tail with no gesture in progress: follow re-arms.
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: h.maxY))
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertTrue(h.bridge.isFollowingTail)
    }

    /// Final review Important 1: inside a gesture (between began and ended)
    /// arriving at the tail does not re-arm — the gesture's end decides.
    func test_moveToTheTailInsideAGestureWaitsForItsEnd() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        h.controller.scrollView.onUserScrollBegan?()
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: h.maxY - 1500))
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: h.maxY))
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)
        h.controller.scrollView.onUserScrollEnded?()
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
    }

    /// Final review Important 2: a pane toggle makes the NEW controller
    /// (whose `init` mounts and reads the remembered position) before the
    /// old one tears down. `makeNSViewController` stores through the bridge
    /// first — the bridge still points at the old controller — so the new
    /// one opens where the reader was, and the old one's later `tearDown`
    /// doesn't overwrite it.
    func test_paneToggleKeepsTheReadersPlace() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 2000)
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())

        // What `MacTimelineView.makeNSViewController` does, in its order.
        h.bridge.storeScrollPosition()
        let second = MacTimelineController(viewModel: h.viewModel, stripViewModel: h.strip, bridge: h.bridge,
                                           selection: h.selection, actions: .inert,
                                           cache: MacTimelineMeasureCache(countLimit: 4000))
        h.controller.tearDown()                         // SwiftUI dismantles the old one afterwards
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: h.viewModel.roomID)?.itemID, anchor.rowID)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentViewController = second
        window.setContentSize(CGSize(width: 800, height: 600))
        window.orderFront(nil)
        defer { second.tearDown(); window.orderOut(nil) }
        try await waitUntil {
            second.session.scrollModel.rows.count == h.viewModel.windowedRows.count && !second.hasPendingWork
        }
        XCTAssertEqual(second.session.scrollModel.topAnchor(), anchor)
        XCTAssertFalse(second.session.scrollModel.isFollowingTail)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }
}

@Observable private final class HostedHeightBox {
    var height: CGFloat = 40
}

private struct HostedHeightBoxView: View {
    let box: HostedHeightBox
    var body: some View {
        Color.orange.frame(height: box.height)
    }
}
