import XCTest
@testable import MatronViewModels
@testable import MatronJournal
import MatronModels

/// One parked sleep: `arrived` opens when the loop reaches it, `resume`
/// releases it — so a test can change the world while a wake loop is
/// provably mid-wait.
private final class Park: @unchecked Sendable {
    let resume = Gate()
    let arrived = Gate()
}

/// Records every wake-retry sleep the view model takes instead of actually
/// sleeping, so the loops run at test speed. `parkNext()` queues a park;
/// each sleep consumes at most one, in order.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []
    private var _pending: [Park] = []

    var delays: [Duration] { lock.withLock { _delays } }

    func parkNext() -> Park {
        let park = Park()
        lock.withLock { _pending.append(park) }
        return park
    }

    func sleep(_ duration: Duration) async {
        let park = lock.withLock { () -> Park? in
            _delays.append(duration)
            return _pending.isEmpty ? nil : _pending.removeFirst()
        }
        if let park {
            park.arrived.open()
            await park.resume.wait()
        }
    }
}

/// Deterministic clock that jumps forward on every read — lets a test walk
/// the wake loop's wall-clock deadline without waiting for it.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 0)
    private let step: TimeInterval
    init(step: TimeInterval) { self.step = step }
    func now() -> Date {
        lock.withLock {
            time.addTimeInterval(step)
            return time
        }
    }
}

/// Clock the test moves by hand — nothing advances between reads, so a
/// wake stamp can be compared against an exact expected instant.
private final class SettableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
}

private func agent(_ id: Int64, name: String = "dev", connected: Bool) -> DeviceDTO {
    DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0,
              lag: 0, lastSeenAt: nil, isSelf: false, connected: connected)
}

private let unreachable: Result<RPCReply, RPCRequestError> =
    .success(.failure(code: "agent_unreachable", detail: nil))
private let folders = Result<RPCReply, RPCRequestError>.success(
    .ok(resultData: Data(#"{"folders":[{"path":"/home/alice/app","last_used":100}]}"#.utf8)))
private let started = Result<RPCReply, RPCRequestError>.success(
    .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8)))

/// The wake loops (spec: sleeping-VPS boxes, journal `wake.js`): a refused
/// `agent_request` to an offline box has already booted it server-side, so
/// the client's job is to keep re-asking until the bridge connects.
/// `agent_unreachable` is the ONLY retried failure — the server refuses it
/// before anything reaches the bridge, so a retry can never double-start.
@MainActor
final class NewChatViewModelWakeTests: XCTestCase {
    /// Two-asleep-box fleet: big enough to show the roster (a single-box
    /// fleet auto-skips it, asleep or not — pinned separately below).
    private func makeAsleepVM(fake: FakeAgentRPCProvider,
                              sleeper: SleepRecorder,
                              clock: SettableClock? = nil) async -> (NewChatViewModel, DeviceDTO) {
        let box = agent(7, name: "box-7", connected: false)
        fake.devicesResult = .success([box, agent(8, name: "box-8", connected: false)])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  now: { clock?.now() ?? Date() },
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        guard case .agents = vm.phase else {
            XCTFail("an all-asleep fleet still shows the roster"); return (vm, box)
        }
        return (vm, box)
    }

    private func foldersRequests(_ fake: FakeAgentRPCProvider) -> Int {
        fake.requests.filter { $0.method == "recent_folders" }.count
    }

    func test_selectAsleepBox_retriesUntilFoldersAnswer() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [unreachable, unreachable, folders]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
        XCTAssertNil(vm.foldersError)
        XCTAssertFalse(vm.isWakingBox, "the waking banner comes down once the box answers")
        XCTAssertNil(vm.wakeStartedAt)
        XCTAssertFalse(vm.wakeGaveUp)
        XCTAssertEqual(foldersRequests(fake), 3)
        XCTAssertEqual(sleeper.delays, [NewChatViewModel.wakeRetryDelay, NewChatViewModel.wakeRetryDelay])
    }

    func test_selectAsleepBox_givesUpAfterAttemptLimit() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertEqual(foldersRequests(fake), NewChatViewModel.wakeAttemptLimit)
        XCTAssertEqual(sleeper.delays.count, NewChatViewModel.wakeAttemptLimit - 1,
                       "no sleep after the last attempt")
        XCTAssertEqual(vm.errorMessage, "The box didn't wake — try again.")
        XCTAssertTrue(vm.wakeGaveUp)
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_retryWake_runsTheLoopAgain() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertTrue(vm.wakeGaveUp)
        fake.replySequences["recent_folders"] = [folders]
        await vm.retryWake()
        XCTAssertNil(vm.errorMessage, "a retry clears the gave-up banner")
        XCTAssertFalse(vm.wakeGaveUp)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
    }

    func test_selectAsleepBox_nonUnreachableFailureDegradesToFreeText() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [.success(.failure(code: "internal", detail: "boom"))]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertNotNil(vm.foldersError, "an awake box that can't list folders degrades, not retries")
        XCTAssertEqual(foldersRequests(fake), 1)
        XCTAssertTrue(sleeper.delays.isEmpty)
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_selectAsleepBox_timeoutKeepsWaking() async {
        // Mid-boot the socket can be up while the bridge is still starting:
        // the RPC times out rather than being refused. That is a wake in
        // progress, not a dead end.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [.failure(.timeout), folders]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
        XCTAssertEqual(sleeper.delays.count, 1)
    }

    func test_wakeDeadline_boundsATimeoutStreak() async {
        // Attempts cost RPC + sleep, so 40 timeouts would otherwise run ~12
        // minutes of "Waking…" banner. The wall-clock deadline cuts in long
        // before the attempt limit.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        let clock = SteppingClock(step: 40)
        fake.rpcError = .timeout
        let box = agent(7, name: "box-7", connected: false)
        fake.devicesResult = .success([box, agent(8, name: "box-8", connected: false)])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  now: { clock.now() },
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        await vm.select(agent: box)
        XCTAssertLessThan(foldersRequests(fake), 10,
                          "the deadline, not the attempt count, bounds a timeout streak")
        XCTAssertGreaterThanOrEqual(foldersRequests(fake), 2)
        XCTAssertEqual(vm.errorMessage, "The box didn't wake — try again.")
        XCTAssertTrue(vm.wakeGaveUp)
    }

    func test_backDuringWake_stopsTheFolderLoopSilently_andTheRowKeepsWaking() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let folderPark = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await folderPark.arrived.wait()
        // The box is still booting, so going back hands it to a row wake:
        // park that loop's first wait to look at the roster mid-boot.
        let rowPark = sleeper.parkNext()
        let goingBack = Task { await vm.backToAgents() }
        await rowPark.arrived.wait()
        guard case .agents = vm.phase else { return XCTFail("back shows the roster") }
        XCTAssertFalse(vm.isWakingBox, "the folder step's banner is gone with the step")
        XCTAssertNil(vm.errorMessage, "an abandoned wake is not a failure")
        XCTAssertEqual(vm.rowWake(for: box), .waking, "the booting box does not go back to Asleep")
        let asked = foldersRequests(fake)
        folderPark.resume.open()
        await selecting.value
        XCTAssertEqual(foldersRequests(fake), asked,
                       "the retired folder loop asks nothing more once it wakes up")
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        rowPark.resume.open()
        await goingBack.value
        XCTAssertNil(vm.rowWake(for: rosterBox(vm, box.id)), "the row finishes awake")
    }

    private func rosterBox(_ vm: NewChatViewModel, _ id: Int64) -> DeviceDTO {
        guard case .agents(let agents) = vm.phase, let box = agents.first(where: { $0.id == id }) else {
            XCTFail("box \(id) is on the roster")
            return agent(id, connected: false)
        }
        return box
    }

    // MARK: Waking from the roster row

    func test_rowWake_retriesUntilTheBoxAnswers_thenReadsConnectedInPlace() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [unreachable, unreachable, folders]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        XCTAssertEqual(vm.rowWake(for: box), .asleep)
        let park = sleeper.parkNext()
        let waking = Task { await vm.wake(agent: box) }
        await park.arrived.wait()
        guard case .agents = vm.phase else { return XCTFail("waking a row stays on the roster") }
        XCTAssertEqual(vm.rowWake(for: box), .waking)
        XCTAssertFalse(vm.isWakingBox, "the folder step's banner is not the row's")
        park.resume.open()
        await waking.value
        XCTAssertEqual(foldersRequests(fake), 3)
        guard case .agents(let agents) = vm.phase else { return XCTFail("still the roster") }
        XCTAssertEqual(agents.map(\.id), [7, 8], "rows do not move when one wakes")
        XCTAssertTrue(agents[0].connected)
        XCTAssertNil(vm.rowWake(for: agents[0]), "an awake box offers no Wake")
        XCTAssertEqual(vm.rowWake(for: agents[1]), .asleep)
        XCTAssertEqual(vm.cachedFoldersForTesting(7)?.map(\.path), ["/home/alice/app"],
                       "the answer that proved it awake also fills its folder step")
    }

    func test_rowWake_severalBoxesAtOnce() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let other = agent(8, name: "box-8", connected: false)
        let firstPark = sleeper.parkNext()
        let secondPark = sleeper.parkNext()
        let first = Task { await vm.wake(agent: box) }
        let second = Task { await vm.wake(agent: other) }
        await firstPark.arrived.wait()
        await secondPark.arrived.wait()
        XCTAssertEqual(vm.wakingRows, [7, 8])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        firstPark.resume.open()
        secondPark.resume.open()
        await first.value
        await second.value
        XCTAssertTrue(vm.wakingRows.isEmpty)
        guard case .agents(let agents) = vm.phase else { return XCTFail("still the roster") }
        XCTAssertTrue(agents.allSatisfy(\.connected))
    }

    func test_rowWake_secondTapWhileWakingIsIgnored() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [unreachable, folders]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let park = sleeper.parkNext()
        let waking = Task { await vm.wake(agent: box) }
        await park.arrived.wait()
        await vm.wake(agent: box)
        XCTAssertEqual(foldersRequests(fake), 1, "a second tap must not stack a second loop")
        park.resume.open()
        await waking.value
        XCTAssertEqual(foldersRequests(fake), 2)
    }

    func test_rowWake_givesUpAfterAttemptLimit_andOffersWakeAgain() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.wake(agent: box)
        XCTAssertEqual(foldersRequests(fake), NewChatViewModel.wakeAttemptLimit)
        XCTAssertEqual(vm.rowWake(for: box), .failed)
        XCTAssertNil(vm.errorMessage, "one row's failure is the row's, not the sheet's")
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        await vm.wake(agent: box)
        XCTAssertNil(vm.rowWake(for: rosterBox(vm, box.id)))
    }

    func test_rowWake_keepsGoingWhileAnotherBoxIsOpen_andIsAwakeOnTheWayBack() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        fake.repliesByDevice[7] = .failure(code: "agent_unreachable", detail: nil)
        fake.repliesByDevice[8] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let park = sleeper.parkNext()
        let waking = Task { await vm.wake(agent: box) }
        await park.arrived.wait()
        await vm.select(agent: agent(8, name: "box-8", connected: false))
        XCTAssertFalse(vm.isWakingBox)
        XCTAssertTrue(vm.wakingRows.contains(7), "opening another box does not stop the row")
        fake.repliesByDevice[7] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        park.resume.open()
        await waking.value
        XCTAssertTrue(vm.canGoBackToAgents)
        await vm.backToAgents()
        guard case .agents = vm.phase else { return XCTFail("back shows the roster") }
        XCTAssertTrue(vm.wakingRows.isEmpty)
    }

    func test_rowWake_stopsWhenTheSheetGoesAway() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let park = sleeper.parkNext()
        let waking = Task { await vm.wake(agent: box) }
        await park.arrived.wait()
        vm.abandon()
        park.resume.open()
        await waking.value
        XCTAssertEqual(foldersRequests(fake), 1, "an abandoned sheet asks no box again")
        XCTAssertTrue(vm.wakingRows.isEmpty)
        XCTAssertTrue(vm.rowWakeFailed.isEmpty, "walking away is not a failed wake")
    }

    func test_back_isRefusedWhileAStartIsInFlight() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.replies["start"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        let park = sleeper.parkNext()
        let starting = Task { await vm.start(workdir: "/x") }
        await park.arrived.wait()
        await vm.backToAgents()
        guard case .folders = vm.phase else { return XCTFail("a start in flight holds the folder step") }
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        park.resume.open()
        await starting.value
        XCTAssertEqual(vm.phase, .done(convoID: "c-new"))
    }

    func test_back_thenOpeningABoxBeforeTheRefreshLands_staysOnThatBox() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        let read = fake.gateNextDevicesRead()
        let goingBack = Task { await vm.backToAgents() }
        await read.arrived.wait()
        guard case .agents = vm.phase else { return XCTFail("the roster is up before the refresh lands") }
        let other = agent(8, name: "box-8", connected: false)
        await vm.select(agent: other)
        read.gate.open()
        await goingBack.value
        XCTAssertEqual(vm.phase, .folders(agent: other),
                       "a late roster refresh must not pull the user off the box they opened")
    }

    func test_backFromABootingBox_thenOpeningAnother_keepsTheFirstWaking() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        fake.repliesByDevice[7] = .failure(code: "agent_unreachable", detail: nil)
        fake.repliesByDevice[8] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let folderPark = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await folderPark.arrived.wait()
        let read = fake.gateNextDevicesRead()
        let rowPark = sleeper.parkNext()
        let goingBack = Task { await vm.backToAgents() }
        await read.arrived.wait()
        let other = agent(8, name: "box-8", connected: false)
        await vm.select(agent: other)
        read.gate.open()
        await rowPark.arrived.wait()
        XCTAssertEqual(vm.phase, .folders(agent: other))
        XCTAssertTrue(vm.wakingRows.contains(7), "the booting box keeps waking behind the other's folder step")
        fake.repliesByDevice[7] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        folderPark.resume.open()
        rowPark.resume.open()
        await selecting.value
        await goingBack.value
        XCTAssertTrue(vm.wakingRows.isEmpty)
        XCTAssertTrue(vm.rowWakeFailed.isEmpty)
    }

    func test_rowWake_finishingDuringARosterRead_isNotPutBackToSleepByItsOlderSnapshot() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: agent(8, name: "box-8", connected: false))
        // The read is answered (both asleep) before the wake completes.
        let read = fake.gateNextDevicesRead()
        let goingBack = Task { await vm.backToAgents() }
        await read.arrived.wait()
        await vm.wake(agent: box)
        read.gate.open()
        await goingBack.value
        await vm.capacityFanOutForTesting?.value
        XCTAssertTrue(rosterBox(vm, box.id).connected)
        XCTAssertNil(vm.rowWake(for: rosterBox(vm, box.id)))
    }

    func test_rowWake_boxThatAnswersWithAFailure_isUp() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "not_ready", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.wake(agent: box)
        XCTAssertEqual(foldersRequests(fake), 1, "only agent_unreachable means still booting")
        XCTAssertTrue(rosterBox(vm, box.id).connected)
        if case .offline = vm.capacityFreshness(for: box.id) {
            XCTFail("a box that answered is not captioned as offline")
        }
    }

    func test_singleBoxFleet_hasNoRosterToGoBackTo() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(7, name: "box-7", connected: true)])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        guard case .folders = vm.phase else { return XCTFail("one box skips the roster") }
        XCTAssertFalse(vm.canGoBackToAgents)
    }

    func test_back_clearsTheFolderStepsError() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.replies["start"] = .failure(code: "bad_workdir", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        await vm.start(workdir: "/nope")
        XCTAssertNotNil(vm.errorMessage)
        await vm.backToAgents()
        XCTAssertNil(vm.errorMessage, "one box's start error must not head the boxes list")
    }

    func test_selectAsleepBox_secondTapWhileWakingIsIgnored() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let park = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await park.arrived.wait()
        await vm.select(agent: box) // impatient re-tap
        XCTAssertEqual(foldersRequests(fake), 1,
                       "one wake loop per box — a re-tap must not double the RPC traffic")
        fake.replySequences["recent_folders"] = [folders]
        park.resume.open()
        await selecting.value
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
    }

    func test_selectDifferentBoxWhileWaking_retiresTheOldLoopWithoutClobber() async {
        // The retired loop's teardown must not clear the flags the NEW
        // loop owns — that would drop the banner and reopen the dedup
        // guards mid-wake.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, boxA) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let boxB = agent(8, name: "box-8", connected: false)
        let parkA = sleeper.parkNext()
        let selectingA = Task { await vm.select(agent: boxA) }
        await parkA.arrived.wait()
        XCTAssertTrue(vm.isWakingBox)
        let parkB = sleeper.parkNext()
        let selectingB = Task { await vm.select(agent: boxB) }
        await parkB.arrived.wait()
        parkA.resume.open()
        await selectingA.value
        XCTAssertTrue(vm.isWakingBox, "the retired loop must not clear the new loop's banner")
        XCTAssertNotNil(vm.wakeStartedAt)
        fake.replySequences["recent_folders"] = [folders]
        parkB.resume.open()
        await selectingB.value
        guard case .folders(let current) = vm.phase, current.id == boxB.id else {
            return XCTFail("expected box-8's folder step")
        }
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
        XCTAssertFalse(vm.isWakingBox)
        XCTAssertEqual(foldersRequests(fake), 3, "loop A stopped asking after being superseded")
    }

    func test_startFailureDuringFolderWake_keepsTheBannerAndTheRealError() async {
        // Start Here is live while the folder wake loop runs. A start that
        // fails fast (the box just booted) must not tear down the live
        // loop's banner, and the loop's later writes must not overwrite the
        // start error the user needs to read.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let park = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await park.arrived.wait()
        XCTAssertTrue(vm.isWakingBox)
        XCTAssertNotNil(vm.wakeStartedAt)
        fake.replySequences["start"] = [.success(.failure(code: "bad_workdir", detail: "/nope"))]
        await vm.start(workdir: "/nope")
        XCTAssertEqual(vm.errorMessage, "That folder doesn't exist on the box.")
        XCTAssertTrue(vm.isWakingBox, "a fast-failing start must not tear down the live wake banner")
        XCTAssertNotNil(vm.wakeStartedAt)
        fake.replySequences["recent_folders"] = [folders]
        park.resume.open()
        await selecting.value
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
        XCTAssertFalse(vm.isWakingBox)
        XCTAssertEqual(vm.errorMessage, "That folder doesn't exist on the box.",
                       "the folder loop's outcome never overwrites the start error")
    }

    func test_load_singleAsleepBoxFleet_autoSkipsIntoTheWakeLoop() async {
        // One box, asleep: there is nothing to choose between, so the sheet
        // goes straight to the folder step and the wake loop starts — the
        // roster would be a dead stop.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.devicesResult = .success([agent(7, name: "box-7", connected: false)])
        fake.replySequences["recent_folders"] = [unreachable, folders]
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        guard case .folders(let picked) = vm.phase, picked.id == 7 else {
            return XCTFail("a single-box fleet auto-skips, asleep or not")
        }
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
        XCTAssertEqual(sleeper.delays.count, 1)
    }

    func test_connectedRowThatAnswersUnreachable_entersTheWakeLoop() async {
        // The roster's `connected` is a snapshot; a box idle-stopped since
        // then answers agent_unreachable — which has already fired its
        // wake, so it gets the wake loop, not the degrade copy.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        let stale = agent(9, name: "box-9", connected: true)
        fake.devicesResult = .success([stale, agent(8, name: "box-8", connected: false)])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        await vm.capacityFanOutForTesting?.value // let the roster fan-out settle first
        fake.replySequences["recent_folders"] = [unreachable, folders]
        await vm.select(agent: stale)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
        XCTAssertNil(vm.foldersError, "unreachable means waking, never the degrade copy")
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_abandon_stopsTheStartRetries() async {
        // Dismissing the sheet must stop the start loop: a retried start
        // that lands minutes later would silently open a session (and a
        // live Claude process) on a box nobody is looking at.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.replies["start"] = .failure(code: "agent_unreachable", detail: nil)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        let park = sleeper.parkNext()
        let starting = Task { await vm.start(workdir: "/x") }
        await park.arrived.wait()
        vm.abandon()
        park.resume.open()
        await starting.value
        XCTAssertEqual(fake.requests.filter { $0.method == "start" }.count, 1,
                       "no start re-asks after the sheet is gone")
        XCTAssertFalse(vm.isStarting)
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_start_retriesOnUnreachableUntilTheBridgeAnswers() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.replySequences["start"] = [unreachable, unreachable, started]
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        await vm.start(workdir: "/x")
        XCTAssertEqual(vm.phase, .done(convoID: "c-new"))
        XCTAssertEqual(fake.requests.filter { $0.method == "start" }.count, 3)
        XCTAssertEqual(sleeper.delays.count, 2)
        XCTAssertFalse(vm.isWakingBox)
        XCTAssertNil(vm.wakeStartedAt)
    }

    func test_start_timeoutIsNeverRetried() async {
        // A timeout is ambiguous — the start may have been delivered — and
        // `start` is non-idempotent, so retrying could open two sessions.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.replySequences["start"] = [.failure(.timeout), started]
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        await vm.start(workdir: "/x")
        XCTAssertEqual(vm.errorMessage, "The agent didn't answer — is the box awake?")
        XCTAssertEqual(fake.requests.filter { $0.method == "start" }.count, 1)
        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func test_start_givesUpAfterAttemptLimit() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.replies["start"] = .failure(code: "agent_unreachable", detail: nil)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        await vm.start(workdir: "/x")
        XCTAssertEqual(fake.requests.filter { $0.method == "start" }.count,
                       NewChatViewModel.wakeAttemptLimit)
        XCTAssertEqual(vm.errorMessage, "The agent didn't answer — is the box awake?")
        guard case .folders = vm.phase else { return XCTFail("a failed start stays on the folder step") }
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_folderWakeGivingUp_neverBuriesAStartError() async {
        // A start that fails fast for a real reason (bad_workdir) never
        // takes the wake token, so the folder loop keeps polling behind it
        // and later hits its ceiling. Its give-up copy is generic — burying
        // "That folder doesn't exist" under "The box didn't wake" would send
        // the user to retry a wake that was never the problem.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let park = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await park.arrived.wait()
        fake.replySequences["start"] = [.success(.failure(code: "bad_workdir", detail: "/nope"))]
        await vm.start(workdir: "/nope")
        XCTAssertEqual(vm.errorMessage, "That folder doesn't exist on the box.")
        park.resume.open()
        await selecting.value
        XCTAssertEqual(foldersRequests(fake), NewChatViewModel.wakeAttemptLimit,
                       "the folder loop really did run all the way to its give-up tail")
        XCTAssertEqual(vm.errorMessage, "That folder doesn't exist on the box.",
                       "the give-up copy must not overwrite the start error already on screen")
        XCTAssertTrue(vm.wakeGaveUp,
                      "the box never answered recent_folders, so the flag still flips: it keeps "
                      + "the folder list's empty state suppressed and offers the Try Again it earned")
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_selectFastBoxWhileAnotherWakes_dropsTheWakingBannerNow() async {
        // A superseded wake loop only notices at its next suspension point,
        // up to a full retry delay away. Switching to a box that answers
        // instantly must retire the old owner itself, or its "Waking…"
        // banner hangs over the new box's folder step until then.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let boxA = agent(7, name: "box-7", connected: false)
        let boxB = agent(8, name: "box-8", connected: true)
        fake.devicesResult = .success([boxA, boxB])
        fake.repliesByDevice[boxB.id] = .ok(
            resultData: Data(#"{"folders":[{"path":"/home/alice/app","last_used":100}]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        let parkA = sleeper.parkNext()
        let selectingA = Task { await vm.select(agent: boxA) }
        await parkA.arrived.wait()
        XCTAssertTrue(vm.isWakingBox)

        await vm.select(agent: boxB)
        XCTAssertFalse(vm.isWakingBox,
                       "box B answered — box A's parked loop must not keep the banner up")
        XCTAssertNil(vm.wakeStartedAt)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])

        parkA.resume.open()
        await selectingA.value
        XCTAssertFalse(vm.isWakingBox, "the retired loop exits without redressing the step")
        XCTAssertEqual(vm.folders.map(\.path), ["/home/alice/app"])
    }

    func test_selectDifferentBoxWhileWaking_restartsTheWakeClock() async {
        // "Waking… 45s" is per box. Switching boxes mid-wake must stamp the
        // new loop now, or the new box inherits the old one's elapsed time
        // and reads as having been booting far longer than it has.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        let clock = SettableClock()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let boxA = agent(7, name: "box-7", connected: false)
        let boxB = agent(8, name: "box-8", connected: false)
        fake.devicesResult = .success([boxA, boxB])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  now: { clock.now() },
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        let parkA = sleeper.parkNext()
        let selectingA = Task { await vm.select(agent: boxA) }
        await parkA.arrived.wait()
        guard let stampedA = vm.wakeStartedAt else { return XCTFail("box A's wake is clocked") }
        clock.advance(45)
        let parkB = sleeper.parkNext()
        let selectingB = Task { await vm.select(agent: boxB) }
        await parkB.arrived.wait()
        XCTAssertEqual(vm.wakeStartedAt, stampedA.addingTimeInterval(45),
                       "a different box's Waking… clock starts now, not from box A's stamp")
        parkA.resume.open()
        await selectingA.value
        XCTAssertEqual(vm.wakeStartedAt, stampedA.addingTimeInterval(45),
                       "the retired loop must not restore its own stamp on the way out")
        fake.replySequences["recent_folders"] = [folders]
        parkB.resume.open()
        await selectingB.value
        XCTAssertFalse(vm.isWakingBox)
        XCTAssertNil(vm.wakeStartedAt)
    }

    func test_startRetryOnTheSameBox_keepsTheWakeClockRunning() async {
        // The other half of the ownership rule: a start that supersedes the
        // folder wake loop on the SAME box is the same boot from the user's
        // side, so the banner clock carries on rather than snapping to zero.
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        let clock = SettableClock()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        fake.replies["start"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper, clock: clock)
        let folderPark = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await folderPark.arrived.wait()
        guard let stamped = vm.wakeStartedAt else { return XCTFail("the folder wake is clocked") }
        clock.advance(30)
        let startPark = sleeper.parkNext()
        let starting = Task { await vm.start(workdir: "/x") }
        await startPark.arrived.wait()
        XCTAssertEqual(vm.wakeStartedAt, stamped,
                       "the same box's boot keeps one clock across the folder→start handover")
        folderPark.resume.open()
        await selecting.value
        XCTAssertEqual(vm.wakeStartedAt, stamped, "the retired folder loop leaves the start's clock alone")
        startPark.resume.open()
        await starting.value
        XCTAssertFalse(vm.isWakingBox)
        XCTAssertNil(vm.wakeStartedAt)
    }
}
