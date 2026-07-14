import XCTest
@testable import MatronViewModels

/// Pins the recent-folder store contract backing `/start` / `/workdir`
/// completion: record (trim / dedupe-case-insensitive / cap / order),
/// prefix matching, and persistence via the injected UserDefaults suite.
///
/// Each test uses its own throwaway suite so runs never touch `.standard`
/// and stay isolated from one another. The suite is removed in `tearDown`.
final class RecentStartFoldersTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.recentStartFolders.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    private func makeStore() -> RecentStartFolders {
        RecentStartFolders(defaults: defaults)
    }

    @MainActor
    func test_record_thenMatch_returnsRecordedFolder() {
        let store = makeStore()
        store.record("~/yearbook-app")
        XCTAssertEqual(store.matches(prefix: "~/y"), ["~/yearbook-app"])
    }

    @MainActor
    func test_record_trimsWhitespace_andIgnoresEmpty() {
        let store = makeStore()
        store.record("   ")
        store.record("\t\n")
        XCTAssertTrue(store.matches(prefix: "").isEmpty, "empty / whitespace-only input is ignored")

        store.record("  ~/spaced  ")
        XCTAssertEqual(store.matches(prefix: ""), ["~/spaced"], "surrounding whitespace is trimmed")
    }

    @MainActor
    func test_record_dedupesCaseInsensitively_movingToFront() {
        let store = makeStore()
        store.record("~/Alpha")
        store.record("~/beta")
        store.record("~/alpha")   // case-insensitive dup of ~/Alpha

        // Single entry for alpha, moved to the front with the latest casing.
        XCTAssertEqual(store.matches(prefix: ""), ["~/alpha", "~/beta"])
    }

    @MainActor
    func test_record_capsAtFifteen_droppingOldest() {
        let store = makeStore()
        for i in 1...20 { store.record("~/dir\(i)") }
        let all = store.matches(prefix: "")
        XCTAssertEqual(all.count, 15, "history caps at 15")
        XCTAssertEqual(all.first, "~/dir20", "newest is first")
        XCTAssertEqual(all.last, "~/dir6", "oldest surviving entry is dir6 (dir1–5 dropped)")
    }

    @MainActor
    func test_matches_isCaseInsensitivePrefix() {
        let store = makeStore()
        store.record("~/Projects/App")
        XCTAssertEqual(store.matches(prefix: "~/pro"), ["~/Projects/App"])
        XCTAssertTrue(store.matches(prefix: "~/z").isEmpty, "non-matching prefix returns nothing")
    }

    @MainActor
    func test_matches_emptyPrefix_returnsFullListMostRecentFirst() {
        let store = makeStore()
        store.record("~/one")
        store.record("~/two")
        store.record("~/three")
        XCTAssertEqual(store.matches(prefix: ""), ["~/three", "~/two", "~/one"])
    }

    @MainActor
    func test_persistsAcrossStoreInstances_viaSharedDefaults() {
        makeStore().record("~/persisted")
        // A fresh store over the same suite sees the recorded folder.
        let reopened = RecentStartFolders(defaults: defaults)
        XCTAssertEqual(reopened.matches(prefix: "~/p"), ["~/persisted"])
    }
}
