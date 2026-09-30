import SwiftUI
import MatronModels

/// The project page as one `List` (spec §6: "a single List on iOS"). The
/// Mac draws its own two-column page from the same `ProjectPageModel`.
public struct ProjectDetailView: View {
    let page: ProjectPageModel
    let now: Date?
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenMilestone: (Milestone) -> Void
    let onMoveMission: (String, String?) -> Void
    let onRefresh: () async -> Void
    @State private var showClosed = false

    public init(page: ProjectPageModel, now: Date? = nil, onOpenMission: @escaping (String) -> Void,
                onOpenItem: @escaping (String) -> Void, onOpenMilestone: @escaping (Milestone) -> Void,
                onMoveMission: @escaping (String, String?) -> Void, onRefresh: @escaping () async -> Void) {
        self.page = page; self.now = now; self.onOpenMission = onOpenMission; self.onOpenItem = onOpenItem
        self.onOpenMilestone = onOpenMilestone; self.onMoveMission = onMoveMission; self.onRefresh = onRefresh
    }

    public var body: some View {
        List {
            Section { header }
            if let status = page.project.status { Section { statusCard(status) } }
            if !page.needsYou.isEmpty { needsYouSection }
            missionsSection
            if !page.recentMilestones.isEmpty { milestonesSection }
            if !page.sessionsByBox.isEmpty {
                Section("Sessions on it now") {
                    Text(ProjectsFormat.sessionsByBox(page.sessionsByBox)).font(.subheadline)
                }
            }
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
        }
    }

    private func statusCard(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(MissionsDashboardFormat.statusText(status)).font(.body)
        }
    }

    private var statusHeading: String {
        ProjectsFormat.statusHeading(updatedAt: page.project.statusUpdatedAt, now: now ?? Date())
    }

    private var needsYouSection: some View {
        Section {
            ForEach(page.needsYou) { item in
                Button { onOpenItem(item.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(.red)
                        Text(item.title).lineLimit(2)
                        Spacer(minLength: 4)
                        if let num = item.missionNum { Text(verbatim: "#\(num)").font(.caption.monospacedDigit()).foregroundStyle(.blue) }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        } header: {
            Text("Needs you · \(page.needsYouCount)").foregroundStyle(.red)
        }
    }

    private var missionsSection: some View {
        Section("Missions") {
            ForEach(page.missions) { row in
                Button { onOpenMission(row.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MissionRowView(row: row, now: now)
                        SessionChipLine(sessions: page.sessionsByMission[row.id] ?? [])
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
                .contextMenu {
                    MoveToProjectMenu(currentProjectID: row.mission.projectID,
                                      targets: page.mergeTargets + (page.project.state == .open ? [page.project] : [])) { onMoveMission(row.id, $0) }
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

    private var milestonesSection: some View {
        Section("Latest steps") {
            ForEach(page.recentMilestones) { milestone in
                Button { onOpenMilestone(milestone) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: MissionGlyph.symbol(milestone.kind)).font(.caption2)
                            .foregroundStyle(MissionGlyph.tint(milestone.kind))
                        Text(milestone.title).lineLimit(2)
                        if let num = page.missionNums[milestone.missionID] {
                            Text(verbatim: "#\(num)").font(.caption.monospacedDigit()).foregroundStyle(.blue)
                        }
                        Spacer(minLength: 4)
                        Text(RelativeMinuteTimeView.format(milestone.createdAt, now: now ?? Date()))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.primary)
            }
        }
    }
}
