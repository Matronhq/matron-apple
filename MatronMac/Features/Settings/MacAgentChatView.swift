#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Agent Chats: requests still waiting on a decision, and the
/// standing allowances that let future requests through without asking.
/// Mac analogue of `Matron/Features/Settings/AgentChatView`.
///
/// The consent card in a conversation is the primary surface; this screen is
/// the two things a card can't be. A request that arrived while no client was
/// connected has no card to tap, and an allowance granted with "always allow"
/// is otherwise invisible and permanent — this is where it can be seen and
/// taken back.
struct MacAgentChatView: View {
    @State private var viewModel: AgentChatViewModel
    @State private var confirmingRevoke: AgentChatAllowanceDTO?

    init(api: any AgentChatProviding) {
        _viewModel = State(initialValue: AgentChatViewModel(api: api))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isSupported {
                Spacer()
                Text("This server doesn't support agent chats yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            } else if !viewModel.hasLoaded && !viewModel.isLoading && viewModel.errorMessage != nil {
                // The first load failed and nothing is in flight: the error and
                // Refresh button in the footer are the whole screen. Two
                // spinners over sections that will never fill would claim we
                // were still trying.
                Spacer()
            } else {
                List {
                    Section("Waiting for you") {
                        if !viewModel.hasLoaded {
                            ProgressView().controlSize(.small)
                        } else if viewModel.pending.isEmpty {
                            Text("No requests waiting.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        } else {
                            ForEach(viewModel.pending) { row in
                                pendingRow(row)
                            }
                        }
                    }
                    Section("Always allowed") {
                        if !viewModel.hasLoaded {
                            ProgressView().controlSize(.small)
                        } else if viewModel.allowances.isEmpty {
                            Text("None — every request asks you first.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        } else {
                            ForEach(viewModel.allowances) { allowance in
                                allowanceRow(allowance)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Refresh") { Task { await viewModel.refresh() } }
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .task { await viewModel.refresh() }
        .alert(item: $confirmingRevoke) { allowance in
            Alert(
                title: Text("Stop always allowing this?"),
                message: Text("\(allowance.fromLabel) will have to ask you again before talking to \(allowance.targetLabel)."),
                primaryButton: .destructive(Text("Stop Allowing")) {
                    Task { await viewModel.revoke(allowance) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func pendingRow(_ row: AgentChatPendingDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.headline)
            if let topic = row.topic {
                labelled("About", topic)
            }
            if let justification = row.justification {
                labelled("Why", justification)
            }
            HStack(spacing: 8) {
                Text("Asked \(row.ageText())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.busyIDs.contains(row.id) {
                    ProgressView().controlSize(.small)
                }
                Button("Decline") {
                    Task { await viewModel.answer(row, decision: .deny) }
                }
                Button("Approve") {
                    Task { await viewModel.answer(row, decision: .approve) }
                }
            }
            // "Always allow" is deliberately not offered here — see the iOS
            // view for why a standing grant belongs beside the conversation
            // it is about, not in a list stripped of that context.
        }
        .padding(.vertical, 4)
        .disabled(viewModel.busyIDs.contains(row.id))
    }

    private func allowanceRow(_ allowance: AgentChatAllowanceDTO) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(allowance.fromLabel) → \(allowance.targetLabel)")
                    .fontWeight(.medium)
                Text("Can start a chat without asking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop Allowing") { confirmingRevoke = allowance }
                .disabled(viewModel.busyIDs.contains(allowance.id))
        }
        .padding(.vertical, 2)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
#endif
