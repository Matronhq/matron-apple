import XCTest
@testable import MatronViewModels
@testable import MatronJournal
import MatronModels

/// One-shot async gate: `wait()` suspends until somebody calls `open()`,
/// and stays open afterwards. Lets a test park one RPC leg mid-flight and
/// decide exactly when it answers.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Recording fake for the New-Chat RPC surface. Replies are scripted per
/// method; `agentRequest` throws when `rpcError` is set.
///
/// Every state access is lock-guarded because the roster fan-out calls
/// `agentRequest` from several task-group children at once, off the main
/// actor: an unsynchronised `requests.append` silently loses entries (it
/// made `test_load_fansOutToConnectedAgentsOnly` fail roughly two runs in
/// five, and TSan reports the access race).
final class FakeAgentRPCProvider: AgentRPCProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _devicesResult: Result<[DeviceDTO], JournalAPIError> = .success([])
    private var _replies: [String: RPCReply] = [:]
    private var _repliesByDevice: [Int64: RPCReply] = [:]
    private var _rpcError: RPCRequestError?
    private var _replySequences: [String: [Result<RPCReply, RPCRequestError>]] = [:]
    private var _gates: [Int64: Gate] = [:]
    private var _arrivals: [Int64: Gate] = [:]
    private var _requests: [(method: String, agentDeviceID: Int64, params: [String: Any])] = []

    var devicesResult: Result<[DeviceDTO], JournalAPIError> {
        get { lock.withLock { _devicesResult } }
        set { lock.withLock { _devicesResult = newValue } }
    }
    /// Keyed by method.
    var replies: [String: RPCReply] {
        get { lock.withLock { _replies } }
        set { lock.withLock { _replies = newValue } }
    }
    /// `recent_folders` replies scripted per device, for the roster fan-out
    /// (takes precedence over `replies`).
    var repliesByDevice: [Int64: RPCReply] {
        get { lock.withLock { _repliesByDevice } }
        set { lock.withLock { _repliesByDevice = newValue } }
    }
    var rpcError: RPCRequestError? {
        get { lock.withLock { _rpcError } }
        set { lock.withLock { _rpcError = newValue } }
    }
    /// Per-method scripted outcomes, consumed one per call ahead of every
    /// other source — lets a test answer `agent_unreachable` twice and then
    /// `.ok`, which is the shape the wake-retry loops exist for. An
    /// exhausted sequence falls through to the usual lookup order.
    var replySequences: [String: [Result<RPCReply, RPCRequestError>]] {
        get { lock.withLock { _replySequences } }
        set { lock.withLock { _replySequences = newValue } }
    }
    /// Parks the *next* `recent_folders` call for a device until the gate is
    /// opened; the reply is captured before parking, so re-scripting
    /// `repliesByDevice` meanwhile doesn't change what the parked leg
    /// eventually answers.
    var gates: [Int64: Gate] {
        get { lock.withLock { _gates } }
        set { lock.withLock { _gates = newValue } }
    }
    /// Opened when a gated call arrives, so a test can wait for the leg to
    /// actually be in flight instead of guessing at scheduling.
    var arrivals: [Int64: Gate] {
        get { lock.withLock { _arrivals } }
        set { lock.withLock { _arrivals = newValue } }
    }
    var requests: [(method: String, agentDeviceID: Int64, params: [String: Any])] {
        lock.withLock { _requests }
    }

    func devices() async throws -> [DeviceDTO] { try devicesResult.get() }

    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        let (error, scripted) = lock.withLock { () -> (RPCRequestError?, Result<RPCReply, RPCRequestError>?) in
            _requests.append((method, agentDeviceID, params))
            if var sequence = _replySequences[method], !sequence.isEmpty {
                let next = sequence.removeFirst()
                _replySequences[method] = sequence
                return (nil, next)
            }
            return (_rpcError, nil)
        }
        if let scripted { return try scripted.get() }
        if let error { throw error }
        let (reply, gate, arrival) = lock.withLock { () -> (RPCReply, Gate?, Gate?) in
            let reply = (method == "recent_folders" ? _repliesByDevice[agentDeviceID] : nil)
                ?? _replies[method]
                ?? .failure(code: "unknown_method", detail: nil)
            guard method == "recent_folders",
                  let gate = _gates.removeValue(forKey: agentDeviceID) else { return (reply, nil, nil) }
            return (reply, gate, _arrivals[agentDeviceID])
        }
        // Never hold the lock across the suspension — the test opens the
        // gate from the main actor and would deadlock against it.
        if let gate {
            arrival?.open()
            await gate.wait()
        }
        return reply
    }
}

private func agent(_ id: Int64, name: String = "dev", connected: Bool) -> DeviceDTO {
    DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0,
              lag: 0, lastSeenAt: nil, isSelf: false, connected: connected)
}

@MainActor
final class NewChatViewModelTests: XCTestCase {
    private func foldersReply(_ json: String) -> RPCReply {
        .ok(resultData: Data(json.utf8))
    }

    func test_load_showsAgentsOnly_connectedFirst() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([
            DeviceDTO(id: 1, kind: "client", name: "dan-mac", createdAt: 0, cursor: 0,
                      lag: 0, lastSeenAt: nil, isSelf: true, connected: true),
            agent(2, name: "dev-7", connected: false),
            agent(3, name: "dev-2", connected: true),
            agent(4, name: "dev-9", connected: true),
        ])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        guard case let .agents(list) = vm.phase else { return XCTFail("expected agents phase") }
        XCTAssertEqual(list.map(\.id), [3, 4, 2], "clients excluded; connected first, then by name")
    }

    func test_load_singleBoxFleet_skipsStraightToFolders() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[{"path":"/home/dan/app","last_used":100}]}"#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        guard case let .folders(picked) = vm.phase else { return XCTFail("expected folders phase") }
        XCTAssertEqual(picked.id, 9)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/dan/app"])
    }

    func test_load_oneConnectedAmongAsleep_showsTheRoster() async {
        // The host idle-stops boxes, so one-awake-among-asleep is the
        // normal steady state — auto-skipping to the awake box would make
        // every sleeping (but wakeable) row unreachable.
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true), agent(2, connected: false)])
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        guard case let .agents(list) = vm.phase else { return XCTFail("expected the roster") }
        XCTAssertEqual(list.map(\.id), [9, 2])
    }

    func test_folders_sortNewestFirst_nullsLast() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[
          {"path":"/never","last_used":null},
          {"path":"/old","last_used":100},
          {"path":"/new","last_used":900}
        ]}
        """#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        XCTAssertEqual(vm.folders.map(\.path), ["/new", "/old", "/never"])
        XCTAssertNil(vm.folders.last?.lastUsed, "never-used folder carries nil lastUsed")
    }

    func test_foldersFailure_degradesPickerButKeepsFreeText() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.rpcError = .timeout
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        guard case .folders = vm.phase else { return XCTFail("expected folders phase despite RPC failure") }
        XCTAssertNotNil(vm.foldersError)
        XCTAssertTrue(vm.folders.isEmpty)
    }

    func test_start_sendsWorkdirAndBrowser_navigatesOnConvoID() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        vm.browserEnabled = true
        await vm.start(workdir: "~/dev/app")
        XCTAssertEqual(vm.phase, .done(convoID: "c-new"))
        let start = fake.requests.last
        XCTAssertEqual(start?.method, "start")
        XCTAssertEqual(start?.params["workdir"] as? String, "~/dev/app")
        XCTAssertEqual(start?.params["browser"] as? Bool, true)
    }

    func test_start_omitsEmptyWorkdirAndFalseBrowser() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.start(workdir: "  ")
        let params = fake.requests.last?.params
        XCTAssertNil(params?["workdir"], "blank workdir means the bridge default — omit the key")
        XCTAssertNil(params?["browser"], "browser only travels when true")
    }

    // MARK: Model picker

    func test_start_sendsSelectedModel() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[],"model_options":[{"value":"opus","label":"Opus"},{"value":"sonnet","label":"Sonnet"}]}
        """#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        vm.selectedModel = "sonnet"
        await vm.start(workdir: "~/dev/app")
        XCTAssertEqual(fake.requests.last?.params["model"] as? String, "sonnet")
    }

    func test_start_omitsModelWhenDefaultPicked() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[],"model_options":[{"value":"opus","label":"Opus"}]}
        """#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        XCTAssertNil(vm.selectedModel, "the picker opens on the bridge's own default")
        await vm.start(workdir: "~/dev/app")
        XCTAssertNil(fake.requests.last?.params["model"],
                     "no pick means the bridge decides — omit the key rather than name a default")
    }

    func test_modelOptions_parsedFromRecentFolders() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[],"model_options":[
          {"value":"default","label":"Default"},
          {"value":"opus","label":"Opus 4.6"},
          {"value":"sonnet"},
          {"value":"opus","label":"Opus again"},
          {"label":"nameless"},
          {"value":""}
        ]}
        """#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        XCTAssertEqual(vm.modelOptions, [ModelOption(value: "opus", label: "Opus 4.6"),
                                         ModelOption(value: "sonnet", label: "sonnet")],
                       "bridge order kept; a missing label falls back to the value; "
                       + "an entry with nothing to send is dropped; a repeated value "
                       + "keeps its first row (value is the ForEach identity); and the "
                       + "bridge's `default` alias folds into the picker's own nil row")
    }

    func test_modelOptions_absentKeyLeavesNoOffer() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[{"path":"/a","last_used":1}]}"#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        XCTAssertTrue(vm.modelOptions.isEmpty, "an older bridge omits the key — the picker hides")
        XCTAssertEqual(vm.folders.map(\.path), ["/a"], "and the rest of the reply still parses")
    }

    /// The roster fan-out already asked every connected box, so the folder
    /// step must render that box's offer without a second round-trip — the
    /// same prefetch that serves `folders` from cache.
    func test_modelOptions_arriveFromTheRosterPrefetch() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(
            #"{"folders":[],"model_options":[{"value":"opus","label":"Opus"}]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        let before = fake.requests.filter { $0.method == "recent_folders" }.count

        await vm.select(agent: agent(1, name: "a", connected: true))
        XCTAssertEqual(vm.modelOptions.map(\.value), ["opus"])
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, before,
                       "served from the prefetch, not re-asked")
    }

    func test_switchingBoxes_dropsAModelTheNewBoxDoesNotOffer() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(
            #"{"folders":[],"model_options":[{"value":"opus","label":"Opus"},{"value":"sonnet","label":"Sonnet"}]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(
            #"{"folders":[],"model_options":[{"value":"sonnet","label":"Sonnet"}]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        await vm.select(agent: agent(1, name: "a", connected: true))
        vm.selectedModel = "sonnet"
        await vm.select(agent: agent(2, name: "b", connected: true))
        XCTAssertEqual(vm.selectedModel, "sonnet", "a model the new box also offers survives")

        await vm.select(agent: agent(1, name: "a", connected: true))
        vm.selectedModel = "opus"
        await vm.select(agent: agent(2, name: "b", connected: true))
        XCTAssertNil(vm.selectedModel,
                     "box b can't run opus — carrying the pick over would earn a bad_model")
    }

    // MARK: Default model

    func test_defaultModel_titlesTheDefaultRowAndStillOmitsTheKey() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[],"default_model":"fable","model_options":[{"value":"opus","label":"Opus"},{"value":"fable","label":"Fable"}]}
        """#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        XCTAssertEqual(vm.defaultModelLabel, "Fable", "the offered option's label, not the raw alias")
        XCTAssertEqual(vm.defaultRowTitle, "Default (Fable)")
        XCTAssertNil(vm.selectedModel, "naming the default is not picking it")
        await vm.start(workdir: "~/dev/app")
        XCTAssertNil(fake.requests.last?.params["model"],
                     "the bridge applies its own default — the key stays omitted")
    }

    func test_defaultModel_absentOrEmptyReadsPlainDefault() async {
        for reply in [#"{"folders":[],"model_options":[{"value":"opus","label":"Opus"}]}"#,
                      #"{"folders":[],"default_model":"","model_options":[{"value":"opus","label":"Opus"}]}"#] {
            let fake = FakeAgentRPCProvider()
            fake.devicesResult = .success([agent(9, connected: true)])
            fake.replies["recent_folders"] = foldersReply(reply)
            let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
            await vm.load()
            XCTAssertNil(vm.defaultModelLabel)
            XCTAssertEqual(vm.defaultRowTitle, "Default", "an older bridge, or one with no box default")
        }
    }

    func test_defaultModel_unlistedValueShowsTheRawName() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"""
        {"folders":[],"default_model":"claude-opus-5","model_options":[{"value":"opus","label":"Opus"}]}
        """#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        XCTAssertEqual(vm.defaultRowTitle, "Default (claude-opus-5)",
                       "a full model name is not in the alias offer — show it as sent")
    }

    /// Same prefetch contract as `model_options`: the folder step renders
    /// the box's default off the roster fan-out, and switching boxes swaps
    /// it for the new box's (or drops it for a box that doesn't say).
    func test_defaultModel_followsTheBoxAcrossTheRosterPrefetch() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(
            #"{"folders":[],"default_model":"fable","model_options":[{"value":"fable","label":"Fable"}]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(
            #"{"folders":[],"model_options":[{"value":"sonnet","label":"Sonnet"}]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        let before = fake.requests.filter { $0.method == "recent_folders" }.count

        await vm.select(agent: agent(1, name: "a", connected: true))
        XCTAssertEqual(vm.defaultRowTitle, "Default (Fable)")
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, before,
                       "served from the prefetch, not re-asked")
        await vm.select(agent: agent(2, name: "b", connected: true))
        XCTAssertEqual(vm.defaultRowTitle, "Default", "box b never said — no stale label carried over")
    }

    func test_start_errorCopyTable() async {
        // `agent_unreachable` is absent on purpose: start retries it (the
        // wake loop) — NewChatViewModelWakeTests owns that behaviour.
        let cases: [(RPCReply, String)] = [
            (.failure(code: "not_ready", detail: nil), "The agent didn't answer — is the box awake?"),
            (.failure(code: "bad_workdir", detail: "/nope"), "That folder doesn't exist on the box."),
            (.failure(code: "bad_model", detail: "opus"), "That box doesn't offer that model — pick another."),
            (.failure(code: "spawn_failed", detail: "boom"), "Couldn't start — boom."),
            (.failure(code: "unsupported_mode", detail: nil), "Couldn't start — unsupported_mode."),
        ]
        for (reply, expected) in cases {
            let fake = FakeAgentRPCProvider()
            fake.devicesResult = .success([agent(9, connected: true)])
            fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
            fake.replies["start"] = reply
            let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
            await vm.load()
            await vm.start(workdir: "/x")
            XCTAssertEqual(vm.errorMessage, expected)
            guard case .folders = vm.phase else { return XCTFail("failed start stays on the folder step") }
        }
    }

    func test_start_timeoutUsesUnreachableCopy() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        fake.rpcError = .timeout
        await vm.start(workdir: "/x")
        XCTAssertEqual(vm.errorMessage, "The agent didn't answer — is the box awake?")
    }

    func test_start_missingConvoID_surfacesError() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        fake.replies["start"] = .ok(resultData: Data(#"{}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.start(workdir: "/x")
        XCTAssertNotNil(vm.errorMessage)
        guard case .folders = vm.phase else { return XCTFail("no convo_id means no navigation") }
    }

    func test_start_reentrantCallIgnored() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        fake.replies["start"] = .ok(resultData: Data(#"{"convo_id":"c-new"}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        async let first: Void = vm.start(workdir: "/x")
        async let second: Void = vm.start(workdir: "/x")
        _ = await (first, second)
        XCTAssertEqual(fake.requests.filter { $0.method == "start" }.count, 1,
                       "start must never double-fire — the relay has no dedup")
    }

    // MARK: Roster capacity fan-out

    func test_load_fansOutToConnectedAgentsOnly() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([
            agent(1, name: "a", connected: true),
            agent(2, name: "b", connected: true),
            agent(3, name: "c", connected: false),
        ])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"account":{"email":"pat@yearbook.com"},"activity":{"live_sessions":2}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        let fanned = fake.requests.filter { $0.method == "recent_folders" }.map(\.agentDeviceID).sorted()
        XCTAssertEqual(fanned, [1, 2], "offline agents are never queried")
        XCTAssertEqual(vm.capacities[1]?.accountEmail, "pat@yearbook.com")
        XCTAssertEqual(vm.capacities[1]?.liveSessions, 2)
        XCTAssertEqual(vm.capacities[2], BoxCapacity(liveSessions: nil, limitLines: [], accountEmail: nil))
        XCTAssertTrue(vm.capacityPending.isEmpty)
    }

    func test_fanOut_oneFailingBoxDegradesAlone() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":1}}"#.utf8))
        fake.repliesByDevice[2] = .failure(code: "agent_unreachable", detail: nil)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertEqual(vm.capacities[1]?.liveSessions, 1)
        XCTAssertNil(vm.capacities[2], "failed box has no capacity entry")
        XCTAssertTrue(vm.capacityPending.isEmpty, "failure still clears pending")
    }

    func test_select_usesFannedFoldersWithoutSecondRPC() async {
        let fake = FakeAgentRPCProvider()
        let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
        fake.devicesResult = .success(agents)
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/w/app","last_used":100}]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        let callsBefore = fake.requests.filter { $0.method == "recent_folders" }.count
        await vm.select(agent: agents[0])
        XCTAssertEqual(vm.folders.map(\.path), ["/w/app"])
        XCTAssertEqual(fake.requests.filter { $0.method == "recent_folders" }.count, callsBefore,
                       "cached folder list — no second RPC")
    }

    func test_select_fallsBackToLiveRPCWhenFanOutFailed() async {
        let fake = FakeAgentRPCProvider()
        let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
        fake.devicesResult = .success(agents)
        fake.repliesByDevice[1] = .failure(code: "agent_unreachable", detail: nil)
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/late","last_used":1}]}"#.utf8))
        await vm.select(agent: agents[0])
        XCTAssertEqual(vm.folders.map(\.path), ["/late"], "live RPC fallback after failed fan-out")
    }

    func test_reload_keepsLastKnownCapacityWhileTheRefreshIsInFlight() async {
        let fake = FakeAgentRPCProvider()
        let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
        fake.devicesResult = .success(agents)
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":2},"account":{"email":"pat@yearbook.com"}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        let gate = Gate(), arrived = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrived
        await vm.backToAgents()
        await arrived.wait()

        // Stale-while-revalidate, on purpose: blanking the row to "Checking…"
        // on every back-navigation would collapse a three-line row to one and
        // grow it back a moment later.
        XCTAssertEqual(vm.capacities[1]?.liveSessions, 2,
                       "last-known capacity stays on the row while its refresh is in flight")
        XCTAssertTrue(vm.capacityPending.contains(1))
        gate.open()
        await vm.capacityFanOutForTesting?.value
    }

    func test_reload_failedRefetchDropsTheStaleCapacity() async {
        let fake = FakeAgentRPCProvider()
        let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
        fake.devicesResult = .success(agents)
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":2},"account":{"email":"pat@yearbook.com"}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value
        XCTAssertNotNil(vm.capacities[1])

        fake.repliesByDevice[1] = .failure(code: "agent_unreachable", detail: nil)
        await vm.backToAgents()
        await vm.capacityFanOutForTesting?.value

        XCTAssertNil(vm.capacities[1],
                     "a box that just failed to answer must not keep presenting last visit's numbers as live")
        XCTAssertEqual(vm.capacities[2], BoxCapacity(liveSessions: nil, limitLines: [], accountEmail: nil),
                       "the box that did answer is unaffected")
    }

    /// The host suspends idle boxes, so "went offline" is the normal resting
    /// state of a box, not a fault. Nothing will revalidate it — which is
    /// precisely why its row keeps the numbers it reported while it was up,
    /// re-seeded from the capacity cache and captioned with their age
    /// (`NewChatViewModelOfflineCapacityTests` covers the seeding rules).
    func test_reload_reseedsCapacityForBoxesThatWentOffline() async {
        let fake = FakeAgentRPCProvider()
        // Three connected boxes so the reload still shows a roster — dropping
        // to one would auto-skip straight to the folder step instead.
        fake.devicesResult = .success([agent(1, name: "a", connected: true),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "c", connected: true)])
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[],"activity":{"live_sessions":2},"account":{"email":"pat@yearbook.com"}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        fake.repliesByDevice[3] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let captured = Date(timeIntervalSince1970: 1_754_900_000)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache(),
                                  now: { captured })
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        fake.devicesResult = .success([agent(1, name: "a", connected: false),
                                       agent(2, name: "b", connected: true),
                                       agent(3, name: "c", connected: true)])
        await vm.backToAgents()
        await vm.capacityFanOutForTesting?.value

        XCTAssertEqual(vm.capacities[1]?.accountEmail, "pat@yearbook.com",
                       "a sleeping box still shows which account it runs")
        XCTAssertEqual(vm.capacityFreshness(for: 1), .offline(capturedAt: captured),
                       "and says so — those numbers predate this visit")
        XCTAssertNotNil(vm.capacities[2])
        XCTAssertEqual(vm.capacityFreshness(for: 2), .live)
    }

    func test_reload_dropsCachedFoldersUntilTheNewFanOutAnswers() async {
        let fake = FakeAgentRPCProvider()
        let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
        fake.devicesResult = .success(agents)
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/old","last_used":1}]}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        await vm.capacityFanOutForTesting?.value

        // The box moved on between visits, and its second fan-out leg is
        // still in flight when the user picks it.
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/new","last_used":2}]}"#.utf8))
        let gate = Gate(), arrived = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrived
        await vm.backToAgents()
        await arrived.wait()

        await vm.select(agent: agents[0])
        XCTAssertEqual(vm.folders.map(\.path), ["/new"],
                       "a reload invalidates the folder cache — pick refetches instead of serving last visit's list")
        gate.open()
        await vm.capacityFanOutForTesting?.value
    }

    func test_reload_lateReplyFromSupersededFanOutIsIgnored() async {
        let fake = FakeAgentRPCProvider()
        let agents = [agent(1, name: "a", connected: true), agent(2, name: "b", connected: true)]
        fake.devicesResult = .success(agents)
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/stale","last_used":1}],"activity":{"live_sessions":9}}"#.utf8))
        fake.repliesByDevice[2] = .ok(resultData: Data(#"{"folders":[]}"#.utf8))
        let gate = Gate(), arrived = Gate()
        fake.gates[1] = gate
        fake.arrivals[1] = arrived
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        let supersededFanOut = vm.capacityFanOutForTesting
        await arrived.wait()

        // Second visit: box 1 answers straight away with fresh numbers.
        fake.repliesByDevice[1] = .ok(resultData: Data(#"{"folders":[{"path":"/fresh","last_used":2}],"activity":{"live_sessions":1}}"#.utf8))
        await vm.backToAgents()
        await vm.capacityFanOutForTesting?.value
        // Only now does the first visit's leg answer.
        gate.open()
        await supersededFanOut?.value

        XCTAssertEqual(vm.capacities[1]?.liveSessions, 1,
                       "a superseded leg must not overwrite the current generation's capacity")
        XCTAssertTrue(vm.capacityPending.isEmpty)
        await vm.select(agent: agents[0])
        XCTAssertEqual(vm.folders.map(\.path), ["/fresh"],
                       "nor its folder cache")
    }

    func test_selectAgent_fromRoster() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(3, connected: true), agent(4, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        let vm = NewChatViewModel(api: fake, capacityCache: InMemoryBoxCapacityCache())
        await vm.load()
        // Drain the roster fan-out before selecting — its legs land in
        // nondeterministic order, so nothing below may assert on `last`
        // relative to them (this raced in CI for exactly that reason).
        await vm.capacityFanOutForTesting?.value
        guard case let .agents(list) = vm.phase else { return XCTFail("expected agents phase") }
        await vm.select(agent: list[1])
        guard case let .folders(picked) = vm.phase else { return XCTFail("expected folders phase") }
        XCTAssertEqual(picked.id, list[1].id)
        // The fan-out asked both boxes; select reuses the fanned folder
        // cache, so picking one adds no third request.
        XCTAssertEqual(Set(fake.requests.map(\.agentDeviceID)), [3, 4])
        XCTAssertEqual(fake.requests.count, 2)
    }
}
