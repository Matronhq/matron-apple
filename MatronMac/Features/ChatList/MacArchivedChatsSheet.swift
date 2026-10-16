#if os(macOS)
import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// The Archived sheet: every archived conversation, most recently active
/// first, with a search field. Select one or more (⌘- and ⇧-click) to
/// Unarchive them; double-click, or Open, shows a conversation in the
/// window (a message sent there brings it back to the list).
struct MacArchivedChatsSheet: View {
    @State private var viewModel: ArchivedChatsViewModel
    @State private var selection: Set<ChatSummary.ID> = []
    private let notifyStore: NotifySettingsStore?
    /// Opens a conversation, with its summary for the chat header (it is
    /// not in the list the header normally reads).
    private let onOpen: (ChatSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    init(chat: ChatService, notifyStore: NotifySettingsStore?, onOpen: @escaping (ChatSummary) -> Void) {
        self.init(viewModel: ArchivedChatsViewModel(chat: chat), notifyStore: notifyStore, onOpen: onOpen)
    }

    /// For tests: a view model the caller already holds.
    init(viewModel: ArchivedChatsViewModel, notifyStore: NotifySettingsStore? = nil,
         selection: Set<ChatSummary.ID> = [], onOpen: @escaping (ChatSummary) -> Void) {
        _viewModel = State(initialValue: viewModel)
        _selection = State(initialValue: selection)
        self.notifyStore = notifyStore
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archived")
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search archived", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("archived.search")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        let rows = viewModel.filtered
        if viewModel.isLoading {
            ProgressView()
        } else if viewModel.summaries.isEmpty {
            ContentUnavailableView(
                "No archived conversations",
                systemImage: "archivebox",
                description: Text("Conversations you archive, or that sit idle long enough, appear here.")
            )
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: viewModel.query)
        } else {
            List(rows, selection: $selection) { summary in
                MacChatRow(summary: summary,
                           isNotifySilenced: notifyStore?.state(for: summary.id).isSilenced ?? false)
                    .tag(summary.id)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: ChatSummary.ID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Open") { open(id) }
                }
                if !ids.isEmpty {
                    Button(ids.count > 1 ? "Unarchive \(ids.count) Conversations" : "Unarchive") { unarchive(ids) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { open(id) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(Self.countLabel(shown: viewModel.filtered.count, total: viewModel.summaries.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(selection.count > 1 ? "Unarchive \(selection.count)" : "Unarchive") { unarchive(selection) }
                .disabled(selection.isEmpty)
            Button("Open") { if let id = selection.first { open(id) } }
                .disabled(selection.count != 1)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func open(_ id: ChatSummary.ID) {
        if let summary = viewModel.summaries.first(where: { $0.id == id }) { onOpen(summary) }
    }

    private func unarchive(_ ids: Set<ChatSummary.ID>) {

        let list = ids.sorted()
        selection.subtract(ids)
        Task { await viewModel.unarchive(list) }
    }

    /// "12 conversations", or "3 of 12" while a search narrows the list.
    static func countLabel(shown: Int, total: Int) -> String {
        if shown == total { return "\(total) conversation\(total == 1 ? "" : "s")" }
        return "\(shown) of \(total)"
    }
}
#endif
