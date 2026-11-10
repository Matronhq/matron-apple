import Foundation
import os
import MatronModels

private let timelineAPILogger = Logger(subsystem: "chat.matron", category: "timeline-api")

/// The Projects weekly timeline reads (`GET /timeline/...`). A journal
/// without the routes answers 404 (`JournalAPIError.notFound`) on the weeks
/// route; callers read that as "unsupported".
public protocol TimelineProviding: Sendable {
    /// Weeks newest first. `before` is a week key (a page's `nextBefore`);
    /// `limit` nil takes the journal's default.
    func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?)
    func timelineWeek(_ week: String) async throws -> TimelineWeek
    func wentQuiet() async throws -> StalledList
    func openLong() async throws -> StalledList
    /// Finished projects, newest finish first; `before` is a page's `nextBefore`.
    func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?)
    /// Every project, the most recently moved first; `before` is a page's `nextBefore`.
    func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList
    /// One project's page. A journal without the route answers 404, as it
    /// does for a project it doesn't have.
    func timelineProject(_ id: String) async throws -> TimelineProjectPage
    /// The project's weeks newest first; `before` is a week key (a page's `nextBefore`).
    func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?)
}

extension JournalAPI: TimelineProviding {
    /// Rows that fail to decode are dropped and logged: every timeline route
    /// is a read, never an authoritative replace.
    private static func decodeRows<Row>(_ raw: [[String: Any]], _ what: String, _ make: ([String: Any]) -> Row?) -> [Row] {
        raw.compactMap { row in
            if let decoded = make(row) { return decoded }
            let id = row["week"] as? String ?? (row["project"] as? [String: Any])?["id"] as? String ?? row["id"] as? String
            timelineAPILogger.error("dropped malformed timeline \(what, privacy: .public) row id=\(id ?? "?", privacy: .public)")
            return nil
        }
    }

    static func decodeTimelineWeeks(_ obj: [String: Any]) throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        guard let rows = obj["weeks"] as? [[String: Any]] else { throw JournalAPIError.transport("malformed timeline weeks response") }
        return (decodeRows(rows, "week", TimelineWeekSummary.init(json:)), obj["next_before"] as? String)
    }

    static func decodeTimelineWeek(_ obj: [String: Any]) throws -> TimelineWeek {
        guard let week = TimelineWeek(json: obj) else { throw JournalAPIError.transport("malformed timeline week response") }
        // The model drops bad stories and `also` rows quietly; say so here.
        let sent = (obj["stories"] as? [Any])?.count ?? 0
        let sentAlso = (obj["also"] as? [Any])?.count ?? 0
        if week.stories.count < sent || week.also.count < sentAlso {
            timelineAPILogger.error("dropped \(sent - week.stories.count + sentAlso - week.also.count, privacy: .public) malformed row(s) in timeline week \(week.week, privacy: .public)")
        }
        return week
    }

    static func decodeStalledList(_ obj: [String: Any]) throws -> StalledList {
        guard let list = StalledList(json: obj) else { throw JournalAPIError.transport("malformed timeline list response") }
        let sent = (obj["rows"] as? [Any])?.count ?? 0
        if list.rows.count < sent {
            timelineAPILogger.error("dropped \(sent - list.rows.count, privacy: .public) malformed row(s) in timeline list")
        }
        return list
    }

    static func decodeFinishedProjects(_ obj: [String: Any]) throws -> (rows: [FinishedProject], nextBefore: String?) {
        guard let rows = obj["rows"] as? [[String: Any]] else { throw JournalAPIError.transport("malformed timeline finished response") }
        return (decodeRows(rows, "finished", FinishedProject.init(json:)), obj["next_before"] as? String)
    }

    static func decodeTimelineProjects(_ obj: [String: Any]) throws -> TimelineProjectList {
        guard let list = TimelineProjectList(json: obj) else { throw JournalAPIError.transport("malformed timeline projects response") }
        let sent = (obj["rows"] as? [Any])?.count ?? 0
        if list.rows.count < sent {
            timelineAPILogger.error("dropped \(sent - list.rows.count, privacy: .public) malformed row(s) in timeline projects")
        }
        return list
    }

    static func decodeTimelineProject(_ obj: [String: Any]) throws -> TimelineProjectPage {
        guard let page = TimelineProjectPage(json: obj) else { throw JournalAPIError.transport("malformed timeline project response") }
        return page
    }

    static func decodeTimelineProjectHistory(_ obj: [String: Any]) throws -> (weeks: [TimelineHistoryWeek], nextBefore: String?) {
        guard let rows = obj["weeks"] as? [[String: Any]] else { throw JournalAPIError.transport("malformed timeline history response") }
        return (decodeRows(rows, "history week", TimelineHistoryWeek.init(json:)), obj["next_before"] as? String)
    }

    private static func pageQuery(before: String?, limit: Int?) -> [URLQueryItem] {
        var query: [URLQueryItem] = []
        if let before { query.append(.init(name: "before", value: before)) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return query
    }

    public func timelineWeeks(before: String?, limit: Int?) async throws -> (weeks: [TimelineWeekSummary], nextBefore: String?) {
        try Self.decodeTimelineWeeks(
            try await request(path: "/timeline/weeks", query: Self.pageQuery(before: before, limit: limit)))
    }

    public func timelineWeek(_ week: String) async throws -> TimelineWeek {
        try Self.decodeTimelineWeek(try await request(path: "/timeline/weeks/\(Self.pathSegment(week))"))
    }

    public func wentQuiet() async throws -> StalledList {
        try Self.decodeStalledList(try await request(path: "/timeline/quiet"))
    }

    public func openLong() async throws -> StalledList {
        try Self.decodeStalledList(try await request(path: "/timeline/long"))
    }

    public func finishedProjects(before: String?, limit: Int?) async throws -> (rows: [FinishedProject], nextBefore: String?) {
        try Self.decodeFinishedProjects(
            try await request(path: "/timeline/finished", query: Self.pageQuery(before: before, limit: limit)))
    }

    public func timelineProjects(before: String?, limit: Int?) async throws -> TimelineProjectList {
        try Self.decodeTimelineProjects(
            try await request(path: "/timeline/projects", query: Self.pageQuery(before: before, limit: limit)))
    }

    public func timelineProject(_ id: String) async throws -> TimelineProjectPage {
        try Self.decodeTimelineProject(try await request(path: "/timeline/projects/\(Self.pathSegment(id))"))
    }

    public func timelineProjectHistory(_ id: String, before: String?, limit: Int?) async throws
        -> (weeks: [TimelineHistoryWeek], nextBefore: String?) {
        try Self.decodeTimelineProjectHistory(
            try await request(path: "/timeline/projects/\(Self.pathSegment(id))/history",
                              query: Self.pageQuery(before: before, limit: limit)))
    }
}
