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
    public init(project: Project, missions: [Mission], recentMilestones: [Milestone],
                sessionsByBox: [String: Int]) {
        self.project = project; self.missions = missions
        self.recentMilestones = recentMilestones; self.sessionsByBox = sessionsByBox
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
            sessionsByBox: boxes)
    }

    static func decodeConversationMissions(_ obj: [String: Any]) throws -> [ConversationMissionLink] {
        guard let rows = obj["missions"] as? [[String: Any]] else {
            throw JournalAPIError.transport("malformed conversation missions response")
        }
        return rows.compactMap(ConversationMissionLink.init(json:))
    }

    public func listProjects() async throws -> ProjectsListDecode {
        try Self.decodeProjects(try await request(path: "/projects"))
    }

    public func project(id: String) async throws -> ProjectDetail {
        try Self.decodeProjectDetail(try await request(path: "/projects/\(Self.pathSegment(id))"))
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
