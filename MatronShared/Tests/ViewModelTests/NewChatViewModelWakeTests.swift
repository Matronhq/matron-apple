import XCTest
@testable import MatronViewModels
@testable import MatronJournal
import MatronModels

/// Records every wake-retry sleep the view model takes instead of actually
/// sleeping, so the loops run at test speed. `parkNext()` additionally
/// parks the next sleep on a gate, letting a test change the world while
/// the loop is provably mid-wait.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []
    private var _parkGate: Gate?
    /// Opened when a parked sleep is reached.
    let arrival = Gate()

    var delays: [Duration] { lock.withLock { _delays } }

    func parkNext() -> Gate {
        let gate = Gate()
        lock.withLock { _parkGate = gate }
        return gate
    }

    func sleep(_ duration: Duration) async {
        let gate = lock.withLock { () -> Gate? in
            _delays.append(duration)
            defer { _parkGate = nil }
            return _parkGate
        }
        if let gate {
            arrival.open()
            await gate.wait()
        }
    }
}

private func agent(_ id: Int64, name: String = "dev", connected: Bool) -> DeviceDTO {
    DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0,
              lag: 0, lastSeenAt: nil, isSelf: false, connected: connected)
}

private let unreachable: Result<RPCReply, RPCRequestError> =
    .success(.failure(code: "agent_unreachable", detail: nil))
private let folders = Result<RPCReply, RPCRequestError>.success(
    .ok(resultData: Data(#"{"folders":[{"path":"/home/dan/app","last_used":100}]}"#.utf8)))
private let started = Result<RPCReply, RPCRequestError>.success(
    .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8)))

/// The wake loops (spec: sleeping-VPS boxes, journal `wake.js`): a refused
/// `agent_request` to an offline box has already booted it server-side, so
/// the client's job is to keep re-asking until the bridge connects.
/// `agent_unreachable` is the ONLY retried failure — the server refuses it
/// before anything reaches the bridge, so a retry can never double-start.
@MainActor
final class NewChatViewModelWakeTests: XCTestCase {
    private func makeAsleepVM(fake: FakeAgentRPCProvider,
                              sleeper: SleepRecorder) async -> (NewChatViewModel, DeviceDTO) {
        let box = agent(7, name: "dev-7", connected: false)
        fake.devicesResult = .success([box])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  wakeSleep: { await sleeper.sleep($0) })
        await vm.load()
        guard case .agents = vm.phase else {
            XCTFail("an all-asleep fleet still shows the roster"); return (vm, box)
        }
        return (vm, box)
    }

    func test_selectAsleepBox_retriesUntilFoldersAnswer() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [unreachable, unreachable, folders]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/dan/app"])
        XCTAssertNil(vm.foldersError)
        XCTAssertFalse(vm.isWakingBox, "the waking banner comes down once the box answers")
        XCTAssertNil(vm.wakeStartedAt)
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, 3)
        XCTAssertEqual(sleeper.delays, [NewChatViewModel.wakeRetryDelay, NewChatViewModel.wakeRetryDelay])
    }

    func test_selectAsleepBox_givesUpAfterAttemptLimit() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count,
                       NewChatViewModel.wakeAttemptLimit)
        XCTAssertEqual(sleeper.delays.count, NewChatViewModel.wakeAttemptLimit - 1,
                       "no sleep after the last attempt")
        XCTAssertEqual(vm.errorMessage, "The box didn't wake — try again.")
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_retryWake_runsTheLoopAgain() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertNotNil(vm.errorMessage)
        fake.replySequences["recent_folders"] = [folders]
        await vm.retryWake()
        XCTAssertNil(vm.errorMessage, "a retry clears the gave-up banner")
        XCTAssertEqual(vm.folders.map(\.path), ["/home/dan/app"])
    }

    func test_selectAsleepBox_nonUnreachableFailureDegradesToFreeText() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replySequences["recent_folders"] = [.success(.failure(code: "internal", detail: "boom"))]
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        await vm.select(agent: box)
        XCTAssertNotNil(vm.foldersError, "an awake box that can't list folders degrades, not retries")
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, 1)
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
        XCTAssertEqual(vm.folders.map(\.path), ["/home/dan/app"])
        XCTAssertEqual(sleeper.delays.count, 1)
    }

    func test_backDuringWake_stopsTheLoopSilently() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let resume = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await sleeper.arrival.wait()
        await vm.backToAgents()
        resume.open()
        await selecting.value
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, 1,
                       "leaving the folder step ends the wake loop before its next ask")
        XCTAssertNil(vm.errorMessage, "an abandoned wake is not a failure")
        XCTAssertFalse(vm.isWakingBox)
    }

    func test_selectAsleepBox_secondTapWhileWakingIsIgnored() async {
        let fake = FakeAgentRPCProvider()
        let sleeper = SleepRecorder()
        fake.replies["recent_folders"] = .failure(code: "agent_unreachable", detail: nil)
        let (vm, box) = await makeAsleepVM(fake: fake, sleeper: sleeper)
        let resume = sleeper.parkNext()
        let selecting = Task { await vm.select(agent: box) }
        await sleeper.arrival.wait()
        await vm.select(agent: box) // impatient re-tap
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, 1,
                       "one wake loop per box — a re-tap must not double the RPC traffic")
        fake.replySequences["recent_folders"] = [folders]
        resume.open()
        await selecting.value
        XCTAssertEqual(vm.folders.map(\.path), ["/home/dan/app"])
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
}
