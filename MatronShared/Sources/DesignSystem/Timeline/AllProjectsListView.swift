import SwiftUI
import MatronModels

/// "All projects": every project, the most recently moved first, each with
/// when it last moved. A row opens the project; reaching the end loads the
/// next page (`onLoadMore` nil when there is none).
public struct AllProjectsListView: View {
    let list: TimelineProjectList
    let now: Date
    let onOpenProject: (String) -> Void
    let onLoadMore: (() -> Void)?

    public init(list: TimelineProjectList, now: Date, onOpenProject: @escaping (String) -> Void,
                onLoadMore: (() -> Void)?) {
        self.list = list; self.now = now; self.onOpenProject = onOpenProject; self.onLoadMore = onLoadMore
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                TimelineListHeader(title: TimelineFormat.allProjects, lede: nil)
                    .padding(.bottom, 14)
                if list.rows.isEmpty {
                    Text(TimelineFormat.noProjects).font(TimelinePage.ledeFont).foregroundStyle(.secondary)
                        .accessibilityIdentifier("timeline.projects.empty")
                }
                ForEach(list.rows, id: \.project.id) { row in
                    Divider()
                    Button { onOpenProject(row.project.id) } label: { rowView(row) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.projects.\(row.project.num)")
                }
                if let onLoadMore {
                    // Reaching the end asks for the next page. Keyed by the
                    // row count, so a page too short to scroll still asks
                    // for the one after it.
                    Color.clear.frame(height: 1).id(list.rows.count).onAppear(perform: onLoadMore)
                }
            }
            .padding(TimelinePage.padding)
            .frame(maxWidth: TimelineListHeader.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowView(_ row: TimelineProjectRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.project.title).font(FinishedListView.rowFont).foregroundStyle(Color.primary).lineLimit(2)
            Spacer(minLength: 12)
            if let moved = TimelineFormat.moved(row.lastMovedAt, now: now) {
                Text(moved).font(FinishedListView.metaFont).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
