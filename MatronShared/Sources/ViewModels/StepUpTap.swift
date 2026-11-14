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
        guard item.consentKind == nil else { return nil }
        guard item.stepUp || comment?.stepUp == true else { return nil }
        // The asking comment's own subject when that comment is step-up,
        // else the item's; none is signed as `{}`.
        let subject = (comment?.stepUp == true ? comment?.subject : item.subject) ?? [:]
        let digest = comment.map { PromptDigest.comment(body: $0.body) }
            ?? PromptDigest.item(title: item.title, body: item.body)
        return ApprovalRequest(
            kind: .itemTap(itemID: item.id, num: item.num, replyTo: comment?.id, action: label, promptDigest: digest),
            subject: subject, headline: item.title, reference: "#\(item.num)", button: label,
            detail: comment?.body ?? item.body)
    }

    /// Whether a tap on `label` may need a signature, judged from the
    /// cached item: enough to decide between the outbox and `send`, which
    /// reads the item again before anything is signed.
    public static func mayNeedSignature(item: TrackerItem, comment: TrackerComment?, label: String) -> Bool {
        if item.stepUp || comment?.stepUp == true { return true }
        return false
    }

    /// What a consent item's Approve signs. A consent ask is answered with
    /// a `consent` statement over the subject the journal published, and
    /// only its yes is signed.
    ///
    /// The subject names the work by a hash, which nobody can read. So the
    /// app signs only when it holds the very text that hash is of and has
    /// shown it: `verifiedText` is the spawn's task as its card carries it.
    /// A spawn with no card to hand, and a chat invite (whose message this
    /// path never has), are sent to their cards instead. A file transfer's
    /// subject is the file's own hash and size, shown as they are.
    static func consentRequest(item: TrackerItem, label: String, verifiedText: String?) throws -> ApprovalRequest? {
        guard let kind = item.consentKind, item.stepUp, TrackerItem.isAffirmativeAnswer(label) else { return nil }
        let subject = item.subject ?? [:]
        guard subject["op"] == kind, subject["decision"] == "approve" else {
            throw ApprovalError.subjectMismatch("This request's details don't match what would be approved. Reload it and read it again.")
        }
        var detail: String?
        switch kind {
        case "spawn":
            guard let task = verifiedText else {
                throw ApprovalError.subjectMismatch("Open this request and approve it from its card, where the task is shown in full.")
            }
            guard subject["task_sha256"] == ApprovalSubjects.sha256(task) else {
                throw ApprovalError.subjectMismatch("The task on this request is not the task that would be approved. Reload the request and read it again.")
            }
            detail = task
        case "transfer":
            detail = item.body
        default:
            throw ApprovalError.subjectMismatch("Approve this request from its card in the conversation, or in Settings ▸ Agent Chats, where its message is shown in full.")
        }
        return ApprovalRequest(kind: .consent, subject: subject, headline: item.title, reference: "#\(item.num)",
                               button: label, detail: detail)
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
    public static func send(item: TrackerItem, comment: TrackerComment?, label: String, verifiedText: String? = nil,
                            api: any ItemsProviding, sync: any ItemsSyncing, signer: ApprovalSigner?) async -> Outcome {
        guard mayNeedSignature(item: item, comment: comment, label: label) else { return .unsigned }
        guard let signer else {
            return .failed(ApprovalError.noKeyOnThisDevice.localizedDescription)
        }
        do {
            // The current words: the digest must be over the stored text,
            // and only a fresh read says whether this is a consent ask.
            let fresh = try await api.item(id: item.id)
            let request: ApprovalRequest?
            if fresh.item.consentKind != nil {
                request = comment == nil ? try consentRequest(item: fresh.item, label: label, verifiedText: verifiedText) : nil
            } else if let comment {
                request = fresh.comments.first { $0.id == comment.id }
                    .flatMap { Self.request(item: fresh.item, comment: $0, label: label) }
            } else {
                request = Self.request(item: fresh.item, comment: nil, label: label)
            }
            guard let request else {
                // No longer step-up (the mark was lowered), a decline, or
                // the asking comment has gone: an ordinary tap.
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
    /// The message the user was shown; `""` when the ask carried none, and
    /// `nil` only when the caller does not know it (nothing is signed then).
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

    /// The open consent item of `kind` that stands for `link`, if the
    /// journal filed one. `kind` is the journal's own mark on the item, so
    /// an item an agent filed with the same link is never taken for it.
    private func consentItem(_ link: ConsentLink, kind: String) async -> TrackerItem? {
        var query = ItemsListQuery()
        query.label = TrackerItem.consentLabel
        query.state = .open
        query.limit = 200
        var seen: Set<String> = []
        // Every page: the ask may not be among the first 200.
        for _ in 0..<20 {
            guard let page = try? await api.listItems(query) else { return nil }
            if let item = page.items.first(where: { item in
                item.consentKind == kind && item.links.contains { $0.url == link.url }
            }) { return item }
            guard let next = page.nextCursor, seen.insert(next).inserted else { return nil }
            query.cursor = next
        }
        return nil
    }

    private static let openTheCard = "Open this request and approve it from its card, where it is shown in full."

    private func spawnApproval(_ ask: SpawnAsk) async throws -> SignedApproval? {
        let subject: ApprovalSubject
        var reference: String?
        var headline = ask.headline ?? "Start a session"
        if let item = await consentItem(.spawn(requestID: ask.requestID), kind: "spawn") {
            guard item.stepUp else { return nil }
            subject = item.subject ?? [:]
            reference = "#\(item.num)"
            headline = item.title
        } else {
            // No item to read the subject from: build it from the card and
            // the box's stored name, when the box is protected.
            guard let targetID = ask.targetDeviceID, let workdir = ask.workdir, let task = ask.task,
                  let box = try await api.devices().first(where: { $0.id == targetID }), box.isProtected
            else { return nil }
            subject = ApprovalSubjects.spawn(ask: ask.requestID, box: box.name, workdir: workdir, task: task)
        }
        try Self.check(subject, op: "spawn", ask: ask.requestID)
        // The subject names the task by its hash. Only the task itself,
        // as the card showed it, may stand behind a signature.
        guard let task = ask.task else { throw ApprovalError.subjectMismatch(Self.openTheCard) }
        guard subject["task_sha256"] == ApprovalSubjects.sha256(task) else {
            throw ApprovalError.subjectMismatch("The task on this request is not the task that would be approved. Reload the request and read it again.")
        }
        if let workdir = ask.workdir, !Self.matches(subject, "workdir", workdir) {
            throw ApprovalError.subjectMismatch("The folder on this request is not the folder that would be approved. Reload the request and read it again.")
        }
        return try await signer(ApprovalRequest(kind: .consent, subject: subject, headline: headline,
                                                reference: reference, button: "Approve", detail: task))
    }

    private func chatApproval(_ ask: ChatAsk) async throws -> SignedApproval? {
        guard let item = await consentItem(.chat(roomID: ask.roomID, deviceID: ask.targetDeviceID), kind: "chat"),
              item.stepUp else {
            // Not aimed at a protected box, or no item to read the subject
            // from: sent unsigned, and the journal says so if it needed one.
            return nil
        }
        let subject = item.subject ?? [:]
        try Self.check(subject, op: "chat", ask: "\(ask.roomID)/\(ask.targetDeviceID)")
        guard let message = ask.justification else { throw ApprovalError.subjectMismatch(Self.openTheCard) }
        guard subject["message_sha256"] == ApprovalSubjects.sha256(message) else {
            throw ApprovalError.subjectMismatch("The message on this request is not the one that would be approved. Reload the request and read it again.")
        }
        return try await signer(ApprovalRequest(kind: .consent, subject: subject, headline: item.title,
                                                reference: "#\(item.num)", button: "Approve",
                                                detail: message.isEmpty ? item.body : message))
    }

    /// Whether the subject's `name` (or its hashed form, for a long value)
    /// is `value`.
    private static func matches(_ subject: ApprovalSubject, _ name: String, _ value: String) -> Bool {
        if let plain = subject[name] { return plain == value }
        return subject[name + "_sha256"] == ApprovalSubjects.sha256(value)
    }

    /// The published subject must be about this ask, and an approval.
    private static func check(_ subject: ApprovalSubject, op: String, ask: String) throws {
        guard subject["op"] == op, subject["ask"] == ask, subject["decision"] == "approve" else {
            throw ApprovalError.subjectMismatch("This request's details don't match what would be approved. Reload it and read it again.")
        }
    }
}
