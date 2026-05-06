import XCTest
@testable import MatronStorage

/// Round-5 bugbot finding #3 extracted `LRUCache` (and `TimelineCacheKey`)
/// out of the duplicated copies in `Matron/App/AppDependencies.swift` and
/// `MatronMac/App/AppDependencies.swift` into `MatronStorage`. These tests
/// pin the eviction + recency invariants at the type level — both apps'
/// `AppDependenciesTests` exercise the same contract via the cache backing
/// `timelineCache`, but covering the type directly means a future
/// refactor that swaps the underlying recency structure can be validated
/// without rebuilding the app targets.
final class LRUCacheTests: XCTestCase {

    func test_init_negativeOrZeroLimit_traps() {
        // `precondition` guards a zero/negative limit; we don't assert
        // the trap directly (XCTest can't catch it), but a positive
        // limit must construct cleanly.
        let cache = LRUCache<String, Int>(limit: 1)
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(cache.contains("anything"))
    }

    func test_setNewKey_growsCount_untilLimit() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        XCTAssertEqual(cache.count, 3)
        XCTAssertTrue(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }

    func test_setBeyondLimit_evictsLeastRecentlyUsed() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        // Inserting a 4th distinct key evicts "a" (the LRU — never touched).
        cache["d"] = 4
        XCTAssertEqual(cache.count, 3, "cache must stay bounded at limit")
        XCTAssertFalse(cache.contains("a"), "least-recently-used must be evicted")
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
        XCTAssertTrue(cache.contains("d"))
    }

    func test_getDoesNotTouchRecency() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        // Reads must NOT promote "a" — the subscript getter is
        // explicitly non-mutating now (see `LRUCache.swift` doc-comment
        // for the @Observable-render-loop rationale). After a read of
        // "a" then writing "d", "a" is still the LRU and must be
        // evicted; reads aren't a touch.
        _ = cache["a"]
        cache["d"] = 4
        XCTAssertFalse(cache.contains("a"), "untouched-by-write entry must be evicted on next over-fill")
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
        XCTAssertTrue(cache.contains("d"))
    }

    func test_setExistingKey_updatesValue_andTouchesRecency() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        // Re-setting "a" must update its value AND promote it to MRU —
        // otherwise a frequently-overwritten key would still get evicted
        // before less-touched entries.
        cache["a"] = 99
        XCTAssertEqual(cache["a"], 99)
        cache["d"] = 4
        XCTAssertTrue(cache.contains("a"), "re-set key must be promoted to MRU")
        XCTAssertFalse(cache.contains("b"), "now-LRU 'b' must evict instead")
    }

    func test_setNil_removesKeyAndShrinksCount() {
        var cache = LRUCache<String, Int>(limit: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["a"] = nil
        XCTAssertEqual(cache.count, 1)
        XCTAssertFalse(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
        // Re-inserting a previously-removed key works as a fresh insert
        // (no stale recency entry left around).
        cache["a"] = 10
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache["a"], 10)
    }

    func test_getMissingKey_returnsNil_andDoesNotMutateRecency() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache["a"] = 1
        cache["b"] = 2
        XCTAssertNil(cache["missing"])
        // No spurious recency entry: inserting "c" still evicts the true
        // LRU, which is "a" (untouched after insertion).
        cache["c"] = 3
        XCTAssertFalse(cache.contains("a"))
        XCTAssertTrue(cache.contains("b"))
        XCTAssertTrue(cache.contains("c"))
    }

    func test_timelineCacheKey_equalityAndHashing() {
        let a = TimelineCacheKey(userID: "@u:s", roomID: "!r1:s")
        let b = TimelineCacheKey(userID: "@u:s", roomID: "!r1:s")
        let c = TimelineCacheKey(userID: "@u:s", roomID: "!r2:s")
        XCTAssertEqual(a, b, "same userID + roomID must compare equal")
        XCTAssertNotEqual(a, c, "different roomID must not collide")
        // Hashing is the load-bearing property since LRUCache uses these
        // as dictionary keys — equal values must hash identically.
        XCTAssertEqual(a.hashValue, b.hashValue)
    }
}
