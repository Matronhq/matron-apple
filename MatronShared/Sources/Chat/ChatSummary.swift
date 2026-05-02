import Foundation
import MatronModels

public struct ChatSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let bot: BotIdentity
    public let lastActivity: Date
    public let unreadCount: Int

    public init(
        id: String,
        title: String,
        bot: BotIdentity,
        lastActivity: Date,
        unreadCount: Int
    ) {
        self.id = id
        self.title = title
        self.bot = bot
        self.lastActivity = lastActivity
        self.unreadCount = unreadCount
    }
}

public enum ChatRecencyGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 days"
    case earlier = "Earlier"

    public static func bucket(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> ChatRecencyGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        return date >= sevenDaysAgo ? .lastSevenDays : .earlier
    }
}
