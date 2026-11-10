import SwiftUI
import MatronEvents

/// Inline, non-blocking rendering of a bot question in the timeline — the
/// replacement for the old `AskUserSheet`/`MacAskUserSheet` modals. Bot-card
/// styling (matches `ToolCallCard`). Two states:
///
/// - **Unanswered:** embeds the shared `AskUserSheetBody` (prompt + inputs +
///   Send). `AskUserSheetBody` already disables its controls + shows the
///   expired notice when `isExpired`.
/// - **Answered:** the prompt plus "✓ You chose: <answerSummary>" (or
///   "✓ Answered" when the specific choice can't be resolved), non-interactive.
///
/// Pure: parameterised on plain values + bindings (no app/service types), so it
/// stays in MatronDesignSystem and snapshots directly.
public struct AskUserCard: View {
    public let event: AskUserEvent
    public let isAnswered: Bool
    public let answerSummary: String?
    @Binding public var textInput: String
    @Binding public var selectedChoiceIDs: Set<String>
    @Binding public var booleanAnswer: Bool?
    public let isSending: Bool
    public let isExpired: Bool
    public let error: String?
    public let onSend: () -> Void
    /// Draw the bridge's reminder card (`AskUserEvent.isReminderCard`) as
    /// one line with its buttons on it, the reminder text one click away.
    public let foldsReminder: Bool
    /// The line's time, when folded.
    public let timestamp: Date?
    /// Edit on a queued message (`AskUserEvent.QueuedEdit`), `nil` when the
    /// card offers none.
    public let edit: QueuedEditControls?
    @State private var expanded: Bool

    /// What the card needs to draw Edit and the editor it opens. Plain
    /// values and closures, so the card stays free of view-model types.
    public struct QueuedEditControls {
        public let text: Binding<String>
        public let isEditing: Bool
        public let isBusy: Bool
        public let canSave: Bool
        public let error: String?
        public let holdMinutes: Int
        public let onEdit: () -> Void
        public let onSave: () -> Void
        public let onCancel: () -> Void

        public init(text: Binding<String>, isEditing: Bool, isBusy: Bool, canSave: Bool, error: String?,
                    holdMinutes: Int, onEdit: @escaping () -> Void, onSave: @escaping () -> Void,
                    onCancel: @escaping () -> Void) {
            self.text = text; self.isEditing = isEditing; self.isBusy = isBusy; self.canSave = canSave
            self.error = error; self.holdMinutes = holdMinutes
            self.onEdit = onEdit; self.onSave = onSave; self.onCancel = onCancel
        }
    }

    public init(
        event: AskUserEvent,
        isAnswered: Bool,
        answerSummary: String?,
        textInput: Binding<String>,
        selectedChoiceIDs: Binding<Set<String>>,
        booleanAnswer: Binding<Bool?>,
        isSending: Bool,
        isExpired: Bool,
        error: String? = nil,
        onSend: @escaping () -> Void,
        foldsReminder: Bool = false,
        timestamp: Date? = nil,
        expanded: Bool = false,
        edit: QueuedEditControls? = nil
    ) {
        self.event = event
        self.isAnswered = isAnswered
        self.answerSummary = answerSummary
        self._textInput = textInput
        self._selectedChoiceIDs = selectedChoiceIDs
        self._booleanAnswer = booleanAnswer
        self.isSending = isSending
        self.isExpired = isExpired
        self.error = error
        self.onSend = onSend
        self.foldsReminder = foldsReminder
        self.timestamp = timestamp
        self.edit = edit
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        if foldsReminder, event.isReminderCard {
            reminderRow
        } else {
            card
        }
    }

    private var card: some View {
        Group {
            if isAnswered {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.prompt).font(.body)
                    Label {
                        Text(answerSummary.map { "You chose: \($0)" } ?? "Answered")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding()
            } else if let edit, edit.isEditing {
                editor(edit)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // AskUserSheetBody self-pads.
                    AskUserSheetBody(
                        event: event,
                        textInput: $textInput,
                        selectedChoiceIDs: $selectedChoiceIDs,
                        booleanAnswer: $booleanAnswer,
                        // An Edit on its way holds the buttons too.
                        isSending: isSending || (edit?.isBusy ?? false),
                        isExpired: isExpired,
                        error: error,
                        onSend: onSend
                    )
                    if let edit { editRow(edit) }
                }
            }
        }
        // Bot-bubble surface (matches `MessageBubble`'s bot chrome): a warm
        // white fill lifted off the cream timeline by the web's soft drop
        // shadow. The shadow is applied to the shape itself (not the card's
        // content) so the prompt text and buttons don't cast their own.
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.matronBubbleBot)
                .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
        )
    }

    /// Edit, under the card's own Send now / Cancel.
    private func editRow(_ edit: QueuedEditControls) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    edit.onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(edit.isBusy || isSending || isExpired)
                .accessibilityIdentifier("queued-edit")
                .accessibilityHint("Holds this message so it isn't sent while you edit it")
                if edit.isBusy { ProgressView().controlSize(.small) }
            }
            if let error = edit.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding([.horizontal, .bottom])
    }

    /// The open editor: the message is held until Save or Cancel edit.
    private func editor(_ edit: QueuedEditControls) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Held while you edit. It won't be sent until you save or cancel "
                  + "(or after \(edit.holdMinutes) minutes, with the original text).",
                  systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: edit.text)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("queued-edit-text")
            if let error = edit.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Cancel edit", action: edit.onCancel)
                    .buttonStyle(.bordered)
                    .disabled(edit.isBusy)
                    .accessibilityIdentifier("queued-edit-cancel")
                Button("Save", action: edit.onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(edit.isBusy || !edit.canSave)
                    .accessibilityIdentifier("queued-edit-save")
                if edit.isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding()
    }

    /// The reminder as one line: Send now / Cancel while it is pending,
    /// the choice once answered, nothing once it has fired or gone.
    private var reminderRow: some View {
        CompactCardRow(line: event.compactLine, timestamp: timestamp, expanded: $expanded) {
            if isAnswered {
                Text(answerSummary.map { splitLeadingGlyph($0).text } ?? "Answered")
                    .foregroundStyle(.tertiary)
            } else if !isExpired, case .choice(let options, _) = event.kind {
                // On the line, beside the buttons it is about: a failed tap
                // must not look like a no-op on a folded row.
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                ForEach(options, id: \.id) { option in
                    Button(splitLeadingGlyph(option.label).text) {
                        selectedChoiceIDs = [option.id]
                        onSend()
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSending)
                }
                if isSending { ProgressView().controlSize(.small) }
            }
        } detail: {
            Text(event.prompt)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
            }
        }
    }
}
