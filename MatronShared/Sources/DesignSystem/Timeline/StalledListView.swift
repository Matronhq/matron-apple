import SwiftUI
import MatronModels

/// "Went quiet" or "Open a long time": a short lede, then one row per
/// project with where it was left, when it last moved, a small chart of
/// its last seven weeks and one action, asking the Coordinator about it.
/// The row opens the project.
public struct StalledListView: View {
    let title: String
    let lede: String
    let list: StalledList
    let now: Date
    let onOpenProject: (String) -> Void
    let onAsk: (StalledProject) -> Void
    /// Projects already asked about: their row says so, quietly, instead.
    let asked: Set<String>

    public init(title: String, lede: String, list: StalledList, now: Date, onOpenProject: @escaping (String) -> Void,
                onAsk: @escaping (StalledProject) -> Void, asked: Set<String> = []) {
        self.title = title; self.lede = lede; self.list = list; self.now = now
        self.onOpenProject = onOpenProject; self.onAsk = onAsk; self.asked = asked
    }

    #if os(macOS)
    static let rowTitleFont = Font.system(size: 18, weight: .semibold)
    static let noteFont = Font.system(size: 15)
    static let metaFont = Font.system(size: 13)
    static let actionFont = Font.system(size: 14)
    static let chartCaptionFont = Font.system(size: 12)
    #else
    static let rowTitleFont = Font.headline
    static let noteFont = Font.body
    static let metaFont = Font.footnote
    static let actionFont = Font.subheadline
    static let chartCaptionFont = Font.caption
    #endif

    public var body: some View {
        GeometryReader { geo in
            ScrollView { page(wide: geo.size.width >= TimelinePage.wideWidth) }
        }
    }

    private func page(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineListHeader(title: title, lede: lede)
                .padding(.bottom, 18)
            ForEach(list.rows, id: \.project.id) { row in
                Divider()
                rowView(row, wide: wide).padding(.vertical, 18)
            }
            if let more = TimelineFormat.moreRows(list.total - list.rows.count) {
                Divider()
                Text(more).font(Self.metaFont).foregroundStyle(.secondary).padding(.vertical, 18)
            }
        }
        .padding(TimelinePage.padding)
        .frame(maxWidth: TimelineListHeader.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Wide, the chart stands to the right of the row; narrow, it shares
    /// the "Last moved" line so the words keep the width.
    private func rowView(_ row: StalledProject, wide: Bool) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.project.title).font(Self.rowTitleFont)
                if let note = row.note, !note.isEmpty {
                    Text(MissionsDashboardFormat.statusPreviewText(note)).font(Self.noteFont).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    if let lastMoved = TimelineFormat.lastMoved(row.lastMovedAt, now: now) {
                        Text(lastMoved).font(Self.metaFont).foregroundStyle(.secondary)
                    }
                    if !wide {
                        Spacer(minLength: 0)
                        TimelineActivityChart(weekly: row.weekly)
                    }
                }
                if asked.contains(row.project.id) {
                    Text(TimelineFormat.askedAction).font(Self.actionFont).foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityIdentifier("timeline.stalled.asked.\(row.project.num)")
                } else {
                    Button { onAsk(row) } label: {
                        Text(TimelineFormat.askAction + " ›").font(Self.actionFont).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityIdentifier("timeline.stalled.ask.\(row.project.num)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if wide {
                TimelineActivityChart(weekly: row.weekly).padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenProject(row.project.id) }
        .accessibilityAction(named: Text("Open project")) { onOpenProject(row.project.id) }
        .accessibilityIdentifier("timeline.stalled.\(row.project.num)")
    }
}

/// A list page's title and lede.
struct TimelineListHeader: View {
    /// Lines of reading text stay this wide on a wide window.
    static let maxWidth: CGFloat = 860

    let title: String
    let lede: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(TimelinePage.titleFont).accessibilityAddTraits(.isHeader)
            if let lede {
                Text(lede).font(TimelinePage.ledeFont).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Seven weeks of moves as small bars, newest on the right; a week
/// without any is a short grey dash. Pale, so it reads as a hint.
struct TimelineActivityChart: View {
    let weekly: [Int]

    private static let barWidth: CGFloat = 9
    private static let maxHeight: CGFloat = 22

    var body: some View {
        let bars = TimelineFormat.chartBars(weekly)
        let peak = max(bars.max() ?? 0, 1)
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bars.indices, id: \.self) { index in
                    if bars[index] > 0 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.blue.opacity(0.28))
                            .frame(width: Self.barWidth,
                                   height: max(5, Self.maxHeight * CGFloat(bars[index]) / CGFloat(peak)))
                    } else {
                        Capsule().fill(Color.primary.opacity(0.10)).frame(width: Self.barWidth, height: 2.5)
                    }
                }
            }
            .frame(height: Self.maxHeight, alignment: .bottom)
            Text(TimelineFormat.chartCaption).font(StalledListView.chartCaptionFont).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Moves in the last seven weeks, oldest first: "
                            + bars.map(String.init).joined(separator: ", "))
    }
}
