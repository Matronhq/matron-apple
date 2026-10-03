import XCTest
@testable import MatronViewModels
@testable import MatronJournal
import MatronModels

/// A box that reports while this client's socket is down is stored by the
/// journal but never fanned here, and `box_status` is not a conversation
/// event, so the reconnect replay does not carry it either. The chooser
/// therefore re-reads the stored reports from `GET /devices` each time the
/// socket comes back up while its watcher runs.
///
/// Shares `FakeAgentRPCProvider` with `NewChatViewModelTests`.
@MainActor
final class NewChatViewModelReconnectTests: XCTestCase {
    /// 2026-08-11 08:13 UTC — every report time below is relative to this.
    private let now = Date(timeIntervalSince1970: 1_754_900_000)

    private func agent(_ id: Int64, connected: Bool, status: BoxStatus? = nil,
                       kind: String = "agent") -> DeviceDTO {
        DeviceDTO(id: id, kind: kind, name: "box-\(id)", createdAt: 0, cursor: 0,
                  lag: 0, lastSeenAt: nil, isSelf: false, connected: connected, status: status)
    }

    private func capacity(percent: Int) -> BoxCapacity {
        BoxCapacity(liveSessions: 2,
                    limitLines: [LimitLine(id: "session", label: "Current session",
                                           percent: percent, resetsAt: nil)],
                    accountEmail: "pat@yearbook.com")
    }

    private func report(percent: Int, ago: TimeInterval) -> BoxStatus {
        BoxStatus(reportedAt: now.addingTimeInterval(-ago), capacity: capacity(percent: percent))
    }

    private func makeViewModel(_ fake: FakeAgentRPCProvider) -> NewChatViewModel {
        NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(), now: { [now] in now })
    }

    private let emptyFolders = RPCReply.ok(resultData: Data(#"{"folders":[]}"#.utf8))

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    /// The socket drops and comes back, as the engine reports it.
    private func reconnect(_ fake: FakeAgentRPCProvider) {
        fake.sendConnectionState(.connecting)
        fake.sendConnectionState(.catchingUp)
        fake.sendConnectionState(.running)
    }

    func test_reconnect_reseedsAnOfflineRowFromTheStoredReport() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: report(percent: 39, ago: 3600))])
        fake.repliesByDevice[1] = emptyFolders
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 39)

        // Box 2 reported while the socket was down: only the roster has it.
        let missed = report(percent: 44, ago: 5)
        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: missed)])
        reconnect(fake)

        await waitUntil { vm.capacities[2]?.limitLines.first?.percent == 44 }
        XCTAssertEqual(vm.capacityFreshness(for: 2), .offline(capturedAt: missed.reportedAt),
                       "an offline box's row stays captioned, now dated by the newer report")
    }

    /// The state in place when the watcher subscribes is the baseline, not a
    /// reconnect: a sheet opened on a running socket has just read the roster.
    /// One drop-and-return is one read, however many states it passes through.
    func test_reconnect_readsTheRosterOncePerReturnToRunning_andNotOnSubscribe() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false)])
        fake.repliesByDevice[1] = emptyFolders
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(fake.devicesCallCount, 1)

        reconnect(fake)
        await waitUntil { fake.devicesCallCount == 2 }
        // A repeated `.running` is not a transition.
        fake.sendConnectionState(.running)
        reconnect(fake)
        await waitUntil { fake.devicesCallCount == 3 }
        // Box 2's frame behind the last state marks the point where every
        // earlier state has certainly been processed.
        fake.sendBoxStatus(2, report(percent: 61, ago: 1))
        await waitUntil { vm.capacities[2]?.limitLines.first?.percent == 61 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.devicesCallCount, 3)
    }

    /// A sheet opened while the socket is down does re-seed once it
    /// connects: reports made between the roster read and the connection
    /// are not replayed either.
    func test_aSheetOpenedWhileTheSocketIsDown_reseedsWhenItConnects() async {
        let fake = FakeAgentRPCProvider()
        fake.initialConnectionState = .connecting
        fake.devicesResult = .success([agent(1, connected: false, status: report(percent: 10, ago: 3600)),
                                       agent(2, connected: false)])
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        fake.devicesResult = .success([agent(1, connected: false, status: report(percent: 55, ago: 2)),
                                       agent(2, connected: false)])
        fake.sendConnectionState(.running)

        await waitUntil { vm.capacities[1]?.limitLines.first?.percent == 55 }
    }

    /// The re-seed follows the rules a live frame follows: a connected box
    /// whose row shows live numbers read after the stored report was made is
    /// not repainted with the older word.
    func test_reconnect_doesNotRepaintAConnectedBoxShowingNewerLiveNumbers() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false),
                                       agent(3, connected: false)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"""
        {"folders":[],"limits":{"lines":[{"id":"session","label":"Current session","percent":25}]}}
        """#.utf8))
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 25)

        // Box 1's stored report predates its fan-out reply; box 3's is new
        // and marks the point where the re-seed has been applied.
        fake.devicesResult = .success([agent(1, connected: true, status: report(percent: 90, ago: 600)),
                                       agent(2, connected: false),
                                       agent(3, connected: false, status: report(percent: 61, ago: 1))])
        reconnect(fake)

        await waitUntil { vm.capacities[3]?.limitLines.first?.percent == 61 }
        XCTAssertEqual(vm.capacities[1]?.limitLines.first?.percent, 25,
                       "the fan-out reply is the newer word")
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live)
        XCTAssertTrue(vm.hasReportForTesting(1), "the older report is still held for the next seed")
    }

    func test_reconnect_repaintsAConnectedBoxWhoseStoredReportIsNewer_asLive() async {
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

        clock.advance(120)
        fake.devicesResult = .success([
            agent(1, connected: true, status: BoxStatus(reportedAt: clock.now.addingTimeInterval(-5),
                                                        capacity: capacity(percent: 90))),
            agent(2, connected: false),
        ])
        reconnect(fake)

        await waitUntil { vm.capacities[1]?.limitLines.first?.percent == 90 }
        XCTAssertEqual(vm.capacityFreshness(for: 1), .live)
    }

    /// Best effort: a failed read leaves the rows as they were and the
    /// watcher running, so the next frame and the next reconnect still apply.
    func test_aFailedReseed_isSwallowed_andTheWatcherGoesOn() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: report(percent: 39, ago: 3600))])
        fake.repliesByDevice[1] = emptyFolders
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        fake.devicesResult = .failure(.rateLimited)
        reconnect(fake)
        await waitUntil { fake.devicesCallCount == 2 }
        XCTAssertEqual(vm.capacities[2]?.limitLines.first?.percent, 39)
        XCTAssertNil(vm.errorMessage, "a background refresh never raises the sheet's error")
        guard case .agents = vm.phase else { return XCTFail("the roster stays up") }

        fake.sendBoxStatus(2, report(percent: 44, ago: 30))
        await waitUntil { vm.capacities[2]?.limitLines.first?.percent == 44 }

        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: report(percent: 50, ago: 5))])
        reconnect(fake)
        await waitUntil { vm.capacities[2]?.limitLines.first?.percent == 50 }
    }

    /// Off the roster the stored reports are only held, as a frame is; the
    /// next `load()` seeds from them. Devices that are not boxes are skipped.
    func test_reconnect_onTheFolderStep_onlyHoldsTheReports() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, connected: true), agent(2, connected: false)])
        fake.repliesByDevice[1] = emptyFolders
        let vm = makeViewModel(fake)
        let watcher = Task { await vm.watchBoxStatus() }
        defer { watcher.cancel() }
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        await vm.select(agent: agent(1, connected: true))
        XCTAssertFalse(vm.hasReportForTesting(2))

        fake.devicesResult = .success([agent(1, connected: true),
                                       agent(2, connected: false, status: report(percent: 70, ago: 5)),
                                       agent(9, connected: true, status: report(percent: 1, ago: 5), kind: "client")])
        reconnect(fake)

        await waitUntil { vm.hasReportForTesting(2) }
        XCTAssertFalse(vm.hasReportForTesting(9))
        guard case .folders = vm.phase else { return XCTFail("the folder step stays up") }
        XCTAssertNil(vm.capacities[2])
    }
}
