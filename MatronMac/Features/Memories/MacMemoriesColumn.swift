import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Memories list in the Mac sidebar column (decision #3948). Its
/// appearance starts the view model — the load and the live refetch — and
/// leaving the entry stops it, so nothing loads until the entry is shown.
struct MacMemoriesColumn: View {
    let viewModel: MemoriesViewModel
    @Binding var selection: MacMemorySelection?

    var body: some View {
        MemoriesListView(
            model: .init(memories: viewModel.memories,
                         isSupported: viewModel.isSupported != false,
                         isLoading: viewModel.isLoading, loadError: viewModel.loadError),
            selectedName: selection?.name,
            onSelect: { selection = .memory($0) },
            onNew: { selection = .new },
            onRefresh: { await viewModel.load() })
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}

/// The Memories entry's detail column: the selected memory's editor, the
/// new-memory form, or "Select a memory". A selected name no longer in the
/// loaded list (deleted elsewhere) says so instead of binding an editor to
/// a stale record.
struct MacMemoryDetail: View {
    let viewModel: MemoriesViewModel
    @Binding var selection: MacMemorySelection?

    var body: some View {
        switch selection {
        case nil:
            ContentUnavailableView("Select a memory", systemImage: "brain",
                                   description: Text("Pick a memory from the list, or add a new one."))
        case .new:
            editor(nil).id("memories.new")
        case .memory(let name):
            if let memory = viewModel.memory(named: name) {
                editor(memory).id(name)
            } else if viewModel.memories == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Memory not found", systemImage: "brain",
                                       description: Text("It may have been deleted on another device."))
            }
        }
    }

    /// After a save, as the web tracker does: a new memory opens in its
    /// editor, an edit returns to the list; a delete returns to the list.
    static func selection(afterSavingNew isNew: Bool, name: String) -> MacMemorySelection? {
        isNew ? .memory(name) : nil
    }

    private func editor(_ memory: Memory?) -> some View {
        MemoryEditorView(
            memory: memory,
            onSave: { draft in
                let isNew = memory == nil
                let error = await viewModel.save(isNew: isNew, name: draft.name, type: draft.type,
                                                 description: draft.description, body: draft.body)
                if error == nil { selection = Self.selection(afterSavingNew: isNew, name: draft.name) }
                return error
            },
            onDelete: {
                guard let memory else { return nil }
                let error = await viewModel.delete(name: memory.name)
                if error == nil, selection == .memory(memory.name) { selection = nil }
                return error
            })
    }
}
