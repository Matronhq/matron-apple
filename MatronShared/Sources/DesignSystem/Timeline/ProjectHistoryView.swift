import SwiftUI
import MatronModels

/// "This week and before": a project week by week, newest first. Each week
/// has its heading ("This week", "Last week", then dates), that week's
/// sentence and picture when the project had a card, and its milestones,
/// one line each with the day, then "4 more" for those not listed. A
/// milestone opens through `onOpenMilestone`; reaching the end asks for
/// older weeks while `hasMore`.
public struct ProjectHistoryView: View {
    let weeks: [TimelineHistoryWeek]
    let now: Date
    let images: [String: Image]
    let sizes: [String: CGSize]
    let hasMore: Bool
    let onOpenMilestone: (ProjectMilestone) -> Void
    let onLoadMore: () -> Void

    public init(weeks: [TimelineHistoryWeek], now: Date, images: [String: Image], sizes: [String: CGSize] = [:],
                hasMore: Bool, onOpenMilestone: @escaping (ProjectMilestone) -> Void,
                onLoadMore: @escaping () -> Void) {
        self.weeks = weeks; self.now = now; self.images = images; self.sizes = sizes
        self.hasMore = hasMore; self.onOpenMilestone = onOpenMilestone; self.onLoadMore = onLoadMore
    }

    private typealias M = ProjectPageMetrics

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                TimelineListHeader(title: TimelineFormat.sectionTitle(.history), lede: nil)
                ForEach(weeks, id: \.week) { week in section(week) }
                if hasMore {
                    // Keyed by the week count, so a page too short to
                    // scroll still asks for the one after it.
                    Color.clear.frame(height: 1).id(weeks.count).onAppear(perform: onLoadMore)
                }
            }
            .frame(maxWidth: M.readableWidth, alignment: .leading)
            .padding(TimelinePage.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("projects.history")
    }

    private func section(_ week: TimelineHistoryWeek) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectPageHeading(TimelineFormat.historyWeekTitle(week, now: now))
            if let sentence = week.sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                Text(MissionsDashboardFormat.statusPreviewText(sentence))
                    .font(M.sentenceFont).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let media = week.media {
                let shape = RoundedRectangle(cornerRadius: M.pictureCorner, style: .continuous)
                TimelineMediaView(media: media, image: images[media.blobID], pixelSize: sizes[media.blobID])
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
                    .frame(maxWidth: M.historyPictureWidth)
            }
            milestones(week)
        }
        .accessibilityIdentifier("projects.history.\(week.week)")
    }

    @ViewBuilder private func milestones(_ week: TimelineHistoryWeek) -> some View {
        let more = TimelineFormat.moreMilestones(week.moreMilestones)
        if !week.milestones.isEmpty || more != nil {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(week.milestones) { milestone in
                    Button { onOpenMilestone(milestone) } label: { row(milestone) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projects.history.milestone.\(milestone.milestone.num)")
                    Divider()
                }
                if let more {
                    Text(more).font(M.detailFont).foregroundStyle(.secondary).padding(.top, 9)
                }
            }
        }
    }

    private func row(_ milestone: ProjectMilestone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(ProjectsFormat.oneLine(milestone.milestone.title)).font(M.rowFont).foregroundStyle(Color.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(TimelineFormat.weekday(milestone.milestone.createdAt)).font(M.detailFont).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
