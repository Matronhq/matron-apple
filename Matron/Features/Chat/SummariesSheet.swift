import SwiftUI
import MatronChat
import MatronViewModels

/// TOC of the conversation: one row per bridge summary pass, newest first.
/// Rows expand to the fuller rolling summary; tapping navigates the
/// transcript to where that pass happened.
struct SummariesSheet: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSeq: Int64?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.summaryEntries.isEmpty {
                    ContentUnavailableView(
                        "No summaries yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("They appear as the conversation grows."))
                } else {
                    List(viewModel.summaryEntries) { entry in
                        Button {
                            dismiss()
                            Task { await viewModel.focus(seq: entry.seq) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.toc)
                                    Spacer()
                                    if !entry.detail.isEmpty {
                                        Button {
                                            toggle(entry.seq)
                                        } label: {
                                            Image(systemName: expandedSeq == entry.seq ? "chevron.up" : "chevron.down")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Show detail")
                                    }
                                }
                                if expandedSeq == entry.seq, !entry.detail.isEmpty {
                                    Text(entry.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Summaries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func toggle(_ seq: Int64) { expandedSeq = expandedSeq == seq ? nil : seq }
}
