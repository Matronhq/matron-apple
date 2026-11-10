import XCTest
@testable import MatronViewModels
import MatronJournal
import MatronModels

private struct FakeBoxes: BoxesProviding {
    var agents: [DeviceDTO]
    var snapshot = RosterSnapshot()

    func devices() async throws -> [DeviceDTO] { agents }
    func roster() async throws -> RosterSnapshot { snapshot }
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        .failure(code: "agent_unreachable", detail: nil)
    }
    func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { $0.finish() } }
    func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { $0.finish() } }
}

@MainActor
final class BoxesViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func box(_ id: Int64, _ name: String, connected: Bool = true, percent: Int? = nil,
                     email: String? = nil, resetsIn days: Double = 3) -> DeviceDTO {
        let lines = percent.map {
            [LimitLine(id: "week_all", label: "Week (all models)", percent: $0,
                       resetsAt: now.addingTimeInterval(days * 86_400))]
        } ?? []
        let status = BoxStatus(reportedAt: now, capacity: BoxCapacity(
            liveSessions: 2, limitLines: lines, accountEmail: email))
        return DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0, lag: 0,
                         lastSeenAt: nil, isSelf: false, connected: connected, status: status)
    }

    private func model(_ agents: [DeviceDTO], snapshot: RosterSnapshot = RosterSnapshot()) async -> BoxesViewModel {
        let vm = BoxesViewModel(api: FakeBoxes(agents: agents, snapshot: snapshot),
                                capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        return vm
    }

    func test_rows_orderOnlineThenAsleepThenOffline_thenByName() async {
        let vm = await model(
            [box(1, "zed"), box(2, "amy", connected: false), box(3, "bob"), box(4, "cat", connected: false)],
            snapshot: RosterSnapshot(wakeableBoxes: [4]))
        XCTAssertEqual(vm.rows(now: now).map(\.device.name), ["bob", "zed", "cat", "amy"])
        XCTAssertEqual(vm.rows(now: now).map(\.state), [.online, .online, .asleep, .offline])
    }

    func test_clientDevicesAreNotBoxes() async {
        let phone = DeviceDTO(id: 9, kind: "client", name: "phone", createdAt: 0, cursor: 0, lag: 0,
                              lastSeenAt: nil, isSelf: true)
        let vm = await model([box(1, "a"), phone])
        XCTAssertEqual(vm.rows(now: now).map(\.device.name), ["a"])
    }

    func test_onlyTheBoxStillUpIsNearLimit() async {
        let vm = await model([box(1, "up", percent: 94), box(2, "down", connected: false, percent: 94)],
                             snapshot: RosterSnapshot(wakeableBoxes: [2]))
        let rows = vm.rows(now: now)
        XCTAssertEqual(rows.map(\.isNearLimit), [true, false])
    }

    func test_mostSpareMarksEveryBoxOnTheLogin() async {
        let vm = await model([
            box(1, "a", percent: 20, email: "shared@example.com"),
            box(2, "b", percent: 20, email: "shared@example.com"),
            box(3, "c", percent: 90, email: "other@example.com"),
        ])
        let rows = vm.rows(now: now)
        XCTAssertEqual(rows.map(\.isMostSpare), [true, true, false])
        XCTAssertEqual(vm.summary(of: rows, now: now).spareBoxNames, ["a", "b"])
    }

    func test_aSleepingBoxShowsNoLiveCountOrSessions() async {
        let session = RosterSession(id: "c1", title: "T", isRunning: true, lastActivity: now)
        let vm = await model([box(1, "a", connected: false)],
                             snapshot: RosterSnapshot(wakeableBoxes: [1], sessionsByBox: [1: [session]]))
        let row = vm.rows(now: now)[0]
        XCTAssertNil(row.liveCount)
        XCTAssertTrue(row.sessions.isEmpty)
        XCTAssertTrue(row.canStartSession)
    }

    func test_anOfflineBoxCannotStartASession() async {
        let vm = await model([box(1, "a", connected: false)], snapshot: RosterSnapshot())
        XCTAssertEqual(vm.rows(now: now)[0].state, .offline)
        XCTAssertFalse(vm.rows(now: now)[0].canStartSession)
    }

    func test_shownSessions_runningAlwaysThenWaitingUpToTheLiveCount() {
        func s(_ id: String, running: Bool, ago: TimeInterval) -> RosterSession {
            RosterSession(id: id, title: id, isRunning: running, lastActivity: now.addingTimeInterval(-ago))
        }
        let all = [s("old", running: false, ago: 90_000), s("run", running: true, ago: 500),
                   s("new", running: false, ago: 10), s("mid", running: false, ago: 600)]
        XCTAssertEqual(BoxesViewModel.shownSessions(all, liveCount: 3, isOnline: true, now: now).map(\.id),
                       ["run", "new", "mid"])
        XCTAssertEqual(BoxesViewModel.shownSessions(all, liveCount: 0, isOnline: true, now: now).map(\.id), ["run"])
        XCTAssertEqual(BoxesViewModel.shownSessions(all, liveCount: nil, isOnline: true, now: now).map(\.id),
                       ["run", "new", "mid"])
    }

    func test_countsText_leavesOutZeroes() {
        let summary = BoxesSummary(total: 3, online: 2, asleep: 1, offline: 0, spare: nil,
                                   spareBoxNames: [], nearLimitNames: [], lowestDisk: nil)
        XCTAssertEqual(summary.countsText, "3 boxes · 2 online · 1 asleep")
    }

    func test_namesText_truncates() {
        XCTAssertEqual(BoxesSummary.namesText(["a", "b"]), "a, b")
        XCTAssertEqual(BoxesSummary.namesText(["a", "b", "c", "d", "e"]), "a, b, c and 2 more")
    }
}
