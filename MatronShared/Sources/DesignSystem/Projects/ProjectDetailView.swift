import SwiftUI
import MatronModels

/// The project page as one `List` (spec §6: "a single List on iOS"), in the
/// Mac page's order — its left column (needs you, decisions, milestones),
/// then its right (files, missions, sessions, other items). The Mac draws
/// its own two-column page from the same `ProjectPageModel`.
///
/// Decisions, files and the day-grouped milestones are the journal's
/// roll-up (Projects view v2); without it (`hasFeed` false) the page is
/// today's, with "Latest steps" from `recentMilestones`.
public struct ProjectDetailView: View {
    let page: ProjectPageModel
    let now: Date?
    /// Feed kinds with a "Show all" in flight (`ProjectDetailViewModel.loadingMore`).
    let loadingMore: Set<ProjectFeedKind>
    /// File thumbnails the host has loaded, by blob id.
    let images: [String: Image]
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenSession: (String) -> Void
    let onOpenMilestone: (Milestone) -> Void
    let onOpenFile: (ProjectFile) -> Void
    let onLoadMore: (ProjectFeedKind) -> Void
    let onMoveMission: (String, String) -> Void
    let onRefresh: () async -> Void
    @State private var showClosed = false
    @State private var showsAllItems = false

    public init(page: ProjectPageModel, now: Date? = nil, loadingMore: Set<ProjectFeedKind> = [],
                images: [String: Image] = [:], onOpenMission: @escaping (String) -> Void,
                onOpenItem: @escaping (String) -> Void, onOpenSession: @escaping (String) -> Void,
                onOpenMilestone: @escaping (Milestone) -> Void, onOpenFile: @escaping (ProjectFile) -> Void = { _ in },
                onLoadMore: @escaping (ProjectFeedKind) -> Void = { _ in },
                onMoveMission: @escaping (String, String) -> Void, onRefresh: @escaping () async -> Void) {
        self.page = page; self.now = now; self.loadingMore = loadingMore; self.images = images
        self.onOpenMission = onOpenMission; self.onOpenItem = onOpenItem; self.onOpenSession = onOpenSession
        self.onOpenMilestone = onOpenMilestone; self.onOpenFile = onOpenFile; self.onLoadMore = onLoadMore
        self.onMoveMission = onMoveMission; self.onRefresh = onRefresh
    }

    public var body: some View {
        List {
            Section { header }
            if let status = page.project.status { Section { statusCard(status) } }
            if !page.needsYou.isEmpty { needsYouSection }
            if !page.decisions.rows.isEmpty { decisionsSection }
            if page.hasFeed {
                if !page.milestonesPage.rows.isEmpty { milestonesSection }
            } else if !page.recentMilestones.isEmpty {
                latestStepsSection
            }
            if !page.files.rows.isEmpty { filesSection }
            missionsSection
            sessionsSection
            otherItemsSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MatronTimelineBackground())
        .refreshable { await onRefresh() }
        #else
        .listStyle(.inset)
        #endif
    }

    private var clock: Date { now ?? Date() }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.project.title).font(.title2.weight(.bold))
                Spacer(minLength: 8)
                NeedsYouPill(count: page.needsYouCount)
            }
            if !page.project.body.isEmpty {
                Text(MissionsDashboardFormat.statusText(page.project.body)).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(ProjectFeedFormat.pageMetaLine(page, now: clock)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusCard(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(MissionsDashboardFormat.statusText(status)).font(.body)
        }
    }

    private var statusHeading: String {
        ProjectsFormat.statusHeading(updatedAt: page.project.statusUpdatedAt, now: clock)
    }

    private var needsYouSection: some View {
        Section {
            ForEach(page.needsYou) { item in
                Button { onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).lineLimit(2)
                        Spacer(minLength: 4)
                        if let num = item.missionNum { missionChip(num) }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        } header: {
            Text("Needs you · \(page.needsYouCount)").foregroundStyle(.red)
        }
    }

    // MARK: Roll-up

    private var decisionsSection: some View {
        Section {
            ForEach(page.decisions.rows) { decision in
                Button { onOpenItem(decision.id) } label: { decisionRow(decision) }
                    .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
            if page.decisions.hasMore { showAll(.decisions, title: "Show all") }
        } header: {
            Text("Decisions · \(ProjectFeedFormat.feedCount(page.decisions))")
        }
    }

    private func decisionRow(_ decision: ProjectDecision) -> some View {
        let mark = ProjectDecisionMark(decision)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark.symbol).foregroundStyle(mark.tint).accessibilityLabel(mark.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.title).lineLimit(3).strikethrough(mark.isStruck)
                    .foregroundStyle(mark.isStruck ? Color.secondary : Color.primary)
                if let answer = decision.answer, !answer.isEmpty {
                    Text(answer).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let num = decision.missionNum { missionChip(num) }
                Text(ProjectFeedFormat.dayLabel(decision.at, now: clock)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var milestonesSection: some View {
        Section {
            ForEach(ProjectFeedFormat.milestoneDays(page.milestonesPage.rows, now: clock)) { day in
                Text(day.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(day.rows) { row in
                    Button { onOpenMilestone(row.milestone) } label: {
                        milestoneRow(row.milestone, missionNum: row.missionNum,
                                     time: ProjectFeedFormat.timeOfDay(row.milestone.createdAt))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
            }
            if page.milestonesPage.hasMore { showAll(.milestones, title: "Show more") }
        } header: {
            Text("Milestones · \(ProjectFeedFormat.feedCount(page.milestonesPage))")
        }
    }

    /// A journal without the roll-up: today's "Latest steps".
    private var latestStepsSection: some View {
        Section("Latest steps") {
            ForEach(page.recentMilestones) { milestone in
                Button { onOpenMilestone(milestone) } label: {
                    milestoneRow(milestone, missionNum: page.missionNums[milestone.missionID],
                                 time: RelativeMinuteTimeView.format(milestone.createdAt, now: clock))
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        }
    }

    private func milestoneRow(_ milestone: Milestone, missionNum: Int?, time: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: MissionGlyph.symbol(milestone.kind)).font(.caption2)
                .foregroundStyle(MissionGlyph.tint(milestone.kind))
                .accessibilityLabel(MissionGlyph.label(milestone.kind))
            Text(milestone.title).lineLimit(2)
            Spacer(minLength: 4)
            if let missionNum { missionChip(missionNum) }
            Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var filesSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                      alignment: .leading, spacing: 12) {
                ForEach(page.files.rows) { file in
                    Button { onOpenFile(file) } label: {
                        ProjectFileTile(file: file, image: images[file.blobID], now: clock)
                    }
                    // Each tile its own tap target inside the one List row.
                    .buttonStyle(.borderless).foregroundStyle(Color.primary)
                }
            }
            .padding(.vertical, 4)
            if page.files.hasMore { showAll(.files, title: "Show all") }
        } header: {
            Text("Files and images · \(page.files.total)")
        }
    }

    /// "Show all" / "Show more", a spinner while that page loads.
    private func showAll(_ kind: ProjectFeedKind, title: String) -> some View {
        HStack(spacing: 8) {
            Button(title) { onLoadMore(kind) }
                .disabled(loadingMore.contains(kind))
                .accessibilityIdentifier("projects.page.\(kind.rawValue).more")
            if loadingMore.contains(kind) { ProgressView().controlSize(.small) }
        }
    }

    private func missionChip(_ num: Int) -> some View {
        Text(verbatim: "#\(num)").font(.caption.monospacedDigit()).foregroundStyle(.blue)
    }

    // MARK: Missions, sessions, items

    private var missionsSection: some View {
        Section("Missions") {
            ForEach(page.missions) { row in
                Button { onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MissionRowView(row: row, now: now)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [],
                                        roomCount: page.roomCountsByMission[row.id] ?? 0)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: row.mission.projectID,
                                      targets: page.moveTargets) { onMoveMission(row.id, $0) }
                }
            }
            if !page.closedMissions.isEmpty {
                DisclosureGroup("Closed (\(page.closedMissions.count))", isExpanded: $showClosed) {
                    ForEach(page.closedMissions) { mission in
                        Button { onOpenMission(mission.id) } label: {
                            MissionRowView(row: MissionRowModel(closed: mission), now: now)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }

    /// The box counts on one line when 2+ boxes are named, then a row per
    /// session (tap opens its conversation) — the Mac page's rows without
    /// its box filter; shown even when no session names a box at all.
    @ViewBuilder private var sessionsSection: some View {
        let rows = ProjectPageSections.sessionRows(page)
        let counts = ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox)
        if ProjectPageSections.showsSessionsCard(rows: rows, counts: counts) {
            Section("Sessions on it now") {
                if ProjectPageSections.showsBoxFilter(counts) {
                    Text(ProjectsFormat.boxCounts(counts)).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button { onOpenSession(row.id) } label: { ProjectSessionRowView(row: row) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
            }
        }
    }

    /// The missions' open items Needs you does not list, grouped by
    /// mission, folded past `ProjectPageSections.foldedItemLimit`.
    @ViewBuilder private var otherItemsSection: some View {
        let list = ProjectPageSections.itemList(page, expanded: showsAllItems)
        let count = ProjectPageSections.otherOpenItemCount(page)
        if count > 0 {
            Section("Other open items · \(count)") {
                ForEach(list.groups) { group in
                    Button { onOpenMission(group.missionID) } label: {
                        Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    ForEach(group.items) { item in
                        Button { onOpenItem(item.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(ItemGlyph.tint(item.kind))
                                Text(item.title).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                    }
                }
                if list.total > ProjectPageSections.foldedItemLimit {
                    Button(showsAllItems ? "Show fewer" : "Show all (\(list.total))") { showsAllItems.toggle() }
                }
            }
        }
    }
}
