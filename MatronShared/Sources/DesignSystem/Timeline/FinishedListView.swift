import SwiftUI
import MatronModels

/// "Finished": projects with nothing left open, newest first, each with
/// when it finished, or one calm line when there are none. A row opens the
/// project; reaching the end loads the next page (`onLoadMore` nil when
/// there is none).
public struct FinishedListView: View {
    let rows: [FinishedProject]
    let now: Date
    let onOpenProject: (String) -> Void
    let onLoadMore: (() -> Void)?

    public init(rows: [FinishedProject], now: Date, onOpenProject: @escaping (String) -> Void,
                onLoadMore: (() -> Void)?) {
        self.rows = rows; self.now = now; self.onOpenProject = onOpenProject; self.onLoadMore = onLoadMore
    }

    #if os(macOS)
    static let rowFont = Font.system(size: 15)
    static let metaFont = Font.system(size: 13)
    #else
    static let rowFont = Font.body
    static let metaFont = Font.footnote
    #endif

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                TimelineListHeader(title: TimelineFormat.finished, lede: nil)
                    .padding(.bottom, 14)
                if rows.isEmpty {
                    Text(TimelineFormat.nothingFinished).font(TimelinePage.ledeFont).foregroundStyle(.secondary)
                        .accessibilityIdentifier("timeline.finished.empty")
                }
                ForEach(rows, id: \.project.id) { row in
                    Divider()
                    Button { onOpenProject(row.project.id) } label: { rowView(row) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.finished.\(row.project.num)")
                }
                if let onLoadMore {
                    // Reaching the end asks for the next page. Keyed by the
                    // row count, so a page too short to scroll still asks
                    // for the one after it.
                    Color.clear.frame(height: 1).id(rows.count).onAppear(perform: onLoadMore)
                }
            }
            .padding(TimelinePage.padding)
            .frame(maxWidth: TimelineListHeader.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowView(_ row: FinishedProject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.project.title).font(Self.rowFont).foregroundStyle(Color.primary).lineLimit(2)
            Spacer(minLength: 12)
            Text(TimelineFormat.daysAgo(row.finishedAt, now: now))
                .font(Self.metaFont).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
