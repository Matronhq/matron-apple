import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The iOS Memories list, pushed on the Missions tab's stack (decision
/// #3948). The view model is the shell's, but nothing loads until this
/// screen appears, so an older journal's 404 stays here.
struct MemoriesScreen: View {
    let viewModel: MemoriesViewModel
    let onOpen: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        MemoriesListView(
            model: .init(memories: viewModel.memories,
                         // Not proven false yet ⇒ supported, like every
                         // other `isSupported` consumer.
                         isSupported: viewModel.isSupported != false,
                         isLoading: viewModel.isLoading, loadError: viewModel.loadError),
            onSelect: onOpen,
            onNew: onNew,
            onRefresh: { await viewModel.load() })
        .navigationTitle("Memories")
        .toolbar {
            if viewModel.isSupported != false {
                ToolbarItem(placement: .primaryAction) {
                    Button { onNew() } label: { Label("New memory", systemImage: "plus") }
                        .accessibilityIdentifier("memories.new")
                }
            }
        }
        // Every appearance reloads — including the pop back from an editor.
        .onAppear { viewModel.start() }
    }
}

/// One memory's editor (`name`), or the new-memory form (`name == nil`).
/// A name no longer in the loaded list — deleted elsewhere — says so rather
/// than binding an editor to a stale record.
struct MemoryEditorHost: View {
    let viewModel: MemoriesViewModel
    let name: String?
    let onSaved: (_ name: String, _ wasNew: Bool) -> Void
    let onDeleted: () -> Void

    var body: some View {
        if let name {
            if let memory = viewModel.memory(named: name) {
                editor(memory)
            } else if viewModel.memories == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Memory not found", systemImage: "brain",
                                       description: Text("It may have been deleted on another device."))
            }
        } else {
            editor(nil)
        }
    }

    private func editor(_ memory: Memory?) -> some View {
        MemoryEditorView(
            memory: memory,
            onSave: { draft in
                let isNew = memory == nil
                let error = await viewModel.save(isNew: isNew, name: draft.name, type: draft.type,
                                                 description: draft.description, body: draft.body)
                if error == nil { onSaved(draft.name, isNew) }
                return error
            },
            onDelete: {
                guard let memory else { return nil }
                let error = await viewModel.delete(name: memory.name)
                if error == nil { onDeleted() }
                return error
            })
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
