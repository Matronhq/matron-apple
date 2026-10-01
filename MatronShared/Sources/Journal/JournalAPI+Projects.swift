import Foundation
import os
import MatronModels

private let projectsAPILogger = Logger(subsystem: "chat.matron", category: "projects-api")

/// `decodeProjects`' result: the rows that decoded plus the ids of any that
/// did not, so an authoritative replace never reads a local decode failure
/// as "the server removed it" (same contract as `MissionsListDecode`).
public struct ProjectsListDecode: Equatable, Sendable {
    public let projects: [Project]
    public let droppedIDs: [String]
    public init(projects: [Project], droppedIDs: [String]) { self.projects = projects; self.droppedIDs = droppedIDs }
}

/// `GET /projects/:id` (spec 2026-09-30 §4.2). For a merged project the
/// journal answers with the TARGET — `project.id` differs from the id asked.
///
/// R1 (preflight 2026-09-30-projects-apple): the journal's `needs_you` rows
/// here are slim — no `created_at` — so `TrackerItem(json:)` drops every one
/// of them, and decoding them leniently would let an authoritative item
/// upsert overwrite a fully-synced cached item with a slim one. `needsYou`
/// is deliberately absent; the project page reads needs-you from the local
/// item cache that `ItemsSync` keeps full.
public struct ProjectDetail: Equatable, Sendable {
    public let project: Project
    public let missions: [Mission]
    public let recentMilestones: [Milestone]
    public let sessionsByBox: [String: Int]
    /// The first page of decisions, files and milestones across the
    /// project's missions (Projects view v2). `nil` from a journal without
    /// the roll-up.
    public let feed: ProjectFeed?
    public init(project: Project, missions: [Mission], recentMilestones: [Milestone],
                sessionsByBox: [String: Int], feed: ProjectFeed? = nil) {
        self.project = project; self.missions = missions
        self.recentMilestones = recentMilestones; self.sessionsByBox = sessionsByBox; self.feed = feed
    }
}

/// The projects routes the apps use, plus the link read for the header.
/// Only the three writes spec §6 gives the apps: create, merge, file.
public protocol ProjectsProviding: Sendable {
    func listProjects() async throws -> ProjectsListDecode
    func project(id: String) async throws -> ProjectDetail
    func createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project
    func mergeProject(id: String, into: String) async throws
    func setMissionProject(missionID: String, project: String?) async throws -> Mission
    func conversationMissions(convoID: String) async throws -> [ConversationMissionLink]
    /// `GET /projects/:id/feed`: one page of `kind`, older than the
    /// `before` cursor (a page's `nextBefore`; `nil` for the first page).
    /// `limit` nil takes the journal's default (20; at most 100). A
    /// journal without the roll-up answers 404 (`JournalAPIError.notFound`).
    func projectFeed(id: String, kind: ProjectFeedKind, before: String?, limit: Int?) async throws -> ProjectFeedSlice
}

extension JournalAPI: ProjectsProviding {
    static func decodeProjects(_ obj: [String: Any]) throws -> ProjectsListDecode {
        guard let rows = obj["projects"] as? [Any] else { throw JournalAPIError.transport("malformed projects response") }
        var projects: [Project] = []
        var dropped: [String] = []
        for element in rows {
            let row = element as? [String: Any]
            if let row, let project = Project(json: row) { projects.append(project); continue }
            let id = row?["id"] as? String
            projectsAPILogger.error("dropped malformed project row id=\(id ?? "?", privacy: .public)")
            if let id { dropped.append(id) }
        }
        return ProjectsListDecode(projects: projects, droppedIDs: dropped)
    }

    static func decodeProject(_ obj: [String: Any]) throws -> Project {
        guard let project = (obj["project"] as? [String: Any]).flatMap(Project.init(json:)) else {
            throw JournalAPIError.transport("malformed project response")
        }
        return project
    }

    static func decodeProjectDetail(_ obj: [String: Any]) throws -> ProjectDetail {
        let boxes = (obj["sessions_by_box"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.intValue }
        return ProjectDetail(
            project: try decodeProject(obj),
            missions: (obj["missions"] as? [[String: Any]] ?? []).compactMap(Mission.init(json:)),
            recentMilestones: (obj["recent_milestones"] as? [[String: Any]] ?? []).compactMap(Milestone.init(json:)),
            sessionsByBox: boxes,
            feed: ProjectFeed(detailJSON: obj))
    }

    /// Rows that fail to decode are dropped (the page is a read, never an
    /// authoritative replace); a response without `rows`, or for another
    /// kind than asked, is a transport error.
    static func decodeProjectFeed(_ obj: [String: Any], kind: ProjectFeedKind) throws -> ProjectFeedSlice {
        guard (obj["kind"] as? String).map({ $0 == kind.rawValue }) ?? true else {
            throw JournalAPIError.transport("project feed answered another kind")
        }
        let malformed = JournalAPIError.transport("malformed project feed response")
        switch kind {
        case .decisions:
            guard let page = ProjectFeedPage<ProjectDecision>(json: obj) else { throw malformed }
            return .decisions(page)
        case .files:
            guard let page = ProjectFeedPage<ProjectFile>(json: obj) else { throw malformed }
            return .files(page)
        case .milestones:
            guard let page = ProjectFeedPage<ProjectMilestone>(json: obj) else { throw malformed }
            return .milestones(page)
        }
    }

    /// All or nothing. `ProjectsSync` hands the result to the AUTHORITATIVE
    /// `replaceConversationMissionLinks`, which deletes every cached link
    /// not in it — so a dropped row would read as "the server unlinked this
    /// mission". Any row that fails to decode fails the whole response; the
    /// cached links stand until a response decodes cleanly.
    static func decodeConversationMissions(_ obj: [String: Any]) throws -> [ConversationMissionLink] {
        guard let rows = obj["missions"] as? [[String: Any]] else {
            throw JournalAPIError.transport("malformed conversation missions response")
        }
        return try rows.map { row in
            guard let link = ConversationMissionLink(json: row) else {
                let id = ((row["mission"] as? [String: Any]) ?? row)["id"] as? String
                projectsAPILogger.error("malformed conversation mission row id=\(id ?? "?", privacy: .public)")
                throw JournalAPIError.transport("malformed conversation mission row")
            }
            return link
        }
    }

    public func listProjects() async throws -> ProjectsListDecode {
        try Self.decodeProjects(try await request(path: "/projects"))
    }

    public func project(id: String) async throws -> ProjectDetail {
        try Self.decodeProjectDetail(try await request(path: "/projects/\(Self.pathSegment(id))"))
    }

    public func projectFeed(id: String, kind: ProjectFeedKind, before: String?, limit: Int?) async throws -> ProjectFeedSlice {
        var query: [URLQueryItem] = [.init(name: "kind", value: kind.rawValue)]
        if let before { query.append(.init(name: "before", value: before)) }
        if let limit { query.append(.init(name: "limit", value: String(limit))) }
        return try Self.decodeProjectFeed(
            try await request(path: "/projects/\(Self.pathSegment(id))/feed", query: query), kind: kind)
    }

    public func createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project {
        var payload: [String: Any] = ["title": title]
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["body"] = body }
        return try Self.decodeProject(try await request(path: "/projects", method: "POST", body: payload,
                                                        accept: [200, 201], headers: ["Idempotency-Key": idempotencyKey]))
    }

    public func mergeProject(id: String, into: String) async throws {
        _ = try await request(path: "/projects/\(Self.pathSegment(id))/merge", method: "POST", body: ["into": into])
    }

    public func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        let value: Any = project ?? NSNull()
        return try Self.decodeMission(try await request(path: "/missions/\(Self.pathSegment(missionID))",
                                                        method: "PATCH", body: ["project": value]))
    }

    public func conversationMissions(convoID: String) async throws -> [ConversationMissionLink] {
        try Self.decodeConversationMissions(
            try await request(path: "/conversations/\(Self.pathSegment(convoID))/missions"))
    }
}
