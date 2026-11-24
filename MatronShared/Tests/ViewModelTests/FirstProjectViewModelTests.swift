import XCTest
@testable import MatronViewModels
import MatronJournal
import MatronModels

private actor FirstProjectRPC: AgentRPCProviding {
    var roster = [DeviceDTO(id: 1, kind: "agent", name: "box-a", createdAt: 0,
        cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false, connected: true)]
    var setup = RPCReply.ok(resultData: Data("{\"state\":\"connected\"}".utf8))
    var start = RPCReply.ok(resultData: Data("{\"convo_id\":\"first-chat\"}".utf8))
    var timesStarted = 0
    var setupBoxes: [Int64] = []
    var timeout = false
    func devices() async throws -> [DeviceDTO] { roster }
    func setDevices(_ devices: [DeviceDTO]) { roster = devices }
    func setSetup(_ reply: RPCReply) { setup = reply }
    func setTimeout() { timeout = true }
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        if method == "start" {
            timesStarted += 1
            if timeout { throw RPCRequestError.timeout }
            return start
        }
        setupBoxes.append(agentDeviceID)
        return setup
    }
    nonisolated func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { $0.finish() } }
    nonisolated func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { $0.finish() } }
}

@MainActor
final class FirstProjectViewModelTests: XCTestCase {
    private func box(_ id: Int64, name: String = "box-a", connected: Bool) -> DeviceDTO {
        DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0,
            cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false, connected: connected)
    }

    func testOfflineBoxSkipsLoginRPCAndCanRecoverWhenCheckedAgain() async {
        let rpc = FirstProjectRPC()
        await rpc.setDevices([box(1, connected: false)])
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in XCTFail() }, readResult: { _ in nil })
        await model.load()
        await model.connect()
        XCTAssertEqual(model.connection, "offline")
        XCTAssertFalse(model.canStart)
        XCTAssertNil(model.errorMessage)
        let offlineRequests = await rpc.setupBoxes
        XCTAssertTrue(offlineRequests.isEmpty)
        await rpc.setDevices([box(1, connected: true)])
        await model.refresh()
        XCTAssertEqual(model.connection, "connected")
        XCTAssertTrue(model.canStart)
        let requests = await rpc.setupBoxes
        XCTAssertEqual(requests, [1])
    }

    func testFirstChoicePrefersConnectedBoxOverAlphabeticalOrder() async {
        let rpc = FirstProjectRPC()
        await rpc.setDevices([box(1, connected: false), box(2, name: "box-b", connected: true)])
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in }, readResult: { _ in nil })
        await model.load()
        XCTAssertEqual(model.selectedBox?.id, 2)
        let requests = await rpc.setupBoxes
        XCTAssertEqual(requests, [2])
    }

    func testPendingLoginStaysWithItsBoxWhenItGoesOffline() async {
        let rpc = FirstProjectRPC()
        await rpc.setSetup(.ok(resultData: Data("{\"state\":\"waiting\",\"flow_id\":\"fixture-flow\",\"authorization_url\":\"https://claude.com/cai/oauth/authorize?state=fixture\"}".utf8)))
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in }, readResult: { _ in nil })
        await model.load()
        XCTAssertNotNil(model.authorizationURL)
        await rpc.setDevices([box(1, connected: false), box(2, name: "box-b", connected: true)])
        await model.refresh()
        XCTAssertEqual(model.connection, "offline")
        XCTAssertEqual(model.progress.boxID, 1)
        XCTAssertEqual(model.progress.flowID, "fixture-flow")
        XCTAssertNil(model.authorizationURL)
        XCTAssertNil(model.errorMessage)
        let requests = await rpc.setupBoxes
        XCTAssertEqual(requests, [1])
    }

    func testUnreachableReplyNamesOfflineBoxWithoutServerError() async {
        let rpc = FirstProjectRPC()
        await rpc.setSetup(.failure(code: "agent_unreachable", detail: nil))
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in }, readResult: { _ in nil })
        await model.load()
        XCTAssertEqual(model.connection, "offline")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canStart)
    }

    func testConfirmedConnectionSkipsToProjectWithoutStartingWork() async {
        let rpc = FirstProjectRPC()
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in XCTFail() }, readResult: { _ in nil })
        await model.load()
        XCTAssertEqual(model.step, 2)
        XCTAssertTrue(model.canStart)
        let starts = await rpc.timesStarted
        XCTAssertEqual(starts, 0)
    }

    func testOpeningAuthorizationDoesNotCountAsConnectedAndURLIsNotSaved() async throws {
        let rpc = FirstProjectRPC()
        let data = Data("{\"state\":\"waiting\",\"flow_id\":\"fixture-flow\",\"authorization_url\":\"https://claude.com/cai/oauth/authorize?state=fixture\"}".utf8)
        await rpc.setSetup(.ok(resultData: data))
        var saved = FirstProjectProgress()
        let model = FirstProjectViewModel(api: rpc, save: { saved = $0 }, send: { _, _, _ in XCTFail() }, readResult: { _ in nil })
        await model.load()
        XCTAssertEqual(model.step, 1)
        XCTAssertFalse(model.canStart)
        XCTAssertNotNil(model.authorizationURL)
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        XCTAssertFalse(encoded.contains("https://"))
        XCTAssertEqual(saved.flowID, "fixture-flow")
    }

    func testUntrustedAuthorizationURLIsNotOffered() async {
        let rpc = FirstProjectRPC()
        await rpc.setSetup(.ok(resultData: Data("{\"state\":\"waiting\",\"authorization_url\":\"https://example.com/oauth/authorize\"}".utf8)))
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in }, readResult: { _ in nil })
        await model.load()
        XCTAssertNil(model.authorizationURL)
        XCTAssertFalse(model.canStart)
    }

    func testOldBridgeShowsUnsupportedWithoutStarting() async {
        let rpc = FirstProjectRPC()
        await rpc.setSetup(.failure(code: "unknown_method", detail: nil))
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in }, readResult: { _ in nil })
        await model.load()
        XCTAssertEqual(model.connection, "unsupported")
        XCTAssertFalse(model.canStart)
        XCTAssertNil(model.errorMessage)
        await model.refresh()
        XCTAssertEqual(model.connection, "unsupported")
        XCTAssertNil(model.errorMessage)
    }

    func testLockedBoxClearsAuthorizationWithoutReportingNetworkFailure() async {
        let rpc = FirstProjectRPC()
        await rpc.setSetup(.ok(resultData: Data("{\"state\":\"waiting\",\"flow_id\":\"fixture-flow\",\"authorization_url\":\"https://claude.com/cai/oauth/authorize?state=fixture\"}".utf8)))
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, _ in }, readResult: { _ in nil })
        await model.load()
        XCTAssertNotNil(model.authorizationURL)
        await rpc.setSetup(.failure(code: "box_locked", detail: nil))
        await model.refresh()
        XCTAssertEqual(model.connection, "locked")
        XCTAssertNil(model.authorizationURL)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canStart)
    }

    func testBriefSendFailureRetriesExistingChatWithSameMessageID() async {
        let rpc = FirstProjectRPC()
        var failSend = true
        var messageIDs: [String] = []
        let model = FirstProjectViewModel(api: rpc, save: { _ in }, send: { _, _, id in
            messageIDs.append(id)
            if failSend { throw RPCRequestError.timeout }
        }, readResult: { _ in nil })
        await model.load()
        await model.startProject()
        XCTAssertEqual(model.progress.conversationID, "first-chat")
        XCTAssertFalse(model.progress.promptQueued)
        XCTAssertFalse(model.progress.startUnconfirmed)
        XCTAssertTrue(model.errorMessage?.contains("brief could not be sent") == true)
        await model.load()
        XCTAssertTrue(model.errorMessage?.contains("brief could not be sent") == true)
        failSend = false
        await model.load()
        XCTAssertTrue(model.progress.promptQueued)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(messageIDs.count, 3)
        XCTAssertEqual(Set(messageIDs), [model.progress.messageID])
        let starts = await rpc.timesStarted
        XCTAssertEqual(starts, 1)
    }

    func testBriefStartsOnceAndUsesDurableMessageIdentity() async {
        let rpc = FirstProjectRPC()
        var saved = FirstProjectProgress()
        var sent: [(String, String, String)] = []
        let model = FirstProjectViewModel(api: rpc, save: { saved = $0 },
            send: { sent.append(($0, $1, $2)) }, readResult: { _ in nil })
        await model.load()
        model.choose(.report)
        await model.startProject()
        await model.startProject()
        XCTAssertEqual(saved.conversationID, "first-chat")
        XCTAssertTrue(saved.promptQueued)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.2, saved.messageID)
        XCTAssertTrue(sent.first?.1.hasPrefix(FirstProjectKind.report.example) == true)
        XCTAssertTrue(sent.first?.1.contains(FirstProjectResult.noticeTitle) == true)
        XCTAssertFalse(sent.first?.1.contains("first-project-result") == true)
        XCTAssertEqual(model.step, 3)
        XCTAssertNil(model.result)
    }

    func testLostStartReplySurvivesRelaunchWithoutDuplicateWork() async {
        let rpc = FirstProjectRPC()
        await rpc.setTimeout()
        var saved = FirstProjectProgress()
        let model = FirstProjectViewModel(api: rpc, save: { saved = $0 }, send: { _, _, _ in XCTFail() }, readResult: { _ in nil })
        await model.load()
        await model.startProject()
        XCTAssertTrue(saved.startUnconfirmed)
        let resumed = FirstProjectViewModel(api: rpc, progress: saved, save: { _ in }, send: { _, _, _ in XCTFail() }, readResult: { _ in nil })
        await resumed.load()
        await resumed.startProject()
        let starts = await rpc.timesStarted
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(resumed.step, 3)
    }

    func testSavedConversationResumesSendingWithSameMessageID() async {
        let rpc = FirstProjectRPC()
        var progress = FirstProjectProgress()
        progress.conversationID = "first-chat"
        var messageIDs: [String] = []
        let model = FirstProjectViewModel(api: rpc, progress: progress, save: { _ in },
            send: { _, _, id in messageIDs.append(id) }, readResult: { _ in nil })
        await model.load()
        await model.load()
        XCTAssertEqual(messageIDs, [progress.messageID])
        let starts = await rpc.timesStarted
        XCTAssertEqual(starts, 0)
    }

    func testCompletionRequiresAResultAndOpeningIt() async {
        let rpc = FirstProjectRPC()
        var progress = FirstProjectProgress()
        progress.conversationID = "first-chat"; progress.promptQueued = true
        var answer: FirstProjectResult?
        let model = FirstProjectViewModel(api: rpc, progress: progress, save: { _ in },
            send: { _, _, _ in XCTFail() }, readResult: { _ in answer })
        await model.load()
        model.openedResult()
        XCTAssertFalse(model.progress.completed)
        answer = FirstProjectResult(noticeID: "notice", title: "Your report", projectID: "project")
        await model.refresh()
        XCTAssertFalse(model.progress.completed)
        model.openedResult()
        XCTAssertTrue(model.progress.completed)
    }

    func testProgressIsScopedToBothServerAndAccount() {
        let first = FirstProjectProgress.defaultsKey(server: URL(string: "https://one.example.com")!, userID: "alice")
        XCTAssertNotEqual(first, FirstProjectProgress.defaultsKey(server: URL(string: "https://two.example.com")!, userID: "alice"))
        XCTAssertNotEqual(first, FirstProjectProgress.defaultsKey(server: URL(string: "https://one.example.com")!, userID: "bob"))
    }
}
