import Foundation

/// One row of the project page's "Sessions on it now": a session on at
/// least one of the project's open missions, with every such mission.
public struct ProjectSessionRow: Identifiable, Equatable, Sendable {
    public let session: DashboardSession
    /// The project's open missions the session is on, in the page's order.
    public let missions: [Mission]
    public var id: String { session.id }
    public init(session: DashboardSession, missions: [Mission]) {
        self.session = session; self.missions = missions
    }
}

/// "greg 2" in the sessions summary line.
public struct ProjectBoxCount: Equatable, Hashable, Sendable {
    public let box: String
    public let count: Int
    public init(box: String, count: Int) { self.box = box; self.count = count }
}

/// One mission's share of "Other open items".
public struct ProjectItemGroup: Identifiable, Equatable, Sendable {
    public let missionID: String
    /// The mission when the page knows it (open or closed); nil leaves the
    /// header to the items' own `#num`.
    public let mission: Mission?
    public let items: [TrackerItem]
    public var id: String { missionID }
    public init(missionID: String, mission: Mission?, items: [TrackerItem]) {
        self.missionID = missionID; self.mission = mission; self.items = items
    }

    /// "#4791 Promo branch…", or "#4791" when only the number is known.
    public var title: String {
        if let mission { return mission.label }
        return items.first?.missionNum.map { "#\($0)" } ?? "No mission"
    }
}

/// "Other open items", grouped and folded.
public struct ProjectItemList: Equatable, Sendable {
    public let groups: [ProjectItemGroup]
    /// Every other open item, shown or folded.
    public let total: Int
    /// How many the fold hides (0 when expanded or under the limit).
    public let hidden: Int
    public init(groups: [ProjectItemGroup], total: Int, hidden: Int) {
        self.groups = groups; self.total = total; self.hidden = hidden
    }
}

/// The project page's sessions and items rules (Dan's feedback on the
/// project page, tracker 5671), pure so the Mac and iOS pages share them
/// and each one is a plain test.
public enum ProjectPageSections {
    /// Past this many items, "Other open items" folds behind "Show all (n)".
    public static let foldedItemLimit = 8

    // MARK: Sessions

    /// Every session on the project's open missions, once each, in the
    /// dashboard's session order (`DashboardSession.precedes`). The same
    /// conversations the journal's `sessions_by_box` counts: active links,
    /// top-level only, open missions only.
    public static func sessionRows(_ page: ProjectPageModel) -> [ProjectSessionRow] {
        var order: [String] = []
        var sessions: [String: DashboardSession] = [:]
        var missions: [String: [Mission]] = [:]
        for row in page.missions {
            for session in page.sessionsByMission[row.id] ?? [] {
                if sessions[session.id] == nil { order.append(session.id); sessions[session.id] = session }
                missions[session.id, default: []].append(row.mission)
            }
        }
        return order.compactMap { id in sessions[id].map { ProjectSessionRow(session: $0, missions: missions[id] ?? []) } }
            .sorted { DashboardSession.precedes($0.session, $1.session) }
    }

    /// The summary line's boxes, most sessions first, then by name. Counted
    /// from `rows` so a box's count is exactly what clicking it shows; the
    /// journal's `sessions_by_box` stands in until the missions' sessions
    /// have loaded (no rows yet).
    public static func boxCounts(_ rows: [ProjectSessionRow], fallback: [String: Int]) -> [ProjectBoxCount] {
        var counts: [String: Int] = [:]
        if rows.isEmpty {
            counts = fallback
        } else {
            for row in rows { if let box = row.session.box { counts[box, default: 0] += 1 } }
        }
        return counts.map { ProjectBoxCount(box: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.box < $1.box }
    }

    /// The box filter in force: `selected` while it still has sessions,
    /// else none (the box emptied since it was clicked).
    public static func activeBox(_ selected: String?, in counts: [ProjectBoxCount]) -> String? {
        guard let selected, counts.contains(where: { $0.box == selected }) else { return nil }
        return selected
    }

    /// Whether "Sessions on it now" has anything to show at all: live rows
    /// (even when none of them name a box — a single-box journal never
    /// tags its sessions), or, before the missions' sessions have loaded,
    /// the journal's box-count fallback.
    public static func showsSessionsCard(rows: [ProjectSessionRow], counts: [ProjectBoxCount]) -> Bool {
        !rows.isEmpty || !counts.isEmpty
    }

    /// Whether the box summary/filter line is worth showing: only once
    /// there are 2+ named boxes to tell apart. A single box, or none named
    /// at all, has nothing for it to filter.
    public static func showsBoxFilter(_ counts: [ProjectBoxCount]) -> Bool {
        counts.count > 1
    }

    /// `rows` on `box`, or every row when `box` is nil.
    public static func rows(_ rows: [ProjectSessionRow], onBox box: String?) -> [ProjectSessionRow] {
        guard let box else { return rows }
        return rows.filter { $0.session.box == box }
    }

    /// What clicking `box` in the summary line selects: the box, or none
    /// when it was already selected (a second click clears).
    public static func toggled(_ selected: String?, box: String) -> String? {
        selected == box ? nil : box
    }

    // MARK: Items

    /// The "Other open items" heading's count: the journal's open items
    /// less Needs you, or the rows this device has, whichever is more — a
    /// cache that has not caught up never under-reports, and the list
    /// never outnumbers it.
    public static func otherOpenItemCount(_ page: ProjectPageModel) -> Int {
        max(0, page.project.openItems - page.needsYou.count, otherItems(page).count)
    }

    /// The project's open items that Needs you does not already list.
    public static func otherItems(_ page: ProjectPageModel) -> [TrackerItem] {
        let shown = Set(page.needsYou.map(\.id))
        return page.openItems.filter { !shown.contains($0.id) }
    }

    /// "Other open items" grouped by mission — the page's open missions in
    /// its order, then its closed ones, then any other mission by number —
    /// each group awaiting-you first, then awaiting an agent, then the
    /// rest, newest first. Unless `expanded`, only the first
    /// `foldedItemLimit` items show; the groups are cut to match.
    public static func itemList(_ page: ProjectPageModel, expanded: Bool) -> ProjectItemList {
        let items = otherItems(page)
        var byMission: [String: [TrackerItem]] = [:]
        for item in items { if let id = item.missionID { byMission[id, default: []].append(item) } }
        let known = page.missions.map(\.mission) + page.closedMissions
        var missionsByID: [String: Mission] = [:]
        for mission in known where missionsByID[mission.id] == nil { missionsByID[mission.id] = mission }
        var order: [String] = []
        for mission in known where byMission[mission.id] != nil && !order.contains(mission.id) { order.append(mission.id) }
        let others = byMission.keys.filter { missionsByID[$0] == nil }.sorted { a, b in
            let (numA, numB) = (byMission[a]?.first?.missionNum ?? 0, byMission[b]?.first?.missionNum ?? 0)
            return numA != numB ? numA > numB : a < b
        }
        order += others
        var remaining = expanded ? Int.max : foldedItemLimit
        var groups: [ProjectItemGroup] = []
        var shown = 0
        for id in order where remaining > 0 {
            let sorted = (byMission[id] ?? []).sorted(by: itemPrecedes)
            let slice = Array(sorted.prefix(remaining))
            remaining -= slice.count
            shown += slice.count
            groups.append(ProjectItemGroup(missionID: id, mission: missionsByID[id], items: slice))
        }
        let total = byMission.values.reduce(0) { $0 + $1.count }
        return ProjectItemList(groups: groups, total: total, hidden: total - shown)
    }

    /// Awaiting you, then awaiting an agent, then neither; newest first;
    /// the higher number breaks a tie.
    static func itemPrecedes(_ a: TrackerItem, _ b: TrackerItem) -> Bool {
        let (rankA, rankB) = (awaitingRank(a.awaiting), awaitingRank(b.awaiting))
        if rankA != rankB { return rankA < rankB }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.num > b.num
    }

    private static func awaitingRank(_ awaiting: ItemAwaiting?) -> Int {
        switch awaiting {
        case .user: return 0
        case .agent: return 1
        case nil: return 2
        }
    }
}
