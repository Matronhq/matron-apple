import XCTest
@testable import MatronViewModels
@testable import MatronJournal

/// Recording fake for the New-Chat RPC surface. Replies are scripted per
/// method; `agentRequest` throws when `rpcError` is set.
final class FakeAgentRPCProvider: AgentRPCProviding, @unchecked Sendable {
    var devicesResult: Result<[DeviceDTO], JournalAPIError> = .success([])
    var replies: [String: RPCReply] = [:]   // keyed by method
    var rpcError: RPCRequestError?

    private(set) var requests: [(method: String, agentDeviceID: Int64, params: [String: Any])] = []

    func devices() async throws -> [DeviceDTO] { try devicesResult.get() }

    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        requests.append((method, agentDeviceID, params))
        if let rpcError { throw rpcError }
        return replies[method] ?? .failure(code: "unknown_method", detail: nil)
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
        let vm = NewChatViewModel(api: fake)
        await vm.load()
        guard case let .agents(list) = vm.phase else { return XCTFail("expected agents phase") }
        XCTAssertEqual(list.map(\.id), [3, 4, 2], "clients excluded; connected first, then by name")
    }

    func test_load_singleConnectedAgent_skipsStraightToFolders() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true), agent(2, connected: false)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[{"path":"/home/dan/app","last_used":100}]}"#)
        let vm = NewChatViewModel(api: fake)
        await vm.load()
        guard case let .folders(picked) = vm.phase else { return XCTFail("expected folders phase") }
        XCTAssertEqual(picked.id, 9)
        XCTAssertEqual(vm.folders.map(\.path), ["/home/dan/app"])
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
        let vm = NewChatViewModel(api: fake)
        await vm.load()
        XCTAssertEqual(vm.folders.map(\.path), ["/new", "/old", "/never"])
        XCTAssertNil(vm.folders.last?.lastUsed, "never-used folder carries nil lastUsed")
    }

    func test_foldersFailure_degradesPickerButKeepsFreeText() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(9, connected: true)])
        fake.rpcError = .timeout
        let vm = NewChatViewModel(api: fake)
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
        let vm = NewChatViewModel(api: fake)
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
        let vm = NewChatViewModel(api: fake)
        await vm.load()
        await vm.start(workdir: "  ")
        let params = fake.requests.last?.params
        XCTAssertNil(params?["workdir"], "blank workdir means the bridge default — omit the key")
        XCTAssertNil(params?["browser"], "browser only travels when true")
    }

    func test_start_errorCopyTable() async {
        let cases: [(RPCReply, String)] = [
            (.failure(code: "agent_unreachable", detail: nil), "The agent didn't answer — is the box awake?"),
            (.failure(code: "not_ready", detail: nil), "The agent didn't answer — is the box awake?"),
            (.failure(code: "bad_workdir", detail: "/nope"), "That folder doesn't exist on the box."),
            (.failure(code: "spawn_failed", detail: "boom"), "Couldn't start — boom."),
            (.failure(code: "unsupported_mode", detail: nil), "Couldn't start — unsupported_mode."),
        ]
        for (reply, expected) in cases {
            let fake = FakeAgentRPCProvider()
            fake.devicesResult = .success([agent(9, connected: true)])
            fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
            fake.replies["start"] = reply
            let vm = NewChatViewModel(api: fake)
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
        let vm = NewChatViewModel(api: fake)
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
        let vm = NewChatViewModel(api: fake)
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
        let vm = NewChatViewModel(api: fake)
        await vm.load()
        async let first: Void = vm.start(workdir: "/x")
        async let second: Void = vm.start(workdir: "/x")
        _ = await (first, second)
        XCTAssertEqual(fake.requests.filter { $0.method == "start" }.count, 1,
                       "start must never double-fire — the relay has no dedup")
    }

    func test_selectAgent_fromRoster() async {
        let fake = FakeAgentRPCProvider()
        fake.devicesResult = .success([agent(3, connected: true), agent(4, connected: true)])
        fake.replies["recent_folders"] = foldersReply(#"{"folders":[]}"#)
        let vm = NewChatViewModel(api: fake)
        await vm.load()
        guard case let .agents(list) = vm.phase else { return XCTFail("expected agents phase") }
        await vm.select(agent: list[1])
        guard case let .folders(picked) = vm.phase else { return XCTFail("expected folders phase") }
        XCTAssertEqual(picked.id, list[1].id)
        XCTAssertEqual(fake.requests.last?.agentDeviceID, list[1].id)
    }
}
