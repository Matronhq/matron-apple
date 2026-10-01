import Foundation
import MatronModels

/// The Projects screens' words (spec 2026-09-30 §2), pure so each is a
/// plain test and every surface says it the same way.
public enum ProjectsFormat {
    /// "5 missions · 2 running · 2 waiting · 1 quiet · updated 11m ago";
    /// "6 missions · all quiet · last activity 2d ago".
    public static func countsLine(_ counts: ProjectMissionCounts, statusUpdatedAt: Date?, lastActivityAt: Date?,
                                  now: Date) -> String {
        let total = counts.open
        var parts = ["\(total) mission\(total == 1 ? "" : "s")"]
        if total > 0, counts.quiet == total {
            parts.append("all quiet")
            if let lastActivityAt { parts.append("last activity \(MissionsDashboardFormat.relative(lastActivityAt, now: now))") }
            return parts.joined(separator: " · ")
        }
        if counts.running > 0 { parts.append("\(counts.running) running") }
        if counts.waiting > 0 { parts.append("\(counts.waiting) waiting") }
        if counts.quiet > 0 { parts.append("\(counts.quiet) quiet") }
        if let statusUpdatedAt {
            parts.append("updated \(MissionsDashboardFormat.relative(statusUpdatedAt, now: now))")
        } else if let lastActivityAt {
            parts.append("last activity \(MissionsDashboardFormat.relative(lastActivityAt, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    public static func noStatusLine(latest: MissionLastMilestone?, now: Date) -> String {
        guard let latest else { return "No written status yet" }
        return "No written status yet — latest: “\(latest.title)” (\(MissionsDashboardFormat.relative(latest.createdAt, now: now)))"
    }

    /// The project page's status heading: "STATUS · 12m ago",
    /// "STATUS · just now", "STATUS · on 24 Sep"; bare "STATUS" when unset.
    public static func statusHeading(updatedAt: Date?, now: Date) -> String {
        guard let updatedAt else { return "STATUS" }
        return "STATUS · \(MissionsDashboardFormat.relative(updatedAt, now: now))"
    }

    /// A slim row's second line.
    public static func missionLine(_ mission: Mission, now: Date) -> String {
        if let status = mission.status { return oneLine(status) }
        if let last = mission.lastMilestone {
            return "No status · last milestone \(MissionsDashboardFormat.relative(last.createdAt, now: now)): “\(last.title)”"
        }
        return "No status yet"
    }

    /// A closed slim row's second line: the close summary on one line, or
    /// the closed label when there is no summary or it is only whitespace.
    public static func closedMissionLine(_ mission: Mission) -> String {
        let summary = mission.closeSummary.map(oneLine) ?? ""
        return summary.isEmpty ? MissionGlyph.label(.closed) : summary
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "29 Sep".
    public static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    /// A mission page conversation row's dates: "since 29 Sep (started this
    /// mission)", "joined 29 Sep", "inherited 29 Sep", "29 Sep → 30 Sep".
    public static func linkSpan(joinedAt: Date?, endedAt: Date?, how: String?, timeZone: TimeZone = .current) -> String {
        let joined = joinedAt.map { shortDate($0, timeZone: timeZone) }
        if let endedAt {
            let ended = shortDate(endedAt, timeZone: timeZone)
            return joined.map { "\($0) → \(ended)" } ?? "until \(ended)"
        }
        guard let joined else { return "" }
        switch how {
        case "origin": return "since \(joined) (started this mission)"
        case "inherited": return "inherited \(joined)"
        case "spawned": return "spawned \(joined)"
        default: return "joined \(joined)"
        }
    }

    /// The header list's second line for one mission.
    public static func headerLine(_ link: ConversationMissionLink, timeZone: TimeZone = .current) -> String {
        let joined = link.joinedAt.map { shortDate($0, timeZone: timeZone) }
        if link.isEarlier {
            let end = link.endedAt ?? link.mission.closedAt
            switch (joined, end.map { shortDate($0, timeZone: timeZone) }) {
            case let (j?, e?): return "\(j) → \(e)"
            case let (nil, e?): return "until \(e)"
            case let (j?, nil): return "since \(j)"
            default: return "Earlier"
            }
        }
        if link.isCurrent { return joined.map { "Current · since \($0)" } ?? "Current" }
        return joined.map { "Also on · joined \($0)" } ?? "Also on"
    }

    /// "greg 2 · bev 1 · pat 1": most sessions first, then by name.
    public static func sessionsByBox(_ map: [String: Int]) -> String {
        map.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    /// "3 on it now · 4 earlier · 2 rooms · 11 sub-chats folded".
    public static func conversationsSummary(_ groups: MissionConversationGroups) -> String {
        var parts = ["\(groups.onItNow.count) on it now"]
        if !groups.earlier.isEmpty { parts.append("\(groups.earlier.count) earlier") }
        if !groups.rooms.isEmpty { parts.append("\(groups.rooms.count) room\(groups.rooms.count == 1 ? "" : "s")") }
        let folded = groups.subchatTotal
        if folded > 0 { parts.append("\(folded) sub-chat\(folded == 1 ? "" : "s") folded") }
        return parts.joined(separator: " · ")
    }
}
