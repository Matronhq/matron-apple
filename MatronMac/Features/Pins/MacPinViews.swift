import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// What a pin's menus ask the shell to do (journal "Pinned desk chats").
enum MacPinAction: Equatable {
    case edit(ConvoPin)
    /// Move pin… — the chooser.
    case move(convoID: String)
    case unpin(convoID: String)
    /// The successor hint's "Move pin here".
    case moveToSuccessor(convoID: String, successorID: String)
    case dismissSuccessor(convoID: String)
}

/// The menu a pin's nav-column entry and its page offer. A missing pin
/// offers only Move pin… and Unpin.
struct MacPinMenu: View {
    let pin: ConvoPin
    var successorHint: String?
    let onAction: (MacPinAction) -> Void

    var body: some View {
        if let successor = pin.successor, !pin.missing {
            Button(successorHint ?? "Move pin to the new session") {
                onAction(.moveToSuccessor(convoID: pin.convoID, successorID: successor.convoID))
            }
            Button("Dismiss new-session hint") { onAction(.dismissSuccessor(convoID: pin.convoID)) }
            Divider()
        }
        if !pin.missing {
            Button("Edit Pin…") { onAction(.edit(pin)) }
        }
        Button("Move Pin…") { onAction(.move(convoID: pin.convoID)) }
        Button("Unpin", role: .destructive) { onAction(.unpin(convoID: pin.convoID)) }
    }
}

/// "New session on box-b — move pin here?" across the top of a
/// desk's page, with its two answers. Nothing moves until the user clicks.
struct MacPinSuccessorBanner: View {
    let text: String
    let onMove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
            Text(text).font(.callout)
            Spacer()
            Button("Move Pin Here", action: onMove)
                .controlSize(.small)
                .accessibilityIdentifier("pin.successor.move")
            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
                .accessibilityIdentifier("pin.successor.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }
}

/// A desk page whose conversation is gone (journal `missing`), or a
/// restored page whose pin has since gone.
struct MacPinGonePage: View {
    let pin: ConvoPin?
    let onAction: (MacPinAction) -> Void

    var body: some View {
        if let pin {
            ContentUnavailableView {
                Label(pin.label, systemImage: "pin.slash")
            } description: {
                Text("This pinned conversation is gone. Move the pin to another conversation, or unpin it.")
            } actions: {
                Button("Move Pin…") { onAction(.move(convoID: pin.convoID)) }
                Button("Unpin") { onAction(.unpin(convoID: pin.convoID)) }
            }
        } else {
            ContentUnavailableView("Not pinned any more", systemImage: "pin.slash",
                                   description: Text("This chat was unpinned. Find it under Conversations."))
        }
    }
}

/// The name-and-emoji sheet for a new pin ("Pin to Sidebar…") or an
/// existing one. `onSave` returns the error to show, or `nil` once the
/// journal took it.
struct MacPinEditorSheet: View {
    let heading: String
    var saveLabel = "Save"
    let onSave: (_ label: String, _ emoji: String) async -> String?
    @State private var label: String
    @State private var emoji: String
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(heading: String, saveLabel: String = "Save", label: String, emoji: String,
         onSave: @escaping (_ label: String, _ emoji: String) async -> String?) {
        self.heading = heading
        self.saveLabel = saveLabel
        self.onSave = onSave
        _label = State(initialValue: label)
        _emoji = State(initialValue: emoji)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.headline)
            Form {
                PinEditorFields(label: $label, emoji: $emoji, labelMax: ConvoPin.labelMax)
            }
            Text(error ?? "The name shows in place of the chat's title. Leave the emoji empty to show its first letter.")
                .font(.caption)
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveLabel) {
                    saving = true
                    Task { @MainActor in
                        error = await onSave(label, emoji)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || ConvoPin.clampLabel(label).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// What a Mac pin sheet edits: a conversation about to be pinned, or a pin.
enum MacPinEditTarget: Identifiable, Equatable {
    case new(convoID: String, suggestedLabel: String)
    case edit(ConvoPin)

    var id: String {
        switch self {
        case .new(let convoID, _): return "new:\(convoID)"
        case .edit(let pin): return "edit:\(pin.convoID)"
        }
    }
}

/// The editor sheet, the Move pin… chooser and the error alert for one
/// window or the Settings screen. `perform` runs a `MacPinAction` through
/// the store, opening the sheets it needs.
struct MacPinSheets: ViewModifier {
    let store: PinsStore?
    @Binding var editTarget: MacPinEditTarget?
    @Binding var movingPinID: String?
    @Binding var error: String?
    /// What the chooser leaves out: the pins and the Coordinator.
    let excluding: Set<String>
    let deps: AppDependencies?
    let session: UserSession?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editTarget) { target in
                if let store {
                    switch target {
                    case .new(let convoID, let suggested):
                        MacPinEditorSheet(heading: "Pin to Sidebar", saveLabel: "Pin", label: suggested, emoji: "") { label, emoji in
                            await store.pin(convoID, label: label, emoji: emoji)
                        }
                    case .edit(let pin):
                        MacPinEditorSheet(heading: "Edit Pin", label: pin.label, emoji: pin.emoji) { label, emoji in
                            await store.edit(pin.convoID, label: label, emoji: emoji)
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { movingPinID != nil }, set: { if !$0 { movingPinID = nil } })) {
                if let deps, let session, let store, let from = movingPinID {
                    MacCoordinatorChooserSheet(deps: deps, session: session,
                                               heading: "Move “\(store.pin(for: from)?.label ?? "pin")” to…",
                                               newChatLabel: nil, excluding: excluding) { to in
                        movingPinID = nil
                        Task { @MainActor in
                            if let message = await store.move(from, to: to) { error = message }
                        }
                    }
                }
            }
            .alert("Pinned chats", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
}

extension PinsStore {
    /// Runs the store half of a pin menu action; `.edit` and `.move` open
    /// sheets and are the caller's. Returns the error to show.
    @MainActor
    func perform(_ action: MacPinAction) async -> String? {
        switch action {
        case .edit, .move: return nil
        case .unpin(let convoID): return await unpin(convoID)
        case .moveToSuccessor(let convoID, let successorID): return await move(convoID, to: successorID)
        case .dismissSuccessor(let convoID): return await dismissSuccessor(of: convoID)
        }
    }
}

/// A pin menu used outside a window's view tree (the chat header, hosted
/// in the title bar) asks the window for its sheets through here. Only the
/// window showing that conversation answers.
enum MacPinRequest {
    static let name = Notification.Name("chat.matron.pinRequest")
    static let actionKey = "action"
    static let pinConvoKey = "pinConvoID"

    static func post(_ action: MacPinAction) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: [actionKey: action])
    }

    /// "Pin to Sidebar…" for `convoID`.
    static func postPin(_ convoID: String) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: [pinConvoKey: convoID])
    }

    /// The conversation a request is about.
    static func convoID(of note: Notification) -> String? {
        if let id = note.userInfo?[pinConvoKey] as? String { return id }
        switch note.userInfo?[actionKey] as? MacPinAction {
        case .edit(let pin): return pin.convoID
        case .move(let id), .unpin(let id), .dismissSuccessor(let id): return id
        case .moveToSuccessor(let id, _): return id
        case nil: return nil
        }
    }
}
