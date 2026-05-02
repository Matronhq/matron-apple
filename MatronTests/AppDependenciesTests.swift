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
}
