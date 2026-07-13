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

    public init(
        id: String,
        title: String,
        bot: BotIdentity,
        lastActivity: Date?,
        unreadCount: Int,
        snippet: String = ""
    ) {
        self.id = id
        self.title = title
        self.bot = bot
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
        self.snippet = snippet
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
