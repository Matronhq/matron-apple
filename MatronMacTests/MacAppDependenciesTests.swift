#if os(macOS)
import XCTest
import MatronChat
import MatronModels
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
