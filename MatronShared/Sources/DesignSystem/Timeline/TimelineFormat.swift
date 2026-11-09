import Foundation
import MatronModels

/// The Projects timeline's words: week names, ledes and the lines on a
/// story or a list row. Sentences, not counts.
public enum TimelineFormat {
    public static let worthALook = "WORTH A LOOK"
    public static let earlierWeeks = "Earlier weeks ›"
    public static let wentQuiet = "Went quiet"
    public static let openLong = "Open a long time"
    public static let finished = "Finished"
    public static let quietLede = "These were moving, then stopped without being finished."
    public static let longLede = "These have been open for three weeks or more."
    public static let emptyLede = "Nothing moved this week."
    public static let askAction = "Ask the Coordinator what to do with it"
    public static let needsYouPrefix = "Needs you: "
    /// A story the journal gave no sentence (the project moved without a milestone).
    public static let movedSentence = "Moved this week."
    public static let chartCaption = "last 7 weeks"
    /// Bars in a list row's activity chart.
    public static let chartWeeks = 7

    // MARK: Weeks

    /// "2 – 8 Nov", "26 Oct – 1 Nov"; nil for a key that is not a date.
    public static func shortRange(_ week: String) -> String? {
        range(week, month: "MMM")
    }

    /// "2 – 8 November": the page's dates.
    public static func longRange(_ week: String) -> String? {
        range(week, month: "MMMM")
    }

    /// The journal lists weeks newest first from the current one, so the
    /// first is this week and the second last week.
    public static func sidebarTitle(index: Int, week: String) -> String {
        switch index {
        case 0: return "This week"
        case 1: return "Last week"
        default: return shortRange(week) ?? week
        }
    }

    /// The page title: the week still being written is this week, the one
    /// that ended within the last seven days last week, any other its dates.
    public static func pageTitle(_ week: TimelineWeek, now: Date) -> String {
        if !week.final { return "This week" }
        if endedLastWeek(week, now: now) { return "Last week" }
        return longRange(week.week) ?? week.week
    }

    /// The dates beside a "This week" / "Last week" title; nil when the
    /// title is the dates.
    public static func pageDates(_ week: TimelineWeek, now: Date) -> String? {
        !week.final || endedLastWeek(week, now: now) ? longRange(week.week) : nil
    }

    private static func endedLastWeek(_ week: TimelineWeek, now: Date) -> Bool {
        week.final && now < week.end.addingTimeInterval(7 * 86_400)
    }

    /// The week's written lede, else the sidebar's sentence; a week where
    /// nothing moved says so calmly.
    public static func lede(_ week: TimelineWeek, sentence: String?) -> String? {
        if let lede = week.lede?.trimmingCharacters(in: .whitespacesAndNewlines), !lede.isEmpty { return lede }
        if week.stories.isEmpty && week.also.isEmpty { return emptyLede }
        guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return nil }
        return sentence
    }

    public static func alsoLine(_ count: Int) -> String {
        "Also this week: \(count) smaller job\(count == 1 ? "" : "s") ›"
    }

    // MARK: Stories

    public static func sentence(_ story: TimelineStory) -> String {
        guard let sentence = story.sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else {
            return movedSentence
        }
        return sentence
    }

    /// What follows "Needs you: ": the first item waiting, and how many more.
    public static func needsYou(_ story: TimelineStory) -> String? {
        guard let first = story.needsYou.first else { return nil }
        let more = story.needsYou.count - 1
        return more > 0 ? "\(first.title), and \(more) more" : first.title
    }

    // MARK: Lists

    /// "Last moved 19 days ago"; under a day, the dashboard's relative time.
    public static func lastMoved(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        return "Last moved \(daysAgo(date, now: now))"
    }

    /// "19 days ago", "yesterday", under a day "3h ago".
    public static func daysAgo(_ date: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return MissionsDashboardFormat.relative(date, now: now)
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    /// The newest `chartWeeks` of a row's weekly moves (oldest first),
    /// padded with quiet weeks at the old end.
    public static func chartBars(_ weekly: [Int]) -> [Int] {
        let recent = Array(weekly.suffix(chartWeeks))
        return Array(repeating: 0, count: chartWeeks - recent.count) + recent
    }

    public static func moreRows(_ count: Int) -> String? {
        count > 0 ? "And \(count) more." : nil
    }

    // MARK: Project story

    public static let comingUpPrefix = "Coming up:"
    public static let allDetails = "All details"
    public static let openItem = "Open"
    /// The gallery's first two week headings; older weeks are their dates.
    public static let thisWeek = "This week"
    public static let lastWeek = "Last week"

    /// The page's one sentence: the Coordinator's status, else the goal,
    /// else the newest milestone's title; nil when there is none.
    public static func storySentence(_ page: ProjectPageModel) -> String? {
        let newest = (page.recentMilestones + page.milestonesPage.rows.map(\.milestone))
            .max { $0.createdAt < $1.createdAt }?.title
        for text in [page.project.status, page.project.body, newest] {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// What follows "Coming up:": the first three open tasks as one
    /// sentence ("a rehearsal, the switch-over, then launch."), leaving out
    /// what already waits on the user; nil when there are none.
    public static func comingUp(_ page: ProjectPageModel) -> String? {
        let waiting = Set(page.needsYou.map(\.id))
        let titles = page.openItems
            .filter { $0.kind == .task && $0.state == .open && !waiting.contains($0.id) }
            .prefix(3)
            .map { phrase($0.title) }
            .filter { !$0.isEmpty }
        guard let last = titles.last else { return nil }
        let head = titles.dropLast().joined(separator: ", ")
        return (head.isEmpty ? last : "\(head), then \(last)") + "."
    }

    /// A title as part of a sentence: one line, no closing full stop, and a
    /// capitalised first word in lower case ("Launch" → "launch"), leaving
    /// "I" and words that are capitals throughout or mixed ("CDN", "iOS")
    /// alone.
    static func phrase(_ title: String) -> String {
        var text = ProjectsFormat.oneLine(title).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        let word = text.prefix { !$0.isWhitespace }
        guard let first = word.first, first.isUppercase, word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’"),
              word.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// A gallery tile's caption: the file's name without its extension,
    /// else the title of the item it was posted on; nil when neither is
    /// known.
    public static func galleryCaption(_ file: ProjectFile, items: [TrackerItem]) -> String? {
        if let name = file.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let bare = (name as NSString).deletingPathExtension
            return bare.isEmpty ? name : bare
        }
        guard case .item(let num) = file.source,
              let title = items.first(where: { $0.num == num })?.title, !title.isEmpty else { return nil }
        return ProjectsFormat.oneLine(title)
    }

    /// "This week", "Last week", else "19 – 25 Oct", for the week starting
    /// `weekStart` in `calendar`'s zone.
    public static func galleryWeekTitle(weekStart: Date, thisWeekStart: Date, calendar: Calendar) -> String {
        if weekStart == thisWeekStart { return thisWeek }
        if let previous = calendar.date(byAdding: .day, value: -7, to: thisWeekStart), weekStart == previous {
            return lastWeek
        }
        let day = calendar.dateComponents([.year, .month, .day], from: weekStart)
        let key = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return shortRange(key) ?? key
    }

    /// "Tuesday": the day under a gallery tile's caption.
    public static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    // MARK: Private

    /// Week keys are the Monday's date in the user's zone, so the days are
    /// read off the key itself, never shifted by this device's zone.
    private static let keyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let keyParser: DateFormatter = formatter("yyyy-MM-dd")
    private static let dayFormatter: DateFormatter = formatter("d")
    private static let dayMonthShort: DateFormatter = formatter("d MMM")
    private static let dayMonthLong: DateFormatter = formatter("d MMMM")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = keyCalendar
        formatter.timeZone = keyCalendar.timeZone
        // The copy is English; a fixed locale keeps "2 – 8 Nov" whatever the device's.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static func range(_ week: String, month: String) -> String? {
        guard let start = keyParser.date(from: week),
              let end = keyCalendar.date(byAdding: .day, value: 6, to: start) else { return nil }
        let full = month == "MMM" ? dayMonthShort : dayMonthLong
        let sameMonth = keyCalendar.component(.month, from: start) == keyCalendar.component(.month, from: end)
        let first = sameMonth ? dayFormatter.string(from: start) : full.string(from: start)
        return "\(first) – \(full.string(from: end))"
    }
}
