import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The For you list on the shared AppKit list host
/// (`list.appkit.decisions`): `DecisionsListView`'s header, tabs and empty
/// states in SwiftUI, around a `MacListView` of native `MacItemRowCell`
/// rows fed by `MacDecisionsSource`.
///
/// The host only makes views for the rows on screen, and a change edits
/// just the rows it touched, once a frame. The Done tab keeps its latest
/// 50 and "Show more": that is how the list reads, not a performance cap.
///
/// Selection: the list shows the item open on the right; clicking a row,
/// or moving with the arrow keys, opens that item, as a row click does in
/// the SwiftUI list.
struct MacDecisionsAppKitList: View {
    let vm: ItemsPanelViewModel
    let selectedID: String?
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void

    @State private var source: MacDecisionsSource
    @State private var rows = MacDecisionsRows()

    static let accessibilityIdentifier = "decisions.list"

    init(vm: ItemsPanelViewModel, originLabels: MacOriginLabels, selectedID: String?,
         onSelect: @escaping (String) -> Void, onOpenConversation: @escaping (String) -> Void) {
        self.vm = vm
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onOpenConversation = onOpenConversation
        self._source = State(wrappedValue: MacDecisionsSource(viewModel: vm, originLabels: originLabels))
    }

    var body: some View {
        // The closures capture this view's callbacks, which a later update
        // may change; plain stored properties, not observed.
        let _ = rows.actions = actions
        VStack(spacing: 0) {
            header
            if vm.isSupported == false {
                placeholder(ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                                   description: Text("Update the journal server to use items.")))
            } else {
                tabPicker
                ZStack {
                    MacListView(rows: rows, selection: selection, style: .plain,
                                accessibilityIdentifier: Self.accessibilityIdentifier,
                                publications: { [source] in source.publications() })
                    emptyState
                }
            }
        }
        .alert("Tracker", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    /// The window's open item; a row the user picks opens its item. A
    /// click on empty space keeps the item open, as in the SwiftUI list.
    /// ("Show more" cannot be selected: `MacDecisionsRows.canSelect`.)
    private var selection: Binding<String?> {
        let onSelect = onSelect
        return Binding(get: { selectedID }, set: { id in
            if let id { onSelect(id) }
        })
    }

    private var header: some View {
        HStack {
            Text(DecisionsListView.title).font(.headline)
            Spacer()
            if vm.isRefreshing {
                ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
            }
            Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var tabPicker: some View {
        Picker("Show", selection: Binding(get: { vm.forYouTab }, set: { vm.forYouTab = $0 })) {
            ForEach(ForYouTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("decisions.tabs")
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Over the list (which stays mounted, so its host and stream survive
    /// a tab with no rows). Reads the source's `isEmpty`, which flips
    /// rarely, never the view model's lists.
    @ViewBuilder
    private var emptyState: some View {
        if source.isEmpty == true {
            switch vm.forYouTab {
            case .open:
                placeholder(ContentUnavailableView(DecisionsListView.emptyTitle, systemImage: "checkmark.seal",
                                                   description: Text(DecisionsListView.emptyDescription)))
            case .closed:
                placeholder(ContentUnavailableView(DecisionsListView.closedEmptyTitle, systemImage: "tray",
                                                   description: Text(DecisionsListView.closedEmptyDescription)))
            case .spare:
                placeholder(ContentUnavailableView(DecisionsListView.spareEmptyTitle, systemImage: "hourglass",
                                                   description: Text(DecisionsListView.spareEmptyDescription)))
            }
        }
    }

    private func placeholder<Content: View>(_ content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actions: MacDecisionsRows.Actions {
        let vm = vm
        return MacDecisionsRows.Actions(
            open: onSelect,
            openConversation: onOpenConversation,
            seen: { id in Task { await vm.markSeen(id) } },
            showMore: { vm.showMoreDecided() })
    }
}
