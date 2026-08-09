import Foundation
import MatronJournal

/// The one call that resolves a consent card. Split out from
/// `AgentChatProviding` because `ChatViewModel` answers cards inline in the
/// timeline and has no business listing or revoking anything.
public protocol AgentChatAnswering: Sendable {
    @discardableResult
    func answerAgentChat(
        roomID: String, targetDeviceID: Int64,
        decision: AgentChatDecision, alwaysAllow: Bool
    ) async throws -> Bool
}

/// The agent-chat slice of `JournalAPI`, extracted so the settings screen can
/// be tested against a fake without a URL session. `JournalAPI` conforms
/// as-is.
public protocol AgentChatProviding: AgentChatAnswering {
    func agentChatPending() async throws -> [AgentChatPendingDTO]
    func agentChatAllowances() async throws -> [AgentChatAllowanceDTO]
    func revokeAgentChatAllowance(fromDeviceID: Int64, targetDeviceID: Int64) async throws
}

extension JournalAPI: AgentChatProviding {}

/// Drives the Agent chats settings screen: requests still waiting on the
/// user, and the standing allowances that let future requests through
/// without asking.
///
/// Pull-based like `DevicesViewModel` — neither list is a journal event, so
/// callers `refresh()` on screen enter and the model re-fetches after every
/// mutation.
@Observable @MainActor
public final class AgentChatViewModel {
    public private(set) var pending: [AgentChatPendingDTO] = []
    public private(set) var allowances: [AgentChatAllowanceDTO] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Rows with a call in flight, keyed by `AgentChatPendingDTO.id` /
    /// `AgentChatAllowanceDTO.id`, so one row's spinner doesn't disable the
    /// whole screen.
    public private(set) var busyIDs: Set<String> = []

    /// `false` on a server that predates the agent-chat endpoints, so the
    /// screen can say so instead of showing two permanently empty lists.
    public private(set) var isSupported = true

    /// `false` until the first successful load. The screens gate their
    /// "nothing here" copy on it: `refresh()` runs from `.task`, i.e. after
    /// the first frame, so an unguarded empty list tells the user they have no
    /// pending requests a beat before their pending requests appear.
    public private(set) var hasLoaded = false

    private let api: any AgentChatProviding

    public init(api: any AgentChatProviding) {
        self.api = api
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Both calls first, both assignments after: a partial failure must
            // not leave one list fresh beside the other's stale contents, next
            // to an error saying the load failed. Sequential rather than
            // concurrent because two round trips on screen entry is nothing.
            let freshPending = try await api.agentChatPending()
            let freshAllowances = try await api.agentChatAllowances()
            pending = freshPending.sorted { $0.createdAt > $1.createdAt }
            allowances = freshAllowances.sorted { $0.createdAt > $1.createdAt }
            hasLoaded = true
            isSupported = true
            errorMessage = nil
        } catch JournalAPIError.notFound {
            // No such route: this journal predates agent chat. Say so once
            // rather than showing two permanently empty lists as if the user
            // simply had nothing pending.
            isSupported = false
            hasLoaded = true
            pending = []
            allowances = []
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load agent chats — \(Self.describe(error))"
        }
    }

    /// Answers a parked request. `.conflict` means the row stopped awaiting
    /// an answer between the list load and the tap (answered on another
    /// device, or expired) — the decision the user wanted is either already
    /// made or moot, so drop the row rather than showing an error for
    /// something they cannot act on.
    public func answer(_ row: AgentChatPendingDTO, decision: AgentChatDecision, alwaysAllow: Bool = false) async {
        guard !busyIDs.contains(row.id) else { return }
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        do {
            do {
                try await api.answerAgentChat(
                    roomID: row.roomID, targetDeviceID: row.targetDeviceID,
                    decision: decision, alwaysAllow: alwaysAllow)
            } catch JournalAPIError.conflict {
                // Already resolved elsewhere — fall through to the refresh.
            }
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "Couldn't answer that request — \(Self.describe(error))"
        }
    }

    /// Withdraws a standing allowance, so that pair has to ask again.
    public func revoke(_ allowance: AgentChatAllowanceDTO) async {
        guard !busyIDs.contains(allowance.id) else { return }
        busyIDs.insert(allowance.id)
        defer { busyIDs.remove(allowance.id) }
        do {
            try await api.revokeAgentChatAllowance(
                fromDeviceID: allowance.fromDeviceID, targetDeviceID: allowance.targetDeviceID)
            // Reflect it locally first: a failed refetch leaves `allowances`
            // untouched and the revoked row would linger, looking live.
            allowances.removeAll { $0.id == allowance.id }
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "Couldn't revoke that allowance — \(Self.describe(error))"
        }
    }

    static func describe(_ error: Error) -> String {
        if case JournalAPIError.transport = error { return "check your connection and try again." }
        return "the server said no (\(error))."
    }
}

extension AgentChatPendingDTO {
    /// One line stating what is being asked, in the user's terms. A join
    /// self-targets (the requester IS the target), which is what tells the
    /// two apart without a separate field.
    public var headline: String {
        initiatorDeviceID == targetDeviceID
            ? "\(requesterLabel) wants to join a chat."
            : "\(requesterLabel) wants to start a chat with \(targetLabel)."
    }

    public func ageText(now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
