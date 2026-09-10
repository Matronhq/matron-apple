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
    /// What the refresh reports back (item #115, fix round 5). Default is
    /// the happy path; a test flips it to `.failed` to stand in for offline.
    var outcome: ItemsRefreshOutcome = .succeeded

    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome {
        refreshed.append(scope); onRefresh(); return outcome
    }
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

    func test_failedRefresh_isFailedNotNotSynced() async {
        // A transport fault must not be reported as "this item doesn't
        // exist here" — the user would go looking for a missing item.
        // `ItemsSync.refresh` swallows the throw internally; what it
        // REPORTS is the whole fix (item #115, fix round 5).
        let resolver = TrackerItemLinkResolver(
            lookup: { _ in nil },
            refreshAll: { .failed(ItemsRefreshFailure(Boom())) })
        let resolution = await resolver.resolve(num: 65)

        guard case .failed(let error) = resolution else { return XCTFail("expected .failed, got \(resolution)") }
        XCTAssertEqual(error.localizedDescription, "the journal said no")
        XCTAssertEqual(resolution.alertMessage(num: 65), "Couldn't open item #65 — the journal said no")
    }

    /// The pair that gives the two messages their meaning: the SAME miss
    /// reports differently depending on whether the fetch happened.
    func test_refreshOutcomeDecidesWhichMissTheUserIsTold() async {
        let store = FakeNumberStore()

        let offline = FakeRefreshSync()
        offline.outcome = .failed(ItemsRefreshFailure(Boom()))
        let failed = await TrackerItemLinkResolver(store: store, sync: offline).resolve(num: 65)
        guard case .failed = failed else { return XCTFail("expected .failed, got \(failed)") }
        XCTAssertEqual(failed.alertMessage(num: 65), "Couldn't open item #65 — the journal said no")
        // Round 6: a failed refresh still earns one more local read, in case
        // an earlier page landed the item before a later page's error —
        // this store never got it, so the read confirms the miss and the
        // failure still reports.
        XCTAssertEqual(store.reads, [65, 65], "the failure path re-checks the store before reporting")

        let online = FakeRefreshSync()
        let missed = await TrackerItemLinkResolver(store: store, sync: online).resolve(num: 65)
        guard case .notSynced = missed else { return XCTFail("expected .notSynced, got \(missed)") }
        XCTAssertEqual(missed.alertMessage(num: 65), "Item #65 isn't on this device yet.")
    }

    /// `ItemsSync.refreshOnce` upserts each page before fetching the next,
    /// so a later-page transport error can still leave the tapped item
    /// already in the store from an earlier page. A `.failed` refresh must
    /// not report failure without checking that first (Bugbot, item #115
    /// fix round 6).
    func test_failedRefresh_butItemLandedFromAnEarlierPage_stillOpens() async {
        let store = FakeNumberStore()
        let sync = FakeRefreshSync()
        // Simulates the item landing from an earlier page of the refresh,
        // moments before a later page fails.
        sync.onRefresh = { store.present.insert(65) }
        sync.outcome = .failed(ItemsRefreshFailure(Boom()))
        let resolution = await TrackerItemLinkResolver(store: store, sync: sync).resolve(num: 65)

        guard case .open(let id) = resolution else { return XCTFail("expected .open, got \(resolution)") }
        XCTAssertEqual(id, "id-65")
        XCTAssertEqual(store.reads, [65, 65], "the failure path gets its own re-read, not a third one")
    }

    /// A journal with no tracker routes, and a sync stopped mid-tap by a
    /// sign-out, both leave a genuine local miss — not a failure to report.
    func test_unsupportedOrStoppedRefresh_stillReadsAsNotSynced() async {
        for outcome in [ItemsRefreshOutcome.unsupported, .stopped] {
            let sync = FakeRefreshSync()
            sync.outcome = outcome
            let resolution = await TrackerItemLinkResolver(store: FakeNumberStore(), sync: sync).resolve(num: 65)
            guard case .notSynced = resolution else {
                return XCTFail("expected .notSynced for \(outcome), got \(resolution)")
            }
        }
    }

    func test_refreshIsCalledAtMostOncePerResolve_evenAcrossRepeatedTaps() async {
        let refreshes = Counter()
        let resolver = TrackerItemLinkResolver(lookup: { _ in nil },
                                               refreshAll: { refreshes.bump(); return .succeeded })
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
            refreshAll: { XCTFail("no refresh on a hit"); return .succeeded })
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
