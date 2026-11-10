import Foundation

// The Projects weekly timeline (journal `GET /timeline/...`): one summary per
// week, one week's stories, and the went-quiet / open-a-long-time / finished
// lists, plus every project, one project's page and its weeks. Dates arrive as ms since epoch. Every `init?(json:)` returns nil for
// a row missing a required field; the parents drop such rows and keep the rest.

/// Where the Projects timeline is looking: one week's stories, every
/// project, or one of the three lists below the weeks.
public enum TimelinePlace: Hashable, Sendable {
    case week(String)
    /// Every project, the most recently moved first.
    case projects
    /// Projects that went quiet.
    case quiet
    /// Projects open a long time.
    case long
    case finished
}

/// The compact project reference every timeline read carries.
public struct TimelineProjectRef: Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let title: String

    public init(id: String, num: Int, title: String) { self.id = id; self.num = num; self.title = title }

    public init?(json: [String: Any]?) {
        guard let json, let id = json["id"] as? String, !id.isEmpty,
              let num = (json["num"] as? NSNumber)?.intValue else { return nil }
        self.init(id: id, num: num, title: json["title"] as? String ?? "")
    }
}

/// An item a week's story names as needing the user: open (waiting), or
/// `done` (named by the story, since sorted out).
public struct TimelineItemRef: Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let title: String
    /// The Coordinator's story named it, and it no longer waits on the
    /// user (answered, or closed). False when the journal doesn't say.
    public let done: Bool

    public init(id: String, num: Int, title: String, done: Bool = false) {
        self.id = id; self.num = num; self.title = title; self.done = done
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, let num = (json["num"] as? NSNumber)?.intValue else { return nil }
        self.init(id: id, num: num, title: json["title"] as? String ?? "", done: json["done"] as? Bool ?? false)
    }
}

/// A picture or video a story shows, by journal blob.
public struct TimelineMedia: Equatable, Hashable, Sendable {
    public let blobID: String
    public let contentType: String
    public let name: String

    public var isVideo: Bool { contentType.lowercased().hasPrefix("video/") }

    public init(blobID: String, contentType: String, name: String) {
        self.blobID = blobID; self.contentType = contentType; self.name = name
    }

    public init?(json: [String: Any]?) {
        guard let json, let blobID = json["blob_id"] as? String, !blobID.isEmpty,
              let contentType = json["content_type"] as? String else { return nil }
        self.init(blobID: blobID, contentType: contentType, name: json["name"] as? String ?? "")
    }
}

/// What a card says about its project's week in counts and a word, never
/// item titles.
public struct TimelineMarks: Equatable, Hashable, Sendable {
    /// Items waiting on the user.
    public let forYou: Int
    /// Items sorted out that week.
    public let done: Int
    /// Whether the project says what comes next.
    public let next: Bool

    /// Nothing to mark.
    public var isEmpty: Bool { forYou == 0 && done == 0 && !next }

    public init(forYou: Int = 0, done: Int = 0, next: Bool = false) {
        self.forYou = forYou; self.done = done; self.next = next
    }

    /// A missing count is 0 and a missing `next` false; nil only for no object.
    public init?(json: [String: Any]?) {
        guard let json else { return nil }
        self.init(forYou: (json["for_you"] as? NSNumber)?.intValue ?? 0,
                  done: (json["done"] as? NSNumber)?.intValue ?? 0, next: json["next"] as? Bool ?? false)
    }
}

/// One row of `GET /timeline/weeks`.
public struct TimelineWeekSummary: Equatable, Hashable, Sendable {
    /// The Monday's local date, `YYYY-MM-DD`.
    public let week: String
    public let start: Date
    public let end: Date
    public let sentence: String
    /// How many projects moved that week.
    public let moved: Int

    public init(week: String, start: Date, end: Date, sentence: String, moved: Int) {
        self.week = week; self.start = start; self.end = end; self.sentence = sentence; self.moved = moved
    }

    public init?(json: [String: Any]) {
        guard let week = json["week"] as? String, !week.isEmpty,
              let start = msDate(json["start"]), let end = msDate(json["end"]) else { return nil }
        self.init(week: week, start: start, end: end, sentence: json["sentence"] as? String ?? "",
                  moved: (json["moved"] as? NSNumber)?.intValue ?? 0)
    }
}

/// A story on a week's page: the Coordinator's written story when the
/// journal has one, else a project that moved.
public struct TimelineStory: Equatable, Hashable, Sendable {
    /// The main project (the story's first).
    public let project: TimelineProjectRef
    /// The Coordinator's title for the story; nil when none was written
    /// (the project's name stands in).
    public let title: String?
    /// Every project the story covers, the main one first. Never empty:
    /// a journal that sends none gives `[project]`.
    public let projects: [TimelineProjectRef]
    /// The newest milestone title that week; nil when the project moved
    /// without one.
    public let sentence: String?
    public let next: String?
    public let needsYou: [TimelineItemRef]
    public let media: TimelineMedia?
    /// The journal's marks; from one that sends none, what the story
    /// itself carries (items still waiting, a next step, nothing done).
    public let marks: TimelineMarks

    /// `projects` nil (or empty) means just `project`; `marks` nil derives
    /// them from `needsYou` and `next`.
    public init(project: TimelineProjectRef, title: String? = nil, projects: [TimelineProjectRef]? = nil,
                sentence: String? = nil, next: String? = nil,
                needsYou: [TimelineItemRef] = [], media: TimelineMedia? = nil, marks: TimelineMarks? = nil) {
        self.project = project; self.title = title
        // The main project always leads, once, whatever the decoded list held.
        self.projects = [project] + (projects ?? []).filter { $0.id != project.id }
        self.sentence = sentence; self.next = next
        self.needsYou = needsYou; self.media = media
        self.marks = marks ?? TimelineMarks(forYou: needsYou.filter { !$0.done }.count, done: 0, next: next != nil)
    }

    public init?(json: [String: Any]) {
        guard let project = TimelineProjectRef(json: json["project"] as? [String: Any]) else { return nil }
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(project: project, title: title?.isEmpty == false ? title : nil,
                  projects: (json["projects"] as? [[String: Any]])?.compactMap { TimelineProjectRef(json: $0) },
                  sentence: json["sentence"] as? String, next: json["next"] as? String,
                  needsYou: (json["needs_you"] as? [[String: Any]] ?? []).compactMap(TimelineItemRef.init(json:)),
                  media: TimelineMedia(json: json["media"] as? [String: Any]),
                  marks: TimelineMarks(json: json["marks"] as? [String: Any]))
    }
}

/// `GET /timeline/weeks/:week`.
public struct TimelineWeek: Equatable, Hashable, Sendable {
    public let week: String
    public let start: Date
    public let end: Date
    /// False for the current week (and when the journal doesn't say).
    public let final: Bool
    public let lede: String?
    public let stories: [TimelineStory]
    /// Projects that moved beyond the stories the journal shows.
    public let also: [TimelineProjectRef]

    public init(week: String, start: Date, end: Date, final: Bool, lede: String? = nil,
                stories: [TimelineStory] = [], also: [TimelineProjectRef] = []) {
        self.week = week; self.start = start; self.end = end; self.final = final
        self.lede = lede; self.stories = stories; self.also = also
    }

    /// Stories and `also` rows that fail to decode are dropped; a week with
    /// no key or no bounds is nil.
    public init?(json: [String: Any]) {
        guard let week = json["week"] as? String, !week.isEmpty,
              let start = msDate(json["start"]), let end = msDate(json["end"]) else { return nil }
        self.init(week: week, start: start, end: end, final: json["final"] as? Bool ?? false,
                  lede: json["lede"] as? String,
                  stories: (json["stories"] as? [[String: Any]] ?? []).compactMap(TimelineStory.init(json:)),
                  also: (json["also"] as? [[String: Any]] ?? []).compactMap { TimelineProjectRef(json: $0) })
    }
}

/// A row of `GET /timeline/quiet` or `/timeline/long`.
public struct StalledProject: Equatable, Hashable, Sendable {
    public let project: TimelineProjectRef
    /// nil for a project with no recorded move.
    public let lastMovedAt: Date?
    /// Only the open-a-long-time list sends it.
    public let createdAt: Date?
    /// Move counts for the last eight weeks, oldest first.
    public let weekly: [Int]
    public let note: String?

    public init(project: TimelineProjectRef, lastMovedAt: Date? = nil, createdAt: Date? = nil,
                weekly: [Int] = [], note: String? = nil) {
        self.project = project; self.lastMovedAt = lastMovedAt; self.createdAt = createdAt
        self.weekly = weekly; self.note = note
    }

    public init?(json: [String: Any]) {
        guard let project = TimelineProjectRef(json: json["project"] as? [String: Any]) else { return nil }
        // Positional (oldest first): a non-number counts as 0 rather than shifting the weeks.
        self.init(project: project, lastMovedAt: msDate(json["last_moved_at"]), createdAt: msDate(json["created_at"]),
                  weekly: (json["weekly"] as? [Any] ?? []).map { ($0 as? NSNumber)?.intValue ?? 0 },
                  note: json["note"] as? String)
    }
}

/// `GET /timeline/quiet` / `/timeline/long`: the top rows and the full count.
public struct StalledList: Equatable, Hashable, Sendable {
    public let total: Int
    public let rows: [StalledProject]

    public init(total: Int, rows: [StalledProject]) { self.total = total; self.rows = rows }

    public init?(json: [String: Any]) {
        guard let total = (json["total"] as? NSNumber)?.intValue, let rows = json["rows"] as? [[String: Any]] else { return nil }
        self.init(total: total, rows: rows.compactMap(StalledProject.init(json:)))
    }
}

/// A row of `GET /timeline/finished`.
public struct FinishedProject: Equatable, Hashable, Sendable {
    public let project: TimelineProjectRef
    public let finishedAt: Date

    public init(project: TimelineProjectRef, finishedAt: Date) { self.project = project; self.finishedAt = finishedAt }

    public init?(json: [String: Any]) {
        guard let project = TimelineProjectRef(json: json["project"] as? [String: Any]),
              let finishedAt = msDate(json["finished_at"]) else { return nil }
        self.init(project: project, finishedAt: finishedAt)
    }
}

/// A row of `GET /timeline/projects`.
public struct TimelineProjectRow: Equatable, Hashable, Sendable {
    public let project: TimelineProjectRef
    /// nil for a project with no recorded move.
    public let lastMovedAt: Date?
    public let openMissions: Int

    public init(project: TimelineProjectRef, lastMovedAt: Date? = nil, openMissions: Int = 0) {
        self.project = project; self.lastMovedAt = lastMovedAt; self.openMissions = openMissions
    }

    public init?(json: [String: Any]) {
        guard let project = TimelineProjectRef(json: json["project"] as? [String: Any]) else { return nil }
        self.init(project: project, lastMovedAt: msDate(json["last_moved_at"]),
                  openMissions: (json["open_missions"] as? NSNumber)?.intValue ?? 0)
    }
}

/// `GET /timeline/projects`: one page of every project, the full count and
/// the cursor for the next page (nil on the last).
public struct TimelineProjectList: Equatable, Hashable, Sendable {
    public let total: Int
    public let rows: [TimelineProjectRow]
    public let nextBefore: String?

    public init(total: Int, rows: [TimelineProjectRow], nextBefore: String? = nil) {
        self.total = total; self.rows = rows; self.nextBefore = nextBefore
    }

    public init?(json: [String: Any]) {
        guard let total = (json["total"] as? NSNumber)?.intValue, let rows = json["rows"] as? [[String: Any]] else { return nil }
        self.init(total: total, rows: rows.compactMap(TimelineProjectRow.init(json:)),
                  nextBefore: json["next_before"] as? String)
    }
}

/// `GET /timeline/projects/:id`: one project's page.
public struct TimelineProjectPage: Equatable, Hashable, Sendable {
    public let project: TimelineProjectRef
    /// The project has at least one open mission. False when the journal
    /// doesn't say.
    public let isLive: Bool
    /// The project's own state as the journal names it (`open`, `closed`).
    public let state: String
    /// The project can still be changed: any other state is closed or finished.
    public var isOpen: Bool { state == "open" }
    /// Where the project stands; nil when nothing says.
    public let sentence: String?
    public let next: String?
    /// The first items waiting on the user; `needsYouTotal` counts them all.
    public let needsYou: [TimelineItemRef]
    public let needsYouTotal: Int
    public let media: TimelineMedia?
    /// How many weeks the project moved in.
    public let weeks: Int
    public let missionsOpen: Int
    public let missionsDone: Int
    public let files: Int
    /// The project asked for, when it was merged into this one.
    public let mergedFromID: String?

    public init(project: TimelineProjectRef, isLive: Bool = false, state: String = "open", sentence: String? = nil,
                next: String? = nil, needsYou: [TimelineItemRef] = [], needsYouTotal: Int? = nil,
                media: TimelineMedia? = nil, weeks: Int = 0, missionsOpen: Int = 0, missionsDone: Int = 0,
                files: Int = 0, mergedFromID: String? = nil) {
        self.project = project; self.isLive = isLive; self.state = state
        self.sentence = sentence; self.next = next
        self.needsYou = needsYou; self.needsYouTotal = needsYouTotal ?? needsYou.count
        self.media = media
        self.weeks = weeks; self.missionsOpen = missionsOpen; self.missionsDone = missionsDone; self.files = files
        self.mergedFromID = mergedFromID
    }

    /// nil without a project; bad items are dropped, a missing count is 0
    /// and a missing `needs_you_total` counts the items sent.
    public init?(json: [String: Any]) {
        let raw = json["project"] as? [String: Any]
        guard let project = TimelineProjectRef(json: raw) else { return nil }
        let counts = json["counts"] as? [String: Any] ?? [:]
        func count(_ key: String) -> Int { (counts[key] as? NSNumber)?.intValue ?? 0 }
        self.init(project: project, isLive: raw?["live"] as? Bool ?? false, state: raw?["state"] as? String ?? "open",
                  sentence: json["sentence"] as? String, next: json["next"] as? String,
                  needsYou: (json["needs_you"] as? [[String: Any]] ?? []).compactMap(TimelineItemRef.init(json:)),
                  needsYouTotal: (json["needs_you_total"] as? NSNumber)?.intValue,
                  media: TimelineMedia(json: json["media"] as? [String: Any]),
                  weeks: count("weeks"), missionsOpen: count("missions_open"), missionsDone: count("missions_done"),
                  files: count("files"),
                  mergedFromID: ((json["merged_from"] as? [String: Any])?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// One week of `GET /timeline/projects/:id/history`: the project's card
/// that week, when one was written, and the milestones posted in it.
public struct TimelineHistoryWeek: Equatable, Hashable, Sendable {
    /// The Monday's local date, `YYYY-MM-DD`.
    public let week: String
    public let start: Date
    public let end: Date
    /// The card's sentence; nil for a week with no card.
    public let sentence: String?
    public let media: TimelineMedia?
    /// The week's first milestones; `moreMilestones` counts the rest.
    public let milestones: [ProjectMilestone]
    public let moreMilestones: Int

    public init(week: String, start: Date, end: Date, sentence: String? = nil, media: TimelineMedia? = nil,
                milestones: [ProjectMilestone] = [], moreMilestones: Int = 0) {
        self.week = week; self.start = start; self.end = end; self.sentence = sentence; self.media = media
        self.milestones = milestones; self.moreMilestones = moreMilestones
    }

    /// Milestones that fail to decode are dropped; a week with no key or
    /// no bounds is nil.
    public init?(json: [String: Any]) {
        guard let week = json["week"] as? String, !week.isEmpty,
              let start = msDate(json["start"]), let end = msDate(json["end"]) else { return nil }
        let card = json["card"] as? [String: Any]
        self.init(week: week, start: start, end: end, sentence: card?["sentence"] as? String,
                  media: TimelineMedia(json: card?["media"] as? [String: Any]),
                  milestones: (json["milestones"] as? [[String: Any]] ?? []).compactMap(ProjectMilestone.init(json:)),
                  moreMilestones: (json["more_milestones"] as? NSNumber)?.intValue ?? 0)
    }
}
