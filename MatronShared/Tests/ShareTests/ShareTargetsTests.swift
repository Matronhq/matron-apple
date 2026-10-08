import XCTest
@testable import MatronShare

final class ShareTargetsTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func test_ordered_putsTheCoordinatorFirst_thenNewestFirst() {
        let targets = [
            ShareTarget(id: "old", title: "Old", lastActivity: date(10)),
            ShareTarget(id: "never", title: "Never"),
            ShareTarget(id: "coord", title: "Coordinator", isCoordinator: true, lastActivity: date(5)),
            ShareTarget(id: "new", title: "New", lastActivity: date(20)),
        ]
        XCTAssertEqual(ShareTargets.ordered(targets).map(\.id), ["coord", "new", "old", "never"])
    }

    func test_ordered_keepsOnlyTheLimit() {
        let targets = (0..<10).map { ShareTarget(id: "c\($0)", title: "T", lastActivity: date(Double($0))) }
        XCTAssertEqual(ShareTargets.ordered(targets, limit: 3).map(\.id), ["c9", "c8", "c7"])
    }

    func test_filter_needsEveryWord_ignoringCaseAndAccents() {
        let targets = [
            ShareTarget(id: "a", title: "Café menu redesign"),
            ShareTarget(id: "b", title: "Menu printing"),
        ]
        XCTAssertEqual(ShareTargets.filter(targets, query: "cafe MENU").map(\.id), ["a"])
        XCTAssertEqual(ShareTargets.filter(targets, query: "menu").map(\.id), ["a", "b"])
        XCTAssertEqual(ShareTargets.filter(targets, query: "  ").map(\.id), ["a", "b"])
    }

    func test_cache_roundTrips_forTheSameAccountOnly() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let targets = [ShareTarget(id: "a", title: "A", detail: "box", isCoordinator: true, lastActivity: date(1))]

        XCTAssertNil(ShareTargetsCache.read(userID: "me", in: container))
        try ShareTargetsCache.write(targets, userID: "me", in: container)

        XCTAssertEqual(ShareTargetsCache.read(userID: "me", in: container), targets)
        XCTAssertNil(ShareTargetsCache.read(userID: "someone-else", in: container))

        ShareTargetsCache.clear(in: container)
        XCTAssertNil(ShareTargetsCache.read(userID: "me", in: container))
    }
}
