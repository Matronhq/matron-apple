import Foundation
import MatronModels

/// The Projects home and page rules (spec 2026-09-30 §2), pure so every
/// one is a plain unit test.
public enum ProjectsHomeAssembly {
    /// "Quiet for over a week" (spec §2, decision 5).
    public static let quietAfter: TimeInterval = 7 * 86_400

    /// The row's age: the journal's `last_activity_at` when it sent one (it
    /// also sees active links' joins and newest messages); otherwise the
    /// newest of last milestone, status and update.
    public static func lastActivity(of mission: Mission) -> Date {
        mission.lastActivityAt
            ?? ([mission.lastMilestoneAt, mission.statusUpdatedAt].compactMap { $0 } + [mission.updatedAt]).max()
            ?? mission.createdAt
    }

    /// The server's value when it sent one; otherwise derived. Anything
    /// asking the user is waiting, never quiet — a quiet fold must not
    /// hide a question. Quiet from exactly `quietAfter`, as the journal's
    /// `activityOf` (`>= QUIET_MS`).
    public static func activity(of mission: Mission, needsYou: Int, now: Date) -> MissionActivity {
        if let server = mission.activity { return server == .quiet && needsYou > 0 ? .waiting : server }
        if needsYou > 0 { return .waiting }
        return now.timeIntervalSince(lastActivity(of: mission)) >= quietAfter ? .quiet : .idle
    }

    public static func row(for mission: Mission, needsYouItems: [String: [TrackerItem]], now: Date) -> MissionRowModel {
        let needsYou = max(mission.needsYou, needsYouItems[mission.id]?.count ?? 0)
        return MissionRowModel(mission: mission, activity: activity(of: mission, needsYou: needsYou, now: now),
                               needsYouCount: needsYou, lastActivity: lastActivity(of: mission))
    }

    /// Open missions as rows, needs-you first, then running → waiting →
    /// idle → quiet, then newest activity, then the higher number.
    public static func missionRows(_ missions: [Mission], needsYouItems: [String: [TrackerItem]], now: Date) -> [MissionRowModel] {
        missions.filter { $0.state == .open }.map { row(for: $0, needsYouItems: needsYouItems, now: now) }
            .sorted(by: rowPrecedes)
    }

    static func rowPrecedes(_ a: MissionRowModel, _ b: MissionRowModel) -> Bool {
        let (na, nb) = (a.needsYouCount > 0, b.needsYouCount > 0)
        if na != nb { return na }
        if a.activity.sortRank != b.activity.sortRank { return a.activity.sortRank < b.activity.sortRank }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.mission.num > b.mission.num
    }

    public static func card(for project: Project, missions: [Mission], needsYouItems: [String: [TrackerItem]]) -> ProjectCard {
        let mine = missions.filter { $0.projectID == project.id && $0.state == .open }
        let local = mine.reduce(0) { $0 + max($1.needsYou, needsYouItems[$1.id]?.count ?? 0) }
        let latest = mine.compactMap(\.lastMilestone).max { $0.createdAt < $1.createdAt }
        return ProjectCard(project: project, needsYouCount: max(project.needsYou, local), latestMilestone: latest)
    }

    /// Needs you first, then anything running, then newest activity.
    static func cardPrecedes(_ a: ProjectCard, _ b: ProjectCard) -> Bool {
        let (na, nb) = (a.needsYouCount > 0, b.needsYouCount > 0)
        if na != nb { return na }
        let (ra, rb) = (a.project.missions.running > 0, b.project.missions.running > 0)
        if ra != rb { return ra }
        let (la, lb) = (a.project.lastActivityAt ?? .distantPast, b.project.lastActivityAt ?? .distantPast)
        if la != lb { return la > lb }
        return a.project.num > b.project.num
    }

    public static func assemble(projects: [Project], missions: [Mission], needsYouItems: [String: [TrackerItem]],
                                now: Date) -> ProjectsHomeSnapshot {
        let openProjects = projects.filter { $0.state == .open }
        let openIDs = Set(openProjects.map(\.id))
        // Unfiled includes a mission whose project this device doesn't know
        // or that closed — it must stay visible somewhere.
        let unfiledRows = missionRows(missions.filter { m in m.projectID.map { !openIDs.contains($0) } ?? true },
                                      needsYouItems: needsYouItems, now: now)
        let closed = missions.filter { $0.state == .closed }.sorted { a, b in
            let (ca, cb) = (a.closedAt ?? .distantPast, b.closedAt ?? .distantPast)
            return ca != cb ? ca > cb : a.num > b.num
        }
        return ProjectsHomeSnapshot(
            cards: openProjects.map { card(for: $0, missions: missions, needsYouItems: needsYouItems) }.sorted(by: cardPrecedes),
            unfiled: unfiledRows.filter { $0.activity != .quiet },
            quiet: unfiledRows.filter { $0.activity == .quiet }.sorted { $0.lastActivity > $1.lastActivity },
            closed: closed,
            statusRefreshedAt: projects.compactMap(\.statusUpdatedAt).max())
    }
}
