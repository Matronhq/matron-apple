import Foundation
import MatronJournal
import MatronModels

/// A tap that needs a signature: a button on a step-up item or follow-up
/// question, or Approve on a consent item aimed at a protected box.
///
/// Such a tap never goes through the offline outbox. A nonce lives five
/// minutes and a signature must not wait on disk, so it is confirmed,
/// signed and posted at once, and the item is refetched.
public enum StepUpTap {
    /// What a tap on `label` must be signed with, or nil when the journal
    /// asks for no signature on it. `comment` is the follow-up question
    /// whose button was tapped; nil for the item's own buttons.
    public static func request(item: TrackerItem, comment: TrackerComment?, label: String) -> ApprovalRequest? {
        let reference = "#\(item.num)"
        if item.labels.contains(TrackerItem.consentLabel) {
            // A consent ask is answered with a `consent` statement over the
            // subject the journal published, and only its yes is signed.
            guard item.stepUp, comment == nil, TrackerItem.isAffirmativeAnswer(label) else { return nil }
            return ApprovalRequest(kind: .consent, subject: item.subject ?? [:], headline: item.title,
                                   reference: reference, button: label, detail: item.body)
        }
        guard item.stepUp || comment?.stepUp == true else { return nil }
        // The asking comment's own subject when that comment is step-up,
        // else the item's; none is signed as `{}`.
        let subject = (comment?.stepUp == true ? comment?.subject : item.subject) ?? [:]
        let digest = comment.map { PromptDigest.comment(body: $0.body) }
            ?? PromptDigest.item(title: item.title, body: item.body)
        return ApprovalRequest(
            kind: .itemTap(itemID: item.id, num: item.num, replyTo: comment?.id, action: label, promptDigest: digest),
            subject: subject, headline: item.title, reference: reference, button: label,
            detail: comment?.body ?? item.body)
    }

    public enum Outcome: Equatable, Sendable {
        /// No signature applies (not step-up, or the account has no key):
        /// send the tap the ordinary way.
        case unsigned
        /// Signed and accepted.
        case sent
        /// The user backed out; nothing was sent.
        case cancelled
        /// Not sent, or refused; the sentence says why.
        case failed(String)
    }

    /// Signs and posts the tap when it needs a signature.
    ///
    /// The item is read again first, so what is shown and hashed is the
    /// journal's current text. A `mismatch` (the question was edited while
    /// the user was signing) refetches it once more, so the next tap signs
    /// the new words.
    @MainActor
    public static func send(item: TrackerItem, comment: TrackerComment?, label: String,
                            api: any ItemsProviding, sync: any ItemsSyncing, signer: ApprovalSigner?) async -> Outcome {
        guard request(item: item, comment: comment, label: label) != nil else { return .unsigned }
        guard let signer else {
            return .failed(ApprovalError.noKeyOnThisDevice.localizedDescription)
        }
        do {
            // The current words: the digest must be over the stored text.
            let fresh = try await api.item(id: item.id)
            let freshComment = comment.flatMap { asked in fresh.comments.first { $0.id == asked.id } }
            guard let request = request(item: fresh.item, comment: comment == nil ? nil : freshComment, label: label),
                  comment == nil || freshComment != nil else {
                // No longer step-up (the mark was lowered): an ordinary tap.
                await sync.refreshItem(id: item.id)
                return .unsigned
            }
            guard let approval = try await signer(request) else { return .unsigned }
            _ = try await api.tapItem(id: item.id, action: label, replyTo: comment?.id, approval: approval,
                                      idempotencyKey: UUID().uuidString)
            await sync.refreshItem(id: item.id)
            return .sent
        } catch ApprovalKeyFailure.cancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            await sync.refreshItem(id: item.id)
            if case JournalAPIError.approvalInvalid(let reason) = error, reason == "mismatch" {
                return .failed("The question changed while you were approving it. Read it again, then approve.")
            }
            if case JournalAPIError.transport = error {
                return .failed("This answer needs a signature and can't wait for a connection. \(error.localizedDescription)")
            }
            return .failed(error.localizedDescription)
        }
    }
}

/// A spawn ask as its card shows it: what the app needs to check the
/// subject it signs against what the user read.
public struct SpawnAsk: Equatable, Sendable {
    public var requestID: String
    public var targetDeviceID: Int64?
    public var workdir: String?
    public var task: String?
    public var headline: String?

    public init(requestID: String, targetDeviceID: Int64? = nil, workdir: String? = nil, task: String? = nil,
                headline: String? = nil) {
        self.requestID = requestID; self.targetDeviceID = targetDeviceID; self.workdir = workdir
        self.task = task; self.headline = headline
    }
}

/// A chat invite or join ask, as its card shows it.
public struct ChatAsk: Equatable, Sendable {
    public var roomID: String
    public var targetDeviceID: Int64
    public var justification: String?
    public var headline: String?

    public init(roomID: String, targetDeviceID: Int64, justification: String? = nil, headline: String? = nil) {
        self.roomID = roomID; self.targetDeviceID = targetDeviceID
        self.justification = justification; self.headline = headline
    }
}

/// What the consent service needs from the journal.
public protocol ConsentSigningAPI: Sendable {
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage
    func devices() async throws -> [DeviceDTO]
    func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision, approval: SignedApproval?) async throws
    @discardableResult
    func answerAgentChat(roomID: String, targetDeviceID: Int64, decision: AgentChatDecision,
                         approval: SignedApproval?) async throws -> Bool
    func agentChatPending() async throws -> [AgentChatPendingDTO]
}

extension JournalAPI: ConsentSigningAPI {}

/// Answers spawn and chat consent cards, signing an approval when the ask
/// is aimed at a protected box and the account has an approval key.
///
/// The subject signed is the one the journal published on the ask's
/// consent item. Before signing, the app checks it against what the card
/// showed: the ask's id, and the hash of the task or message the user
/// read. With no item to read (filing it is best-effort) a spawn's subject
/// is built from the card and the box's stored name. A decline is never
/// signed.
public struct SigningConsentService: AgentSpawnAnswering, AgentChatProviding {
    private let api: any ConsentSigningAPI
    private let signer: ApprovalSigner

    public init(api: any ConsentSigningAPI, signer: @escaping ApprovalSigner) {
        self.api = api
        self.signer = signer
    }

    public func agentChatPending() async throws -> [AgentChatPendingDTO] {
        try await api.agentChatPending()
    }

    public func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision) async throws {
        try await answerAgentSpawn(SpawnAsk(requestID: requestID), decision: decision)
    }

    public func answerAgentSpawn(_ ask: SpawnAsk, decision: AgentSpawnDecision) async throws {
        guard decision == .approve else {
            return try await api.answerAgentSpawn(requestID: ask.requestID, decision: decision, approval: nil)
        }
        let approval = try await spawnApproval(ask)
        try await api.answerAgentSpawn(requestID: ask.requestID, decision: .approve, approval: approval)
    }

    @discardableResult
    public func answerAgentChat(roomID: String, targetDeviceID: Int64, decision: AgentChatDecision) async throws -> Bool {
        try await answerAgentChat(ChatAsk(roomID: roomID, targetDeviceID: targetDeviceID), decision: decision)
    }

    @discardableResult
    public func answerAgentChat(_ ask: ChatAsk, decision: AgentChatDecision) async throws -> Bool {
        guard decision == .approve else {
            return try await api.answerAgentChat(roomID: ask.roomID, targetDeviceID: ask.targetDeviceID,
                                                 decision: decision, approval: nil)
        }
        let approval = try await chatApproval(ask)
        return try await api.answerAgentChat(roomID: ask.roomID, targetDeviceID: ask.targetDeviceID,
                                             decision: .approve, approval: approval)
    }

    // MARK: Subjects

    /// The open consent item that stands for `link`, if the journal filed
    /// one.
    private func consentItem(_ link: ConsentLink) async -> TrackerItem? {
        var query = ItemsListQuery()
        query.label = TrackerItem.consentLabel
        query.state = .open
        query.limit = 200
        guard let page = try? await api.listItems(query) else { return nil }
        return page.items.first { $0.links.contains { $0.url == link.url } }
    }

    private func spawnApproval(_ ask: SpawnAsk) async throws -> SignedApproval? {
        let subject: ApprovalSubject
        var detail = ask.task
        var reference: String?
        var headline = ask.headline ?? "Start a session"
        if let item = await consentItem(.spawn(requestID: ask.requestID)) {
            guard item.stepUp else { return nil }
            subject = item.subject ?? [:]
            reference = "#\(item.num)"
            headline = item.title
            if detail == nil { detail = item.body }
        } else {
            // No item to read the subject from: build it from the card and
            // the box's stored name, when the box is protected.
            guard let targetID = ask.targetDeviceID, let workdir = ask.workdir, let task = ask.task,
                  let box = try await api.devices().first(where: { $0.id == targetID }), box.isProtected
            else { return nil }
            subject = ApprovalSubjects.spawn(ask: ask.requestID, box: box.name, workdir: workdir, task: task)
        }
        try Self.check(subject, op: "spawn", ask: ask.requestID)
        if let task = ask.task, subject["task_sha256"] != ApprovalSubjects.sha256(task) {
            throw ApprovalError.subjectMismatch("The task on this request is not the task that would be approved. Reload the request and read it again.")
        }
        return try await signer(ApprovalRequest(kind: .consent, subject: subject, headline: headline,
                                                reference: reference, button: "Approve", detail: detail))
    }

    private func chatApproval(_ ask: ChatAsk) async throws -> SignedApproval? {
        guard let item = await consentItem(.chat(roomID: ask.roomID, deviceID: ask.targetDeviceID)), item.stepUp else {
            // Not aimed at a protected box, or no item to read the subject
            // from: sent unsigned, and the journal says so if it needed one.
            return nil
        }
        let subject = item.subject ?? [:]
        try Self.check(subject, op: "chat", ask: "\(ask.roomID)/\(ask.targetDeviceID)")
        if let message = ask.justification, subject["message_sha256"] != ApprovalSubjects.sha256(message) {
            throw ApprovalError.subjectMismatch("The message on this request is not the one that would be approved. Reload the request and read it again.")
        }
        return try await signer(ApprovalRequest(kind: .consent, subject: subject, headline: item.title,
                                                reference: "#\(item.num)", button: "Approve",
                                                detail: ask.justification ?? item.body))
    }

    /// The published subject must be about this ask, and an approval.
    private static func check(_ subject: ApprovalSubject, op: String, ask: String) throws {
        guard subject["op"] == op, subject["ask"] == ask, subject["decision"] == "approve" else {
            throw ApprovalError.subjectMismatch("This request's details don't match what would be approved. Reload it and read it again.")
        }
    }
}
