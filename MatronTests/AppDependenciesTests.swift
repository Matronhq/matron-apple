import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Identity-cache coverage for `AppDependencies`. `mediaService(for:)` was
/// previously returning a fresh `MediaServiceLive` on every call (each
/// with its own empty 64 MB `NSCache`), defeating media caching across
/// rooms. The cache pattern mirrors `syncCache` / `timelineCache`.
@MainActor
final class AppDependenciesTests: XCTestCase {
    func test_mediaService_isCached_perSession() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )

        let first = deps.mediaService(for: session)
        let second = deps.mediaService(for: session)

        // Identity, not just equality — `MediaServiceLive` is a class with
        // an internal `NSCache`. Two distinct instances would each hold
        // empty caches, which is the bug we're guarding against.
        XCTAssertTrue(first as AnyObject === second as AnyObject,
                      "mediaService(for:) must return the same instance for the same session")
    }

    func test_mediaService_isDistinct_perUser() {
        let deps = AppDependencies()
        let s1 = UserSession(userID: "@a:s", deviceID: "D",
                             homeserverURL: URL(string: "https://s")!, accessToken: "t")
        let s2 = UserSession(userID: "@b:s", deviceID: "D",
                             homeserverURL: URL(string: "https://s")!, accessToken: "t")

        let a = deps.mediaService(for: s1)
        let b = deps.mediaService(for: s2)

        // Different users get different instances — sharing a media cache
        // across users would leak authenticated bytes across accounts.
        XCTAssertFalse(a as AnyObject === b as AnyObject,
                       "different sessions must get different media services")
    }

    /// Bugbot finding: `timelineCache` was a plain `Dictionary` so every
    /// distinct room visited grew the cache forever. Each entry holds an
    /// SDK timeline handle + an in-memory snapshot, so a long session
    /// that hops through many rooms would accumulate them indefinitely.
    /// The fix bounds the cache with an LRU cap of `timelineCacheLimit`
    /// (16). Visiting `limit + 1` distinct rooms must evict the oldest;
    /// the `limit + 1`-th room must remain cached.
    func test_timelineCache_evictsOldestEntry_whenLimitExceeded() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let limit = AppDependencies.timelineCacheLimit
        XCTAssertEqual(limit, 16, "limit drift would invalidate the regression coverage below")

        // Fill the cache exactly to capacity. Each call inserts a new
        // (userID, roomID) entry — none should evict yet.
        for i in 0..<limit {
            _ = deps.timelineService(for: session, roomID: "!room\(i):s")
        }
        XCTAssertEqual(deps.timelineCacheCount, limit,
                       "cache must reach exactly the limit before evicting")
        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"),
                      "earliest entry must be live before the limit is exceeded")

        // One more distinct room — this must evict the least-recently-used
        // entry, which is `!room0:s` (we haven't touched it since insertion).
        _ = deps.timelineService(for: session, roomID: "!room\(limit):s")

        XCTAssertEqual(deps.timelineCacheCount, limit,
                       "cache must stay bounded at the LRU limit after over-fill")
        XCTAssertFalse(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"),
                       "least-recently-used entry must be evicted on over-fill")
        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room\(limit):s"),
                      "newly-inserted entry must remain in the cache")
    }

    /// Re-fetching an existing `(userID, roomID)` does NOT promote it
    /// — the subscript getter is non-mutating now (see `LRUCache.swift`
    /// for the @Observable-render-loop rationale that drove the
    /// switch). The eviction order for `timelineService(for:)` is
    /// therefore insertion order: when an over-fill occurs, the
    /// originally-first-cached room is the one evicted, regardless of
    /// how many times it was re-fetched after.
    func test_timelineCache_reaccessDoesNotPromote_evictionIsFIFO() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let limit = AppDependencies.timelineCacheLimit

        for i in 0..<limit {
            _ = deps.timelineService(for: session, roomID: "!room\(i):s")
        }
        // Re-fetch room 0 — under the old touch-on-read semantics this
        // would move it to MRU; now it's a no-op for recency.
        _ = deps.timelineService(for: session, roomID: "!room0:s")
        // Trigger eviction.
        _ = deps.timelineService(for: session, roomID: "!room\(limit):s")

        XCTAssertFalse(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"),
                       "FIFO eviction: oldest insert (room0) goes first regardless of re-access")
        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room1:s"),
                      "second-oldest must still be cached after a single eviction")
    }
}
