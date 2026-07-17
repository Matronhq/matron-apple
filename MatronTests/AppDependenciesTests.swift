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

    // MARK: - Sign-out teardown chaining + fresh-login wipe

    /// bugbot "Sign-out leaves local mirror": if the process dies between
    /// `signOut()`'s synchronous `clearSession()` and its background wipe,
    /// the previous user's journal SQLite mirror and the still-populated
    /// shared search index survive on disk — a fresh sign-in would reopen
    /// them (and a different user could search the previous user's
    /// messages). `wipeLocalDataForFreshLogin()` empties both before the
    /// first core opens. A fresh login resyncs from a server snapshot, so
    /// the clean slate costs nothing.
    func test_wipeLocalDataForFreshLogin_removesStrayJournalMirror_andEmptiesSearch() async throws {
        let deps = AppDependencies()

        // A leftover per-user SQLite mirror a crashed teardown left behind.
        let stray = deps.journalStoreDirectory.appendingPathComponent("@ghost:s.sqlite")
        try Data("leftover".utf8).write(to: stray)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))

        // A previous user's message still sitting in the shared search index.
        let search = try XCTUnwrap(deps.search, "search index must open in the test container")
        let term = "freshlogin\(UUID().uuidString.prefix(8))"
        try await search.index(roomID: "!r:s", eventID: "$ghost", sender: "@ghost:s",
                               timestamp: Date(), body: "secret \(term) payload")
        let before = try await search.query(term, limit: 10)
        XCTAssertEqual(before.count, 1)

        await deps.wipeLocalDataForFreshLogin()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path),
                       "fresh-login wipe must delete leftover journal mirror files")
        let after = try await search.query(term, limit: 10)
        XCTAssertEqual(after.count, 0,
                       "fresh-login wipe must empty the shared search index")
    }

    /// bugbot "Teardown await drops newer job": `awaitPendingTeardown()`
    /// must block until the sign-out teardown actually finishes — observed
    /// here via the search wipe that runs as the last step of the teardown
    /// task. If the await returned early (or the sign-in path skipped it),
    /// the index would still hold the prior user's message.
    ///
    /// NOTE: the suspension-race that motivates the generation-counter loop
    /// (a `signOut()` chaining a newer task *while* `awaitPendingTeardown()`
    /// is suspended) is not deterministically reproducible without a
    /// teardown gate seam that `AppDependencies` doesn't expose — see the
    /// task report. This pins the await-actually-waits invariant.
    func test_awaitPendingTeardown_waitsForSignOutSearchWipe() async throws {
        let deps = AppDependencies()
        let search = try XCTUnwrap(deps.search)
        let term = "teardown\(UUID().uuidString.prefix(8))"
        try await search.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                               timestamp: Date(), body: "\(term) here")
        let before = try await search.query(term, limit: 10)
        XCTAssertEqual(before.count, 1)

        deps.signOut()
        await deps.awaitPendingTeardown()

        let after = try await search.query(term, limit: 10)
        XCTAssertEqual(after.count, 0,
                       "awaitPendingTeardown must not return before the teardown's search wipe completes")
    }

    /// Two `signOut()`s with no await between them: pins only that
    /// `awaitPendingTeardown()` drains the *latest* chained teardown (the
    /// emptied search index is produced by the second teardown's wipe alone,
    /// so this would pass even if the first task were dropped rather than
    /// chained). The bugbot "Sign-out drops prior teardown job" and
    /// "Teardown await drops newer job" interleavings are not deterministically
    /// coverable here: `AppDependencies()` exposes no injection seam that could
    /// hold teardown #1 mid-flight while a second sign-out races the await.
    func test_consecutiveSignOuts_bothTeardownsCompleteUnderAwait() async throws {
        let deps = AppDependencies()
        let search = try XCTUnwrap(deps.search)
        let term = "chain\(UUID().uuidString.prefix(8))"
        try await search.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                               timestamp: Date(), body: "\(term) one")

        deps.signOut()
        deps.signOut()
        await deps.awaitPendingTeardown()

        let after = try await search.query(term, limit: 10)
        XCTAssertEqual(after.count, 0,
                       "both chained teardowns must complete before await returns")
    }
}
