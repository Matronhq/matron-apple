#if os(macOS)
import SwiftUI
import MatronJournal
import MatronModels
import MatronViewModels

/// Mac variant of `NewChatSheet` (the Mac and iOS targets each carry their
/// own `AppDependencies`, so the sheet is duplicated per platform): pick a
/// connected agent → pick a folder → the agent starts a session there
/// (agent RPC — spec 2026-07-15-new-chat-flow-design.md). `onCreated`
/// fires with the new conversation id once a placeholder row exists.
struct MacNewChatSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: NewChatViewModel
    /// Guards double-fire when the `.done` onChange races a re-render.
    @State private var navigated = false
    /// Set on any dismissal (Cancel or Esc). A `start` already in flight
    /// can't be recalled — the session will spawn on the box — but its
    /// late `.done` must not yank the user into a chat they abandoned.
    @State private var cancelled = false

    init(deps: AppDependencies, session: UserSession, onCreated: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onCreated = onCreated
        _viewModel = State(initialValue: NewChatViewModel(api: deps.agentRPCService(for: session)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Chat").font(.title2.bold())
            switch viewModel.phase {
            case .loadingAgents:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your agents…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            case .agents(let agents):
                agentPicker(agents)
            case .folders(let agent):
                folderPicker(agent)
            case .done:
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    cancelled = true
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await viewModel.load() }
        // Esc / window-close dismissal never touches the Cancel button;
        // anything that removes the sheet counts as abandoning the flow.
        .onDisappear { if !navigated { cancelled = true } }
        .onChange(of: viewModel.phase) { _, phase in
            guard case .done(let convoID) = phase, !navigated, !cancelled else { return }
            navigated = true
            Task {
                await deps.prepareConversation(for: session, id: convoID)
                guard !cancelled else { return }
                onCreated(convoID)
            }
        }
    }

    @ViewBuilder private func agentPicker(_ agents: [DeviceDTO]) -> some View {
        if let error = viewModel.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
        }
        if agents.isEmpty {
            Text("No agents yet — pair one in Settings → Devices.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            List(agents) { agent in
                Button {
                    Task { await viewModel.select(agent: agent) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: agent.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name.isEmpty ? "Unnamed agent" : agent.name)
                                .fontWeight(.medium)
                                .foregroundStyle(agent.connected ? .primary : .secondary)
                            Text(agent.connected
                                 ? "Connected"
                                 : "Offline · Last seen \(agent.lastSeenText())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if agent.connected {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!agent.connected)
            }
            .listStyle(.inset)
            .frame(height: 200)
            if !agents.contains(where: \.connected) {
                Text("No agents connected — is the box awake?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func folderPicker(_ agent: DeviceDTO) -> some View {
        Text("Folder on \(agent.name)")
            .font(.callout)
            .foregroundStyle(.secondary)
        if let foldersError = viewModel.foldersError {
            Text(foldersError).font(.caption).foregroundStyle(.secondary)
        }
        List(viewModel.folders) { folder in
            Button {
                Task { await viewModel.start(workdir: folder.path) }
            } label: {
                HStack {
                    Text(folder.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Text(folder.lastUsedText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStarting)
        }
        .listStyle(.inset)
        .frame(height: 160)
        .overlay {
            if viewModel.folders.isEmpty && viewModel.foldersError == nil {
                Text("No recent folders on \(agent.name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 8) {
            TextField("~/path/to/project", text: $viewModel.customPath)
                .font(.callout.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.start(workdir: viewModel.customPath) } }
            Button {
                Task { await viewModel.start(workdir: viewModel.customPath) }
            } label: {
                if viewModel.isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Start Here")
                }
            }
            .disabled(viewModel.isStarting
                      || viewModel.customPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Toggle("Browser tools", isOn: $viewModel.browserEnabled)
            .toggleStyle(.checkbox)
        Text("Blank starts in the agent's default folder — pick a recent one above, or type a path.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let error = viewModel.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }
}
#endif
