import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// One pinned desk chat in the Conversations tab's Pinned section (journal
/// "Pinned desk chats"): glyph, the user's label, the conversation's title
/// beneath, and its needs-you and unread badges. A missing pin draws
/// greyed out with a note in place of the title.
struct PinnedDeskRow: View {
    let pin: ConvoPin
    /// The pinned conversation's summary; `nil` when it is not in the list
    /// (missing, or not loaded yet).
    let summary: ChatSummary?
    var isNotifySilenced = false

    /// The line under the label.
    static func secondaryLine(pin: ConvoPin, summary: ChatSummary?) -> String {
        if pin.missing { return "Conversation gone — move or unpin" }
        return summary?.title ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            PinGlyph(pin.glyph, size: 32, dimmed: pin.missing)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(Self.secondaryLine(pin: pin, summary: summary).isEmpty ? " " : Self.secondaryLine(pin: pin, summary: summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(pin.missing ? Color.secondary : Color.primary)
            Spacer()
            if let summary, !pin.missing {
                HStack(spacing: 4) {
                    if isNotifySilenced {
                        ConvoNotifySilencedIcon().font(.caption)
                    }
                    NeedsYouBadge(count: summary.needsUserCount)
                    UnreadBadge(count: summary.unreadCount)
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pin.row.\(pin.convoID)")
    }
}

/// "New session on box-b — move pin here?" under a pin's row, with
/// its two answers. Nothing moves until the user taps.
struct PinSuccessorHintRow: View {
    let text: String
    let onMove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "arrow.turn.down.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Move pin here", action: onMove)
                    .accessibilityIdentifier("pin.successor.move")
                Button("Dismiss", role: .cancel, action: onDismiss)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pin.successor.dismiss")
            }
            .font(.footnote.weight(.semibold))
            // Two buttons in one List row: borderless, or the row's tap
            // fires both.
            .buttonStyle(.borderless)
        }
        .padding(.leading, 44)
    }
}

/// The name-and-emoji form for a new pin ("Pin to sidebar…") or an existing
/// one (Settings → Pinned chats). `onSave` returns the error to show, or
/// `nil` once the journal took it.
struct PinEditorForm: View {
    let title: String
    let saveLabel: String
    let onSave: (_ label: String, _ emoji: String) async -> String?
    @State private var label: String
    @State private var emoji: String
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(title: String, saveLabel: String = "Save", label: String, emoji: String,
         onSave: @escaping (_ label: String, _ emoji: String) async -> String?) {
        self.title = title
        self.saveLabel = saveLabel
        self.onSave = onSave
        _label = State(initialValue: label)
        _emoji = State(initialValue: emoji)
    }

    var body: some View {
        Form {
            Section {
                PinEditorFields(label: $label, emoji: $emoji, labelMax: ConvoPin.labelMax)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("The name shows in place of the chat's title. Leave the emoji empty to show its first letter.")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saveLabel) {
                    saving = true
                    Task { @MainActor in
                        error = await onSave(label, emoji)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(saving || ConvoPin.clampLabel(label).isEmpty)
            }
        }
    }
}

/// `PinEditorForm` in its own sheet, with Cancel.
struct PinEditorSheet: View {
    let title: String
    var saveLabel = "Save"
    let label: String
    let emoji: String
    let onSave: (_ label: String, _ emoji: String) async -> String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PinEditorForm(title: title, saveLabel: saveLabel, label: label, emoji: emoji, onSave: onSave)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

/// What a pin sheet edits: a conversation about to be pinned, or a pin.
enum PinEditTarget: Identifiable, Equatable {
    case new(convoID: String, suggestedLabel: String)
    case edit(ConvoPin)

    var id: String {
        switch self {
        case .new(let convoID, _): return "new:\(convoID)"
        case .edit(let pin): return "edit:\(pin.convoID)"
        }
    }
}

extension PinsStore {
    /// The editor sheet for `target`, saving through this store.
    @MainActor
    func editorSheet(for target: PinEditTarget) -> PinEditorSheet {
        switch target {
        case .new(let convoID, let suggested):
            return PinEditorSheet(title: "Pin to sidebar", saveLabel: "Pin", label: suggested, emoji: "") { label, emoji in
                await self.pin(convoID, label: label, emoji: emoji)
            }
        case .edit(let pin):
            return PinEditorSheet(title: "Edit pin", label: pin.label, emoji: pin.emoji) { label, emoji in
                await self.edit(pin.convoID, label: label, emoji: emoji)
            }
        }
    }
}
