import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// Where a tapped `matron://mission/<n>` / `matron://project/<n>` resolves.
/// As with item links, the miss path matters as much as the hit: exactly
/// one refresh, and a failed refresh is reported as a failure rather than
/// as "isn't on this device".
final class PageLinkResolverTests: XCTestCase {

    /// The pages on this "device", and what a refresh does to them.
    private final class Fake: @unchecked Sendable {
        var pages: [MatronPageLink: MatronPageTarget]
        var throwsOnRead = false
        var failure: MissionsRefreshFailure?
        var onRefresh: () -> Void = {}
        private(set) var refreshed: [MatronPageLink] = []

        init(_ pages: [MatronPageLink: MatronPageTarget] = [:]) { self.pages = pages }

        var resolver: PageLinkResolver {
            PageLinkResolver(
                lookup: { link in
                    if self.throwsOnRead { throw JournalAPIError.transport("store") }
                    return self.pages[link]
                },
                refresh: { link in
                    self.refreshed.append(link)
                    self.onRefresh()
                    return self.failure
                })
        }
    }

    func test_localHit_opensWithoutRefreshing() async {
        let fake = Fake([.mission(61): .mission(id: "ms_1"), .project(12): .project(id: "pj_1")])

        guard case .open(let mission) = await fake.resolver.resolve(.mission(61)),
              case .open(let project) = await fake.resolver.resolve(.project(12))
        else { return XCTFail("expected both to open") }
        XCTAssertEqual(mission, .mission(id: "ms_1"))
        XCTAssertEqual(project, .project(id: "pj_1"))
        XCTAssertTrue(fake.refreshed.isEmpty, "a local hit must not fetch anything")
    }

    func test_miss_refreshesOnceAndOpensWhatArrived() async {
        let fake = Fake()
        fake.onRefresh = { fake.pages[.mission(61)] = .mission(id: "ms_1") }

        guard case .open(let target) = await fake.resolver.resolve(.mission(61))
        else { return XCTFail("expected .open after the refresh") }
        XCTAssertEqual(target, .mission(id: "ms_1"))
        XCTAssertEqual(fake.refreshed, [.mission(61)])
    }

    func test_missAfterRefresh_isNotSynced() async {
        let fake = Fake()
        let resolution = await fake.resolver.resolve(.project(12))

        guard case .notSynced = resolution else { return XCTFail("expected .notSynced, got \(resolution)") }
        XCTAssertEqual(fake.refreshed, [.project(12)], "exactly one refresh")
        XCTAssertEqual(resolution.alertMessage(for: .project(12)), "Project #12 isn't on this device yet.")
    }

    func test_failedRefresh_isReportedAsAFailure() async {
        let fake = Fake()
        fake.failure = MissionsRefreshFailure(message: "offline")
        let resolution = await fake.resolver.resolve(.mission(61))

        guard case .failed = resolution else { return XCTFail("expected .failed, got \(resolution)") }
        XCTAssertEqual(resolution.alertMessage(for: .mission(61)), "Couldn't open mission #61 — offline")
    }

    /// A refresh that failed part-way may still have landed the page.
    func test_failedRefresh_stillOpensAPageThatArrived() async {
        let fake = Fake()
        fake.failure = MissionsRefreshFailure(message: "offline")
        fake.onRefresh = { fake.pages[.mission(61)] = .mission(id: "ms_1") }

        guard case .open = await fake.resolver.resolve(.mission(61)) else { return XCTFail("expected .open") }
    }

    func test_throwingStore_isAFailureWithoutARefresh() async {
        let fake = Fake()
        fake.throwsOnRead = true
        let resolution = await fake.resolver.resolve(.mission(61))

        guard case .failed = resolution else { return XCTFail("expected .failed, got \(resolution)") }
        XCTAssertTrue(fake.refreshed.isEmpty)
    }

    func test_anOpenResolutionHasNothingToSay() {
        XCTAssertNil(PageLinkResolver.Resolution.open(.mission(id: "ms_1")).alertMessage(for: .mission(61)))
    }
}
