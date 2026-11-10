import SwiftUI
import MatronModels

/// A project's missions: the open ones by name, each with one line on
/// where it stands, then the finished ones under "Done" with how they
/// ended. A row opens its mission.
public struct ProjectMissionsListView: View {
    let open: [MissionRowModel]
    let closed: [Mission]
    let now: Date
    let onOpenMission: (String) -> Void

    /// `now` dates the line of a mission with no status ("last milestone 2h ago").
    public init(open: [MissionRowModel], closed: [Mission], now: Date, onOpenMission: @escaping (String) -> Void) {
        self.open = open; self.closed = closed; self.now = now; self.onOpenMission = onOpenMission
    }

    private typealias M = ProjectPageMetrics

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                TimelineListHeader(title: TimelineFormat.sectionTitle(.missions), lede: nil)
                    .padding(.bottom, 14)
                ForEach(open) { row in
                    Divider()
                    missionRow(row.mission, line: ProjectsFormat.missionLine(row.mission, now: now))
                }
                if !closed.isEmpty {
                    ProjectPageHeading(TimelineFormat.doneHeading)
                        .padding(.top, open.isEmpty ? 0 : 28).padding(.bottom, 10)
                    ForEach(closed) { mission in
                        Divider()
                        missionRow(mission, line: ProjectsFormat.closedMissionLine(mission))
                    }
                }
            }
            .frame(maxWidth: M.readableWidth, alignment: .leading)
            .padding(TimelinePage.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("projects.missions")
    }

    private func missionRow(_ mission: Mission, line: String) -> some View {
        Button { onOpenMission(mission.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(mission.title).font(M.rowFont.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(2)
                Text(line).font(M.detailFont).foregroundStyle(.secondary).lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("projects.missions.\(mission.num)")
    }
}
