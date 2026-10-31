import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The items pane's list on the shared AppKit list host: `ItemsListView`'s
/// scope picker, New item button
/// and empty states in SwiftUI, around a `MacListView` of native rows fed
/// by `MacItemsPaneSource`, with a header per section and drag to reorder
/// inside Tasks.
///
/// A click on an item opens it (the rows' `activatesOnClick`), as a row
/// of the SwiftUI list does, and leaves nothing selected, so the list
/// shows none when it comes back. The arrow keys and type-select only
/// select; Return or Enter opens.
struct MacItemsAppKitList: View {
    let viewModel: ItemsPanelViewModel
    let onSelect: (TrackerItem) -> Void
    let onMove: (String, Int) -> Void
    let onCreate: () -> Void
    let onOpenConversation: (String) -> Void

    @State private var source: MacItemsPaneSource
    @State private var rows = MacItemsPaneRows()
    /// The row the keyboard moved to; a click opens instead of selecting.
    @State private var selectedID: String?

    static let accessibilityIdentifier = "itemsPane.list"

    init(viewModel: ItemsPanelViewModel, originTitles: @escaping () -> [String: String],
         onSelect: @escaping (TrackerItem) -> Void, onMove: @escaping (String, Int) -> Void,
         onCreate: @escaping () -> Void, onOpenConversation: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.onSelect = onSelect
        self.onMove = onMove
        self.onCreate = onCreate
        self.onOpenConversation = onOpenConversation
        self._source = State(wrappedValue: MacItemsPaneSource(viewModel: viewModel, originTitles: originTitles))
    }

    private var isAll: Bool { viewModel.scope == .all }

    var body: some View {
        // The closures capture this view's callbacks, which a later update
        // may change; plain stored properties, not observed.
        let _ = rows.actions = MacItemsPaneRows.Actions(open: onSelect, openConversation: onOpenConversation,
                                                        move: onMove)
        let _ = rows.taskIDs = { [source] in source.taskIDs }
        let _ = rows.row = { [source] in source.row($0) }
        VStack(spacing: 0) {
            header
            if !viewModel.isSupported {
                placeholder(ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                                   description: Text("Update the journal server to use items.")))
            } else {
                ZStack {
                    MacListView(rows: rows, selection: selection, style: .plain,
                                accessibilityIdentifier: Self.accessibilityIdentifier,
                                publications: { [source] in source.publications() })
                    if source.isEmpty == true {
                        placeholder(ContentUnavailableView(
                            "Nothing tracked yet", systemImage: "checklist",
                            description: Text("Questions, tasks and decisions the agent files appear here.")))
                    }
                }
            }
        }
    }

    private var selection: Binding<String?> {
        let selected = $selectedID
        return Binding(get: { selected.wrappedValue }, set: { id in
            selected.wrappedValue = Self.keepsSelection(NSApp.currentEvent?.type) ? id : nil
        })
    }

    /// Whether a selection made during `event` stays: a key's (an arrow,
    /// type-select) does; a click's does not, as the click opens the row.
    static func keepsSelection(_ event: NSEvent.EventType?) -> Bool {
        event != .leftMouseDown && event != .leftMouseUp
    }

    /// `ItemsListView`'s header: the scope picker (with a home chat), the
    /// refresh spinner and New item.
    private var header: some View {
        HStack {
            if let convoID = viewModel.convoID {
                Picker("Scope", selection: Binding(get: { isAll ? 1 : 0 },
                                                   set: { viewModel.scope = $0 == 1 ? .all : .convo(convoID) })) {
                    Text("This chat").tag(0)
                    Text("All").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Spacer(minLength: 0)
            }
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
            Button(action: onCreate) { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .disabled(!viewModel.isSupported)
                .accessibilityLabel("New item")
                .help("New item")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func placeholder<Content: View>(_ content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
