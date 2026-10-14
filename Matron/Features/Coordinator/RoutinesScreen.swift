import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// Settings ▸ Coordinator ▸ Routines, pushed from the Coordinator section.
/// The list is `RoutinesListView`; editing and creating open
/// `RoutineEditorView` in a sheet. Nothing loads until the screen appears,
/// so an older journal's 404 stays here.
struct RoutinesScreen: View {
    @State private var viewModel: RoutinesViewModel
    @State private var editing: EditorTarget?

    /// Which editor the sheet shows: an existing routine by id, or a new one.
    enum EditorTarget: Identifiable, Hashable {
        case existing(String), new
        var id: String { if case .existing(let id) = self { return id } else { return "new" } }
    }

    init(viewModel: RoutinesViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        RoutinesListView(
            model: .init(routines: viewModel.routines,
                         isSupported: viewModel.isSupported != false,
                         isLoading: viewModel.isLoading, loadError: viewModel.loadError,
                         busyIDs: viewModel.busyIDs),
            actions: .init(select: { editing = .existing($0) },
                           setEnabled: { id, enabled in Task { await viewModel.setEnabled(enabled, id: id) } },
                           run: { id in Task { viewModel.actionMessage = await viewModel.run(id: id) } },
                           refresh: { await viewModel.load() }))
        .navigationTitle("Routines")
        .toolbar {
            if viewModel.isSupported != false {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Label("New routine", systemImage: "plus") }
                        .accessibilityIdentifier("routines.new")
                }
            }
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                RoutineEditorHost(viewModel: viewModel, target: target) { editing = nil }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                    }
            }
        }
        .alert("Routines", isPresented: Binding(get: { viewModel.actionMessage != nil },
                                                set: { if !$0 { viewModel.actionMessage = nil } })) {
            Button("OK") { viewModel.actionMessage = nil }
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}

/// The editor for one target. A routine no longer in the loaded list —
/// deleted elsewhere — says so rather than binding to a stale record.
struct RoutineEditorHost: View {
    let viewModel: RoutinesViewModel
    let target: RoutinesScreen.EditorTarget
    let onDone: () -> Void

    var body: some View {
        switch target {
        case .new:
            editor(nil)
        case .existing(let id):
            if let routine = viewModel.routine(id: id) {
                editor(routine)
            } else {
                ContentUnavailableView("Routine not found", systemImage: "clock.arrow.circlepath",
                                       description: Text("It may have been deleted on another device."))
            }
        }
    }

    private func editor(_ routine: Routine?) -> some View {
        RoutineEditorView(
            routine: routine,
            onSave: { draft in
                let error = await viewModel.save(existingID: routine?.id, name: draft.name,
                                                 draft: draft.routineDraft(isNew: routine == nil))
                if error == nil { onDone() }
                return error
            },
            onDelete: {
                guard let routine else { return nil }
                let error = await viewModel.delete(id: routine.id)
                if error == nil { onDone() }
                return error
            },
            onRun: routine.map { routine in { await viewModel.run(id: routine.id) } })
        .navigationBarTitleDisplayMode(.inline)
    }
}
