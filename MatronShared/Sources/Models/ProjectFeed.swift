import Foundation

// Projects view v2 (journal PR 112): the card's three fields on every
// `GET /projects` row, and the roll-up across a project's missions —
// decisions and answered questions, files and images, every milestone —
// paged by `GET /projects/:id/feed`, first pages on `GET /projects/:id`.
// Every type is Codable so the store keeps it as JSON on the project row.
// A journal without PR 112 sends none of it; everything decodes to
// nil / empty, never a failure.

/// The newest open item awaiting the user across the project's missions
/// (`waiting_on`), plus how many more there are.
public struct ProjectWaitingOn: Equatable, Hashable, Sendable, Codable {
    public let itemID: String
    public let num: Int
    public let kind: ItemKind
    public let title: String
    public let missionNum: Int?
    /// Items awaiting the user beyond this one.
    public let more: Int

    public init(itemID: String, num: Int, kind: ItemKind, title: String, missionNum: Int? = nil, more: Int = 0) {
        self.itemID = itemID; self.num = num; self.kind = kind; self.title = title
        self.missionNum = missionNum; self.more = more
    }

    public init?(json: [String: Any]?) {
        guard let json, let itemID = json["item_id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(ItemKind.init(rawValue:)) else { return nil }
        self.init(itemID: itemID, num: num, kind: kind, title: json["title"] as? String ?? "",
                  missionNum: (json["mission_num"] as? NSNumber)?.intValue,
                  more: (json["more"] as? NSNumber)?.intValue ?? 0)
    }
}

/// The project's newest milestone (`latest`).
public struct ProjectLatest: Equatable, Hashable, Sendable, Codable {
    public let title: String
    public let kind: MilestoneKind
    public let at: Date
    public let missionNum: Int?

    public init(title: String, kind: MilestoneKind, at: Date, missionNum: Int? = nil) {
        self.title = title; self.kind = kind; self.at = at; self.missionNum = missionNum
    }

    public init?(json: [String: Any]?) {
        guard let json, let kind = (json["kind"] as? String).flatMap(MilestoneKind.init(rawValue:)),
              let at = msDate(json["at"]) else { return nil }
        self.init(title: json["title"] as? String ?? "", kind: kind, at: at,
                  missionNum: (json["mission_num"] as? NSNumber)?.intValue)
    }
}

/// The three card fields a `GET /projects` row carries. A `Project` holds
/// `nil` when the row had none of them — an older journal, or a route
/// (detail, create, merge) that never sends them — so the store can tell
/// "not sent" from "sent, and empty" and keep what a list refresh wrote.
public struct ProjectCardFields: Equatable, Hashable, Sendable, Codable {
    public let waitingOn: ProjectWaitingOn?
    public let latest: ProjectLatest?
    /// Live top-level sessions on the project's open missions.
    public let sessionsNow: Int

    public init(waitingOn: ProjectWaitingOn? = nil, latest: ProjectLatest? = nil, sessionsNow: Int = 0) {
        self.waitingOn = waitingOn; self.latest = latest; self.sessionsNow = sessionsNow
    }

    /// `nil` unless the row carries at least one of the three keys.
    public init?(json: [String: Any]) {
        guard json.keys.contains(where: { ["waiting_on", "latest", "sessions_now"].contains($0) }) else { return nil }
        self.init(waitingOn: ProjectWaitingOn(json: json["waiting_on"] as? [String: Any]),
                  latest: ProjectLatest(json: json["latest"] as? [String: Any]),
                  sessionsNow: (json["sessions_now"] as? NSNumber)?.intValue ?? 0)
    }
}

/// `kind` of `GET /projects/:id/feed`.
public enum ProjectFeedKind: String, Codable, Sendable, CaseIterable {
    case decisions, files, milestones
}

/// A row of one feed kind: decodes leniently from the journal's JSON
/// (`nil` drops the row) and round-trips through the store as Codable.
public protocol ProjectFeedRow: Identifiable, Equatable, Hashable, Sendable, Codable where ID == String {
    init?(json: [String: Any])
}

/// A decision item (open = in force; closed = decided, done or reversed),
/// or a question closed as answered, on one of the project's missions.
public struct ProjectDecision: ProjectFeedRow {
    public let id: String
    public let num: Int
    /// `.decision` or `.question`.
    public let kind: ItemKind
    public let state: ItemState
    public let resolution: ItemResolution?
    public let title: String
    /// The decision this one replaces.
    public let supersedes: String?
    public let createdAt: Date
    public let closedAt: Date?
    public let missionID: String?
    public let missionNum: Int?
    /// A question's answer: the user's newest comment — the tapped label,
    /// else its words, else a voice note's transcript (≤240 chars). `nil`
    /// for a decision.
    public let answer: String?

    public init(id: String, num: Int, kind: ItemKind, state: ItemState = .open, resolution: ItemResolution? = nil,
                title: String, supersedes: String? = nil, createdAt: Date, closedAt: Date? = nil,
                missionID: String? = nil, missionNum: Int? = nil, answer: String? = nil) {
        self.id = id; self.num = num; self.kind = kind; self.state = state; self.resolution = resolution
        self.title = title; self.supersedes = supersedes; self.createdAt = createdAt; self.closedAt = closedAt
        self.missionID = missionID; self.missionNum = missionNum; self.answer = answer
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(ItemKind.init(rawValue:)),
              let state = (json["state"] as? String).flatMap(ItemState.init(rawValue:)),
              let createdAt = msDate(json["created_at"]) else { return nil }
        self.init(id: id, num: num, kind: kind, state: state,
                  resolution: (json["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
                  title: json["title"] as? String ?? "", supersedes: json["supersedes"] as? String,
                  createdAt: createdAt, closedAt: msDate(json["closed_at"]),
                  missionID: json["mission_id"] as? String, missionNum: (json["mission_num"] as? NSNumber)?.intValue,
                  answer: json["answer"] as? String)
    }

    /// When the row entered the roll-up — the journal's sort key: an
    /// answered question when it closed, a decision when it was recorded.
    public var at: Date { kind == .question ? closedAt ?? createdAt : createdAt }
}

/// Where a file was posted: an attachment on an item's comment, or an
/// image/file event in a conversation linked to one of the missions.
public enum ProjectFileSource: Equatable, Hashable, Sendable, Codable {
    case item(num: Int)
    case chat(convoID: String, seq: Int64)

    public init?(json: [String: Any]?) {
        guard let json else { return nil }
        if let num = (json["item_num"] as? NSNumber)?.intValue { self = .item(num: num); return }
        if let convoID = json["convo_id"] as? String, let seq = (json["seq"] as? NSNumber)?.int64Value {
            self = .chat(convoID: convoID, seq: seq); return
        }
        return nil
    }
}

/// A file or image on the project's items or in its missions' chats.
public struct ProjectFile: ProjectFeedRow {
    public let blobID: String
    public let name: String?
    public let contentType: String?
    public let size: Int64?
    public let caption: String?
    public let missionNum: Int?
    public let source: ProjectFileSource
    /// `posted_at`: when the comment or event was posted. `nil` only from
    /// a pre-release build of the roll-up that did not send it.
    public let postedAt: Date?

    /// One blob can be attached twice (two comments, or a chat image and
    /// a comment); the source tells the rows apart.
    public var id: String {
        switch source {
        case .item(let num): return "item:\(num):\(blobID)"
        case .chat(let convoID, let seq): return "chat:\(convoID):\(seq)"
        }
    }

    public init(blobID: String, name: String? = nil, contentType: String? = nil, size: Int64? = nil,
                caption: String? = nil, missionNum: Int? = nil, source: ProjectFileSource, postedAt: Date?) {
        self.blobID = blobID; self.name = name; self.contentType = contentType; self.size = size
        self.caption = caption; self.missionNum = missionNum; self.source = source; self.postedAt = postedAt
    }

    public init?(json: [String: Any]) {
        guard let blobID = json["blob_id"] as? String,
              let source = ProjectFileSource(json: json["source"] as? [String: Any]) else { return nil }
        self.init(blobID: blobID, name: json["name"] as? String, contentType: json["content_type"] as? String,
                  size: (json["size"] as? NSNumber)?.int64Value, caption: json["caption"] as? String,
                  missionNum: (json["mission_num"] as? NSNumber)?.intValue, source: source,
                  postedAt: msDate(json["posted_at"]))
    }

    public var isImage: Bool { contentType?.hasPrefix("image/") ?? false }
}

/// A milestone on one of the project's missions, with its mission's
/// number (the mission may be closed, and so off the page's mission list).
public struct ProjectMilestone: ProjectFeedRow {
    public let milestone: Milestone
    public let missionNum: Int?
    public var id: String { milestone.id }

    public init(milestone: Milestone, missionNum: Int? = nil) {
        self.milestone = milestone; self.missionNum = missionNum
    }

    public init?(json: [String: Any]) {
        guard let milestone = Milestone(json: json) else { return nil }
        self.init(milestone: milestone, missionNum: (json["mission_num"] as? NSNumber)?.intValue)
    }
}

/// One page of one kind: `total` across every page, `nextBefore` the
/// cursor for the next (older) page, `nil` on the last.
public struct ProjectFeedPage<Row: ProjectFeedRow>: Equatable, Hashable, Sendable, Codable {
    public var total: Int
    public var rows: [Row]
    public var nextBefore: String?

    public init(total: Int = 0, rows: [Row] = [], nextBefore: String? = nil) {
        self.total = total; self.rows = rows; self.nextBefore = nextBefore
    }

    /// Malformed rows are dropped; a missing `total` counts the rows.
    public init?(json: [String: Any]?) {
        guard let json, let raw = json["rows"] as? [Any] else { return nil }
        let rows = raw.compactMap { ($0 as? [String: Any]).flatMap(Row.init(json:)) }
        self.init(total: (json["total"] as? NSNumber)?.intValue ?? rows.count, rows: rows,
                  nextBefore: (json["next_before"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    public var hasMore: Bool { nextBefore != nil }

    /// This page with `next`'s rows appended (any already here skipped)
    /// and `next`'s total and cursor.
    public func appending(_ next: ProjectFeedPage<Row>) -> ProjectFeedPage<Row> {
        let have = Set(rows.map(\.id))
        return ProjectFeedPage(total: next.total, rows: rows + next.rows.filter { !have.contains($0.id) },
                               nextBefore: next.nextBefore)
    }
}

/// The first page of every kind, as `GET /projects/:id` sends them. An
/// absent kind is an empty page.
public struct ProjectFeed: Equatable, Hashable, Sendable, Codable {
    public var decisions: ProjectFeedPage<ProjectDecision>
    public var files: ProjectFeedPage<ProjectFile>
    public var milestones: ProjectFeedPage<ProjectMilestone>

    public init(decisions: ProjectFeedPage<ProjectDecision> = .init(), files: ProjectFeedPage<ProjectFile> = .init(),
                milestones: ProjectFeedPage<ProjectMilestone> = .init()) {
        self.decisions = decisions; self.files = files; self.milestones = milestones
    }

    /// `nil` when the detail carries none of the three — a journal
    /// without the roll-up.
    public init?(detailJSON json: [String: Any]) {
        let decisions = ProjectFeedPage<ProjectDecision>(json: json["decisions"] as? [String: Any])
        let files = ProjectFeedPage<ProjectFile>(json: json["files"] as? [String: Any])
        let milestones = ProjectFeedPage<ProjectMilestone>(json: json["milestones"] as? [String: Any])
        guard decisions != nil || files != nil || milestones != nil else { return nil }
        self.init(decisions: decisions ?? .init(), files: files ?? .init(), milestones: milestones ?? .init())
    }
}

/// One `GET /projects/:id/feed` answer: a page of the kind asked for.
public enum ProjectFeedSlice: Equatable, Sendable {
    case decisions(ProjectFeedPage<ProjectDecision>)
    case files(ProjectFeedPage<ProjectFile>)
    case milestones(ProjectFeedPage<ProjectMilestone>)

    public var kind: ProjectFeedKind {
        switch self {
        case .decisions: return .decisions
        case .files: return .files
        case .milestones: return .milestones
        }
    }

    public var rowCount: Int {
        switch self {
        case .decisions(let p): return p.rows.count
        case .files(let p): return p.rows.count
        case .milestones(let p): return p.rows.count
        }
    }

    public var nextBefore: String? {
        switch self {
        case .decisions(let p): return p.nextBefore
        case .files(let p): return p.nextBefore
        case .milestones(let p): return p.nextBefore
        }
    }
}
