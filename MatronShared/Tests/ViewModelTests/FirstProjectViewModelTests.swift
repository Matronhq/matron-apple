import XCTest
@testable import MatronViewModels
import MatronJournal
import MatronModels

private actor FirstProjectRPC: AgentRPCProviding {
    let box = DeviceDTO(id: 1, kind: "agent", name: "box-a", createdAt: 0,
        cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false, connected: true)
    var setup = RPCReply.ok(resultData: Data("{\"state\":\"connected\"}".utf8))
    var start = RPCReply.ok(resultData: Data("{\"convo_id\":\"first-chat\"}".utf8))
    var timesStarted = 0
    var timeout = false
    func devices() async throws -> [DeviceDTO] { [box] }
    func setSetup(_ reply: RPCReply) { setup = reply }
    func setTimeout() { timeout = true }
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        if method == "start" {
            timesStarted += 1
            if timeout { throw RPCRequestError.timeout }
            return start
        }
        return setup
    }
    nonisolated func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { $0.finish() } }
    nonisolated func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { $0.finish() } }
}

@MainActor
final class FirstProjectViewModelTests: XCTestCase {
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
        XCTAssertTrue(sent.first?.1.contains("first-project-result") == true)
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
