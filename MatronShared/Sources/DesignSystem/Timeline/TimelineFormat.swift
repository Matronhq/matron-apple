import Foundation
import MatronModels

/// The Projects timeline's words: week names, a card's sentence and marks,
/// and the lines on a list row.
public enum TimelineFormat {
    public static let worthALook = "WORTH A LOOK"
    public static let earlierWeeks = "Earlier weeks"
    /// Drawn after a line that opens something ("Earlier weeks ›"); never
    /// spoken, so labels leave it out and views add it to the text alone.
    public static let opensMark = " ›"
    public static let wentQuiet = "Went quiet"
    public static let openLong = "Open a long time"
    public static let finished = "Finished"
    public static let quietLede = "These were moving, then stopped without being finished."
    public static let longLede = "These have been open for three weeks or more."
    public static let allProjects = "All projects"
    /// A week's page when no project moved in it.
    public static let nothingMoved = "Nothing moved this week."
    /// The all-projects list, read and empty.
    public static let noProjects = "No projects yet."
    /// The finished list, read and empty.
    public static let nothingFinished = "Nothing finished yet."
    public static let askAction = "Ask the Coordinator what to do with it"
    /// Replaces `askAction` on a row once the Ask has gone.
    public static let askedAction = "Asked the Coordinator"
    /// The mark of a card whose project says what comes next.
    public static let nextMark = "→ Next"
    /// Cards on a week's page; projects beyond them sit behind the foot line.
    public static let maxCards = 8
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

    /// The week's cards: its first `maxCards` stories.
    public static func cards(_ week: TimelineWeek) -> [TimelineStory] {
        Array(week.stories.prefix(maxCards))
    }

    /// The projects behind the foot line: those of the stories past the
    /// last card, then the ones the journal lists as also moving.
    public static func alsoMovedProjects(_ week: TimelineWeek) -> [TimelineProjectRef] {
        week.stories.dropFirst(maxCards).map(\.project) + week.also
    }

    /// No project moved that week.
    public static func movedNothing(_ week: TimelineWeek) -> Bool {
        week.stories.isEmpty && week.also.isEmpty
    }

    /// "Also moved: 7 projects": the foot line; nil when there are none.
    public static func alsoMoved(_ count: Int) -> String? {
        count > 0 ? "Also moved: \(count) project\(count == 1 ? "" : "s")" : nil
    }

    // MARK: Stories

    public static func sentence(_ story: TimelineStory) -> String {
        guard let sentence = story.sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else {
            return movedSentence
        }
        return sentence
    }

    // MARK: Marks

    /// "2 for you": follows the red dot.
    public static func forYouMark(_ count: Int) -> String { "\(count) for you" }

    /// "✓ 5 done".
    public static func doneMark(_ count: Int) -> String { "✓ \(count) done" }

    /// The marks as they are spoken: "2 waiting for you, 5 done, has a
    /// next step", only those that apply; nil when there are none.
    public static func marksLabel(_ marks: TimelineMarks) -> String? {
        var parts: [String] = []
        if marks.forYou > 0 { parts.append("\(marks.forYou) waiting for you") }
        if marks.done > 0 { parts.append("\(marks.done) done") }
        if marks.next { parts.append("has a next step") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Lists

    /// "Last moved 19 days ago"; under a day, the dashboard's relative time.
    public static func lastMoved(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        return "Last moved \(daysAgo(date, now: now))"
    }

    /// "Moved 3 days ago": a row of the all-projects list.
    public static func moved(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        return "Moved \(daysAgo(date, now: now))"
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

    // MARK: Project page

    public static let nextHeading = "Next"
    public static let needsYouHeading = "Needs you"
    /// Over a project's finished missions.
    public static let doneHeading = "Done"

    /// The row that opens a section, and that section's own title.
    public static func sectionTitle(_ section: ProjectSection) -> String {
        switch section {
        case .history: return "This week and before"
        case .missions: return "Missions"
        case .files: return "Files"
        }
    }

    /// What a section's row says is behind it: "6 weeks", "3 open, 4 done", "7".
    public static func sectionCount(_ section: ProjectSection, page: TimelineProjectPage) -> String {
        switch section {
        case .history: return weeksCount(page.weeks)
        case .missions: return missionsCount(open: page.missionsOpen, done: page.missionsDone)
        case .files: return "\(page.files)"
        }
    }

    /// Nothing is behind the row, so it can't be opened.
    public static func sectionIsEmpty(_ section: ProjectSection, page: TimelineProjectPage) -> Bool {
        switch section {
        case .history: return page.weeks <= 0
        case .missions: return page.missionsOpen + page.missionsDone <= 0
        case .files: return page.files <= 0
        }
    }

    public static func weeksCount(_ count: Int) -> String {
        "\(count) week\(count == 1 ? "" : "s")"
    }

    public static func missionsCount(open: Int, done: Int) -> String {
        "\(open) open, \(done) done"
    }

    /// "and 2 more": the items waiting beyond the rows the page lists; nil
    /// when they are all listed.
    public static func moreWaiting(_ page: TimelineProjectPage) -> String? {
        let more = page.needsYouTotal - page.needsYou.count
        return more > 0 ? "and \(more) more" : nil
    }

    /// What "Needs you" lists. The page carries the newest waiting items
    /// and a count of them all; `all` is every one, once the host has
    /// them. Closed, the list is the page's rows and "and N more", which
    /// can open when `all` has an item the page doesn't list. Open, the
    /// page's rows keep their places, the rest of `all` follow, and the
    /// row counting more goes.
    public static func waitingList(_ page: TimelineProjectPage, all: [TimelineItemRef]?,
                                   expanded: Bool) -> ProjectWaitingList {
        let listed = Set(page.needsYou.map(\.id))
        let rest = (all ?? []).filter { !listed.contains($0.id) }
        guard let more = moreWaiting(page), !rest.isEmpty else {
            return ProjectWaitingList(rows: page.needsYou, more: moreWaiting(page), canExpand: false)
        }
        if expanded { return ProjectWaitingList(rows: page.needsYou + rest, more: nil, canExpand: false) }
        return ProjectWaitingList(rows: page.needsYou, more: more, canExpand: true)
    }

    /// A week of a project's history: the week `now` falls in is this
    /// week, the one that ended within the last seven days last week, any
    /// other its dates ("19 – 25 Oct").
    public static func historyWeekTitle(_ week: TimelineHistoryWeek, now: Date) -> String {
        if now < week.end { return thisWeek }
        if now < week.end.addingTimeInterval(7 * 86_400) { return lastWeek }
        return shortRange(week.week) ?? week.week
    }

    /// "4 more": a week's milestones beyond the ones listed; nil when none.
    public static func moreMilestones(_ count: Int) -> String? {
        count > 0 ? "\(count) more" : nil
    }

    public static let thisWeek = "This week"
    public static let lastWeek = "Last week"

    /// "Tuesday": the day beside a milestone of a project's history.
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
