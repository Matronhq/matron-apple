import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Memories list in the Mac sidebar column. Its
/// appearance starts the view model — the load and the live refetch — and
/// leaving the entry stops it, so nothing loads until the entry is shown.
struct MacMemoriesColumn: View {
    let viewModel: MemoriesViewModel
    /// The "On your boxes" section under the journal's memories; its
    /// online boxes are asked when the column appears.
    let localViewModel: LocalMemoriesViewModel
    @Binding var selection: MacMemorySelection?

    var body: some View {
        MemoriesListView(
            model: .init(memories: viewModel.memories,
                         isSupported: viewModel.isSupported != false,
                         isLoading: viewModel.isLoading, loadError: viewModel.loadError),
            selectedName: selection?.name,
            onSelect: { selection = .memory($0) },
            onNew: { selection = .new },
            onRefresh: {
                localViewModel.reload()
                await viewModel.load()
            },
            local: localViewModel.section(journal: viewModel.memories, selected: selection?.localRef),
            localActions: .init(toggleGroup: { localViewModel.toggle($0) },
                                selectBox: { localViewModel.selectBox($0, in: $1) },
                                showAll: { localViewModel.showAll(in: $0) },
                                open: { selection = .local($0) }))
        .onAppear {
            viewModel.start()
            localViewModel.start()
        }
        .onDisappear {
            viewModel.stop()
            localViewModel.stop()
        }
    }
}

/// One file from a box in the Memories entry's detail column: read-only,
/// its text read from the box when it is selected.
struct MacLocalMemoryDetail: View {
    let viewModel: MemoriesViewModel
    let localViewModel: LocalMemoriesViewModel
    let ref: LocalMemoryRef
    @Binding var selection: MacMemorySelection?

    var body: some View {
        LocalMemoryDetailView(
            model: localViewModel.detail(for: ref, journal: viewModel.memories),
            onRetry: { Task { await localViewModel.loadBody(ref) } },
            onOpenJournalMemory: { selection = .memory($0) })
        // Keyed on the text being absent too, so a text dropped while the
        // pane is up (the column was hidden, which stops the section) is
        // read again.
        .task(id: LoadKey(ref: ref, isMissing: localViewModel.bodies[ref] == nil)) {
            await localViewModel.loadBody(ref)
        }
    }

    private struct LoadKey: Equatable {
        let ref: LocalMemoryRef
        let isMissing: Bool
    }
}

/// The Memories entry's detail column: the selected memory's editor, the
/// new-memory form, or "Select a memory". A selected name no longer in the
/// loaded list (deleted elsewhere) says so instead of binding an editor to
/// a stale record.
struct MacMemoryDetail: View {
    let viewModel: MemoriesViewModel
    let localViewModel: LocalMemoriesViewModel
    @Binding var selection: MacMemorySelection?

    var body: some View {
        switch selection {
        case nil:
            ContentUnavailableView("Select a memory", systemImage: "brain",
                                   description: Text("Pick a memory from the list, or add a new one."))
        case .new:
            editor(nil).id("memories.new")
        case .local(let ref):
            MacLocalMemoryDetail(viewModel: viewModel, localViewModel: localViewModel, ref: ref,
                                 selection: $selection)
                .id(ref)
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
