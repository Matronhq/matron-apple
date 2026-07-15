import Foundation
import MatronModels

public struct ChatSummary: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let bot: BotIdentity
    /// `nil` when the room's timeline hasn't been hydrated yet — e.g. a Phase
    /// 1 sliding-sync snapshot before any timeline events have been pulled.
    /// UI should hide the relative-time label and grouping when nil.
    public let lastActivity: Date?
    public let unreadCount: Int
    /// One-line preview of the newest message (the server/store `snippet`).
    /// Empty when the conversation has no messages yet — rows hide the
    /// preview line rather than showing a blank.
    public let snippet: String
    /// The parent conversation's id when this is a subagent child chat,
    /// else `nil`. Immutable server-side (once a child, always a child).
    /// Children never appear in the main chat list — they are reachable
    /// only through their parent's running-subagent strip — so the chat-
    /// list query filters `parentConvoID == nil`. Carried here so any
    /// summary consumer can defend in depth (no badges / notifications
    /// for children) alongside the server's own silence rule.
    public let parentConvoID: String?

    public init(
        id: String,
        title: String,
        bot: BotIdentity,
        lastActivity: Date?,
        unreadCount: Int,
        snippet: String = "",
        parentConvoID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.bot = bot
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.snippet = snippet
        self.parentConvoID = parentConvoID
    }
}

/// A subagent child conversation as surfaced in its parent's running-
/// subagent strip and the sub-chat switcher menu. Deliberately smaller than
/// `ChatSummary`: the strip needs only identity, a label, and whether the
/// subagent is still running (spinner vs. done). The child's model / context
/// gauge come free from the per-convo session-status stream once the viewer
/// subscribes with `id`, so they're not duplicated here.
public struct SubChatSummary: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// `true` while the subagent is active (`session_state == "running"`),
    /// `false` once finished (`"done"`). The strip shows only running
    /// children; the mini-header renders running/finished state.
    public let isRunning: Bool

    public init(id: String, title: String, isRunning: Bool) {
        self.id = id
        self.title = title
        self.isRunning = isRunning
    }
}

public enum ChatRecencyGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 days"
    case earlier = "Earlier"
    /// Used for chats whose timeline isn't hydrated yet (Phase 1) so we don't
    /// stamp them with a misleading "Today" label.
    case noActivity = "No recent activity"

    public static func bucket(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> ChatRecencyGroup {
        guard let date else { return .noActivity }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        return date >= sevenDaysAgo ? .lastSevenDays : .earlier
    }
}
