import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Agent Chats: requests still waiting on a decision, and the
/// standing allowances that let future requests through without asking.
///
/// The consent card in a conversation is the primary surface; this screen is
/// the two things a card can't be. A request that arrived while no client was
/// connected has no card to tap, and an allowance granted with "always allow"
/// is otherwise invisible and permanent — this is where it can be seen and
/// taken back.
struct AgentChatView: View {
    @State private var viewModel: AgentChatViewModel
    @State private var confirmingRevoke: AgentChatAllowanceDTO?

    init(api: any AgentChatProviding) {
        _viewModel = State(initialValue: AgentChatViewModel(api: api))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            if !viewModel.isSupported {
                Section {
                    Text("This server doesn't support agent chats yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if viewModel.pending.isEmpty {
                        Text("No requests waiting.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.pending) { row in
                            pendingRow(row)
                        }
                    }
                } header: {
                    Text("Waiting for you")
                } footer: {
                    Text("An agent asking to talk to another agent waits here until you decide. Unanswered requests expire after 24 hours.")
                }

                Section {
                    if viewModel.allowances.isEmpty {
                        Text("None — every request asks you first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.allowances) { allowance in
                            allowanceRow(allowance)
                        }
                    }
                } header: {
                    Text("Always allowed")
                } footer: {
                    Text("These pairs skip the request entirely. Each one is one-way: allowing A to reach B says nothing about B reaching A.")
                }
            }
        }
        .navigationTitle("Agent Chats")
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
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
        VStack(alignment: .leading, spacing: 8) {
            Text(row.headline).font(.body)
            if let topic = row.topic {
                labelled("About", topic)
            }
            if let justification = row.justification {
                labelled("Why", justification)
            }
            Text("Asked \(row.ageText())")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Decline") {
                    Task { await viewModel.answer(row, decision: .deny) }
                }
                .buttonStyle(.bordered)
                Button("Approve") {
                    Task { await viewModel.answer(row, decision: .approve) }
                }
                .buttonStyle(.borderedProminent)
                if viewModel.busyIDs.contains(row.id) {
                    ProgressView().controlSize(.small)
                }
            }
            // "Always allow" is deliberately not offered here. It is a
            // standing grant, and this screen shows asks stripped of the
            // conversation they belong to — the consent card in the chat,
            // where the surrounding context is visible, is the place to make
            // a decision that outlives the one request.
        }
        .padding(.vertical, 4)
        .disabled(viewModel.busyIDs.contains(row.id))
    }

    private func allowanceRow(_ allowance: AgentChatAllowanceDTO) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(allowance.fromLabel) → \(allowance.targetLabel)")
                .fontWeight(.medium)
            Text("Can start a chat without asking")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button("Stop Allowing", role: .destructive) { confirmingRevoke = allowance }
        }
        .contextMenu {
            Button("Stop Allowing", role: .destructive) { confirmingRevoke = allowance }
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
