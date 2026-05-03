#if os(macOS)
import XCTest
import MatronChat
import MatronModels
import MatronVerification
import MatronViewModels
@testable import MatronMac

/// Mac mirror of `MatronTests/AppDependenciesTests`. The Mac
/// `AppDependencies` is a separate type (per-platform glue), so it gets
/// its own identity-cache coverage. See iOS test for full rationale.
@MainActor
final class MacAppDependenciesTests: XCTestCase {
    func test_mediaService_isCached_perSession() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )

        let first = deps.mediaService(for: session)
        let second = deps.mediaService(for: session)

        XCTAssertTrue(first as AnyObject === second as AnyObject,
                      "mediaService(for:) must return the same instance for the same session")
    }

    /// Mac mirror — see iOS `test_verificationService_isCached_perSession`
    /// for the full rationale (shared FlowStore + shared registered SDK
    /// delegate; expert-QA finding B1).
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

    /// B2/M5 expert-QA mirror — see iOS
    /// `test_verificationCenter_canBeBuilt_fromCachedService` for full
    /// rationale. Locks the structural invariant that a freshly-built
    /// `VerificationCenter` wraps the cached service identity, so
    /// every consumer in the Mac app shares a FlowStore + delegate.
    func test_verificationCenter_canBeBuilt_fromCachedService() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let svc = deps.verificationService(for: session)
        let center = VerificationCenter(service: svc)
        XCTAssertTrue((center.service as AnyObject) === (svc as AnyObject),
                      "VerificationCenter.service must point at the cached instance")
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

        XCTAssertFalse(a as AnyObject === b as AnyObject,
                       "different sessions must get different media services")
    }

    /// Mac mirror of `AppDependenciesTests.test_timelineCache_evictsOldestEntry_whenLimitExceeded`.
    /// See the iOS test for the full bugbot rationale — `timelineCache` was
    /// an unbounded `Dictionary`; the fix bounds it to `timelineCacheLimit`
    /// (16) entries via an LRU cap.
    func test_timelineCache_evictsOldestEntry_whenLimitExceeded() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let limit = AppDependencies.timelineCacheLimit
        XCTAssertEqual(limit, 16)

        for i in 0..<limit {
            _ = deps.timelineService(for: session, roomID: "!room\(i):s")
        }
        XCTAssertEqual(deps.timelineCacheCount, limit)
        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"))

        _ = deps.timelineService(for: session, roomID: "!room\(limit):s")

        XCTAssertEqual(deps.timelineCacheCount, limit)
        XCTAssertFalse(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"))
        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room\(limit):s"))
    }

    /// Mac mirror of the iOS touch-promotes-MRU test.
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
        _ = deps.timelineService(for: session, roomID: "!room0:s")
        _ = deps.timelineService(for: session, roomID: "!room\(limit):s")

        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"))
        XCTAssertFalse(deps.timelineCacheContains(userID: session.userID, roomID: "!room1:s"))
    }
}
#endif
