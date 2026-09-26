import XCTest
@testable import Matron

/// Spec §4: prepend keeps the anchor exactly; unpinned growth above the
/// viewport doesn't move content; vanished-anchor rescue.
final class TimelineScrollModelAnchorTests: XCTestCase {
    private func rows(_ ids: [String], height: CGFloat = 100) -> [TimelineScrollModel.Row] {
        ids.map { .init(id: $0, height: height) }
    }

    /// Ten 100pt rows a…j, viewport 300, reader parked at y = 450.
    private func reading() -> TimelineScrollModel {
        var model = TimelineScrollModel()
        model.setViewportHeight(300)
        model.replaceRows(rows(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]), footerHeight: 0)
        model.stopFollowing()
        model.noteUserOffset(450)
        return model
    }

    private func onScreenY(_ model: TimelineScrollModel, _ id: String) -> CGFloat {
        model.rowMinY(at: model.index(of: id)!) - model.contentOffsetY
    }

    func test_topAnchor_isTheFirstVisibleRow() {
        let model = reading()
        // d spans 340…440, e spans 448…548 → e is the first row still visible at 450.
        XCTAssertEqual(model.topAnchor(), .init(rowID: "e", offsetInRow: 2))
    }

    func test_prepend_keepsTheAnchorExactly() {
        var model = reading()
        let before = onScreenY(model, "e")
        model.replaceRows(rows(["x", "y", "z"]) + model.rows, footerHeight: 0)
        XCTAssertEqual(onScreenY(model, "e"), before)
        XCTAssertEqual(model.contentOffsetY, 450 + 3 * 108)
    }

    func test_growthAboveTheViewport_doesNotMoveContent() {
        var model = reading()
        let before = onScreenY(model, "f")
        model.updateHeight(ofRow: "b", to: 150)
        XCTAssertEqual(onScreenY(model, "f"), before)
    }

    func test_growthBelowTheViewport_leavesTheOffsetAlone() {
        var model = reading()
        model.updateHeight(ofRow: "j", to: 600)
        XCTAssertEqual(model.contentOffsetY, 450)
    }

    func test_separatorsNeverAnchor() {
        var model = TimelineScrollModel()
        model.setViewportHeight(300)
        model.replaceRows([.init(id: "sep:1", height: 30), .init(id: "a", height: 100), .init(id: "b", height: 400)],
                          footerHeight: 0)
        model.stopFollowing()
        model.noteUserOffset(20)
        XCTAssertEqual(model.topAnchor()?.rowID, "a", "day separators relocate when the window head moves")
    }

    func test_vanishedAnchor_rescuedByNearestSurvivor() {
        var model = reading()
        let before = onScreenY(model, "f")
        var next = model.rows
        next.removeAll { $0.id == "e" }
        model.replaceRows(next, footerHeight: 0)
        XCTAssertEqual(model.lastRescue, .init(lostRowID: "e", survivorID: "f"))
        XCTAssertEqual(onScreenY(model, "f"), before, "the survivor keeps its own screen position, not the vanished anchor's")
    }

    /// A stream row finishes and is replaced by its final message under a
    /// new id — the finding that prompted the fix: the survivor ("b", above)
    /// must not jump to the viewport top; it keeps its own on-screen spot.
    func test_streamRowRetired_survivorAboveKeepsItsScreenPosition() {
        var model = TimelineScrollModel()
        model.setViewportHeight(300)
        model.replaceRows([.init(id: "a", height: 100), .init(id: "b", height: 100), .init(id: "eph:x", height: 500)],
                          footerHeight: 0)
        model.stopFollowing()
        // a: 16…116, b: 124…224, eph:x: 232…732. Anchor lands just inside eph:x.
        model.noteUserOffset(250)
        let before = onScreenY(model, "b")
        model.replaceRows([.init(id: "a", height: 100), .init(id: "b", height: 100), .init(id: "msg:x", height: 500)],
                          footerHeight: 0)
        XCTAssertEqual(model.lastRescue, .init(lostRowID: "eph:x", survivorID: "b"))
        XCTAssertEqual(onScreenY(model, "b"), before)
    }

    func test_nothingSurvives_goesToTheBottom() {
        var model = reading()
        model.replaceRows(rows(["p", "q", "r", "s"]), footerHeight: 0)
        XCTAssertEqual(model.lastRescue, .init(lostRowID: "e", survivorID: nil))
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_bottomAnchor_isTheLastRowStartingAboveTheBottomEdge() {
        let model = reading()
        // Bottom edge at 750: h spans 772…, g spans 664…764 → g, 86pt below its top.
        XCTAssertEqual(model.bottomAnchor(), .init(rowID: "g", offsetInRow: 86))
    }

    /// Final review MUST 3: a pending restore's first rows (no anchor yet,
    /// not following) park at the bottom instead of clamping to the top —
    /// and follow-tail stays off, so the restore can still land.
    func test_holdingBottom_withNoAnchor_parksAtTheBottomWithoutFollowing() {
        var model = TimelineScrollModel()
        model.setViewportHeight(300)
        model.stopFollowing()
        model.replaceRows(rows(["a", "b", "c", "d", "e"]), footerHeight: 0, holdingBottom: true)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        XCTAssertGreaterThan(model.maxOffsetY, 0)
        XCTAssertFalse(model.isFollowingTail)
        // Without the hold the same apply clamps to the window's top.
        var unheld = TimelineScrollModel()
        unheld.setViewportHeight(300)
        unheld.stopFollowing()
        unheld.replaceRows(rows(["a", "b", "c", "d", "e"]), footerHeight: 0)
        XCTAssertEqual(unheld.contentOffsetY, 0)
    }

    /// The hold never overrides a real anchor (a resumed reader's rows).
    func test_holdingBottom_keepsAnExistingAnchor() {
        var model = reading()
        let before = onScreenY(model, "e")
        model.replaceRows(rows(["x"]) + model.rows, footerHeight: 0, holdingBottom: true)
        XCTAssertEqual(onScreenY(model, "e"), before)
    }
}
