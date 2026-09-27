import XCTest
@testable import MatronViewModels
@testable import MatronJournal
import MatronModels

/// The chooser reads every box's usage from the journal (journal PR #82):
/// `GET /devices` carries each box's last `status` report and the socket
/// fans live `box_status` frames. The local capacity cache is only the
/// fallback for a box the journal has no report for.
///
/// Shares `FakeAgentRPCProvider` / `Gate` with `NewChatViewModelTests`.
@MainActor
final class NewChatViewModelBoxStatusTests: XCTestCase {
    /// 2026-08-11 08:13 UTC — every report time below is relative to this.
    private let now = Date(timeIntervalSince1970: 1_754_900_000)

    private func agent(_ id: Int64, connected: Bool, status: BoxStatus? = nil) -> DeviceDTO {
        DeviceDTO(id: id, kind: "agent", name: "box-\(id)", createdAt: 0, cursor: 0,
                  lag: 0, lastSeenAt: nil, isSelf: false, connected: connected, status: status)
    }

    private func capacity(percent: Int, sessions: Int? = 2) -> BoxCapacity {
        BoxCapacity(liveSessions: sessions,
                    limitLines: [LimitLine(id: "session", label: "Current session",
                                           percent: percent, resetsAt: nil)],
                    accountEmail: "pat@yearbook.com")
    }

    private func report(percent: Int, ago: TimeInterval) -> BoxStatus {
        BoxStatus(reportedAt: now.addingTimeInterval(-ago), capacity: capacity(percent: percent))
    }

    private func makeViewModel(_ fake: FakeAgentRPCProvider,
                               cache: InMemoryBoxCapacityCache? = nil) -> NewChatViewModel {
        NewChatViewModel(api: fake, capacityCache: cache ?? InMemoryBoxCapacityCache(), now: { [now] in now })
    }

    private let emptyFolders = RPCReply.ok(resultData: Data(#"{"folders":[]}"#.utf8))

    /// Waits for the view model to apply a frame the fake has just sent: the
    /// watcher hops through the stream on its own task.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    // MARK: Seeding from GET /devices

    func test_load_seedsAnOfflineBoxFromItsJournalReportAgedByReportedAt() async {
        let fake = FakeAgentRPCProvider()
        let reported = report(percent: 39, ago: 2 * 3600)
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false, status: reported)])
        fake.repliesByDevice[1] = emptyFolders

        let vm = makeViewModel(fake)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacities[2], reported.capacity,
                       "a sleeping box shows what it last told the journal, with no cache involved")
        XCTAssertEqual(vm.capacityFreshness(for: 2), .offline(capturedAt: reported.reportedAt),
                       "the caption reads when the box reported, not when this device last asked")
        XCTAssertFalse(fake.requests.map(\.agentDeviceID).contains(2), "a sleeping box is still never queried")
    }

    func test_load_prefersTheJournalReportOverTheLocalCache() async {
        let fake = FakeAgentRPCProvider()
        let reported = report(percent: 71, ago: 3 * 3600)
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false, status: reported)])
        fake.repliesByDevice[1] = emptyFolders
        // A newer local capture must not win: it is this device's memory of
        // one reply, while the journal holds the box's own latest word.
        let cache = InMemoryBoxCapacityCache([
            2: CachedBoxCapacity(capacity: capacity(percent: 5), capturedAt: now.addingTimeInterval(-60)),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 71)
    }

    func test_load_fallsBackToTheCacheForABoxTheJournalHasNoReportFor() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false)])
        fake.repliesByDevice[1] = emptyFolders
        let capturedAt = now.addingTimeInterval(-3600)
        let cache = InMemoryBoxCapacityCache([
            2: CachedBoxCapacity(capacity: capacity(percent: 12), capturedAt: capturedAt),
        ])

        let vm = makeViewModel(fake, cache: cache)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 12,
                       "an older journal, or a box that never reported, still shows last-known numbers")
        XCTAssertEqual(vm.capacityFreshness(for: 2), .offline(capturedAt: capturedAt))
    }

    /// The seven-day cut-off now measures the box's own report: a box that
    /// has not reported in a week describes quota windows long rolled over.
    func test_load_ignoresAReportOlderThanTheAgeLimit() async {
        let fake = FakeAgentRPCProvider()
        let limit = NewChatViewModel.maxCachedCapacityAge
        fake.devicesResult = .success([
            agent(1, connected: false, status: report(percent: 39, ago: limit + 60)),
            agent(2, connected: false, status: report(percent: 40, ago: limit)),
        ])

        let vm = makeViewModel(fake)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertNil(vm.capacities[1])
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live, "nothing shown, nothing to caption")
        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 40, "the boundary is inclusive")
    }

    /// A connected box's report is the box's own recent word, so its row
    /// fills in at once instead of reading "Checking…" until the fan-out
    /// answers — and the answer, when it lands, replaces it.
    func test_load_showsAConnectedBoxsReportWhileItsFanOutIsInFlight() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true, status: report(percent: 20, ago: 60)),
                                       agent(2, connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"""
        {"folders":[],"limits":{"lines":[{"id":"session","label":"Current session","percent":25}]}}
        """#.utf8))
        let gate = Gate(), arrival = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrival

        let vm = makeViewModel(fake)
        await vm.load()
        await arrival.wait()

        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 20)
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live,
                       "a connected box is not offline, and its answer is seconds away")
        XCTAssertTrue(vm.capacityPending.contains(1), "the fan-out is still asked, for folders and live numbers")

        gate.open()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 25)
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live)
    }

    /// A connected box that doesn't answer used to lose its row entirely.
    /// The journal still holds what the box last reported, so the row keeps
    /// it — de-emphasised and aged, because it is no longer vouched for.
    func test_fanOutFailure_fallsBackToTheJournalReportCaptionedWithItsAge() async {
        let fake = FakeAgentRPCProvider()
        let reported = report(percent: 20, ago: 600)
        fake.devicesResult = .success([agent(1, connected: true, status: reported),
                                       agent(2, connected: false)])
        fake.repliesByDevice[1] = .failure(code: "internal", detail: nil)

        let vm = makeViewModel(fake)
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacities[1], reported.capacity)
        XCTAssertEqual(vm.capacityFreshness(for: 1), .reported(at: reported.reportedAt))
    }

    // MARK: Live box_status frames

    func test_boxStatusFrame_updatesAnOfflineRowInPlace() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: report(percent: 39, ago: 3600))])
        fake.repliesByDevice[1] = emptyFolders
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        let fresh = report(percent: 44, ago: 5)
        fake.sendBoxStatus(2, fresh)
        await waitUntil { vm.capacities[2]?.limitLines.first?.percent == 44 }
        XCTAssertEqual(vm.capacityFreshness(for: 2), .offline(capturedAt: fresh.reportedAt))
    }

    func test_boxStatusFrame_forAConnectedBoxReadsLive() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false)])
        fake.repliesByDevice[1] = .failure(code: "internal", detail: nil)
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertNil(vm.capacities[1])

        fake.sendBoxStatus(1, report(percent: 61, ago: 1))
        await waitUntil { vm.capacities[1]?.limitLines.first?.percent == 61 }
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live, "the box is reporting right now")
    }

    /// Frames and the roster race: a report the socket delivered first must
    /// not be overwritten by an older one `GET /devices` answers with later.
    func test_anOlderReportNeverReplacesANewerOne() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: report(percent: 10, ago: 3600))])
        fake.repliesByDevice[1] = emptyFolders
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }

        fake.sendBoxStatus(2, report(percent: 90, ago: 30))
        await waitUntil { vm.hasReportForTesting(2) }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 90)

        // A late, older frame is dropped too; box 1's frame behind it marks
        // the point where the stale one has certainly been processed.
        fake.sendBoxStatus(2, report(percent: 5, ago: 7200))
        fake.sendBoxStatus(1, report(percent: 61, ago: 1))
        await waitUntil { vm.capacities[1]?.limitLines.first?.percent == 61 }
        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 90)
    }

    // MARK: Reload after the folder step

    /// A frame that lands while the folder step is showing is only held. Back
    /// on the roster, the previous visit's live numbers for that connected box
    /// survive the reload (stale-while-revalidate) — but they are older than
    /// the held report, so the report has to win the seed.
    func test_reload_seedsANewerHeldReportOverLastVisitsLiveNumbers() async {
        let clock = TestClock(now)
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"""
        {"folders":[],"limits":{"lines":[{"id":"session","label":"Current session","percent":25}]}}
        """#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(), now: { clock.now })
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 25)

        await vm.select(agent: agent(1, connected: true))
        clock.advance(60)
        fake.sendBoxStatus(1, BoxStatus(reportedAt: clock.now.addingTimeInterval(-5),
                                        capacity: capacity(percent: 90)))
        await waitUntil { vm.hasReportForTesting(1) }

        let gate = Gate(), arrival = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrival
        await vm.backToAgents()
        await arrival.wait()
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 90,
                       "the held report is newer than last visit's reply")
        gate.open()
        await vm.capacityFanOutForTesting?.value
    }

    /// The other way round: a reply newer than the journal's report keeps
    /// its row across the reload rather than stepping back to older numbers.
    func test_reload_keepsLastVisitsLiveNumbersWhenTheReportIsOlder() async {
        let clock = TestClock(now)
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true, status: report(percent: 10, ago: 600)),
                                       agent(2, connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"""
        {"folders":[],"limits":{"lines":[{"id":"session","label":"Current session","percent":25}]}}
        """#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(), now: { clock.now })
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        let gate = Gate(), arrival = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrival
        clock.advance(30)
        await vm.backToAgents()
        await arrival.wait()
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 25)
        gate.open()
        await vm.capacityFanOutForTesting?.value
    }
}

/// A clock a test can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}
