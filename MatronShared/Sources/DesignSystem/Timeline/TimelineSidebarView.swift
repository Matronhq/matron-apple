import SwiftUI
import MatronModels

/// The timeline's list: the weeks newest first, by their dates alone,
/// "Earlier weeks ›" when there are more, "All projects" with its count,
/// then "Worth a look": Went quiet, Open a long time and Finished, each
/// with one count. Text only.
public struct TimelineSidebarView: View {
    let weeks: [TimelineWeekSummary]
    let projectsCount: Int?
    let quietCount: Int?
    let longCount: Int?
    let finishedCount: Int?
    @Binding var selection: TimelinePlace?
    /// nil when there are no earlier weeks to load.
    let onLoadEarlier: (() -> Void)?

    public init(weeks: [TimelineWeekSummary], projectsCount: Int?, quietCount: Int?, longCount: Int?,
                finishedCount: Int?, selection: Binding<TimelinePlace?>, onLoadEarlier: (() -> Void)?) {
        self.weeks = weeks; self.projectsCount = projectsCount; self.quietCount = quietCount
        self.longCount = longCount; self.finishedCount = finishedCount
        self._selection = selection; self.onLoadEarlier = onLoadEarlier
    }

    #if os(macOS)
    private static let titleFont = Font.system(size: 14, weight: .semibold)
    private static let entryFont = Font.system(size: 14)
    private static let smallFont = Font.system(size: 12)
    private static let rowInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    #else
    private static let titleFont = Font.subheadline.weight(.semibold)
    private static let entryFont = Font.body
    private static let smallFont = Font.footnote
    private static let rowInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    #endif

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.element.week) { index, week in
                    weekRow(week, index: index)
                }
                if let onLoadEarlier {
                    Button(action: onLoadEarlier) {
                        Text(TimelineFormat.earlierWeeks + TimelineFormat.opensMark)
                            .font(Self.smallFont.weight(.medium)).foregroundStyle(.secondary)
                            .padding(Self.rowInsets)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(TimelineFormat.earlierWeeks)
                    .accessibilityIdentifier("timeline.sidebar.earlier")
                }
                entry(.projects, symbol: ProjectGlyph.symbol, TimelineFormat.allProjects, count: projectsCount)
                    .padding(.top, 10)
                Text(TimelineFormat.worthALook)
                    .font(Self.smallFont.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    .padding(.horizontal, Self.rowInsets.leading)
                    .padding(.top, 14).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                entry(.quiet, symbol: "circle.lefthalf.filled", TimelineFormat.wentQuiet, count: quietCount)
                entry(.long, symbol: "hourglass", TimelineFormat.openLong, count: longCount)
                entry(.finished, symbol: "checkmark", TimelineFormat.finished, count: finishedCount)
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weekRow(_ week: TimelineWeekSummary, index: Int) -> some View {
        row(.week(week.week), id: "week.\(week.week)") {
            Text(TimelineFormat.sidebarTitle(index: index, week: week.week))
                .font(Self.titleFont).foregroundStyle(Color.primary).lineLimit(1)
        }
    }

    private func entry(_ place: TimelinePlace, symbol: String, _ title: String, count: Int?) -> some View {
        row(place, id: "\(place)") {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(Color.primary)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(Self.entryFont)
        }
    }

    private func row(_ place: TimelinePlace, id: String, @ViewBuilder label: () -> some View) -> some View {
        let selected = selection == place
        return Button { selection = place } label: {
            label()
                .padding(Self.rowInsets)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("timeline.sidebar.\(id)")
    }
}
