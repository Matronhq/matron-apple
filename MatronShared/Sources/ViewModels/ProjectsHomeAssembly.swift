import Foundation
import MatronModels

/// A project page's mission rows and their order (spec 2026-09-30 §2),
/// pure so every rule is a plain unit test.
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
}
