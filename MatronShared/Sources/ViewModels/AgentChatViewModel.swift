import Foundation
import MatronJournal

/// The one call that resolves a consent card. Split out from
/// `AgentChatProviding` because `ChatViewModel` answers cards inline in the
/// timeline and has no business listing anything.
public protocol AgentChatAnswering: Sendable {
    @discardableResult
    func answerAgentChat(
        roomID: String, targetDeviceID: Int64, decision: AgentChatDecision
    ) async throws -> Bool
}

/// The agent-chat slice of `JournalAPI`, extracted so the settings screen can
/// be tested against a fake without a URL session. `JournalAPI` conforms
/// as-is.
public protocol AgentChatProviding: AgentChatAnswering {
    func agentChatPending() async throws -> [AgentChatPendingDTO]
}

extension JournalAPI: AgentChatProviding {}

/// Drives the Agent chats settings screen: the requests still waiting on the
/// user. Every ask waits for an answer — there is no standing consent to
/// list beside them.
///
/// Pull-based like `DevicesViewModel` — the list is not a journal event, so
/// callers `refresh()` on screen enter and the model re-fetches after every
/// mutation.
@Observable @MainActor
public final class AgentChatViewModel {
    public private(set) var pending: [AgentChatPendingDTO] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Rows with a call in flight, keyed by `AgentChatPendingDTO.id`, so one
    /// row's spinner doesn't disable the whole screen.
    public private(set) var busyIDs: Set<String> = []

    /// `false` on a server that predates the agent-chat endpoints, so the
    /// screen can say so instead of showing a permanently empty list.
    public private(set) var isSupported = true

    /// `false` until the first successful load. The screens gate their
    /// "nothing here" copy on it: `refresh()` runs from `.task`, i.e. after
    /// the first frame, so an unguarded empty list tells the user they have no
    /// pending requests a beat before their pending requests arrive.
    public private(set) var hasLoaded = false

    private let api: any AgentChatProviding

    public init(api: any AgentChatProviding) {
        self.api = api
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            pending = try await api.agentChatPending().sorted { $0.createdAt > $1.createdAt }
            hasLoaded = true
            isSupported = true
            errorMessage = nil
        } catch JournalAPIError.notFound {
            // No such route: this journal predates agent chat. Say so once
            // rather than showing a permanently empty list as if the user
            // simply had nothing pending.
            isSupported = false
            hasLoaded = true
            pending = []
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
    public func answer(_ row: AgentChatPendingDTO, decision: AgentChatDecision) async {
        guard !busyIDs.contains(row.id) else { return }
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        do {
            do {
                try await api.answerAgentChat(
                    roomID: row.roomID, targetDeviceID: row.targetDeviceID,
                    decision: decision)
            } catch JournalAPIError.conflict {
                // Already resolved elsewhere — fall through to the refresh.
            }
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = "Couldn't answer that request — \(Self.describe(error))"
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
