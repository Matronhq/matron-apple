import SwiftUI
import MatronModels

/// The timeline's list: the weeks newest first, each with its sentence,
/// "Earlier weeks ›" when there are more, then "Worth a look": Went quiet,
/// Open a long time and Finished, each with one count. Text only.
public struct TimelineSidebarView: View {
    let weeks: [TimelineWeekSummary]
    let quietCount: Int?
    let longCount: Int?
    let finishedCount: Int?
    @Binding var selection: TimelinePlace?
    /// nil when there are no earlier weeks to load.
    let onLoadEarlier: (() -> Void)?

    public init(weeks: [TimelineWeekSummary], quietCount: Int?, longCount: Int?, finishedCount: Int?,
                selection: Binding<TimelinePlace?>, onLoadEarlier: (() -> Void)?) {
        self.weeks = weeks; self.quietCount = quietCount; self.longCount = longCount
        self.finishedCount = finishedCount; self._selection = selection; self.onLoadEarlier = onLoadEarlier
    }

    #if os(macOS)
    private static let titleFont = Font.system(size: 14, weight: .semibold)
    private static let datesFont = Font.system(size: 14)
    private static let sentenceFont = Font.system(size: 13)
    private static let entryFont = Font.system(size: 14)
    private static let smallFont = Font.system(size: 12)
    private static let rowInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    #else
    private static let titleFont = Font.subheadline.weight(.semibold)
    private static let datesFont = Font.subheadline
    private static let sentenceFont = Font.subheadline
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
        let title = TimelineFormat.sidebarTitle(index: index, week: week.week)
        let dates = index < 2 ? TimelineFormat.shortRange(week.week) : nil
        return row(.week(week.week), id: "week.\(week.week)") {
            VStack(alignment: .leading, spacing: 3) {
                (Text(title).font(Self.titleFont).foregroundStyle(Color.primary)
                    + Text(dates.map { " · \($0)" } ?? "").font(Self.datesFont).foregroundStyle(.secondary))
                    .lineLimit(1)
                if !week.sentence.isEmpty {
                    Text(week.sentence).font(Self.sentenceFont).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
