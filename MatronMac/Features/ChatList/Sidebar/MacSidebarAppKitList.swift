import SwiftUI
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels

/// The sidebar's conversation list on the shared AppKit list host
/// (`list.appkit.sidebar`): a `MacListView` fed by the chat-list index
/// through `MacSidebarChatSource`, with native `MacChatListCell` rows.
///
/// Every chat is in the list: the host only makes views for the rows on
/// screen, so there is no row cap and no "Show older chats". Its updates
/// edit just the rows that changed, once a frame, rather than SwiftUI
/// diffing every row once a second.
///
/// Selection: the list can hold several rows (⌘-click, ⇧-click) for
/// Archive; the window's selected conversation follows it while one row is
/// selected (`MacSidebarSelection`), and a conversation the window selects
/// from elsewhere (search, a link, a notification) is selected in the list
/// and scrolled to.
struct MacSidebarAppKitList: View {
    let viewModel: ChatListViewModel
    @Binding var selection: ChatSummary.ID?
    let runChatAction: (@escaping (ChatService) async throws -> Void) -> Void
    var notifyStore: NotifySettingsStore?
    var onPin: ((String) -> Void)?
    var onShowArchived: (() -> Void)?

    @State private var source: MacSidebarChatSource
    @State private var rows = MacSidebarChatRows()
    /// The list's own selection: several rows while the user picks more
    /// than one; else the window's conversation.
    @State private var listSelection: Set<String> = []

    static let accessibilityIdentifier = "sidebar.list"

    init(viewModel: ChatListViewModel, selection: Binding<ChatSummary.ID?>,
         runChatAction: @escaping (@escaping (ChatService) async throws -> Void) -> Void,
         notifyStore: NotifySettingsStore?, onPin: ((String) -> Void)?, onShowArchived: (() -> Void)?,
         source: @autoclosure () -> MacSidebarChatSource) {
        self.viewModel = viewModel
        self._selection = selection
        self.runChatAction = runChatAction
        self.notifyStore = notifyStore
        self.onPin = onPin
        self.onShowArchived = onShowArchived
        self._source = State(wrappedValue: source())
    }

    var body: some View {
        // The closures capture this view's bindings and settings, which a
        // later update may change; plain stored properties, not observed.
        let _ = rows.actions = actions
        ZStack {
            MacListView(rows: rows, selection: $listSelection, style: .sourceList, allowsMultipleSelection: true,
                        accessibilityIdentifier: Self.accessibilityIdentifier,
                        publications: { [source] in source.publications() })
            overlay
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onShowArchived, source.isEmpty == false { MacArchivedButtonRow(action: onShowArchived) }
        }
        .onChange(of: listSelection) { _, ids in
            let window = MacSidebarSelection.window(after: ids, current: selection)
            if window != selection { selection = window }
        }
        .onChange(of: selection, initial: true) { _, id in
            let list = MacSidebarSelection.list(after: id, current: listSelection)
            if list != listSelection { listSelection = list }
        }
    }

    /// The SwiftUI sidebar's other states, over the list (which stays
    /// mounted, so its host and stream survive them).
    @ViewBuilder
    private var overlay: some View {
        // An empty index while the chat service is still on its first load
        // is "connecting", as in the SwiftUI sidebar, not "no chats".
        if source.isEmpty == nil || (source.isEmpty == true && viewModel.isLoading) {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if source.isEmpty == true {
            if let errorMessage = viewModel.error {
                ContentUnavailableView("Couldn't load chats", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Provision a bot via dev-boxer to get started.")
                } actions: {
                    if let onShowArchived { Button("Show Archived", action: onShowArchived) }
                }
            }
        }
    }

    private var actions: MacSidebarChatRows.Actions {
        let selectionBinding = $selection
        let listBinding = $listSelection
        let runChatAction = runChatAction
        return MacSidebarChatRows.Actions(
            open: { ids in
                guard let first = ids.first else { return }
                listBinding.wrappedValue = [first]
                selectionBinding.wrappedValue = first
            },
            archive: { ids in
                // Rows leaving the list leave the selection first.
                if let selected = selectionBinding.wrappedValue, ids.contains(selected) {
                    selectionBinding.wrappedValue = nil
                }
                listBinding.wrappedValue.subtract(ids)
                let list = ids.sorted()
                runChatAction { (chat: ChatService) in await chat.setArchived(list, archived: true) }
            },
            pin: onPin,
            notifyStore: notifyStore)
    }
}
