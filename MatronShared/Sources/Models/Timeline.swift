import Foundation

// The Projects weekly timeline (journal `GET /timeline/...`): one summary per
// week, one week's stories, and the went-quiet / open-a-long-time / finished
// lists. Dates arrive as ms since epoch. Every `init?(json:)` returns nil for
// a row missing a required field; the parents drop such rows and keep the rest.

/// Where the Projects timeline is looking: one week's stories, or one of the
/// three lists below the weeks.
public enum TimelinePlace: Hashable, Sendable {
    case week(String)
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

/// An open item awaiting the user, on a week's story.
public struct TimelineItemRef: Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let title: String

    public init(id: String, num: Int, title: String) { self.id = id; self.num = num; self.title = title }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, let num = (json["num"] as? NSNumber)?.intValue else { return nil }
        self.init(id: id, num: num, title: json["title"] as? String ?? "")
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

/// A project that moved in a week.
public struct TimelineStory: Equatable, Hashable, Sendable {
    public let project: TimelineProjectRef
    /// The newest milestone title that week; nil when the project moved
    /// without one.
    public let sentence: String?
    public let next: String?
    public let needsYou: [TimelineItemRef]
    public let media: TimelineMedia?

    public init(project: TimelineProjectRef, sentence: String? = nil, next: String? = nil,
                needsYou: [TimelineItemRef] = [], media: TimelineMedia? = nil) {
        self.project = project; self.sentence = sentence; self.next = next
        self.needsYou = needsYou; self.media = media
    }

    public init?(json: [String: Any]) {
        guard let project = TimelineProjectRef(json: json["project"] as? [String: Any]) else { return nil }
        self.init(project: project, sentence: json["sentence"] as? String, next: json["next"] as? String,
                  needsYou: (json["needs_you"] as? [[String: Any]] ?? []).compactMap(TimelineItemRef.init(json:)),
                  media: TimelineMedia(json: json["media"] as? [String: Any]))
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
