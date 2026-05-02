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
}
#endif
