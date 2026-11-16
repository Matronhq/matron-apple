import XCTest
import MatronModels
@testable import MatronJournal
@testable import MatronViewModels

private final class TapSync: ItemsSyncing, @unchecked Sendable {
    var refetched: [String] = []
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
    func refreshItem(id: String) async { refetched.append(id) }
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
    func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
}

private final class TapAPI: ItemsProviding, @unchecked Sendable {
    var current: (item: TrackerItem, comments: [TrackerComment])
    var taps: [(id: String, action: String, replyTo: String?, approval: SignedApproval, key: String)] = []
    var tapError: Error?
    init(_ item: TrackerItem, _ comments: [TrackerComment] = []) { current = (item, comments) }

    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { current }
    func tapItem(id: String, action: String, replyTo: String?, approval: SignedApproval, idempotencyKey: String) async throws -> (item: TrackerItem, comment: TrackerComment?) {
        if let tapError { throw tapError }
        taps.append((id, action, replyTo, approval, idempotencyKey))
        return (current.item, nil)
    }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { fatalError() }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) { fatalError() }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
}

private actor Requests {
    var seen: [ApprovalRequest] = []
    func add(_ r: ApprovalRequest) { seen.append(r) }
}

@MainActor
final class StepUpTapTests: XCTestCase {
    private let approval = SignedApproval(statement: "{}", signature: "sig")

    private func item(stepUp: Bool = true, subject: [String: String]? = ["box": "box-a"], labels: [String] = [],
                      title: String = "Deploy box-a", body: String = "Roll out the new build?",
                      consent: String? = nil) -> TrackerItem {
        TrackerItem(id: "it_abc123", num: 7, kind: .question, awaiting: .user, title: title, body: body, labels: labels,
                    originConvoID: "c1", actions: ["Approve", "Decline"], stepUp: stepUp, subject: subject,
                    consentKind: consent)
    }

    private let task = "Run the test suite and report."
    private var spawnSubject: [String: String] {
        ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/home/alice/project", task: task)
    }

    private func comment(stepUp: Bool, subject: [String: String]? = nil) -> TrackerComment {
        TrackerComment(id: "cm_def456", itemID: "it_abc123", author: .agent, body: "Also restart the service?",
                       actions: ["Yes", "No"], stepUp: stepUp, subject: subject)
    }

    // MARK: What is signed

    func test_itemTap_requestMatchesTheVector() {
        let request = StepUpTap.request(item: item(), comment: nil, label: "Approve")
        XCTAssertEqual(request?.kind, .itemTap(itemID: "it_abc123", num: 7, replyTo: nil, action: "Approve",
                                               promptDigest: "ed21b0d465a1c26c16a5800898c5e792473adf2eb04fd99cdbe015cd80200702"))
        XCTAssertEqual(request?.subject, ["box": "box-a"])
        XCTAssertEqual(request?.headline, "Deploy box-a")
        XCTAssertEqual(request?.reference, "#7")
        XCTAssertEqual(request?.button, "Approve")
        XCTAssertEqual(request?.detail, "Roll out the new build?")
    }

    func test_followUpTap_usesTheCommentsBody_andTheItemsSubjectUnlessTheCommentIsStepUp() {
        // A plain follow-up on a step-up item: the item's subject.
        let onItem = StepUpTap.request(item: item(), comment: comment(stepUp: false), label: "Yes")
        XCTAssertEqual(onItem?.kind, .itemTap(itemID: "it_abc123", num: 7, replyTo: "cm_def456", action: "Yes",
                                              promptDigest: "3b4138bc5f9e4d49f9eb9ca5640a6dd12589651e605f13d7086e42a8509819ef"))
        XCTAssertEqual(onItem?.subject, ["box": "box-a"])
        // A step-up follow-up: its own subject, `{}` when it has none.
        XCTAssertEqual(StepUpTap.request(item: item(), comment: comment(stepUp: true, subject: ["svc": "web"]), label: "Yes")?.subject,
                       ["svc": "web"])
        XCTAssertEqual(StepUpTap.request(item: item(), comment: comment(stepUp: true), label: "Yes")?.subject, [:])
        // A step-up follow-up on an ordinary item still needs a signature.
        XCTAssertNotNil(StepUpTap.request(item: item(stepUp: false, subject: nil), comment: comment(stepUp: true), label: "Yes"))
    }

    func test_noSubject_signsAnEmptyOne() {
        XCTAssertEqual(StepUpTap.request(item: item(subject: nil), comment: nil, label: "Approve")?.subject, [:])
    }

    func test_ordinaryItem_needsNoSignature() {
        XCTAssertNil(StepUpTap.request(item: item(stepUp: false, subject: nil), comment: nil, label: "Approve"))
        XCTAssertNil(StepUpTap.request(item: item(stepUp: false, subject: nil), comment: comment(stepUp: false), label: "Yes"))
    }

    // MARK: Consent items

    func test_spawnConsent_isSignedOnlyOverTheTaskTheUserWasShown() throws {
        let consent = item(subject: spawnSubject, labels: ["consent"], title: "Start a session on box-a", consent: "spawn")
        let request = try XCTUnwrap(StepUpTap.consentRequest(item: consent, label: "Approve", verifiedText: task))
        XCTAssertEqual(request.kind, .consent)
        XCTAssertEqual(request.subject, spawnSubject)
        XCTAssertEqual(request.detail, task, "the task is shown in full")
        // A decline is never signed.
        XCTAssertNil(try StepUpTap.consentRequest(item: consent, label: "Decline", verifiedText: task))
        // Not aimed at a protected box: nothing to sign.
        XCTAssertNil(try StepUpTap.consentRequest(item: item(stepUp: false, subject: nil, consent: "spawn"), label: "Approve", verifiedText: task))
    }

    func test_spawnConsent_withNoTaskToHand_isSentToItsCard() {
        let consent = item(subject: spawnSubject, labels: ["consent"], consent: "spawn")
        XCTAssertThrowsError(try StepUpTap.consentRequest(item: consent, label: "Approve", verifiedText: nil)) { error in
            guard case ApprovalError.subjectMismatch(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("card"))
        }
    }

    func test_spawnConsent_whoseTaskIsNotTheSubjects_isRefused() {
        let consent = item(subject: spawnSubject, labels: ["consent"], consent: "spawn")
        XCTAssertThrowsError(try StepUpTap.consentRequest(item: consent, label: "Approve", verifiedText: "Something else"))
    }

    func test_consentSubjectForAnotherKindOfAsk_isRefused() {
        // The journal says "transfer"; the subject says "spawn".
        let consent = item(subject: spawnSubject, labels: ["consent"], consent: "transfer")
        XCTAssertThrowsError(try StepUpTap.consentRequest(item: consent, label: "Approve", verifiedText: task))
    }

    func test_transferConsent_signsTheFilesHashAndSizeAsShown() throws {
        let subject = ApprovalSubjects.transfer(id: "tr_1", box: "box-a", fileSHA256: String(repeating: "ab", count: 32), size: 2048)
        let consent = item(subject: subject, labels: ["consent"], title: "Send report.pdf to box-a", consent: "transfer")
        let request = try XCTUnwrap(StepUpTap.consentRequest(item: consent, label: "Approve", verifiedText: nil))
        XCTAssertEqual(request.kind, .consent)
        XCTAssertEqual(request.subject, subject)
    }

    func test_chatConsent_isSentToItsCard() {
        let subject = ApprovalSubjects.chat(roomID: "r1", targetDeviceID: 5, box: "box-a", justification: "Need the logs")
        let consent = item(subject: subject, labels: ["consent"], consent: "chat")
        XCTAssertThrowsError(try StepUpTap.consentRequest(item: consent, label: "Approve", verifiedText: nil))
    }

    func test_anItemAnAgentLabelledConsent_isAnOrdinaryStepUpTap() {
        // Only the journal's own mark makes an item a consent ask. An
        // agent's item wearing the label signs an item tap, never a
        // consent statement.
        let forged = item(subject: spawnSubject, labels: ["consent"])
        guard case .itemTap = StepUpTap.request(item: forged, comment: nil, label: "Approve")?.kind else {
            return XCTFail("expected an item tap")
        }
        XCTAssertNil(StepUpTap.request(item: item(subject: spawnSubject, consent: "spawn"), comment: nil, label: "Approve"))
    }

    // MARK: Sending

    func test_send_signsTheFreshText_postsWithAnIdempotencyKey_andRefetches() async {
        // The cached copy is stale: the journal's body has changed.
        let fresh = item(body: "Roll out build 42?")
        let api = TapAPI(fresh)
        let sync = TapSync()
        let requests = Requests()
        let approval = self.approval
        let outcome = await StepUpTap.send(item: item(), comment: nil, label: "Approve", api: api, sync: sync) { request in
            await requests.add(request)
            return approval
        }
        XCTAssertEqual(outcome, .sent)
        let seen = await requests.seen
        XCTAssertEqual(seen.first?.detail, "Roll out build 42?")
        XCTAssertEqual(seen.first?.kind, .itemTap(itemID: "it_abc123", num: 7, replyTo: nil, action: "Approve",
                                                  promptDigest: PromptDigest.item(title: "Deploy box-a", body: "Roll out build 42?")))
        XCTAssertEqual(api.taps.count, 1)
        XCTAssertEqual(api.taps.first?.action, "Approve")
        XCTAssertNil(api.taps.first?.replyTo)
        XCTAssertFalse(api.taps.first?.key.isEmpty ?? true)
        XCTAssertEqual(sync.refetched, ["it_abc123"])
    }

    func test_send_ordinaryItem_isLeftToTheOutbox() async {
        let plain = item(stepUp: false, subject: nil)
        let api = TapAPI(plain)
        let outcome = await StepUpTap.send(item: plain, comment: nil, label: "Approve", api: api, sync: TapSync()) { _ in
            XCTFail("nothing to sign"); return nil
        }
        XCTAssertEqual(outcome, .unsigned)
        XCTAssertTrue(api.taps.isEmpty)
    }

    func test_send_accountWithNoKey_isLeftToTheOutbox() async {
        let api = TapAPI(item())
        let outcome = await StepUpTap.send(item: item(), comment: nil, label: "Approve", api: api, sync: TapSync()) { _ in nil }
        XCTAssertEqual(outcome, .unsigned)
        XCTAssertTrue(api.taps.isEmpty)
    }

    func test_send_cancelled_sendsNothing() async {
        let api = TapAPI(item())
        let outcome = await StepUpTap.send(item: item(), comment: nil, label: "Approve", api: api, sync: TapSync()) { _ in
            throw ApprovalKeyFailure.cancelled
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(api.taps.isEmpty)
    }

    func test_send_noKeyOnThisDevice_saysSo() async {
        let api = TapAPI(item())
        let outcome = await StepUpTap.send(item: item(), comment: nil, label: "Approve", api: api, sync: TapSync()) { _ in
            throw ApprovalError.noKeyOnThisDevice
        }
        guard case .failed(let message) = outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("approval key"))
        XCTAssertTrue(api.taps.isEmpty)
    }

    func test_send_mismatch_refetches_andAsksToReadAgain() async {
        let api = TapAPI(item())
        api.tapError = JournalAPIError.approvalInvalid(reason: "mismatch")
        let sync = TapSync()
        let approval = self.approval
        let outcome = await StepUpTap.send(item: item(), comment: nil, label: "Approve", api: api, sync: sync) { _ in approval }
        XCTAssertEqual(outcome, .failed("The question changed while you were approving it. Read it again, then approve."))
        XCTAssertEqual(sync.refetched, ["it_abc123"])
    }

    func test_send_spawnConsent_withItsTask_signsAConsentStatement() async {
        let consent = item(subject: spawnSubject, labels: ["consent"], consent: "spawn")
        let api = TapAPI(consent)
        let requests = Requests()
        let approval = self.approval
        // The cached copy does not carry the journal's mark; the fresh one does.
        let cached = item(subject: spawnSubject, labels: ["consent"])
        let outcome = await StepUpTap.send(item: cached, comment: nil, label: "Approve", verifiedText: task,
                                           api: api, sync: TapSync()) { request in
            await requests.add(request)
            return approval
        }
        XCTAssertEqual(outcome, .sent)
        let seen = await requests.seen
        XCTAssertEqual(seen.first?.kind, .consent)
        XCTAssertEqual(api.taps.first?.action, "Approve")
    }

    func test_send_spawnConsent_fromARowWithNoCard_signsNothing() async {
        let consent = item(subject: spawnSubject, labels: ["consent"], consent: "spawn")
        let api = TapAPI(consent)
        let outcome = await StepUpTap.send(item: consent, comment: nil, label: "Approve", api: api, sync: TapSync()) { _ in
            XCTFail("nothing may be offered for signing"); return nil
        }
        guard case .failed(let message) = outcome else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("card"))
        XCTAssertTrue(api.taps.isEmpty)
    }

    func test_send_consentDecline_isLeftToTheOutbox() async {
        let consent = item(subject: spawnSubject, labels: ["consent"], consent: "spawn")
        let api = TapAPI(consent)
        let outcome = await StepUpTap.send(item: consent, comment: nil, label: "Decline", api: api, sync: TapSync()) { _ in
            XCTFail("a decline is never signed"); return nil
        }
        XCTAssertEqual(outcome, .unsigned)
    }

    func test_send_followUpGone_isNotSigned() async {
        let api = TapAPI(item(stepUp: false, subject: nil), [])
        let outcome = await StepUpTap.send(item: item(stepUp: false, subject: nil), comment: comment(stepUp: true), label: "Yes",
                                           api: api, sync: TapSync()) { _ in
            XCTFail("the asking comment is gone"); return nil
        }
        XCTAssertEqual(outcome, .unsigned)
    }
}

// MARK: Consent cards

private actor ConsentAPI: ConsentSigningAPI {
    var items: [TrackerItem] = []
    var boxes: [DeviceDTO] = []
    var spawnAnswers: [(id: String, decision: AgentSpawnDecision, approval: SignedApproval?)] = []
    var chatAnswers: [(room: String, device: Int64, decision: AgentChatDecision, approval: SignedApproval?)] = []

    func set(items: [TrackerItem]) { self.items = items }
    func set(boxes: [DeviceDTO]) { self.boxes = boxes }

    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { ItemsPage(items: items, nextCursor: nil) }
    func devices() async throws -> [DeviceDTO] { boxes }
    func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision, approval: SignedApproval?) async throws {
        spawnAnswers.append((requestID, decision, approval))
    }
    func answerAgentChat(roomID: String, targetDeviceID: Int64, decision: AgentChatDecision, approval: SignedApproval?) async throws -> Bool {
        chatAnswers.append((roomID, targetDeviceID, decision, approval))
        return true
    }
    func agentChatPending() async throws -> [AgentChatPendingDTO] { [] }
}

final class SigningConsentServiceTests: XCTestCase {
    private let approval = SignedApproval(statement: "{}", signature: "sig")
    private let task = "Run the test suite and report."

    private func consentItem(link: String, subject: [String: String]?, stepUp: Bool = true, kind: String? = nil) -> TrackerItem {
        TrackerItem(id: "it_c", num: 12, kind: .question, awaiting: .user, title: "Start a session on box-a",
                    labels: ["consent"], links: [TrackerLink(json: ["url": link])!], originConvoID: "c1",
                    actions: ["Approve", "Decline"], stepUp: stepUp, subject: subject,
                    consentKind: kind ?? (link.contains("/chat/") ? "chat" : "spawn"))
    }

    private func service(_ api: ConsentAPI, _ seen: Requests) -> SigningConsentService {
        let approval = self.approval
        return SigningConsentService(api: api) { request in
            await seen.add(request)
            return approval
        }
    }

    func test_spawnOntoAProtectedBox_signsTheItemsSubject() async throws {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/home/alice/project", task: task)
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: subject)])
        let seen = Requests()
        try await service(api, seen).answerAgentSpawn(
            SpawnAsk(requestID: "sp_1", targetDeviceID: 5, workdir: "/home/alice/project", task: task), decision: .approve)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.kind, .consent)
        XCTAssertEqual(requests.first?.subject, subject)
        XCTAssertEqual(requests.first?.detail, task, "the full task is shown")
        XCTAssertEqual(requests.first?.reference, "#12")
        let answers = await api.spawnAnswers
        XCTAssertEqual(answers.first?.approval, approval)
    }

    func test_spawn_taskThatDoesNotHashToTheSubject_isRefused() async {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/home/alice/project", task: "Something else entirely")
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: subject)])
        let seen = Requests()
        do {
            try await service(api, seen).answerAgentSpawn(
                SpawnAsk(requestID: "sp_1", targetDeviceID: 5, workdir: "/home/alice/project", task: task), decision: .approve)
            XCTFail("expected a refusal")
        } catch {
            guard case ApprovalError.subjectMismatch = error else { return XCTFail("\(error)") }
        }
        let requests = await seen.seen
        XCTAssertTrue(requests.isEmpty, "nothing is offered for signing")
        let answers = await api.spawnAnswers
        XCTAssertTrue(answers.isEmpty)
    }

    func test_spawn_subjectForAnotherAsk_isRefused() async {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.spawn(ask: "sp_OTHER", box: "box-a", workdir: "/home/alice/project", task: task)
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: subject)])
        do {
            try await service(api, Requests()).answerAgentSpawn(SpawnAsk(requestID: "sp_1", task: task), decision: .approve)
            XCTFail("expected a refusal")
        } catch {
            guard case ApprovalError.subjectMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func test_spawn_withNoTaskToCheck_isRefused() async {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/home/alice/project", task: task)
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: subject)])
        let seen = Requests()
        do {
            // Only the request id: the caller never saw the task.
            try await service(api, seen).answerAgentSpawn(requestID: "sp_1", decision: .approve)
            XCTFail("expected a refusal")
        } catch {
            guard case ApprovalError.subjectMismatch = error else { return XCTFail("\(error)") }
        }
        let requests = await seen.seen
        XCTAssertTrue(requests.isEmpty)
        let answers = await api.spawnAnswers
        XCTAssertTrue(answers.isEmpty)
    }

    func test_spawn_folderThatIsNotTheSubjects_isRefused() async {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/srv/other", task: task)
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: subject)])
        do {
            try await service(api, Requests()).answerAgentSpawn(
                SpawnAsk(requestID: "sp_1", targetDeviceID: 5, workdir: "/home/alice/project", task: task), decision: .approve)
            XCTFail("expected a refusal")
        } catch {
            guard case ApprovalError.subjectMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func test_anAgentsItemWithTheSameLink_isNeverTakenForTheConsentItem() async throws {
        // An item an agent filed with the ask's link and its own subject:
        // without the journal's mark it is not the consent item, so the
        // subject is built from the card instead.
        let api = ConsentAPI()
        let forged = TrackerItem(id: "it_f", num: 13, kind: .question, awaiting: .user, title: "Lunch order",
                                 labels: ["consent"], links: [TrackerLink(json: ["url": "matron://consent/spawn/sp_1"])!],
                                 originConvoID: "c1", actions: ["Approve"], stepUp: true,
                                 subject: ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/", task: "rm -rf"))
        await api.set(items: [forged])
        await api.set(boxes: [DeviceDTO(id: 5, kind: "agent", name: "box-a", createdAt: 0, cursor: 0, lag: 0,
                                        lastSeenAt: nil, isSelf: false, isProtected: true)])
        let seen = Requests()
        try await service(api, seen).answerAgentSpawn(
            SpawnAsk(requestID: "sp_1", targetDeviceID: 5, workdir: "/home/alice/project", task: task), decision: .approve)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.subject["task_sha256"], ApprovalSubjects.sha256(task))
        XCTAssertEqual(requests.first?.subject["workdir"], "/home/alice/project")
    }

    func test_spawnOntoAnOrdinaryBox_goesUnsigned() async throws {
        let api = ConsentAPI()
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: nil, stepUp: false)])
        let seen = Requests()
        try await service(api, seen).answerAgentSpawn(SpawnAsk(requestID: "sp_1", task: task), decision: .approve)
        let requests = await seen.seen
        XCTAssertTrue(requests.isEmpty)
        let answers = await api.spawnAnswers
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers.first?.approval)
    }

    func test_spawn_withNoItem_buildsTheSubjectFromTheCardAndTheBoxesStoredName() async throws {
        let api = ConsentAPI()
        await api.set(boxes: [DeviceDTO(id: 5, kind: "agent", name: "box-a", createdAt: 0, cursor: 0, lag: 0,
                                        lastSeenAt: nil, isSelf: false, isProtected: true)])
        let seen = Requests()
        try await service(api, seen).answerAgentSpawn(
            SpawnAsk(requestID: "sp_1", targetDeviceID: 5, workdir: "/home/alice/project", task: task), decision: .approve)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.subject,
                       ["op": "spawn", "ask": "sp_1", "box": "box-a", "workdir": "/home/alice/project", "decision": "approve",
                        "task_sha256": "98fa3fff3b511b6deb8e13945bc02a59b1833ea712caf83df7e4ec77d94965e1"])
    }

    func test_decline_isNeverSigned() async throws {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "w", task: task)
        await api.set(items: [consentItem(link: "matron://consent/spawn/sp_1", subject: subject)])
        let seen = Requests()
        try await service(api, seen).answerAgentSpawn(requestID: "sp_1", decision: .deny)
        let requests = await seen.seen
        XCTAssertTrue(requests.isEmpty)
        let answers = await api.spawnAnswers
        XCTAssertEqual(answers.first?.decision, .deny)
        XCTAssertNil(answers.first?.approval)
    }

    func test_chatInviteToAProtectedBox_signsTheItemsSubject_andChecksTheMessage() async throws {
        let api = ConsentAPI()
        let subject = ApprovalSubjects.chat(roomID: "r1", targetDeviceID: 5, box: "box-a", justification: "Need the logs")
        await api.set(items: [consentItem(link: "matron://consent/chat/r1/5", subject: subject)])
        let seen = Requests()
        try await service(api, seen).answerAgentChat(
            ChatAsk(roomID: "r1", targetDeviceID: 5, justification: "Need the logs"), decision: .approve)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.subject, subject)
        let answers = await api.chatAnswers
        XCTAssertEqual(answers.first?.approval, approval)

        for justification in ["A different message", nil] as [String?] {
            do {
                // A message that is not the subject's, or none known at all.
                try await service(api, Requests()).answerAgentChat(
                    ChatAsk(roomID: "r1", targetDeviceID: 5, justification: justification), decision: .approve)
                XCTFail("expected a refusal")
            } catch {
                guard case ApprovalError.subjectMismatch = error else { return XCTFail("\(error)") }
            }
        }
    }
}
