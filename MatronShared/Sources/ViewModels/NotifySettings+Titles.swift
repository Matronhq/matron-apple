import Foundation
import MatronJournal

/// The words the Notifications screen and the per-conversation menus use,
/// in one place so the iPhone and the Mac say the same thing.
public extension NotifySettings.Mode {
    var title: String {
        switch self {
        case .coordinator: return "Coordinator mode"
        case .all: return "Every session"
        case .custom: return "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .coordinator: return "Only the Coordinator's turns and anything that needs you"
        case .all: return "Every session's turns and anything that needs you"
        case .custom: return "Your own choice of the events below"
        }
    }
}

public extension NotifySettings.Event {
    var title: String {
        switch self {
        case .prompts: return "Permission prompts & secret requests"
        case .questions: return "Questions and items awaiting me"
        case .notices: return "Things to read"
        case .coordinatorDone: return "Coordinator finished a turn"
        case .otherDone: return "Other sessions finished a turn"
        case .stopped: return "A session stopped or crashed mid-turn"
        case .rooms: return "Agent room messages"
        case .activity: return "Routine activity (batched)"
        }
    }
}

public extension NotifySettings.ConvoLevel {
    var title: String {
        switch self {
        case .all: return "All"
        case .needsMe: return "Needs me"
        case .silent: return "None"
        }
    }
}

public extension NotifyDeviceLevel {
    var title: String {
        switch self {
        case .all: return "All of the above"
        case .needsMe: return "Needs-me only"
        case .off: return "Off"
        }
    }
}

public extension NotifyMuteDuration {
    var title: String {
        switch self {
        case .oneHour: return "Mute for 1 hour"
        case .eightHours: return "Mute for 8 hours"
        case .untilTomorrowMorning: return "Mute until tomorrow 08:00"
        }
    }
}

public extension ConvoNotifyState {
    /// "Default (follow mode)" for no level of its own.
    static let defaultLevelTitle = "Default (follow mode)"

    /// One line for an overrides row: the level and the running mute,
    /// e.g. "Needs me · muted until 14:00".
    func summary(calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let level { parts.append(level.title) }
        if let mutedUntil { parts.append("muted until \(Self.time(mutedUntil, calendar: calendar))") }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The time alone today, with the day otherwise.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        calendar.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
