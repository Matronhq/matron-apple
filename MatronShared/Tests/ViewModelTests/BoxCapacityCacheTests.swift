import XCTest
@testable import MatronViewModels
import MatronModels

/// In-memory `BoxCapacityCaching` for the view-model tests: same contract,
/// no `UserDefaults` domain to clean up. Lives next to the contract tests
/// so the fake and the real adapter can't drift.
@MainActor
final class InMemoryBoxCapacityCache: BoxCapacityCaching {
    private(set) var entries: [Int64: CachedBoxCapacity]
    /// Every `prune(keeping:)` argument, in order — lets a test assert that
    /// the roster, not the cache, decides which boxes still exist.
    private(set) var pruneCalls: [Set<Int64>] = []

    init(_ entries: [Int64: CachedBoxCapacity] = [:]) {
        self.entries = entries
    }

    func loadAll() -> [Int64: CachedBoxCapacity] { entries }

    func save(_ capacity: BoxCapacity, for agentID: Int64, at capturedAt: Date) {
        entries[agentID] = CachedBoxCapacity(capacity: capacity, capturedAt: capturedAt)
    }

    func prune(keeping agentIDs: Set<Int64>) {
        pruneCalls.append(agentIDs)
        entries = entries.filter { agentIDs.contains($0.key) }
    }
}

/// Pins the last-known-capacity store behind the chooser's offline rows: a
/// full round trip through the persisted representation, per-box keying,
/// pruning to the current roster, and survival across store instances.
///
/// Each test uses its own throwaway suite so runs never touch `.standard`
/// and stay isolated from one another (same idiom as
/// `RecentStartFoldersTests`). The suite is removed in `tearDown`.
final class BoxCapacityCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// 2026-08-11 08:13 UTC — the frozen instant the chooser snapshot
    /// baselines already use.
    private let capturedAt = Date(timeIntervalSince1970: 1_754_900_000)

    override func setUp() {
        super.setUp()
        suiteName = "test.boxCapacityCache.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    private func makeCache() -> UserDefaultsBoxCapacityCache {
        UserDefaultsBoxCapacityCache(defaults: defaults)
    }

    private func fullCapacity() -> BoxCapacity {
        BoxCapacity(
            liveSessions: 2,
            limitLines: [
                LimitLine(id: "session", label: "Current session", percent: 39,
                          resetsAt: Date(timeIntervalSince1970: 1_754_936_000)),
                // A line the bridge sent without `resets_at` — the nil has to
                // survive the round trip, not become a bogus epoch date.
                LimitLine(id: "week", label: "Current week (all models)", percent: 85,
                          resetsAt: nil),
            ],
            accountEmail: "pat@yearbook.com")
    }

    @MainActor
    func test_loadAll_isEmptyBeforeAnythingIsSaved() {
        XCTAssertTrue(makeCache().loadAll().isEmpty)
    }

    @MainActor
    func test_save_roundTripsEveryFieldIncludingCaptureTime() {
        let cache = makeCache()
        let capacity = fullCapacity()
        cache.save(capacity, for: 7, at: capturedAt)

        let entry = cache.loadAll()[7]
        XCTAssertEqual(entry?.capacity, capacity, "every capacity field survives the round trip")
        XCTAssertEqual(entry?.capturedAt, capturedAt)
    }

    @MainActor
    func test_save_keysPerBox_andOverwritesTheSameBox() {
        let cache = makeCache()
        cache.save(fullCapacity(), for: 7, at: capturedAt)
        cache.save(BoxCapacity(liveSessions: 0, limitLines: [], accountEmail: "b@x.com"),
                   for: 8, at: capturedAt)
        cache.save(BoxCapacity(liveSessions: 5, limitLines: [], accountEmail: nil),
                   for: 7, at: capturedAt.addingTimeInterval(60))

        XCTAssertEqual(cache.loadAll().count, 2)
        XCTAssertEqual(cache.loadAll()[7]?.capacity.liveSessions, 5, "the newer capture wins")
        XCTAssertEqual(cache.loadAll()[7]?.capturedAt, capturedAt.addingTimeInterval(60))
        XCTAssertEqual(cache.loadAll()[8]?.capacity.accountEmail, "b@x.com", "the other box is untouched")
    }

    @MainActor
    func test_prune_dropsBoxesOutsideTheGivenRoster() {
        let cache = makeCache()
        for id: Int64 in [1, 2, 3] {
            cache.save(BoxCapacity(liveSessions: Int(id), limitLines: [], accountEmail: nil),
                       for: id, at: capturedAt)
        }

        // Box 2 was unpaired: nothing will ever refresh it, so it must not
        // sit in the cache forever.
        cache.prune(keeping: [1, 3])

        XCTAssertEqual(Set(cache.loadAll().keys), [1, 3])
    }

    @MainActor
    func test_persistsAcrossCacheInstances_viaSharedDefaults() {
        makeCache().save(fullCapacity(), for: 7, at: capturedAt)
        // A fresh cache over the same suite — the app-relaunch case.
        let reopened = UserDefaultsBoxCapacityCache(defaults: defaults)
        XCTAssertEqual(reopened.loadAll()[7]?.capacity, fullCapacity())
    }

    @MainActor
    func test_loadAll_degradesToEmptyOnUnreadablePayload() {
        let cache = makeCache()
        cache.save(fullCapacity(), for: 7, at: capturedAt)
        // A payload written by a future (or corrupt) build. The chooser is
        // display-only, so an unreadable cache costs a quieter row — never a
        // crash or a failed load.
        defaults.set(Data("not json".utf8), forKey: UserDefaultsBoxCapacityCache.defaultsKey)

        XCTAssertTrue(cache.loadAll().isEmpty)
        // And it recovers: the next save rewrites the whole payload.
        cache.save(fullCapacity(), for: 7, at: capturedAt)
        XCTAssertEqual(cache.loadAll().count, 1)
    }
}
