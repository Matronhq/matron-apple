import XCTest
import MatronChat
import MatronModels
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

    /// Touching an entry (re-fetching the same `(userID, roomID)`) moves
    /// it to the MRU end so the *next* over-fill evicts something else.
    /// This guards against a regression where `subscript get` doesn't
    /// touch recency, which would degrade the LRU into a FIFO.
    func test_timelineCache_touchPromotesEntryToMRU() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let limit = AppDependencies.timelineCacheLimit

        for i in 0..<limit {
            _ = deps.timelineService(for: session, roomID: "!room\(i):s")
        }
        // Touch room 0 — this should move it to MRU. Now room 1 is LRU.
        _ = deps.timelineService(for: session, roomID: "!room0:s")
        // Trigger eviction.
        _ = deps.timelineService(for: session, roomID: "!room\(limit):s")

        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"),
                      "touched entry must survive the next eviction")
        XCTAssertFalse(deps.timelineCacheContains(userID: session.userID, roomID: "!room1:s"),
                       "true LRU (room1) must be evicted instead")
    }
}
