import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import MatronMac

@MainActor final class FakeSurface: TimelineSurface {
    var applied: [[String]] = []
    var offsets: [CGFloat] = []
    var flashed: [String] = []
    var visible = true
    var hasPendingWork = false
    var syncRequests = 0
    var following: [Bool] = []
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String]) { applied.append(ids) }
    func setContentOffset(_ offsetY: CGFloat) { offsets.append(offsetY) }
    func killMomentum() {}
    func hasVisibleRows() -> Bool { visible }
    func flashRow(_ id: String) { flashed.append(id) }
    func requestSync() { syncRequests += 1 }
    func followingChanged(_ following: Bool) { self.following.append(following) }
}

@MainActor final class TimelineSessionTests: XCTestCase {
    private func texts(_ n: Int) -> [TimelineRowContent] {
        (0..<n).map { .text(TextRowContent(itemID: "m\($0)", body: "b\($0)", isOwn: false, sendState: .sent,
                                           timestamp: Date(timeIntervalSince1970: 0), avatarSender: nil,
                                           senderLabel: "bot", pills: [])) }
    }

    private func makeSession() async -> (TimelineSession, FakeSurface) {
        let service = LiveTimelineFixture()
        let viewModel = TimelineFixtures.viewModel(service, roomID: "!s-\(UUID().uuidString):t")
        let surface = FakeSurface()
        let session = TimelineSession(viewModel: viewModel, surface: surface)
        session.setViewportHeight(500, widthChanging: false)
        return (session, surface)
    }

    func test_applyWhileFollowingPinsToBottom() async {
        let (session, surface) = await makeSession()
        let rows = texts(20)
        session.apply(rows, heights: Dictionary(uniqueKeysWithValues: rows.map { ($0.anchorID, 100) }),
                      footerHeight: 0, forceReconfigure: false)
        XCTAssertEqual(surface.applied.last?.count, 20)
        XCTAssertEqual(surface.offsets.last ?? -1, session.scrollModel.maxOffsetY, accuracy: 0.01)
    }

    func test_userDragReleasesFollowAndPrependKeepsAnchor() async {
        let (session, surface) = await makeSession()
        var rows = texts(20)
        var heights = Dictionary(uniqueKeysWithValues: rows.map { ($0.anchorID, CGFloat(100)) })
        session.apply(rows, heights: heights, footerHeight: 0, forceReconfigure: false)
        session.userDragBegan()
        session.userScrolled(toOffset: 600)
        let anchor = session.scrollModel.topAnchor()
        let older: [TimelineRowContent] = (0..<5).map { .text(TextRowContent(itemID: "o\($0)", body: "o", isOwn: false,
            sendState: .sent, timestamp: Date(timeIntervalSince1970: 0), avatarSender: nil, senderLabel: "bot", pills: [])) }
        rows = older + rows
        for row in older { heights[row.anchorID] = 80 }
        session.apply(rows, heights: heights, footerHeight: 0, forceReconfigure: false)
        XCTAssertEqual(session.scrollModel.topAnchor(), anchor)
        XCTAssertEqual(surface.offsets.last ?? -1, 600 + 5 * 80 + 5 * session.scrollModel.metrics.rowSpacing, accuracy: 0.5)
        XCTAssertEqual(surface.following.last, false)
    }

    func test_invariantSnapsWhenRowsButNothingVisible() async {
        let (session, surface) = await makeSession()
        let rows = texts(3)
        session.apply(rows, heights: Dictionary(uniqueKeysWithValues: rows.map { ($0.anchorID, 100) }),
                      footerHeight: 0, forceReconfigure: false)
        surface.visible = false
        session.verifyVisibleRows()
        XCTAssertEqual(session.invariantSnapCount, 1)
    }
}
