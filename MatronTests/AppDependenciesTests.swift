import XCTest
import MatronChat
import MatronModels
import MatronVerification
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

    /// `verificationService(for:)` must return the same instance for the same
    /// session. The instance owns the FlowStore (per-request controllers +
    /// open `AsyncStream` continuations) AND the registered SDK delegate;
    /// returning a fresh instance every call would mean (a) every consumer
    /// has its own empty FlowStore and (b) only the most-recent caller's
    /// delegate is wired to the SDK. Both produce the user-visible bug
    /// expert-QA finding B1 surfaced (SAS sheet hangs, banner silent).
    func test_verificationService_isCached_perSession() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )

        let first = deps.verificationService(for: session)
        let second = deps.verificationService(for: session)

        XCTAssertTrue(first === second,
                      "verificationService(for:) must return the same instance — shared FlowStore + delegate")
    }

    /// B2/M5 expert-QA fix coverage: a `VerificationCenter` constructed
    /// against the cached `verificationService(for:)` shares the SAME
    /// underlying service instance across every consumer. The host
    /// (`MatronApp`) holds the center in `@State` so it survives body
    /// re-evaluations; this test pins the structural half (a freshly-
    /// constructed center wraps the cached service identity, so two
    /// centers wrapping the same session-cached service share a
    /// FlowStore + SDK delegate). The `@State` survival half is a
    /// SwiftUI runtime invariant that the test infra here can't directly
    /// observe — it's enforced by the source-level `@State private var
    /// verificationCenter: VerificationCenter?` on the host. The full
    /// regression coverage lives in the SPM `VerificationCenterTests`
    /// idempotency tests; this test makes the iOS-host wiring
    /// structurally explicit.
    func test_verificationCenter_canBeBuilt_fromCachedService() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let svc = deps.verificationService(for: session)
        let center = VerificationCenter(service: svc)
        // The center MUST reference the cached service — not a fresh
        // copy. This is the load-bearing identity check that prevents
        // a regression where `MatronApp` rebuilds the service inline
        // instead of going through `dependencies.verificationService(for:)`.
        XCTAssertTrue((center.service as AnyObject) === (svc as AnyObject),
                      "VerificationCenter.service must point at the cached instance")
        // Idempotency: re-firing start() doesn't crash and isn't required
        // to dedup observations (covered by SPM-side tests).
        center.start()
        center.start()
        center.stop()
    }

    func test_verificationService_isDistinct_perUser() {
        let deps = AppDependencies()
        let s1 = UserSession(userID: "@a:s", deviceID: "D",
                             homeserverURL: URL(string: "https://s")!, accessToken: "t")
        let s2 = UserSession(userID: "@b:s", deviceID: "D",
                             homeserverURL: URL(string: "https://s")!, accessToken: "t")

        let a = deps.verificationService(for: s1)
        let b = deps.verificationService(for: s2)

        // Sharing a verification service across users would route a second
        // user's incoming-request delegate callback through the first user's
        // FlowStore — a privacy bug.
        XCTAssertFalse(a === b,
                       "different sessions must get different verification services")
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
