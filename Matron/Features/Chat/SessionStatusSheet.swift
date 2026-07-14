import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// iOS session-status sheet — surfaced from `ChatView`'s ⓘ toolbar button.
/// Shows the context-window gauge and the stacked usage bars from the
/// last journal `status` frame; replaces the old bot-profile sheet.
/// Reads `viewModel.sessionStatus` in its own body — a value snapshot
/// passed through the `.sheet` closure isn't observation-tracked, so an
/// open sheet would never refresh when the first status frame lands.
struct SessionStatusSheet: View {
    let viewModel: ChatViewModel

    private var status: SessionStatus? { viewModel.sessionStatus }

    private var hasContent: Bool {
        status?.context != nil || !(status?.limits ?? []).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let status, hasContent {
                    VStack(alignment: .leading, spacing: 24) {
                        if let context = status.context {
                            ContextGaugeLabel(context: context)
                        }
                        if let limits = status.limits, !limits.isEmpty {
                            UsageBarsView(limits: limits, scale: .regular)
                        }
                        if let model = status.model {
                            Text(model)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                } else {
                    ContentUnavailableView(
                        "No usage data yet",
                        systemImage: "gauge",
                        description: Text("Appears after the next reply.")
                    )
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
