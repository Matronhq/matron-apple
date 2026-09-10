import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// The one place every `[#65](matron://item/65)` tap resolves (item #115).
/// The miss path matters as much as the hit: an unsynced number must come
/// back as `.notSynced` after EXACTLY one refresh, so the host can stay
/// where it is and say so, instead of popping the reader to a list.
private final class FakeNumberStore: TrackerItemNumberReading, @unchecked Sendable {
    /// Numbers present on this "device". Mutated by the refresh fake to
    /// simulate a sync landing the item.
    var present: Set<Int>
    var throwsOnRead = false
    private(set) var reads: [Int] = []

    init(present: Set<Int> = []) { self.present = present }

    func item(num: Int) throws -> TrackerItem? {
        reads.append(num)
        if throwsOnRead { throw JournalAPIError.transport("store") }
        guard present.contains(num) else { return nil }
        return TrackerItem(id: "id-\(num)", num: num, kind: .task, title: "T\(num)", originConvoID: "c1")
    }
}

private final class FakeRefreshSync: ItemsSyncing, @unchecked Sendable {
    private(set) var refreshed: [ItemsScope] = []
    /// Runs on each `refresh` — how a test lands the item mid-resolve.
    var onRefresh: () -> Void = {}

    func refresh(scope: ItemsScope) async { refreshed.append(scope); onRefresh() }
    func refreshItem(id: String) async {}
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {}
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "the journal said no" }
}

final class TrackerItemLinkResolverTests: XCTestCase {

    // MARK: - Store + sync wiring

    func test_localHit_opensWithoutRefreshing() async {
        let store = FakeNumberStore(present: [65])
        let sync = FakeRefreshSync()
        let resolution = await TrackerItemLinkResolver(store: store, sync: sync).resolve(num: 65)

        guard case .open(let id) = resolution else { return XCTFail("expected .open, got \(resolution)") }
        XCTAssertEqual(id, "id-65")
        XCTAssertTrue(sync.refreshed.isEmpty, "a local hit must not fetch anything")
        XCTAssertEqual(store.reads, [65], "one read, no retry")
    }

    func test_missThenRefreshHit_opens() async {
        let store = FakeNumberStore()
        let sync = FakeRefreshSync()
        // The refresh is what lands the item — the exact case the retry
        // exists for (an agent filed #65 seconds ago).
        sync.onRefresh = { store.present.insert(65) }
        let resolution = await TrackerItemLinkResolver(store: store, sync: sync).resolve(num: 65)

        guard case .open(let id) = resolution else { return XCTFail("expected .open, got \(resolution)") }
        XCTAssertEqual(id, "id-65")
        XCTAssertEqual(sync.refreshed, [.all], "the retry refreshes ALL scopes — the item may be another chat's")
        XCTAssertEqual(store.reads, [65, 65])
    }

    func test_missThenRefreshMiss_isNotSynced_andRefreshesExactlyOnce() async {
        let store = FakeNumberStore()
        let sync = FakeRefreshSync()
        let resolution = await TrackerItemLinkResolver(store: store, sync: sync).resolve(num: 65)

        guard case .notSynced = resolution else { return XCTFail("expected .notSynced, got \(resolution)") }
        XCTAssertEqual(sync.refreshed.count, 1, "at most one refresh per resolve")
        XCTAssertEqual(store.reads, [65, 65])
        XCTAssertEqual(resolution.alertMessage(num: 65), "Item #65 isn't on this device yet.")
    }

    func test_throwingStoreRead_failsWithoutRefreshing() async {
        let store = FakeNumberStore(present: [65])
        store.throwsOnRead = true
        let sync = FakeRefreshSync()
        let resolution = await TrackerItemLinkResolver(store: store, sync: sync).resolve(num: 65)

        guard case .failed = resolution else { return XCTFail("expected .failed, got \(resolution)") }
        XCTAssertTrue(sync.refreshed.isEmpty)
        XCTAssertNotNil(resolution.alertMessage(num: 65))
    }

    // MARK: - Seam init

    func test_throwingRefresh_isFailedNotNotSynced() async {
        // A transport fault must not be reported as "this item doesn't
        // exist here" — the user would go looking for a missing item.
        let resolver = TrackerItemLinkResolver(lookup: { _ in nil }, refreshAll: { throw Boom() })
        let resolution = await resolver.resolve(num: 65)

        guard case .failed(let error) = resolution else { return XCTFail("expected .failed, got \(resolution)") }
        XCTAssertEqual(error.localizedDescription, "the journal said no")
        XCTAssertEqual(resolution.alertMessage(num: 65), "Couldn't open item #65 — the journal said no")
    }

    func test_refreshIsCalledAtMostOncePerResolve_evenAcrossRepeatedTaps() async {
        let refreshes = Counter()
        let resolver = TrackerItemLinkResolver(lookup: { _ in nil }, refreshAll: { refreshes.bump() })
        _ = await resolver.resolve(num: 65)
        XCTAssertEqual(refreshes.value, 1)
        // A second tap is a second resolve: one more refresh, not a
        // runaway loop off the back of the first.
        _ = await resolver.resolve(num: 65)
        XCTAssertEqual(refreshes.value, 2)
    }

    func test_openResolution_hasNothingToSay() async {
        let resolver = TrackerItemLinkResolver(
            lookup: { TrackerItem(id: "id-\($0)", num: $0, kind: .task, title: "t", originConvoID: "c1") },
            refreshAll: { XCTFail("no refresh on a hit") })
        let resolution = await resolver.resolve(num: 9)
        XCTAssertNil(resolution.alertMessage(num: 9))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
