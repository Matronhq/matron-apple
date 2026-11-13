import SwiftUI
import MatronModels

/// The colour usage history is drawn in. One hue, stronger the more was
/// left unused, so it never reads as the red/green "how full" of the live
/// meters.
public enum UsageHistoryStyle {
    public static let tint = Color.blue

    public static func fill(unused: Int) -> Color {
        tint.opacity(UsageHistoryTable.tintOpacity(unused: unused))
    }

    /// "Thu 10:00" in the reader's own time zone.
    public static func resetText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "5 Jan".
    public static func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The same, read in UTC: a column's week is a UTC calendar week.
    public static func columnText(_ monday: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? style.timeZone
        return monday.formatted(style)
    }
}

/// One week of one account in the Mac grid: the percentage left unused on
/// a tint that deepens with it. A week with no reading is a dash.
public struct UsageHistoryCell: View {
    private let week: UsageWeek?

    public init(week: UsageWeek?) {
        self.week = week
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(week.map { UsageHistoryStyle.fill(unused: $0.unused) } ?? Color.secondary.opacity(0.06))
            if let week {
                Text("\(week.unused)%")
                    .foregroundStyle(week.unused >= 35 ? Color.white : Color.primary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .frame(height: 34)
    }
}

/// The week in progress: dashed, because it is not a result yet.
public struct UsageHistoryCurrentCell: View {
    private let current: UsageWeekInProgress?

    public init(current: UsageWeekInProgress?) {
        self.current = current
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let current {
                VStack(spacing: 0) {
                    Text("\(current.unused)%").font(.caption).monospacedDigit()
                    Text("so far").font(.system(size: 9))
                }
            } else {
                Text("—").font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 34)
    }
}

/// Twelve weeks as bars, oldest first: the grey part was used, the blue
/// cap was left unused. Ends with the week in progress, dashed.
public struct UsageHistoryBars: View {
    private let row: UsageHistoryTable.Row

    public init(row: UsageHistoryTable.Row) {
        self.row = row
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, week in
                bar(unused: week?.unused, isKnown: week != nil, isDashed: false)
            }
            bar(unused: row.current?.unused, isKnown: row.current != nil, isDashed: true)
        }
        .frame(height: 54)
        .accessibilityHidden(true)
    }

    private func bar(unused: Int?, isKnown: Bool, isDashed: Bool) -> some View {
        GeometryReader { proxy in
            let share = CGFloat(min(max(unused ?? 0, 0), 100)) / 100
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isKnown && !isDashed ? UsageHistoryStyle.tint.opacity(0.75) : Color.clear)
                if isKnown {
                    Rectangle()
                        .fill(Color.secondary.opacity(isDashed ? 0.25 : 0.35))
                        .frame(height: proxy.size.height * (1 - share))
                } else if !isDashed {
                    Rectangle().fill(Color.secondary.opacity(0.08))
                }
                if isDashed {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}
