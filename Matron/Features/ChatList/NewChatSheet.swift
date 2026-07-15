import SwiftUI
import MatronJournal
import MatronModels
import MatronViewModels

/// The `+` toolbar sheet: pick a connected agent → pick a folder → the
/// agent starts a session there (agent RPC — spec
/// 2026-07-15-new-chat-flow-design.md). `onCreated` fires with the new
/// conversation id once a placeholder row exists, so the parent can
/// dismiss and navigate immediately even if the convo's first journal
/// frame hasn't landed yet.
struct NewChatSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: NewChatViewModel
    /// Guards double-fire when the `.done` onChange races a re-render.
    @State private var navigated = false

    init(deps: AppDependencies, session: UserSession, onCreated: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onCreated = onCreated
        _viewModel = State(initialValue: NewChatViewModel(api: deps.agentRPCService(for: session)))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .loadingAgents:
                    ProgressView("Looking for your agents…")
                case .agents(let agents):
                    agentPicker(agents)
                case .folders(let agent):
                    folderPicker(agent)
                case .done:
                    ProgressView() // parent dismisses momentarily
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await viewModel.load() }
        .onChange(of: viewModel.phase) { _, phase in
            guard case .done(let convoID) = phase, !navigated else { return }
            navigated = true
            Task {
                await deps.prepareConversation(for: session, id: convoID)
                onCreated(convoID)
            }
        }
    }

    @ViewBuilder private func agentPicker(_ agents: [DeviceDTO]) -> some View {
        List {
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                if agents.isEmpty {
                    Text("No agents yet — pair one in Settings → Manage Devices.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agents) { agent in
                    Button {
                        Task { await viewModel.select(agent: agent) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: agent.symbolName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name.isEmpty ? "Unnamed agent" : agent.name)
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
                    }
                    .disabled(!agent.connected)
                }
            } header: {
                Text("Start a chat on")
            } footer: {
                if !agents.isEmpty && !agents.contains(where: \.connected) {
                    Text("No agents connected — is the box awake?")
                }
            }
        }
    }

    @ViewBuilder private func folderPicker(_ agent: DeviceDTO) -> some View {
        List {
            Section {
                if let foldersError = viewModel.foldersError {
                    Text(foldersError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if viewModel.folders.isEmpty {
                    Text("No recent folders on \(agent.name).")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.folders) { folder in
                    Button {
                        Task { await viewModel.start(workdir: folder.path) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(folder.lastUsedText())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.isStarting)
                }
            } header: {
                Text("Folder on \(agent.name)")
            } footer: {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section {
                TextField("~/path/to/project", text: $viewModel.customPath)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Toggle("Browser tools", isOn: $viewModel.browserEnabled)
                Button {
                    Task { await viewModel.start(workdir: viewModel.customPath) }
                } label: {
                    if viewModel.isStarting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Starting…")
                        }
                    } else {
                        Text("Start Here").bold()
                    }
                }
                .disabled(viewModel.isStarting
                          || viewModel.customPath.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Other folder")
            } footer: {
                Text("Blank starts in the agent's default folder — pick a recent one above, or type a path.")
            }
        }
    }
}
