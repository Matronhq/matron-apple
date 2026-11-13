import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// Usage history, pushed from Boxes: a card per account with the last
/// twelve weeks as bars and what was left unused last week.
struct UsageHistoryScreen: View {
    static let path = "usage-history"

    @Bindable var viewModel: UsageHistoryViewModel

    var body: some View {
        let table = viewModel.table()
        let choices = viewModel.choices
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if choices.count > 1 {
                    Picker("Meter", selection: $viewModel.choiceID) {
                        ForEach(choices) { choice in
                            Text(choice.title).tag(choice.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("usageHistory.meter")
                }
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(viewModel.history == nil ? Color.secondary : Color.red)
                        .padding(.horizontal, 4)
                }
                ForEach(table.rows) { row in
                    card(row, firstColumn: table.columns.first)
                }
                if table.rows.isEmpty, viewModel.errorMessage == nil {
                    Group {
                        if viewModel.hasLoaded {
                            Text("No usage history yet. A week shows here once it has reset.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if !table.rows.isEmpty {
                    Text("Blue is the share of each week's allowance left unused when it reset. The dashed bar is the week in progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Usage history")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task { await viewModel.load() }
    }

    private func card(_ row: UsageHistoryTable.Row, firstColumn: Date?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.latest.map { "\($0.unused)%" } ?? "—")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    Text(row.latest == nil ? "no finished week" : "unused last week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            UsageHistoryBars(row: row)
            HStack {
                Text(firstColumn.map(UsageHistoryStyle.columnText) ?? "")
                Spacer()
                if let average = row.averageUnused {
                    Text("\(row.cells.count)-week average \(average)% unused")
                }
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
