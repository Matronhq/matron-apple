import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// Settings → Pinned chats (journal "Pinned desk chats"): the user's desk
/// chats in their order — add (with the Coordinator's chooser), rename and
/// change the emoji, drag to reorder, move a pin to another conversation,
/// and unpin. The same list every device shows.
struct PinnedChatsSettingsView: View {
    let store: PinsStore
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var editTarget: PinEditTarget?
    @State private var movingPinID: String?
    @State private var adding = false
    /// The chat picked in the add chooser, named once that sheet is gone.
    @State private var pickedToAdd: PinEditTarget?
    @State private var error: String?

    /// The title under a pin's label, from the local mirror.
    private func title(of pin: ConvoPin) -> String {
        if pin.missing { return "Conversation gone — move or unpin" }
        guard let deps, let session else { return "" }
        let stored = (try? deps.journalStore(for: session).conversation(id: pin.convoID))?.title ?? ""
        return SessionTag.splitTitle(stored).title
    }

    /// The pins and the Coordinator: what the choosers leave out.
    private var excluding: Set<String> {
        var ids = store.pinnedIDs
        if let session, let coordinator = CoordinatorSetting(userID: session.userID).convoID { ids.insert(coordinator) }
        return ids
    }

    var body: some View {
        List {
            if store.isSupported == false {
                Text("This journal server doesn't support pinned chats yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(store.pins) { pin in
                        HStack(spacing: 12) {
                            PinGlyph(pin.glyph, size: 28, dimmed: pin.missing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pin.label)
                                Text(title(of: pin))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(pin.missing ? Color.secondary : Color.primary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !pin.missing { editTarget = .edit(pin) } }
                        .swipeActions {
                            Button("Unpin", role: .destructive) { run { await $0.unpin(pin.convoID) } }
                            Button("Move…") { movingPinID = pin.convoID }.tint(.blue)
                        }
                        .contextMenu {
                            if !pin.missing {
                                Button { editTarget = .edit(pin) } label: { Label("Edit pin…", systemImage: "pencil") }
                            }
                            Button { movingPinID = pin.convoID } label: {
                                Label("Move pin…", systemImage: "arrow.left.arrow.right")
                            }
                            Button(role: .destructive) { run { await $0.unpin(pin.convoID) } } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                        .accessibilityIdentifier("settings.pin.\(pin.convoID)")
                    }
                    .onMove { from, to in
                        var order = store.pins.map(\.convoID)
                        order.move(fromOffsets: from, toOffset: to)
                        run { await $0.reorder(order) }
                    }
                    if !store.isFull {
                        Button { adding = true } label: { Label("Add a pinned chat…", systemImage: "plus") }
                    }
                } footer: {
                    Text("Up to \(store.limit) chats, shown under the Coordinator on every device. Tap one to rename it; drag to reorder.")
                }
            }
        }
        .navigationTitle("Pinned chats")
        .toolbar { if !store.pins.isEmpty { EditButton() } }
        .modifier(PinSheetsModifier(store: store, editTarget: $editTarget, movingPinID: $movingPinID,
                                    error: $error, excluding: excluding))
        .sheet(isPresented: $adding, onDismiss: {
            // The editor is a sheet too: it opens once the chooser is gone.
            if let picked = pickedToAdd {
                pickedToAdd = nil
                editTarget = picked
            }
        }) {
            if let deps, let session {
                CoordinatorChooserSheet(deps: deps, session: session, title: "Pin a chat",
                                        newChatLabel: nil, excluding: excluding) { id in
                    let suggested = (try? deps.journalStore(for: session).conversation(id: id))?.title ?? ""
                    pickedToAdd = .new(convoID: id, suggestedLabel: PinsStore.suggestedLabel(fromTitle: suggested))
                    adding = false
                }
            }
        }
        .task { await store.refresh() }
    }

    private func run(_ action: @escaping (PinsStore) async -> String?) {
        Task { @MainActor in
            if let message = await action(store) { error = message }
        }
    }
}
