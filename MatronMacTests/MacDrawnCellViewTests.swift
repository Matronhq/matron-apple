#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac
import MatronModels

/// The hand-drawn list rows always show one whole drawing at their current
/// size: never what AppKit kept from an earlier size (a For you row once
/// showed text wrapped for an older, narrower row beside the ends of wider
/// drawings, after the list's width had changed).
@MainActor
final class MacDrawnCellViewTests: XCTestCase {
    private func spin() {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            CATransaction.flush()
        }
    }

    private func window(_ size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        window.orderFront(nil)
        return window
    }

    /// The image on `cell`'s layer, and a fresh drawing of it now.
    private func shownAndFresh(_ cell: NSView) -> (shown: CGImage?, fresh: CGImage?) {
        let scale = cell.layer?.contentsScale ?? 1
        let contents = cell.layer?.contents as CFTypeRef?
        let shown = contents.flatMap { CFGetTypeID($0) == CGImage.typeID ? ($0 as! CGImage) : nil }
        return (shown, MacDrawnCellView.image(of: cell, scale: scale,
                                              colorSpace: MacDrawnCellView.colorSpace(of: cell.window)))
    }

    private func assertShowsAFreshDrawing(_ cell: NSView, _ what: String, file: StaticString = #filePath,
                                          line: UInt = #line) {
        let (shown, fresh) = shownAndFresh(cell)
        guard let shown, let fresh else {
            XCTFail("\(what): no image of its own on the layer", file: file, line: line)
            return
        }
        XCTAssertEqual(shown.width, fresh.width, "\(what): width", file: file, line: line)
        XCTAssertEqual(shown.height, fresh.height, "\(what): height", file: file, line: line)
        XCTAssertEqual(shown.dataProvider?.data as Data?, fresh.dataProvider?.data as Data?,
                       "\(what): the same drawing", file: file, line: line)
    }

    func test_everyHandDrawnCell_isADrawnCell() {
        let cells: [NSView] = [MacItemRowCell(frame: .zero), MacDecisionsShowMoreCell(frame: .zero),
                               MacPendingItemCell(frame: .zero), MacChatListCell(frame: .zero)]
        for cell in cells {
            XCTAssertTrue(cell is MacDrawnCellView, "\(type(of: cell))")
        }
    }

    func test_aRow_drawsAgainWholeWhenOnlyItsWidthChanges() {
        let window = window(NSSize(width: 600, height: 200))
        defer { window.close() }
        let item = MacDecisionsFixtures.open()[0]
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        cell.configure(item, origin: "Review", isClosedTab: false, now: MacDecisionsFixtures.now)
        window.contentView?.addSubview(cell)
        spin()
        assertShowsAFreshDrawing(cell, "260 wide")
        for width in [480.0, 300, 520] {
            cell.setFrameSize(NSSize(width: width, height: 80))
            spin()
            assertShowsAFreshDrawing(cell, "\(Int(width)) wide")
        }
    }

    /// Drawn in the window's colour space, so the layer shows the image as
    /// it is: an sRGB image in a P3 window was converted on every commit.
    func test_aRow_drawsInItsWindowsColorSpace() {
        let window = window(NSSize(width: 400, height: 200))
        defer { window.close() }
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 380, height: 80))
        cell.configure(MacDecisionsFixtures.open()[1], origin: "Review", isClosedTab: false, now: MacDecisionsFixtures.now)
        window.contentView?.addSubview(cell)
        for space in [NSColorSpace.displayP3, .sRGB, .displayP3] {
            window.colorSpace = space
            cell.needsDisplay = true
            spin()
            let shown = shownAndFresh(cell).shown
            XCTAssertEqual(shown?.colorSpace?.name, space.cgColorSpace?.name, "\(space.localizedName ?? "")")
        }
    }

    /// With the screen locked a cell keeps what it showed and draws once
    /// the window is back on screen: those drawings paged fonts back in
    /// while memory was short, for nobody to see.
    func test_aCellWaitsToDraw_whileItsWindowIsHidden() {
        var visible = true
        let real = MacDrawnCellView.isWindowVisible
        MacDrawnCellView.isWindowVisible = { _ in visible }
        defer { MacDrawnCellView.isWindowVisible = real }
        let window = window(NSSize(width: 600, height: 200))
        defer { window.close() }
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        cell.configure(MacDecisionsFixtures.open()[0], origin: "Review", isClosedTab: false, now: MacDecisionsFixtures.now)
        window.contentView?.addSubview(cell)
        spin()
        assertShowsAFreshDrawing(cell, "on screen")
        let scale = cell.layer?.contentsScale ?? 1

        visible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        cell.setFrameSize(NSSize(width: 480, height: 80))
        spin()
        XCTAssertEqual(shownAndFresh(cell).shown?.width, Int((260 * scale).rounded(.up)),
                       "hidden: still the drawing from before")

        visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        spin()
        assertShowsAFreshDrawing(cell, "back on screen")
    }

    /// A window never reported on screen (a test host's) draws as before.
    func test_aCellInAWindowNeverOnScreen_keepsDrawing() {
        let real = MacDrawnCellView.isWindowVisible
        MacDrawnCellView.isWindowVisible = { _ in false }
        defer { MacDrawnCellView.isWindowVisible = real }
        let realAsleep = MacScreenState.isAsleep
        MacScreenState.isAsleep = { false }
        defer { MacScreenState.isAsleep = realAsleep }
        let window = window(NSSize(width: 600, height: 200))
        defer { window.close() }
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        cell.configure(MacDecisionsFixtures.open()[0], origin: "Review", isClosedTab: false, now: MacDecisionsFixtures.now)
        window.contentView?.addSubview(cell)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        cell.setFrameSize(NSSize(width: 480, height: 80))
        spin()
        assertShowsAFreshDrawing(cell, "480 wide")
    }

    /// Launched with the display off: never on screen, but nobody can see
    /// it, so it waits, and draws once the window shows.
    func test_aCellInAWindowNeverOnScreen_waitsWhileTheScreenIsAsleep() {
        var visible = false
        let real = MacDrawnCellView.isWindowVisible
        MacDrawnCellView.isWindowVisible = { _ in visible }
        defer { MacDrawnCellView.isWindowVisible = real }
        let realAsleep = MacScreenState.isAsleep
        MacScreenState.isAsleep = { !visible }
        defer { MacScreenState.isAsleep = realAsleep }
        let window = window(NSSize(width: 600, height: 200))
        defer { window.close() }
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        cell.configure(MacDecisionsFixtures.open()[0], origin: "Review", isClosedTab: false, now: MacDecisionsFixtures.now)
        window.contentView?.addSubview(cell)
        spin()
        XCTAssertNil(shownAndFresh(cell).shown, "asleep: nothing drawn yet")

        visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        spin()
        assertShowsAFreshDrawing(cell, "on screen")
    }

    func test_aCellInTheReuseQueue_letsGoOfItsImage() {
        let window = window(NSSize(width: 400, height: 200))
        defer { window.close() }
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 380, height: 80))
        cell.configure(MacDecisionsFixtures.open()[1], origin: "Review", isClosedTab: false, now: MacDecisionsFixtures.now)
        window.contentView?.addSubview(cell)
        spin()
        XCTAssertNotNil(cell.layer?.contents)
        cell.removeFromSuperview()
        XCTAssertNil(cell.layer?.contents)
        window.contentView?.addSubview(cell)
        spin()
        assertShowsAFreshDrawing(cell, "back on screen")
    }

    /// The whole For you list, its width going up and down and its rows
    /// changing: every row on screen shows a fresh drawing at its size.
    func test_theForYouList_showsFreshRows_throughResizesAndUpdates() {
        let rows = MacDecisionsRows()
        rows.now = { MacDecisionsFixtures.now }
        let host = MacListHost(rows: rows, style: .plain,
                               accessibilityIdentifier: MacDecisionsAppKitList.accessibilityIdentifier)
        let window = window(NSSize(width: 300, height: 900))
        defer { window.close() }
        host.view.frame = window.contentView!.bounds
        host.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(host.view)
        var items = MacDecisionsFixtures.open()
        var oldIDs: [String] = []
        func publish() {
            let shown = items.map { MacDecisionsRow(item: $0, origin: MacDecisionsFixtures.origin($0), isClosedTab: false) }
            let ids = shown.map(\.id)
            let update = oldIDs.isEmpty ? ListUpdate.reset([ListSection(key: "open", ids: ids)])
                : ListUpdate(from: [ListSection(key: "open", ids: oldIDs)], to: [ListSection(key: "open", ids: ids)],
                             touched: Set(ids))
            host.apply(ListPublication(update: update, rows: shown))
            oldIDs = ids
        }
        publish()
        spin()
        for (step, width) in [520.0, 340, 560, 380, 600].enumerated() {
            window.setContentSize(NSSize(width: width, height: 900))
            // A row moves to the top, and the consent ask is answered.
            items.insert(items.removeLast(), at: 0)
            if step == 2 { items.removeAll { !$0.rowConsentAnswers.isEmpty } }
            publish()
            spin()
            var checked = 0
            host.tableView.enumerateAvailableRowViews { rowView, _ in
                guard let cell = rowView.view(atColumn: 0) as? MacItemRowCell,
                      host.tableView.visibleRect.contains(rowView.frame.insetBy(dx: 1, dy: 1)) else { return }
                XCTAssertEqual(cell.frame.width, rowView.bounds.width, "#\(cell.item?.num ?? 0) fills its row")
                assertShowsAFreshDrawing(cell, "\(Int(width)) wide, #\(cell.item?.num ?? 0)")
                checked += 1
            }
            XCTAssertEqual(checked, items.count, "\(Int(width)) wide: every row checked")
        }
    }
}
#endif
