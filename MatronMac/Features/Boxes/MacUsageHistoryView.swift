#if os(macOS)
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Boxes page's usage history: an account per row, a week per column,
/// each cell the share of that week's allowance left unused.
struct MacUsageHistoryView: View {
    @Bindable var viewModel: UsageHistoryViewModel

    private static let accountWidth: CGFloat = 230
    private static let averageWidth: CGFloat = 64

    var body: some View {
        let table = viewModel.table()
        let choices = viewModel.choices
        VStack(alignment: .leading, spacing: 12) {
            if choices.count > 1 {
                Picker("Meter", selection: $viewModel.choiceID) {
                    ForEach(choices) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("usageHistory.meter")
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.callout).foregroundStyle(viewModel.history == nil ? Color.secondary : Color.red)
            }
            if table.rows.isEmpty {
                if viewModel.errorMessage == nil {
                    Group {
                        if viewModel.hasLoaded {
                            Text("No usage history yet. A week shows here once it has reset.")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
            } else {
                grid(table)
                Text("Each cell is one weekly window: 100 minus the last reading before that account's reset. "
                     + "A deeper blue means more was left unused. The dashed cell is the week in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await viewModel.load() }
    }

    private func grid(_ table: UsageHistoryTable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Account · % of weekly allowance left unused")
                    .frame(width: Self.accountWidth, alignment: .leading)
                ForEach(table.columns, id: \.self) { monday in
                    Text(UsageHistoryStyle.columnText(monday)).lineLimit(1).frame(maxWidth: .infinity)
                }
                Text("Now").frame(maxWidth: .infinity)
                Text("Average").frame(width: Self.averageWidth, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            ForEach(table.rows) { row in
                rowView(row)
            }
            Divider()
            HStack(spacing: 4) {
                Text("All accounts, average")
                    .foregroundStyle(.secondary)
                    .frame(width: Self.accountWidth, alignment: .leading)
                ForEach(Array(table.columnAverages.enumerated()), id: \.offset) { _, average in
                    Text(average.map { "\($0)%" } ?? "—")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                Color.clear.frame(width: Self.averageWidth, height: 1)
            }
        }
    }

    private func rowView(_ row: UsageHistoryTable.Row) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(Self.caption(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: Self.accountWidth, alignment: .leading)
            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, week in
                UsageHistoryCell(week: week)
                    .frame(maxWidth: .infinity)
                    .help(week.map(Self.helpText) ?? "No reading that week")
                    .accessibilityLabel(week.map { UsageHistoryTable.accessibilityText(account: row.title, week: $0) }
                                        ?? "\(row.title): no reading")
            }
            UsageHistoryCurrentCell(current: row.current)
                .frame(maxWidth: .infinity)
                .help(row.current.map { "Week in progress, resets \(UsageHistoryStyle.resetText($0.resetsAt))" }
                      ?? "No reading this week")
            Text(row.averageUnused.map { "\($0)%" } ?? "—")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: Self.averageWidth, alignment: .trailing)
                .accessibilityLabel(row.averageUnused.map { "\(row.title): \($0)% unused on average" }
                                    ?? "\(row.title): no average")
        }
    }

    /// "Claude · 3 boxes · resets Thu 10:00".
    private static func caption(_ row: UsageHistoryTable.Row) -> String {
        guard let resetsAt = row.current?.resetsAt ?? row.latest?.resetsAt else { return row.subtitle }
        return "\(row.subtitle) · resets \(UsageHistoryStyle.resetText(resetsAt))"
    }

    private static func helpText(_ week: UsageWeek) -> String {
        var text = "\(week.unused)% unused · reset \(UsageHistoryStyle.dayText(week.resetsAt)), "
            + "\(UsageHistoryStyle.resetText(week.resetsAt)) · peak \(week.peak)% used"
        if let last = week.lastReadingAt {
            text += " · last reading \(UsageHistoryStyle.dayText(last)), \(UsageHistoryStyle.resetText(last))"
        }
        return text
    }
}
#endif
