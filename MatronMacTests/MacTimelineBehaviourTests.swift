import XCTest
import AppKit
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import MatronMac

/// Plan Task 10: the session's rules (edges, jumps, restore, resize, cross-row
/// selection) as the table surface delivers them.
@MainActor final class MacTimelineBehaviourTests: XCTestCase {
    func test_nearTopExtendsHistoryAndKeepsTheReaderInPlace() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(300))            // VM window = entry size; more rows exist above
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 10)
        let anchor = h.controller.session.scrollModel.topAnchor()
        for _ in 0..<50 where h.viewModel.windowedRows.count <= 121 { try? await Task.sleep(nanoseconds: 20_000_000) }
        h.controller.sync()
        XCTAssertGreaterThan(h.viewModel.windowedRows.count, 121)
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor(), anchor)
        // Added (Task 10): the check above runs before the grown window is
        // applied (its batch is still measuring). Once it lands, the row the
        // reader saw sits exactly where it was relative to the clip.
        let seen = try XCTUnwrap(anchor)
        try await h.settle()
        let model = h.controller.session.scrollModel
        XCTAssertGreaterThan(model.rows.count, 121)
        let row = try XCTUnwrap(model.index(of: seen.rowID))
        XCTAssertEqual(model.rowMinY(at: row) - h.clipY, -seen.offsetInRow, accuracy: 0.5)
        XCTAssertEqual(h.clipY, model.contentOffsetY, accuracy: 0.5)
    }

    /// Perf follow-ups R2: at the window cap an extend SLIDES (120 rows in
    /// above, 120 out below, of 360). The survivors keep their order, so the
    /// table edits in place: no `reloadData`, and every view on screen is
    /// the very view that was there, with the reader's row unmoved.
    func test_aSlideAtTheWindowCapKeepsEveryVisibleViewWithoutReloadData() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(700))
        // Following at the bottom (no edge triggers): grow to the cap.
        for _ in 0..<5 where h.viewModel.visibleWindowSize < 360 {
            await h.viewModel.extendHistoryWindow()
            try await h.settle()
        }
        XCTAssertEqual(h.viewModel.visibleWindowSize, 360)

        // The reader mid-window: far from both edges, on rows a slide keeps.
        h.controller.session.userDragBegan()
        let mid = (h.maxY / 2).rounded()
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: mid))
        h.controller.session.userScrolled(toOffset: mid)
        h.controller.view.layoutSubtreeIfNeeded()
        let table = h.controller.tableView!
        let before = h.controller.session.scrollModel
        let anchor = try XCTUnwrap(before.topAnchor())
        // The rows on screen, from the model's geometry (the table's own
        // `rect(ofRow:)` can answer from an estimate before it tiles).
        var visible: [(id: String, view: NSView)] = []
        for i in 0..<before.rows.count
        where before.rowMinY(at: i) < mid + before.viewportHeight && before.rowMinY(at: i) + before.rows[i].height > mid {
            let view = try XCTUnwrap(table.view(atColumn: 0, row: i + 1, makeIfNecessary: false))
            visible.append((before.rows[i].id, view))
        }
        XCTAssertGreaterThan(visible.count, 5)
        let firstMessage = {
            h.viewModel.windowedRows.lazy.compactMap { row -> String? in
                if case .message(let item) = row { return item.id } else { return nil }
            }.first
        }
        let firstID = firstMessage()

        h.controller.resetCountersForTesting()
        await h.viewModel.extendHistoryWindow()
        XCTAssertNotEqual(firstMessage(), firstID)                 // it slid
        try await h.settle()

        XCTAssertEqual(h.controller.reloadDataCountForTesting, 0)
        let model = h.controller.session.scrollModel
        XCTAssertEqual(model.rows.count, before.rows.count)
        XCTAssertEqual(model.topAnchor(), anchor)
        for (id, view) in visible {
            let index = try XCTUnwrap(model.index(of: id), "visible row \(id) left the window")
            XCTAssertTrue(table.view(atColumn: 0, row: index + 1, makeIfNecessary: false) === view, "row \(id) got a new view")
        }
        for i in 0..<model.rows.count {
            XCTAssertEqual(table.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        XCTAssertEqual(h.clipY, model.contentOffsetY, accuracy: 0.5)
    }

    func test_pendingFocusLandsRowAtTopAndFlashes() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        let target = "40"
        await h.viewModel.focus(seq: 40)       // harness ids are seqs
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        try await h.settle()
        let i = h.controller.session.scrollModel.index(of: target)!
        XCTAssertEqual(h.clipY, h.controller.session.scrollModel.rowMinY(at: i), accuracy: 0.5)
        // Spec §4 behaviour 2: the landed row flashes (fades after 0.4 s + 0.6 s).
        let view = h.controller.tableView.view(atColumn: 0, row: i + 1, makeIfNecessary: false) as? MacTextRowView
        XCTAssertEqual(view?.hasFlashForTesting, true)
    }

    func test_restoreLandsTheStoredTopAnchor() async throws {
        var h: MacTimelineHarness? = MacTimelineHarness()
        try await h!.start(with: h!.texts(100))
        h!.controller.session.userDragBegan()
        h!.controller.session.userScrolled(toOffset: 2000)
        let anchor = h!.controller.session.scrollModel.topAnchor()!
        h!.controller.tearDown()
        let room = h!.viewModel.roomID
        let viewModel = h!.viewModel, strip = h!.strip
        h = nil
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: room)?.itemID, anchor.rowID)

        // Added (Task 10): a new table over the same room lands that anchor.
        let controller = MacTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: MacTimelineBridge(),
                                               selection: MessageSelectionController(), actions: .inert,
                                               cache: MacTimelineMeasureCache(countLimit: 4000))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 800, height: 600))
        window.orderFront(nil)
        defer { controller.tearDown(); window.orderOut(nil) }
        try await waitUntil { controller.session.scrollModel.rows.count == viewModel.windowedRows.count && !controller.hasPendingWork }
        XCTAssertEqual(controller.session.scrollModel.topAnchor(), anchor)
        XCTAssertEqual(controller.scrollView.contentView.bounds.origin.y, controller.session.scrollModel.contentOffsetY, accuracy: 0.5)
        XCTAssertFalse(controller.session.scrollModel.isFollowingTail)
    }

    func test_widthChangeKeepsTheTopMessage() async throws {
        let h = MacTimelineHarness(size: CGSize(width: 1100, height: 600))
        try await h.start(with: h.texts(100, body: { "Message \($0) " + String(repeating: "long words ", count: 30) }))
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 3000)
        let top = h.controller.session.scrollModel.topAnchor()?.rowID
        h.window.setContentSize(CGSize(width: 480, height: 600))
        h.controller.view.layoutSubtreeIfNeeded()
        h.controller.sync()
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor()?.rowID, top)
        // Heights were re-measured at the new width.
        let i = h.controller.session.scrollModel.index(of: top!)!
        XCTAssertGreaterThan(h.controller.session.scrollModel.rows[i].height, 100)
    }

    func test_crossSelectionAcrossNeverMountedRowsCopiesAll() async throws {
        let h = MacTimelineHarness(size: CGSize(width: 800, height: 400))
        try await h.start(with: h.texts(60))
        h.selection.orderedIDs = h.viewModel.windowedRows.compactMap { if case .message(let it) = $0 { return it.id } else { return nil } }
        XCTAssertTrue(h.selection.beginCrossMessage(anchorID: "5", charIndex: 0))
        // Head on a mounted row near the bottom; rows 6…54 were never mounted.
        let headID = "55"
        let i = h.controller.session.scrollModel.index(of: headID)!
        let view = h.controller.tableView.view(atColumn: 0, row: i + 1, makeIfNecessary: false) as! MacTextRowView
        h.selection.hitTester = { _, _ in view.body.textView as? CrossSelectionTarget }
        h.selection.extend(toWindowPoint: .zero, window: h.window)
        h.selection.finish()
        XCTAssertEqual(h.selection.finishedTranscript?.messageCount, 51)
    }
}
