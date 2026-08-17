import XCTest
@testable import MatronViewModels
@testable import MatronJournal
import MatronModels

/// The chooser's offline-capacity path: the host suspends idle boxes, so a
/// box that is asleep still has to show which account it runs and how much
/// quota it had — from a cache, visibly marked as last-known.
///
/// Shares `FakeAgentRPCProvider` / `Gate` with `NewChatViewModelTests`.
@MainActor
final class NewChatViewModelOfflineCapacityTests: XCTestCase {
    /// 2026-08-11 08:13 UTC — every capture time below is relative to this.
    private let now = Date(timeIntervalSince1970: 1_754_900_000)

    private func agent(_ id: Int64, name: String, connected: Bool) -> DeviceDTO {
        DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0,
                  lag: 0, lastSeenAt: nil, isSelf: false, connected: connected)
    }

    private func capacity(percent: Int, email: String? = "pat@yearbook.com") -> BoxCapacity {
        BoxCapacity(liveSessions: 2,
                    limitLines: [LimitLine(id: "session", label: "Current session",
                                           percent: percent, resetsAt: nil)],
                    accountEmail: email)
    }

    private func makeViewModel(_ fake: FakeAgentRPCProvider,
                               cache: InMemoryBoxCapacityCache) -> NewChatViewModel {
        NewChatViewModel(api: fake, capacityCache: cache, now: { [now] in now })
    }

    // MARK: Seeding offline rows

    func test_load_seedsOfflineBoxesFromTheCacheWithoutAskingThem() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "sleeping", connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let cached = capacity(percent: 39)
        let cache = InMemoryBoxCapacityCache([
            3: CachedBoxCapacity(capacity: cached, capturedAt: now.addingTimeInterval(-2 * 3600)),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacities[3], cached, "an offline box renders what it last reported")
        XCTAssertFalse(fake.requests.map(\.agentDeviceID).contains(3),
                       "a sleeping box is still never queried")
        XCTAssertFalse(vm.capacityPending.contains(3), "nothing is in flight for it to wait on")
    }

    func test_load_marksSeededRowsStaleAndRefreshedOnesLive() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "sleeping", connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":1}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let capturedAt = now.addingTimeInterval(-2 * 3600)
        let cache = InMemoryBoxCapacityCache([
            3: CachedBoxCapacity(capacity: capacity(percent: 39), capturedAt: capturedAt),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacityFreshness(for: 3), .offline(capturedAt: capturedAt))
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live,
                       "a box that answered this visit is not captioned as cached")
        XCTAssertEqual(vm.capacityFreshness(for: 99), .live,
                       "an unknown box has no cached numbers to disclaim")
    }

    /// The whole point of the feature: the host has suspended every box, so
    /// there is nobody to ask and the roster is the only screen the user
    /// gets. It still has to say which box is worth waking.
    func test_load_seedsEveryRowWhenTheWholeFleetIsAsleep() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: false),
                                       agent(2, name: "b", connected: false)])
        let cache = InMemoryBoxCapacityCache([
            1: CachedBoxCapacity(capacity: capacity(percent: 12),
                                 capturedAt: now.addingTimeInterval(-3600)),
            2: CachedBoxCapacity(capacity: capacity(percent: 93),
                                 capturedAt: now.addingTimeInterval(-3600)),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        guard case .agents(let list) = vm.phase else { return XCTFail("expected the roster") }
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 12)
        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 93)
        XCTAssertTrue(fake.requests.isEmpty, "there is nobody awake to ask")
    }

    func test_load_ignoresCacheEntriesTooOldToMeanAnything() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "long-gone", connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let cache = InMemoryBoxCapacityCache([
            3: CachedBoxCapacity(capacity: capacity(percent: 39),
                                 capturedAt: now.addingTimeInterval(-8 * 86_400)),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertNil(vm.capacities[3],
                     "a week-old percentage describes a quota window that has long since rolled over")
        XCTAssertEqual(vm.capacityFreshness(for: 3), .live, "and it carries no age caption either")
    }

    func test_load_prunesCachedBoxesThatLeftTheRoster() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "sleeping", connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let cache = InMemoryBoxCapacityCache([
            3: CachedBoxCapacity(capacity: capacity(percent: 39), capturedAt: now),
            99: CachedBoxCapacity(capacity: capacity(percent: 10), capturedAt: now),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(cache.pruneCalls.last, [1, 2, 3], "the roster decides which boxes still exist")
        XCTAssertNil(cache.loadAll()[99], "an unpaired box would otherwise sit in the cache forever")
    }

    // MARK: Recording

    func test_fanOut_persistsEveryCapacityItParses() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":2},"account":{"email":"pat@yearbook.com"},"limits":{"lines":[{"id":"session","label":"Current session","percent":39}]}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let cache = InMemoryBoxCapacityCache()

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(cache.loadAll()[1]?.capacity, vm.capacities[1])
        XCTAssertEqual(cache.loadAll()[1]?.capturedAt, now, "stamped with when the reply landed")
    }

    /// The single-connected-box fleet never fans out — it skips straight to
    /// the folder step — so this reply is the only chance to learn that box's
    /// capacity before it goes to sleep.
    func test_select_persistsCapacityFromTheLiveFolderReply() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, name: "only", connected: true),
                                       agent(2, name: "b", connected: false)])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[{"path":"/w","last_used":1}],"activity":{"live_sessions":3},"account":{"email":"pat@yearbook.com"}}"#.utf8))
        let cache = InMemoryBoxCapacityCache()

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()

        guard case .folders = vm.phase else { return XCTFail("expected the auto-skip to the folder step") }
        XCTAssertEqual(cache.loadAll()[9]?.capacity.liveSessions, 3)
        XCTAssertEqual(cache.loadAll()[9]?.capacity.accountEmail, "pat@yearbook.com")
        XCTAssertEqual(cache.loadAll()[9]?.capturedAt, now)
    }

    func test_fanOut_failedLegKeepsThePersistedEntryForWhenTheBoxSleeps() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true)])
        fake.repliesByDevice[1] = .failure(code: "agent_unreachable", detail: nil)
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let cache = InMemoryBoxCapacityCache([
            1: CachedBoxCapacity(capacity: capacity(percent: 39),
                                 capturedAt: now.addingTimeInterval(-3600)),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertNil(vm.capacities[1],
                     "a connected box that just failed to answer must not present old numbers as live")
        XCTAssertNotNil(cache.loadAll()[1],
                        "but the cache keeps them for the visit where that box is offline")
    }

    // MARK: Cache seeds are never laundered into live numbers

    func test_reload_dropsTheCacheSeedForABoxThatCameBackOnline() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: false),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "c", connected: true)])
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.repliesByDevice[3] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let cache = InMemoryBoxCapacityCache([
            1: CachedBoxCapacity(capacity: capacity(percent: 39),
                                 capturedAt: now.addingTimeInterval(-3600)),
        ])
        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertNotNil(vm.capacities[1], "seeded while it was asleep")

        // The box woke up. Its refresh is in flight; stale-while-revalidate
        // covers numbers this session fetched live, not a disk seed that has
        // never been confirmed against the running box.
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "c", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":7}}"#.utf8))
        let gate = Gate(), arrived = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrived
        await vm.backToAgents()
        await arrived.wait()

        XCTAssertNil(vm.capacities[1], "a cache seed is not a live reading to hold on to")
        XCTAssertTrue(vm.capacityPending.contains(1))
        gate.open()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[1]?.liveSessions, 7)
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live)
    }
}
