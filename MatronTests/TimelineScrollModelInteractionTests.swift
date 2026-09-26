import XCTest
@testable import Matron

/// Spec §4: follow-tail transitions, jump offset math, keyboard resize while
/// pinned or unpinned, edge triggers.
final class TimelineScrollModelInteractionTests: XCTestCase {
    private func model(count: Int = 10, viewport: CGFloat = 300) -> TimelineScrollModel {
        var model = TimelineScrollModel()
        model.setViewportHeight(viewport)
        model.replaceRows((0..<count).map { .init(id: "r\($0)", height: 100) }, footerHeight: 0)
        return model
    }

    func test_drag_releasesFollow_andGrowthNoLongerPins() {
        var model = model()
        XCTAssertTrue(model.beginUserDrag())
        XCTAssertFalse(model.beginUserDrag(), "already released")
        model.noteUserOffset(200)
        model.updateHeight(ofRow: "r9", to: 500)
        XCTAssertEqual(model.contentOffsetY, 200)
    }

    func test_settleNearTheBottom_reArmsFollow_onlyWhenTheWindowHoldsTheTail() {
        var model = model()
        _ = model.beginUserDrag()
        model.noteUserOffset(model.maxOffsetY - 60)
        model.windowContainsTail = false
        XCTAssertFalse(model.endUserScroll(), "a detached window's bottom is not the tail")
        model.windowContainsTail = true
        XCTAssertTrue(model.endUserScroll())
        XCTAssertTrue(model.isFollowingTail)
    }

    func test_settleFarFromTheBottom_staysReleased() {
        var model = model()
        _ = model.beginUserDrag()
        model.noteUserOffset(100)
        XCTAssertFalse(model.endUserScroll())
        XCTAssertFalse(model.isFollowingTail)
    }

    func test_jump_landsTheRowTopAtTheViewportTop_orClampsAtTheBottom() {
        var model = model()
        XCTAssertEqual(model.jumpOffset(toRow: "r3"), model.rowMinY(at: 3))
        XCTAssertFalse(model.isFollowingTail)
        XCTAssertEqual(model.jumpOffset(toRow: "r9"), model.maxOffsetY)
        XCTAssertNil(model.jumpOffset(toRow: "missing"))
    }

    func test_keyboardResize_whilePinned_staysAtTheBottom() {
        var model = model(viewport: 600)
        model.setViewportHeight(300)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
        model.setViewportHeight(600)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY)
    }

    func test_keyboardResize_whileReading_keepsTheBottomVisibleRowFixed() {
        var model = model(viewport: 600)
        _ = model.beginUserDrag()
        model.noteUserOffset(100)
        let before = model.bottomAnchor()!
        let onScreenBottom = model.rowMinY(at: model.index(of: before.rowID)!) - model.contentOffsetY
        model.setViewportHeight(300)
        let after = model.rowMinY(at: model.index(of: before.rowID)!) - model.contentOffsetY
        XCTAssertEqual(after, onScreenBottom - 300, "the row keeps its distance from the viewport's bottom edge")
    }

    func test_edgeTriggers() {
        var model = model(count: 20, viewport: 300)
        _ = model.beginUserDrag()
        model.noteUserOffset(449)
        XCTAssertTrue(model.isNearTop, "within 1.5 screens")
        model.noteUserOffset(451)
        XCTAssertFalse(model.isNearTop)
        model.noteUserOffset(model.maxOffsetY - 100)
        XCTAssertTrue(model.isNearBottom)
        model.noteUserOffset(model.maxOffsetY - 101)
        XCTAssertFalse(model.isNearBottom)
    }

    func test_visibleRowIDs() {
        var model = model()
        _ = model.beginUserDrag()
        model.noteUserOffset(100)
        // [100, 400): r0 ends at 116, r3 starts at 340, r4 starts at 448.
        XCTAssertEqual(model.visibleRowIDs, ["r0", "r1", "r2", "r3"])
    }

    func test_restore_topAnchor_andBottomAligned() {
        var model = model()
        XCTAssertTrue(model.restore(.init(rowID: "r4", offsetInRow: 30)))
        XCTAssertEqual(model.contentOffsetY, model.rowMinY(at: 4) + 30)
        XCTAssertFalse(model.isFollowingTail)
        XCTAssertTrue(model.restoreBottomAligned(rowID: "r5"))
        XCTAssertEqual(model.contentOffsetY, model.rowMinY(at: 5) + 100 - 300)
        XCTAssertFalse(model.restore(.init(rowID: "gone", offsetInRow: 0)))
    }
}
