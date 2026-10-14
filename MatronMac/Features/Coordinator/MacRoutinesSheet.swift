import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// Settings ▸ Coordinator ▸ Routines on the Mac: the shared
/// `RoutinesListView` in a sheet over Settings, with the editor in a sheet
/// of its own. Nothing loads until it opens, so an older journal's 404
/// stays here.
struct MacRoutinesSheet: View {
    @State private var viewModel: RoutinesViewModel
    let onClose: () -> Void
    @State private var editing: EditorTarget?

    enum EditorTarget: Identifiable, Hashable {
        case existing(String), new
        var id: String { if case .existing(let id) = self { return id } else { return "new" } }
    }

    init(viewModel: RoutinesViewModel, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Routines").font(.headline)
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
                Button { Task { await viewModel.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
                if viewModel.isSupported != false {
                    Button { editing = .new } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("New routine").accessibilityLabel("New routine")
                        .accessibilityIdentifier("routines.new")
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            RoutinesListView(
                model: .init(routines: viewModel.routines,
                             isSupported: viewModel.isSupported != false,
                             isLoading: viewModel.isLoading, loadError: viewModel.loadError,
                             busyIDs: viewModel.busyIDs),
                actions: .init(select: { editing = .existing($0) },
                               setEnabled: { id, enabled in Task { await viewModel.setEnabled(enabled, id: id) } },
                               run: { id in Task { viewModel.actionMessage = await viewModel.run(id: id) } },
                               refresh: { await viewModel.load() }))
            Divider()
            HStack {
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 560, height: 620)
        .sheet(item: $editing) { target in
            VStack(spacing: 0) {
                editor(for: target)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(10)
            }
            .frame(width: 520, height: 640)
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

    /// A routine no longer in the loaded list — deleted elsewhere — says so
    /// rather than binding an editor to a stale record.
    @ViewBuilder
    private func editor(for target: EditorTarget) -> some View {
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
                if error == nil { editing = nil }
                return error
            },
            onDelete: {
                guard let routine else { return nil }
                let error = await viewModel.delete(id: routine.id)
                if error == nil { editing = nil }
                return error
            },
            onRun: routine.map { routine in { await viewModel.run(id: routine.id) } })
    }
}
