import XCTest
@testable import Matron

/// Spec §4 unit tests — geometry + follow-tail. Rows are 100pt unless noted;
/// stack = 16 + rows + 8·(n−1) + 16 + footer.
final class TimelineScrollModelTests: XCTestCase {
    func rows(_ ids: [String], height: CGFloat = 100) -> [TimelineScrollModel.Row] {
        ids.map { .init(id: $0, height: height) }
    }

    func model(_ ids: [String], viewport: CGFloat, height: CGFloat = 100) -> TimelineScrollModel {
        var model = TimelineScrollModel()
        model.setViewportHeight(viewport)
        model.replaceRows(rows(ids, height: height), footerHeight: 0)
        return model
    }

    func test_emptyModel_hasViewportContent_andZeroOffset() {
        var model = TimelineScrollModel()
        model.setViewportHeight(500)
        XCTAssertEqual(model.contentHeight, 500)
        XCTAssertEqual(model.contentOffsetY, 0)
    }

    func test_stackGeometry_matchesTheVStack() {
        let model = model(["a", "b", "c"], viewport: 250)
        XCTAssertEqual(model.stackHeight, 16 + 300 + 16 + 16)
        XCTAssertEqual(model.rowMinY(at: 0), 16)
        XCTAssertEqual(model.rowMinY(at: 1), 124)
        XCTAssertEqual(model.rowMinY(at: 2), 232)
        XCTAssertEqual(model.maxOffsetY, 348 - 250)
    }

    func test_opensFollowingTheTail_atTheBottom() {
        let model = model(["a", "b", "c"], viewport: 250)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_shortContent_hugsTheBottom() {
        let model = model(["only"], viewport: 400, height: 50)
        XCTAssertEqual(model.alignmentPad, 400 - (16 + 50 + 16))
        XCTAssertEqual(model.rowMinY(at: 0) + 50 + 16, 400, "row bottom + bottom inset sits on the viewport bottom")
        XCTAssertEqual(model.contentOffsetY, 0)
    }

    func test_followTail_pinsThroughGrowth() {
        var model = model(["a", "b", "c"], viewport: 250)
        model.updateHeight(ofRow: "c", to: 400)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        model.replaceRows(rows(["a", "b", "c", "d"]), footerHeight: 0)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_footer_sitsBelowTheBottomInset_andPinsWhileFollowing() {
        var model = model(["a", "b"], viewport: 150)
        let before = model.maxOffsetY
        model.setFooterHeight(40)
        XCTAssertEqual(model.footerMinY, model.rowMinY(at: 1) + 100 + 16)
        XCTAssertEqual(model.maxOffsetY, before + 40)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"], "the footer never enters the anchor space")
    }
}
