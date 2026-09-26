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
        var next = model.rows
        next.removeAll { $0.id == "e" }
        model.replaceRows(next, footerHeight: 0)
        XCTAssertEqual(model.lastRescue, .init(lostRowID: "e", survivorID: "f"))
        XCTAssertEqual(model.contentOffsetY, model.rowMinY(at: model.index(of: "f")!))
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
}
