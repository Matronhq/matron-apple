import SwiftUI
import MatronModels

/// One project on the home screen (spec §2): title and needs-you, ONE
/// status paragraph, the state bar, the counts. Nothing from two levels down.
public struct ProjectCardView: View {
    let card: ProjectCard
    let now: Date
    let onOpen: () -> Void
    public init(card: ProjectCard, now: Date, onOpen: @escaping () -> Void) {
        self.card = card; self.now = now; self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) { content }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityIdentifier("projects.card.\(card.project.num)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            status
            ProjectActivityBar(counts: card.project.missions)
            Text(ProjectsFormat.countsLine(card.project.missions, statusUpdatedAt: card.project.statusUpdatedAt,
                                           lastActivityAt: card.project.lastActivityAt, now: now))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DashboardCardChrome())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(card.project.title).font(.headline).lineLimit(2)
            Spacer(minLength: 8)
            NeedsYouPill(count: card.needsYouCount)
        }
    }

    @ViewBuilder private var status: some View {
        if let text = card.project.status {
            Text(MissionsDashboardFormat.statusText(text)).font(.subheadline).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(ProjectsFormat.noStatusLine(latest: card.latestMilestone, now: now))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}
