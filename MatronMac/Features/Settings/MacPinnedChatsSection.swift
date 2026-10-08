import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// Settings → Pinned chats (journal "Pinned desk chats"): the user's desk
/// chats in their order — add (with the Coordinator's chooser), rename and
/// change the emoji, reorder, move a pin to another conversation, and
/// unpin. The same list every device shows.
struct MacPinnedChatsSection: View {
    let session: UserSession
    let deps: AppDependencies
    let store: PinsStore
    @State private var editTarget: MacPinEditTarget?
    @State private var movingPinID: String?
    @State private var adding = false
    @State private var pickedToAdd: MacPinEditTarget?
    @State private var error: String?

    private func title(of pin: ConvoPin) -> String {
        if pin.missing { return "Conversation gone — move or unpin" }
        let stored = (try? deps.journalStore(for: session).conversation(id: pin.convoID))?.title ?? ""
        return SessionTag.splitTitle(stored).title
    }

    /// The pins and the Coordinator: what the choosers leave out.
    private var excluding: Set<String> {
        var ids = store.pinnedIDs
        if let coordinator = CoordinatorSetting(userID: session.userID).convoID { ids.insert(coordinator) }
        return ids
    }

    var body: some View {
        Section {
            if store.isSupported == false {
                Text("This journal server doesn't support pinned chats yet.").foregroundStyle(.secondary)
            } else {
                if store.pins.isEmpty {
                    Text("No pinned chats yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(store.pins.enumerated()), id: \.element.id) { index, pin in
                    row(pin, index: index)
                }
                if !store.isFull {
                    Button("Add a Pinned Chat…") { adding = true }
                }
            }
        } header: {
            Text("Pinned chats")
        } footer: {
            Text("Up to \(store.limit) chats, shown under the Coordinator in the sidebar on every device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .modifier(MacPinSheets(store: store, editTarget: $editTarget, movingPinID: $movingPinID, error: $error,
                               excluding: excluding, deps: deps, session: session))
        .sheet(isPresented: $adding, onDismiss: {
            // The editor is a sheet too: it opens once the chooser is gone.
            if let picked = pickedToAdd {
                pickedToAdd = nil
                editTarget = picked
            }
        }) {
            MacCoordinatorChooserSheet(deps: deps, session: session, heading: "Pin a chat",
                                       newChatLabel: nil, excluding: excluding) { id in
                let suggested = (try? deps.journalStore(for: session).conversation(id: id))?.title ?? ""
                pickedToAdd = .new(convoID: id, suggestedLabel: PinsStore.suggestedLabel(fromTitle: suggested))
                adding = false
            }
        }
        .task { await store.refresh() }
    }

    private func row(_ pin: ConvoPin, index: Int) -> some View {
        HStack(spacing: 10) {
            PinGlyph(pin.glyph, size: 24, dimmed: pin.missing)
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.label)
                Text(title(of: pin)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .foregroundStyle(pin.missing ? Color.secondary : Color.primary)
            Spacer()
            Button { run { await $0.moveStep(pin.convoID, up: true) } } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up")
                .accessibilityLabel("Move \(pin.label) up")
            Button { run { await $0.moveStep(pin.convoID, up: false) } } label: { Image(systemName: "chevron.down") }
                .disabled(index == store.pins.count - 1)
                .help("Move down")
                .accessibilityLabel("Move \(pin.label) down")
            Menu {
                MacPinMenu(pin: pin) { action in
                    switch action {
                    case .edit(let pin): editTarget = .edit(pin)
                    case .move(let id): movingPinID = id
                    default: run { await $0.perform(action) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(pin.label) options")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("settings.pin.\(pin.convoID)")
    }

    private func run(_ action: @escaping (PinsStore) async -> String?) {
        Task { @MainActor in
            if let message = await action(store) { error = message }
        }
    }
}
