import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Agent Chats: the requests still waiting on a decision.
///
/// The consent card in a conversation is the primary surface; this screen is
/// the one thing a card can't be. A request that arrived while no client was
/// connected has no card to tap, and would otherwise sit unanswered until it
/// expired.
struct AgentChatView: View {
    @State private var viewModel: AgentChatViewModel

    init(api: any AgentChatProviding) {
        _viewModel = State(initialValue: AgentChatViewModel(api: api))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Button("Try Again") { Task { await viewModel.refresh() } }
                }
            }

            if !viewModel.isSupported {
                Section {
                    Text("This server doesn't support agent chats yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !viewModel.hasLoaded && !viewModel.isLoading && viewModel.errorMessage != nil {
                // The first load failed and nothing is in flight: the error
                // above, with its retry, is the whole screen. A spinner over a
                // section that will never fill would claim we were still
                // trying. (Before the first attempt there is no error yet, so
                // the section below still shows its loading state.)
                EmptyView()
            } else {
                Section {
                    if !viewModel.hasLoaded {
                        ProgressView()
                    } else if viewModel.pending.isEmpty {
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
                    Text("An agent asking to talk to another agent waits here until you decide. Every request asks — approving one says nothing about the next. Unanswered requests expire after 24 hours.")
                }
            }
        }
        .navigationTitle("Agent Chats")
        .task { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
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
        }
        .padding(.vertical, 4)
        .disabled(viewModel.busyIDs.contains(row.id))
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
