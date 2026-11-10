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

    // MARK: Project story

    public static let comingUpPrefix = "Coming up:"
    public static let allDetails = "All details"
    public static let openItem = "Open"
    /// The gallery's first two week headings; older weeks are their dates.
    public static let thisWeek = "This week"
    public static let lastWeek = "Last week"

    /// The story page's sentence, and the lines it may take (nil: all).
    public struct StorySentence: Equatable, Sendable {
        public let text: String
        public let lineLimit: Int?

        public init(text: String, lineLimit: Int?) {
            self.text = text; self.lineLimit = lineLimit
        }
    }

    /// Lines a goal standing in for the status may take.
    public static let goalLineLimit = 3

    /// The page's one sentence: the Coordinator's status, else the goal's
    /// first paragraph (a few lines at most), else the newest milestone's
    /// title; nil when there is none.
    public static func storySentence(_ page: ProjectPageModel) -> StorySentence? {
        if let status = trimmed(page.project.status) { return StorySentence(text: status, lineLimit: nil) }
        if let goal = firstParagraph(page.project.body) { return StorySentence(text: goal, lineLimit: goalLineLimit) }
        let newest = (page.recentMilestones + page.milestonesPage.rows.map(\.milestone))
            .max { $0.createdAt < $1.createdAt }?.title
        return trimmed(newest).map { StorySentence(text: $0, lineLimit: nil) }
    }

    /// A markdown text's first paragraph as one line, without the marks
    /// that start a heading, a list item or a quote; inline marks stay
    /// for the renderer. nil when it has no words.
    static func firstParagraph(_ markdown: String) -> String? {
        var lines: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if lines.isEmpty { continue } else { break }
            }
            let words = line.replacingOccurrences(of: blockMark, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { lines.append(words) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// "# ", "- ", "* ", "+ ", "> ", "1. " at the start of a line (a lone
    /// mark too). "#tag" and "-5" are words, so they stay.
    private static let blockMark = #"^(#{1,6}|[-*+]|>|\d+[.)])(\s+|$)"#

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
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

    /// A title as part of a sentence: one line, no closing full stop, and
    /// otherwise as written.
    static func phrase(_ title: String) -> String {
        var text = ProjectsFormat.oneLine(title).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// A gallery tile's caption: the file's own caption, else the title of
    /// the item it was posted on; nil when neither is known. Never the
    /// file's name, which is rarely words.
    public static func galleryCaption(_ file: ProjectFile, items: [TrackerItem]) -> String? {
        if let caption = trimmed(file.caption) { return ProjectsFormat.oneLine(caption) }
        guard case .item(let num) = file.source,
              let title = trimmed(items.first(where: { $0.num == num })?.title) else { return nil }
        return ProjectsFormat.oneLine(title)
    }

    /// "This week", "Last week", else "19 – 25 Oct", for the week starting
    /// `weekStart` in `calendar`'s zone. The weeks are `calendar`'s; the
    /// dates are always Gregorian, whatever the device's calendar.
    public static func galleryWeekTitle(weekStart: Date, thisWeekStart: Date, calendar: Calendar) -> String {
        if weekStart == thisWeekStart { return thisWeek }
        if let previous = calendar.date(byAdding: .day, value: -7, to: thisWeekStart), weekStart == previous {
            return lastWeek
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let day = gregorian.dateComponents([.year, .month, .day], from: weekStart)
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
