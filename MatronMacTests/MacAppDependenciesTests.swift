#if os(macOS)
import XCTest
import MatronChat
import MatronModels
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

    /// Mac mirror of the iOS no-touch / FIFO-eviction test. Reads do
    /// not promote (non-mutating subscript get); eviction is insertion
    /// order. See `MatronTests/AppDependenciesTests.swift` for the
    /// @Observable-render-loop rationale.
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
        _ = deps.timelineService(for: session, roomID: "!room0:s")
        _ = deps.timelineService(for: session, roomID: "!room\(limit):s")

        XCTAssertFalse(deps.timelineCacheContains(userID: session.userID, roomID: "!room0:s"))
        XCTAssertTrue(deps.timelineCacheContains(userID: session.userID, roomID: "!room1:s"))
    }

    // MARK: - Sign-out teardown chaining + fresh-login wipe

    /// Mac mirror of `AppDependenciesTests`
    /// `.test_wipeLocalDataForFreshLogin_removesStrayJournalMirror_andEmptiesSearch`.
    /// bugbot "Sign-out leaves local mirror" — see the iOS test for the
    /// full rationale.
    func test_wipeLocalDataForFreshLogin_removesStrayJournalMirror_andEmptiesSearch() async throws {
        let deps = AppDependencies()

        let stray = deps.journalStoreDirectory.appendingPathComponent("@ghost:s.sqlite")
        try Data("leftover".utf8).write(to: stray)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))

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

    /// Mac mirror of the iOS `test_awaitPendingTeardown_waitsForSignOutSearchWipe`.
    /// bugbot "Teardown await drops newer job". Suspension-race determinism
    /// isn't reachable without a teardown gate seam — see the task report.
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

    /// Mac mirror of the iOS `test_consecutiveSignOuts_bothTeardownsCompleteUnderAwait`.
    /// bugbot "Sign-out drops prior teardown job".
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
#endif
