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
        // One turn, one timestamp (the separator case is the next test).
        let turnTS = Date()
        try await h.start(with: items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a", convoTS: turnTS)])
        h.controller.resetCountersForTesting()
        try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a b c", convoTS: turnTS)])
        XCTAssertEqual(h.controller.reconfiguredRowCountForTesting, 1)
        XCTAssertEqual(h.controller.reloadDataCountForTesting, 0)
    }

    /// Perf follow-ups S1: the streaming row's timestamp moves on every
    /// delta. When it opens a new day, the day separator above it used to
    /// carry that timestamp and reconfigured (and re-measured) with it.
    func test_streamDeltaOpeningANewDayReconfiguresOnlyTheStreamingRow() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(50)
        let cal = Calendar.current
        // A later day than every `texts` item, at noon so both deltas share it.
        let noon = cal.date(byAdding: .hour, value: 12,
                            to: cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_300_000)))!
        try await h.start(with: items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a", convoTS: noon)])
        h.controller.resetCountersForTesting()
        try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "a b c",
                                                                      convoTS: noon.addingTimeInterval(5))])
        XCTAssertEqual(h.controller.reconfiguredRowCountForTesting, 1)
        XCTAssertEqual(h.controller.reloadDataCountForTesting, 0)
        #if DEBUG
        XCTAssertEqual(h.controller.lastApplyChangedIDsForTesting, ["eph:r"])
        #endif
    }

    #if DEBUG
    /// Perf follow-ups S5: the streaming row is sized by a sizer that lives
    /// while the row streams (and really edits incrementally on the main
    /// sync path), and is dropped when the finished message replaces it.
    func test_streamingSizerLivesWhileItsRowStreams() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(20)
        let turnTS = Date()
        var body = "First paragraph of the reply."
        try await h.start(with: items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: body, convoTS: turnTS)])
        for delta in ["\n\nSecond", " paragraph", " grows", "\n\n- a list", "\n- more"] {
            body += delta
            try await h.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: body, convoTS: turnTS)])
        }
        XCTAssertEqual(h.controller.streamingSizerIDsForTesting, ["eph:r"])
        XCTAssertGreaterThan(try XCTUnwrap(h.controller.streamingSizerForTesting("eph:r")).incrementalEditCount, 0)

        let final = TimelineItem(id: "$final", sender: "agent", timestamp: turnTS,
                                 kind: .text(body: body, formattedHTML: nil), isOwn: false, sendState: .sent)
        try await h.emit(items + [final])
        XCTAssertEqual(h.controller.streamingSizerIDsForTesting, [])
    }
    #endif

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

    /// Perf follow-ups S6: a pass over a window, width, footer and focus that
    /// are all already applied (an observed property set to an equal value,
    /// the open's duplicate pass) applies nothing and measures nothing. A
    /// real change still applies once, and the reused build equals a full one.
    func test_anUnchangedSnapshotDoesNoApply() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(50)
        try await h.start(with: items)
        h.controller.resetCountersForTesting()

        h.controller.requestSync()
        try await waitUntil { !h.controller.hasPendingWork }
        h.controller.sync()
        XCTAssertEqual(h.controller.applyCountForTesting, 0)
        XCTAssertEqual(h.controller.syncMeasuredRowCountForTesting, 0)
        XCTAssertEqual(h.controller.hostedMeasuredRowCountForTesting, 0)
        XCTAssertEqual(h.controller.reconfiguredRowCountForTesting, 0)

        let added = TimelineItem(id: "51", sender: "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_051),
                                 kind: .text(body: "One more, with a [link](https://example.com)", formattedHTML: nil),
                                 isOwn: false, sendState: .sent)
        try await h.emit(items + [added])
        XCTAssertEqual(h.controller.applyCountForTesting, 1)
        XCTAssertEqual(h.controller.syncMeasuredRowCountForTesting, 1)
        assertContentsEqualAFullBuild(h)
    }

    /// Perf follow-ups S6: the build reuses a row's content only while its
    /// `TimelineRow` is unchanged — but an image's content also carries the
    /// view model's pixel size, which lands later with the row untouched.
    /// That row must still rebuild (and re-measure), as with a full build.
    func test_anImageLandingRebuildsItsRowThoughTheRowIsUnchanged() async throws {
        let h = MacTimelineHarness(media: PNGMediaFixture(width: 400, height: 300))
        let image = TimelineItem(id: "6", sender: "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_006),
                                 kind: .image(url: URL(string: "mxc://s/picture"), caption: nil, sizeBytes: nil, expired: false),
                                 isOwn: false, sendState: .sent)
        try await h.start(with: h.texts(5) + [image])
        // Measuring the row asked the view model for the image; it lands.
        try await waitUntil {
            guard case .hosted(let hosted)? = h.controller.session.contents["6"] else { return false }
            return hosted.imagePixelSize == CGSize(width: 400, height: 300)
        }
        try await h.settle()
        assertContentsEqualAFullBuild(h)

        // Likewise the senders flag: a second sender gives every bot row an
        // avatar, with each of those rows unchanged.
        XCTAssertFalse(h.viewModel.hasMultipleSenders)
        let other = TimelineItem(id: "7", sender: "@other:s", timestamp: Date(timeIntervalSince1970: 1_700_000_007),
                                 kind: .text(body: "Hello from someone else", formattedHTML: nil), isOwn: false, sendState: .sent)
        try await h.emit(h.texts(5) + [image, other])
        XCTAssertTrue(h.viewModel.hasMultipleSenders)
        assertContentsEqualAFullBuild(h)
    }

    private func assertContentsEqualAFullBuild(_ h: MacTimelineHarness, file: StaticString = #filePath, line: UInt = #line) {
        let full = TimelineRowContentBuilder.build(TimelineRowSource(
            rows: h.viewModel.windowedRows, hasMultipleSenders: h.viewModel.hasMultipleSenders,
            children: h.strip.children, imagePixelSize: { h.viewModel.imagePixelSize(for: $0) })).contents
        XCTAssertEqual(h.controller.session.scrollModel.rows.map(\.id), full.map(\.anchorID), file: file, line: line)
        for content in full {
            XCTAssertEqual(h.controller.session.contents[content.anchorID], content, file: file, line: line)
        }
    }

    /// Perf follow-ups S6 (P0 Q2): memory pressure can empty the measure
    /// `NSCache` between passes. A row whose content and width are unchanged
    /// keeps the measurement it was applied with, so a purged cache costs no
    /// re-measure: not on a forced, identical pass, and on a one-row change
    /// only that row.
    func test_aPurgedMeasureCacheReMeasuresNoUnchangedRow() async throws {
        let h = MacTimelineHarness()
        let items = h.texts(50)
        try await h.start(with: items)
        XCTAssertTrue(h.controller.session.contents.values.contains { if case .hosted = $0 { return true } else { return false } })

        h.cache.removeAllForTesting()
        h.controller.resetCountersForTesting()
        // The end-of-live-resize resync: a forced pass (never skipped) at
        // the same width over the same rows.
        h.controller.tableView.viewDidEndLiveResize()
        XCTAssertEqual(h.controller.applyCountForTesting, 1)
        XCTAssertEqual(h.controller.syncMeasuredRowCountForTesting, 0)
        XCTAssertEqual(h.controller.hostedMeasuredRowCountForTesting, 0)

        h.cache.removeAllForTesting()
        h.controller.resetCountersForTesting()
        let added = TimelineItem(id: "51", sender: "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_051),
                                 kind: .text(body: "One more", formattedHTML: nil), isOwn: false, sendState: .sent)
        try await h.emit(items + [added])
        XCTAssertEqual(h.controller.syncMeasuredRowCountForTesting, 1)
        XCTAssertEqual(h.controller.hostedMeasuredRowCountForTesting, 0)
        let model = h.controller.session.scrollModel
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
    }

    /// Perf follow-ups R1 (b): a reconfigure with the content and width the
    /// cell already hosts (here the end-of-live-resize resync, which
    /// reconfigures every row at an unchanged width) writes no rootView.
    func test_reconfiguringIdenticalHostedContentWritesNoRootView() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(3))
        let separator = try XCTUnwrap(h.controller.session.scrollModel.rows.firstIndex { $0.id.hasPrefix("sep:") })
        let cell = try XCTUnwrap(h.controller.tableView.view(atColumn: 0, row: separator + 1, makeIfNecessary: false)
                                 as? MacHostedRowView)
        let writes = cell.rootViewWriteCountForTesting
        XCTAssertGreaterThan(writes, 0)

        h.controller.resetCountersForTesting()
        h.controller.tableView.viewDidEndLiveResize()
        h.controller.view.layoutSubtreeIfNeeded()
        // The resync really reconfigured the rows (the separator included)…
        XCTAssertGreaterThanOrEqual(h.controller.reconfiguredRowCountForTesting, h.controller.session.scrollModel.rows.count)
        XCTAssertTrue(h.controller.tableView.view(atColumn: 0, row: separator + 1, makeIfNecessary: false) === cell)
        // …and the hosted cell, shown the same content at the same width, kept its root.
        XCTAssertEqual(cell.rootViewWriteCountForTesting, writes)
    }

    /// Perf follow-ups R1 (c): reuse swaps no `EmptyView` in. A recycled
    /// host writes one root per reuse, and none when it is shown the very
    /// row it already hosts (a scroll reversal).
    func test_aRecycledHostWritesOneRootPerReuseAndNoneForItsOwnRow() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(3))
        let separator = try XCTUnwrap(h.controller.session.contents.values.lazy.compactMap { content -> HostedRowContent? in
            if case .hosted(let hosted) = content { return hosted } else { return nil }
        }.first)
        let other = HostedRowContent(row: .separator(date: Date(timeIntervalSince1970: 1_600_000_000)), subtaskChild: nil,
                                     hasMultipleSenders: false, imagePixelSize: nil)
        let cell = MacHostedRowView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        h.window.contentView?.addSubview(cell)
        cell.configure(rowID: "a", expectedHeight: 40, content: .row(separator), source: h.controller)
        cell.layoutSubtreeIfNeeded()
        let writes = cell.rootViewWriteCountForTesting
        XCTAssertEqual(writes, 1)

        cell.prepareForReuse()
        cell.configure(rowID: "a", expectedHeight: 40, content: .row(separator), source: h.controller)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.rootViewWriteCountForTesting, writes)

        cell.prepareForReuse()
        cell.configure(rowID: "b", expectedHeight: 40, content: .row(other), source: h.controller)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.rootViewWriteCountForTesting, writes + 1)
        cell.removeFromSuperview()
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
    /// old one tears down. `MacTimelineView.makeController` — the body of
    /// `makeNSViewController` — stores through the bridge first (it still
    /// points at the old controller), so the new one opens where the reader
    /// was. Wave M item 4: the old viewport then MOVES before its `tearDown`
    /// (the window shrink a pane toggle makes), and that tearDown must not
    /// overwrite the stored entry.
    func test_paneToggleKeepsTheReadersPlace() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        h.controller.session.userDragBegan()
        h.controller.session.userScrolled(toOffset: 2000)
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())

        let second = MacTimelineView.makeController(
            viewModel: h.viewModel, stripViewModel: h.strip, bridge: h.bridge, selection: h.selection,
            actions: .inert, registersPerfProbe: false, cache: MacTimelineMeasureCache(countLimit: 4000))
        XCTAssertTrue(h.bridge.controller === second)
        // The old clip moves after the store (no drag: a layout clamp).
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1200))
        XCTAssertEqual(h.controller.session.scrollModel.contentOffsetY, 1200, accuracy: 0.5)
        XCTAssertNotEqual(h.controller.session.scrollModel.topAnchor()?.rowID, anchor.rowID)
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

    /// Wave M item 1: a hosted row that settles at a new height while the
    /// timeline is suspended reports once (the cell records it as its
    /// expected height). `resume()`'s sync must apply that height — it used
    /// to hit the old cached one and keep it.
    func test_hostedHeightReportedWhileSuspendedAppliesOnResume() async throws {
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

        h.controller.session.suspend()
        box.height = 120
        // Let SwiftUI update the host, the cell lay out and its report land.
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 60_000_000)
            h.controller.view.layoutSubtreeIfNeeded()
        }
        // Suspended: no apply yet.
        XCTAssertEqual(h.controller.session.scrollModel.rows[separator].height, 40 + spacing, accuracy: 0.5)

        h.controller.session.resume()
        try await waitUntil {
            abs(h.controller.session.scrollModel.rows[separator].height - (120 + spacing)) < 0.5
                && !h.controller.hasPendingWork
        }
        h.controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(h.controller.tableView.rect(ofRow: separator + 1).height, 120 + spacing, accuracy: 0.5)
        let model = h.controller.session.scrollModel
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
    }

    /// Wave M item 2: the jump button kills momentum, so no
    /// `momentumPhase.ended` ever closes the gesture. Both gesture flags
    /// clear with it — else a later non-gesture move back to the tail could
    /// not re-arm follow.
    func test_jumpButtonClearsTheGestureFlags() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        let sv = h.controller.scrollView!
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .began))
        sv.scrollWheel(with: MacTimelineHarness.wheel(200, phase: .changed))
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .ended))
        sv.scrollWheel(with: MacTimelineHarness.wheel(200, phase: nil, momentum: .begin))
        XCTAssertTrue(sv.isGestureOpenForTesting)
        XCTAssertTrue(h.controller.isUserGestureActiveForTesting)
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)

        h.bridge.jumpToBottom()
        XCTAssertFalse(sv.isGestureOpenForTesting)
        XCTAssertFalse(h.controller.isUserGestureActiveForTesting)
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        try await h.settle()
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)

        // Keyboard scroll away and back, no gesture: follow releases, then re-arms.
        sv.contentView.scroll(to: NSPoint(x: 0, y: h.maxY - 1500))
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)
        sv.contentView.scroll(to: NSPoint(x: 0, y: h.maxY))
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertTrue(h.bridge.isFollowingTail)
    }

    /// Wave M item 3: a stall let the lift's deferred end fire (follow
    /// re-armed at the tail) before momentum began. The momentum reopens
    /// the gesture, releasing follow for its run — even a short one that
    /// never leaves the near-bottom band, which the geometry alone keeps.
    func test_momentumAfterAStalledGraceReleasesFollow() async throws {
        let h = MacTimelineHarness()
        try await h.start(with: h.texts(100))
        let sv = h.controller.scrollView!
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .began))
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .changed))
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .ended))
        try await Task.sleep(nanoseconds: UInt64((MacTimelineScrollView.momentumGrace + 0.15) * 1_000_000_000))
        XCTAssertFalse(h.controller.isUserGestureActiveForTesting)
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)   // settled at the tail

        sv.scrollWheel(with: MacTimelineHarness.wheel(10, phase: nil, momentum: .begin))
        XCTAssertTrue(h.controller.isUserGestureActiveForTesting)
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertFalse(h.bridge.isFollowingTail)
        // A clip move during the momentum, inside the near-bottom band.
        sv.contentView.scroll(to: NSPoint(x: 0, y: h.maxY - 30))
        XCTAssertFalse(h.controller.session.scrollModel.isFollowingTail)
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: nil, momentum: .end))
        XCTAssertFalse(h.controller.isUserGestureActiveForTesting)
    }

    // MARK: Perf follow-ups O1 (a)

    /// An extension prepends rows the reader can't see. Their hosted rows
    /// are measured over several passes, none spending more than the budget
    /// on hosted rows, and the window applies once, after the last of them,
    /// with the reader's row where it was.
    func test_anExtensionMeasuresItsOffScreenHostedRowsInSlicesThenAppliesOnce() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock)
        try await h.startSlowly(with: h.dailyTexts(300))
        // Reading mid-window: far from both edges, with a real top anchor.
        h.controller.session.userDragBegan()
        let mid = (h.maxY / 2).rounded()
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: mid))
        h.controller.session.userScrolled(toOffset: mid)
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())
        let before = Set(h.controller.session.scrollModel.rows.map(\.id))

        h.controller.resetCountersForTesting()
        var hostedMeasuredAtApply: [Int] = []
        h.controller.onApplyForTesting = { hostedMeasuredAtApply.append(h.controller.hostedMeasuredRowCountForTesting) }
        await h.viewModel.extendHistoryWindow()
        try await h.settle(timeout: 15)

        let model = h.controller.session.scrollModel
        let prependedHosted = model.rows.filter { !before.contains($0.id) && $0.id.hasPrefix("sep:") }.count
        XCTAssertGreaterThan(prependedHosted, 40)
        // One apply, and every prepended hosted row was measured before it.
        XCTAssertEqual(hostedMeasuredAtApply, [prependedHosted])
        let passes = h.controller.hostedMeasureTimePerPassForTesting
        XCTAssertGreaterThanOrEqual(passes.count, prependedHosted / 4)
        for spent in passes {
            XCTAssertLessThanOrEqual(spent, MacTimelineController.hostedSliceBudget + 1e-9)
        }
        XCTAssertEqual(model.topAnchor(), anchor)
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        XCTAssertEqual(h.clipY, model.contentOffsetY, accuracy: 0.5)
    }

    /// A cold open (nothing measured) of a window with many hosted rows
    /// shows the rows on screen in its first apply, and the rest prepend
    /// under them: every row that first apply showed stays exactly where it
    /// was, and the blank-chat tripwire never fires.
    func test_aColdOpenShowsItsOnScreenRowsFirstThenPrependsTheRest() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock, cost: MacTimelineController.hostedSliceBudget)
        var applies: [(rows: Int, onScreen: [String: CGFloat], hasVisibleRows: Bool)] = []
        h.controller.onApplyForTesting = {
            let model = h.controller.session.scrollModel
            guard !model.rows.isEmpty else { return }
            applies.append((model.rows.count, model.screenPositions, h.controller.hasVisibleRows()))
        }
        try await h.startSlowly(with: h.dailyTexts(300))

        let model = h.controller.session.scrollModel
        let first = try XCTUnwrap(applies.first)
        XCTAssertLessThan(first.rows, model.rows.count / 2)
        XCTAssertEqual(applies.last?.rows, model.rows.count)
        XCTAssertFalse(first.onScreen.isEmpty)
        let now = model.screenPositions
        XCTAssertEqual(Set(now.keys), Set(first.onScreen.keys))
        for (id, y) in first.onScreen {
            XCTAssertEqual(now[id] ?? .nan, y, accuracy: 0.5, "row \(id) moved")
        }
        XCTAssertTrue(applies.allSatisfy(\.hasVisibleRows))
        XCTAssertEqual(h.controller.session.invariantSnapCount, 0)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
    }

    /// A cold open over a stored position: the first apply already holds the
    /// stored row and lands it exactly; the rest prepend without moving it.
    func test_aColdOpenLandsAStoredPositionInItsFirstApplyAndKeepsIt() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock)
        try await h.startSlowly(with: h.dailyTexts(300))
        h.controller.session.userDragBegan()
        let y = h.maxY - 1000
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        h.controller.session.userScrolled(toOffset: y)
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())
        h.controller.tearDown()
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: h.viewModel.roomID)?.itemID, anchor.rowID)

        // A new table over the same room, with a cold measure cache.
        let controller = MacTimelineController(viewModel: h.viewModel, stripViewModel: h.strip, bridge: MacTimelineBridge(),
                                               selection: MessageSelectionController(), actions: .inert,
                                               cache: MacTimelineMeasureCache(countLimit: 4000))
        controller.hostedRowOverrideForTesting = MacTimelineHarness.costlySeparator(
            clock, cost: MacTimelineController.hostedSliceBudget)
        controller.clock = { clock.now }
        var first: (rows: Int, anchor: TimelineScrollModel.Anchor?)?
        controller.onApplyForTesting = {
            let model = controller.session.scrollModel
            if first == nil, !model.rows.isEmpty { first = (model.rows.count, model.topAnchor()) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 800, height: 600))
        window.orderFront(nil)
        defer { controller.tearDown(); window.orderOut(nil) }
        try await waitUntil(timeout: 15) {
            controller.session.scrollModel.rows.count == h.viewModel.windowedRows.count && !controller.hasPendingWork
        }
        let landed = try XCTUnwrap(first)
        XCTAssertLessThan(landed.rows, h.viewModel.windowedRows.count)
        XCTAssertEqual(landed.anchor, anchor)
        let model = controller.session.scrollModel
        XCTAssertEqual(model.topAnchor(), anchor)
        XCTAssertFalse(model.isFollowingTail)
        XCTAssertEqual(controller.scrollView.contentView.bounds.origin.y, model.contentOffsetY, accuracy: 0.5)
        XCTAssertEqual(controller.session.invariantSnapCount, 0)
    }

    /// Fix round 1, finding 1: a cold open restoring far up a hosted-heavy
    /// window (hundreds of rows between the stored row and the tail). No
    /// pass measures more hosted rows on main than the slice budget allows
    /// — before, a fallback deferred everything and then, once few enough
    /// rows were left, measured them all in one pass — and the stored
    /// position lands in the first apply and stays.
    func test_aColdRestoreFarUpMeasuresHostedRowsOnlyInSlicesAndLandsTheStoredPosition() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock)
        try await h.startSlowly(with: h.dailyTexts(300))
        h.controller.session.userDragBegan()
        // 5 pt into a message row near the window's top.
        let opened = h.controller.session.scrollModel
        let top = try XCTUnwrap(opened.rows.indices.first { $0 >= 10 && !opened.rows[$0].id.hasPrefix("sep:") })
        let y = opened.rowMinY(at: top) + 5
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        h.controller.session.userScrolled(toOffset: y)
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())
        h.controller.tearDown()
        let rows = h.viewModel.windowedRows.map(TimelineRowContentBuilder.anchorID(for:))
        let fromTail = rows.count - (try XCTUnwrap(rows.firstIndex(of: anchor.rowID)))
        XCTAssertGreaterThan(fromTail, 100)                     // far past one screen from the tail

        var first: TimelineScrollModel.Anchor??
        let (controller, window) = h.coldController { controller in
            controller.hostedRowOverrideForTesting = MacTimelineHarness.costlySeparator(clock)
            controller.clock = { clock.now }
            controller.onApplyForTesting = {
                if first == nil, !controller.session.scrollModel.rows.isEmpty {
                    first = .some(controller.session.scrollModel.topAnchor())
                }
            }
        }
        defer { controller.tearDown(); window.orderOut(nil) }
        try await waitUntil(timeout: 20) {
            controller.session.scrollModel.rows.count == h.viewModel.windowedRows.count && !controller.hasPendingWork
        }
        #if DEBUG
        let passes = controller.hostedMeasureTimePerPassForTesting
        XCTAssertGreaterThan(passes.count, 1)
        for spent in passes {
            XCTAssertLessThanOrEqual(spent, MacTimelineController.hostedSliceBudget + 1e-9)
        }
        #endif
        XCTAssertEqual(first, .some(anchor))
        let model = controller.session.scrollModel
        XCTAssertEqual(model.topAnchor(), anchor)
        XCTAssertFalse(model.isFollowingTail)
        XCTAssertEqual(controller.scrollView.contentView.bounds.origin.y, model.contentOffsetY, accuracy: 0.5)
        XCTAssertEqual(controller.session.invariantSnapCount, 0)
    }

    /// Fix round 1, finding 1: a cold open at the tail over a screen of
    /// hosted cards mixed with text. The cards are measured only in slices
    /// (never a screen of them in one pass) and the text rows only by the
    /// precompute (never on main); the first apply shows the tail and the
    /// timeline stays pinned there.
    func test_aColdTailOpenOverCardsMeasuresHostedRowsInSlicesAndNoTextOnMain() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.controller.hostedRowOverrideForTesting = MacTimelineHarness.costlyHosted(clock, cost: 0.002)
        h.controller.clock = { clock.now }
        var applies: [Bool] = []
        h.controller.onApplyForTesting = {
            if !h.controller.session.scrollModel.rows.isEmpty { applies.append(h.controller.hasVisibleRows()) }
        }
        // The last 40 items alternate a card and a text row.
        let cards = (91...130).map { n in
            TimelineItem(id: "\(n)", sender: "@bot:s", timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
                         kind: n % 2 == 0 ? .file(url: nil, filename: "card-\(n).txt", caption: nil, sizeBytes: nil, expired: false)
                                    : .text(body: "Text \(n) between cards", formattedHTML: nil),
                         isOwn: false, sendState: .sent)
        }
        try await h.startSlowly(with: h.texts(90) + cards)

        let model = h.controller.session.scrollModel
        let hosted = model.rows.filter { if case .hosted? = h.controller.session.contents[$0.id] { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(hosted.count, 20)
        XCTAssertEqual(h.controller.syncMeasuredRowCountForTesting, 0)
        #if DEBUG
        let passes = h.controller.hostedMeasureTimePerPassForTesting
        XCTAssertGreaterThan(passes.count, 1)
        for spent in passes {
            XCTAssertLessThanOrEqual(spent, MacTimelineController.hostedSliceBudget + 1e-9)
        }
        #endif
        XCTAssertFalse(applies.isEmpty)
        XCTAssertTrue(applies.allSatisfy { $0 })
        XCTAssertEqual(h.controller.session.invariantSnapCount, 0)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
    }

    /// Fix round 1, finding 3: while an extension's hosted rows wait for
    /// slices, a stream commit and the reader's own send at the tail show
    /// on the next pass, without the rows still being measured above. The
    /// own send returns to the bottom; paging waits for the whole window,
    /// which then prepends with the tail still pinned.
    func test_aTailChangeDuringExtensionSlicingAppliesOnTheNextPass() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock)
        let items = h.dailyTexts(300)
        try await h.startSlowly(with: items)
        try h.readMidWindow()
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())
        let before = h.controller.session.scrollModel.rows.map(\.id)

        h.controller.holdsHostedSlicesForTesting = true
        await h.viewModel.extendHistoryWindow()
        try await waitUntil(timeout: 5) { h.controller.isSlicingHostedRowsForTesting }
        XCTAssertEqual(h.controller.session.scrollModel.rows.map(\.id), before)

        // A stream commit: on screen with the slices still held.
        let lastDay = try XCTUnwrap(items.last).timestamp
        h.service.emit(items + [JournalTimelineMapper.streamingItem(messageRef: "r", text: "Streaming reply", convoTS: lastDay)])
        try await waitUntil { h.controller.session.scrollModel.rows.last?.id == "eph:r" }
        XCTAssertTrue(h.controller.isSlicingHostedRowsForTesting)
        XCTAssertEqual(h.controller.session.scrollModel.rows.map(\.id), before + ["eph:r"])
        XCTAssertEqual(h.controller.session.scrollModel.topAnchor(), anchor)
        XCTAssertEqual(h.clipY, h.controller.session.scrollModel.contentOffsetY, accuracy: 0.5)

        // Paging waits for the whole window.
        let requests = h.controller.session.extendRequestCount
        h.controller.session.userScrolled(toOffset: 0)
        XCTAssertTrue(h.controller.session.scrollModel.isNearTop)
        XCTAssertEqual(h.controller.session.extendRequestCount, requests)

        // The reader's own send: on screen, and back at the bottom.
        let own = TimelineItem(id: "own1", sender: "@me:s", timestamp: lastDay.addingTimeInterval(60),
                               kind: .text(body: "mine", formattedHTML: nil), isOwn: true, sendState: .sent)
        h.service.emit(items + [own])
        try await waitUntil { h.controller.session.scrollModel.rows.last?.id == "own1" }
        XCTAssertTrue(h.controller.isSlicingHostedRowsForTesting)
        XCTAssertTrue(h.controller.session.scrollModel.isFollowingTail)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
        XCTAssertEqual(h.controller.session.extendRequestCount, requests)

        h.controller.holdsHostedSlicesForTesting = false
        try await h.settle(timeout: 15)
        let model = h.controller.session.scrollModel
        XCTAssertGreaterThan(model.rows.count, before.count + 100)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(h.clipY, h.maxY, accuracy: 0.5)
        XCTAssertEqual(h.controller.session.invariantSnapCount, 0)
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
    }

    /// Fix round 1: a width change while an extension's hosted rows wait
    /// for slices applies no measurement taken at the old width (the rows
    /// already measured for the waiting region are at the old width), and
    /// keeps the reader's row.
    func test_aWidthChangeMidSliceAppliesNoOldWidthMeasurement() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock)
        let long = String(repeating: "A longer message body that wraps across several lines at any width. ", count: 3)
        try await h.startSlowly(with: h.dailyTexts(300) { "Message \($0). " + long })
        try h.readMidWindow()
        let anchor = try XCTUnwrap(h.controller.session.scrollModel.topAnchor())
        let before = Set(h.controller.session.scrollModel.rows.map(\.id))
        let oldWidth = h.controller.scrollView.contentView.bounds.width

        h.controller.holdsHostedSlicesForTesting = true
        await h.viewModel.extendHistoryWindow()
        try await waitUntil(timeout: 5) { h.controller.isSlicingHostedRowsForTesting }
        h.window.setContentSize(CGSize(width: 520, height: 600))
        h.controller.view.layoutSubtreeIfNeeded()
        h.controller.holdsHostedSlicesForTesting = false
        try await h.settle(timeout: 15)

        let width = h.controller.scrollView.contentView.bounds.width
        XCTAssertNotEqual(width, oldWidth)
        let model = h.controller.session.scrollModel
        var rewrapped = 0
        for (i, row) in model.rows.enumerated() {
            let content = try XCTUnwrap(h.controller.session.contents[row.id])
            let now = try XCTUnwrap(h.cache.measurement(roomID: h.viewModel.roomID, content: content, width: width))
            let gap = i < model.rows.count - 1 ? MacTimelineController.rowSpacing : 0
            XCTAssertEqual(row.height, now.height + gap, accuracy: 0.01, "row \(row.id)")
            if !before.contains(row.id),
               let old = h.cache.measurement(roomID: h.viewModel.roomID, content: content, width: oldWidth),
               abs(old.height - now.height) > 1 {
                rewrapped += 1
            }
        }
        XCTAssertGreaterThan(rewrapped, 0)                       // the waiting rows really re-wrapped
        XCTAssertEqual(model.topAnchor()?.rowID, anchor.rowID)
        for i in 0..<model.rows.count {
            XCTAssertEqual(h.controller.tableView.rect(ofRow: i + 1).minY, model.rowMinY(at: i), accuracy: 0.5)
        }
        XCTAssertEqual(h.clipY, model.contentOffsetY, accuracy: 0.5)
    }

    /// Fix round 1: tearing the controller down while hosted rows wait for
    /// slices (an extension, or a cold open still in its loading state)
    /// leaves nothing pending and applies nothing afterwards.
    func test_aTearDownMidSliceLeavesNothingPendingAndAppliesNothing() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.useCostlySeparators(clock)
        try await h.startSlowly(with: h.dailyTexts(300))
        try h.readMidWindow()
        let before = h.controller.session.scrollModel.rows.map(\.id)
        h.controller.holdsHostedSlicesForTesting = true
        await h.viewModel.extendHistoryWindow()
        try await waitUntil(timeout: 5) { h.controller.isSlicingHostedRowsForTesting }
        h.controller.resetCountersForTesting()
        h.controller.tearDown()
        XCTAssertFalse(h.controller.hasPendingWork)
        h.controller.sync()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.controller.applyCountForTesting, 0)
        XCTAssertEqual(h.controller.session.scrollModel.rows.map(\.id), before)

        // A cold open torn down in its loading state.
        let (cold, window) = h.coldController { controller in
            controller.hostedRowOverrideForTesting = MacTimelineHarness.costlySeparator(clock)
            controller.clock = { clock.now }
            controller.holdsHostedSlicesForTesting = true
        }
        defer { window.orderOut(nil) }
        try await waitUntil(timeout: 5) { cold.isSlicingHostedRowsForTesting }
        XCTAssertTrue(cold.session.scrollModel.rows.isEmpty)
        cold.tearDown()
        XCTAssertFalse(cold.hasPendingWork)
        cold.sync()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(cold.applyCountForTesting, 0)
        XCTAssertTrue(cold.session.scrollModel.rows.isEmpty)
    }

    // MARK: Perf follow-ups O1 (b)

    /// For a moment after an open (a reload) the table prepares only its
    /// visible rect, and prepares what AppKit asked for, plus what is
    /// visible then, once the moment is over. A tail append does not
    /// restrict.
    func test_anOpenPreparesOnlyTheVisibleRectForAMomentThenWhatWasAsked() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.controller.clock = { clock.now }
        let items = h.texts(300)
        try await h.start(with: Array(items.prefix(299)))
        let table = try XCTUnwrap(h.controller.tableView as? TimelineTableView)
        XCTAssertTrue(table.isRestrictingPreparedContent)       // the open's moment
        let asked = table.overdraw()
        table.prepareContent(in: asked)
        XCTAssertEqual(table.lastPreparedRectForTesting, table.visibleRect)

        // The reader scrolls well away from what AppKit asked for.
        h.controller.session.userDragBegan()
        let away = table.visibleRect.minY - table.visibleRect.height * 3
        h.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: away))
        table.prepareContent(in: asked)
        XCTAssertFalse(asked.intersects(table.visibleRect))
        clock.now += MacTimelineController.preparedContentRestriction + 0.01
        XCTAssertFalse(table.isRestrictingPreparedContent)
        // When the moment ends (real time) the postponed rect is prepared,
        // and what is on screen by then with it.
        try await waitUntil(timeout: 3) { table.lastPreparedRectForTesting == asked.union(table.visibleRect) }
        let wide = table.overdraw().insetBy(dx: 0, dy: 10)
        table.prepareContent(in: wide)
        XCTAssertEqual(table.lastPreparedRectForTesting, wide)

        try await h.emit(items)                                 // a tail append
        XCTAssertFalse(table.isRestrictingPreparedContent)
    }

    /// Fix round 1, finding 2: an extension that lands while the reader is
    /// coasting up into it (momentum after a flick near the top) must not
    /// restrict the prepared rect: the rows it prepends above the viewport
    /// are prepared as AppKit asks, and mounted.
    func test_anExtensionDuringMomentumPreparesThePrependedRows() async throws {
        let h = MacTimelineHarness()
        let clock = FakeClock()
        h.controller.clock = { clock.now }
        try await h.start(with: h.texts(300))
        clock.now += 1                                          // the open's moment is over
        let table = try XCTUnwrap(h.controller.tableView as? TimelineTableView)
        let sv = h.controller.scrollView!
        let before = Set(h.controller.session.scrollModel.rows.map(\.id))

        // A flick up to near the top; its momentum is still running when
        // the near-top extension lands.
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .began))
        sv.scrollWheel(with: MacTimelineHarness.wheel(200, phase: .changed))
        sv.contentView.scroll(to: NSPoint(x: 0, y: 40))
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: .ended))
        sv.scrollWheel(with: MacTimelineHarness.wheel(20, phase: nil, momentum: .begin))
        XCTAssertTrue(h.controller.isUserGestureActiveForTesting)
        try await waitUntil { h.controller.session.scrollModel.rows.count > before.count }
        try await h.settle()
        XCTAssertTrue(h.controller.isUserGestureActiveForTesting)

        let model = h.controller.session.scrollModel
        let prepended = model.rows.indices.filter { !before.contains(model.rows[$0].id) }
        XCTAssertGreaterThan(prepended.count, 10)
        XCTAssertFalse(table.isRestrictingPreparedContent)
        let asked = table.overdraw()
        table.prepareContent(in: asked)
        XCTAssertEqual(table.lastPreparedRectForTesting, asked)
        // The prepended row just above the viewport is mounted.
        let above = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY - 1))
        XCTAssertTrue(prepended.contains(above - 1))
        XCTAssertNotNil(table.view(atColumn: 0, row: above, makeIfNecessary: false))
        sv.scrollWheel(with: MacTimelineHarness.wheel(0, phase: nil, momentum: .end))
    }
}

private extension TimelineTableView {
    /// Twice the visible rect, reaching up (where an extension prepends).
    func overdraw() -> NSRect {
        let visible = visibleRect
        return NSRect(x: visible.minX, y: visible.minY - visible.height, width: visible.width, height: visible.height * 2)
    }
}

/// A clock the O1 tests move by hand (the controller's `clock` seam).
private final class FakeClock {
    var now: CFTimeInterval = 1000
}

private extension MacTimelineHarness {
    /// `n` bot messages, each on its own day: every other row is a hosted
    /// day separator.
    func dailyTexts(_ n: Int, body: (Int) -> String = { "Message \($0) with a few words in it" }) -> [TimelineItem] {
        (1...n).map { TimelineItem(id: "\($0)", sender: "@bot:s",
                                   timestamp: Date(timeIntervalSince1970: 1_699_963_200 + Double($0) * 86_400),
                                   kind: .text(body: body($0), formattedHTML: nil),
                                   isOwn: false, sendState: .sent) }
    }

    /// Separators draw a fixed 30 pt block, and every one built (to measure
    /// or to render) costs `clock` `cost` (1 ms by default; at the slice
    /// budget, each slice measures exactly one).
    static func costlySeparator(_ clock: FakeClock, cost: CFTimeInterval = 0.001) -> (HostedRowContent) -> AnyView? {
        { content in
            guard case .separator = content.row else { return nil }
            clock.now += cost
            return AnyView(Color.gray.frame(height: 30))
        }
    }

    /// Every hosted row (a separator or a card) draws a fixed 30 pt block
    /// and costs `clock` `cost` per build.
    static func costlyHosted(_ clock: FakeClock, cost: CFTimeInterval) -> (HostedRowContent) -> AnyView? {
        { _ in
            clock.now += cost
            return AnyView(Color.gray.frame(height: 30))
        }
    }

    /// `start(with:)` with room for the slices under a loaded machine.
    func startSlowly(with items: [TimelineItem]) async throws {
        service.emit(items)
        _ = await viewModel.start()
        try await settle(timeout: 15)
    }

    /// Scrolls (as the reader) to the middle of the window: far from both
    /// edges, with a real top anchor.
    func readMidWindow() throws {
        controller.session.userDragBegan()
        let mid = (maxY / 2).rounded()
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: mid))
        controller.session.userScrolled(toOffset: mid)
        XCTAssertFalse(controller.session.scrollModel.isFollowingTail)
    }

    func useCostlySeparators(_ clock: FakeClock, cost: CFTimeInterval = 0.001) {
        controller.hostedRowOverrideForTesting = Self.costlySeparator(clock, cost: cost)
        controller.clock = { clock.now }
    }

    /// A second controller over the same room with a cold measure cache,
    /// in its own 800×600 window; `configure` runs before it mounts rows.
    func coldController(configure: (MacTimelineController) -> Void) -> (MacTimelineController, NSWindow) {
        let controller = MacTimelineController(viewModel: viewModel, stripViewModel: strip, bridge: MacTimelineBridge(),
                                               selection: MessageSelectionController(), actions: .inert,
                                               cache: MacTimelineMeasureCache(countLimit: 4000))
        configure(controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 800, height: 600))
        window.orderFront(nil)
        return (controller, window)
    }
}

private extension TimelineScrollModel {
    /// Each visible row's top relative to the viewport's top.
    var screenPositions: [String: CGFloat] {
        var positions: [String: CGFloat] = [:]
        for id in visibleRowIDs {
            if let index = index(of: id) { positions[id] = rowMinY(at: index) - contentOffsetY }
        }
        return positions
    }
}

/// Serves one solid PNG of a fixed size for every media URL.
private final class PNGMediaFixture: MediaService, @unchecked Sendable {
    private let bytes: Data
    init(width: Int, height: Int) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        bytes = rep.representation(using: .png, properties: [:])!
    }
    func image(for mxc: URL) async -> Data? { bytes }
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
