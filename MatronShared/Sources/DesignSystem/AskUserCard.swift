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
    @State private var expanded: Bool

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
        expanded: Bool = false
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
            } else {
                // AskUserSheetBody self-pads.
                AskUserSheetBody(
                    event: event,
                    textInput: $textInput,
                    selectedChoiceIDs: $selectedChoiceIDs,
                    booleanAnswer: $booleanAnswer,
                    isSending: isSending,
                    isExpired: isExpired,
                    error: error,
                    onSend: onSend
                )
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

    /// The reminder as one line: Send now / Cancel while it is pending,
    /// the choice once answered, nothing once it has fired or gone.
    private var reminderRow: some View {
        CompactCardRow(line: event.compactLine, timestamp: timestamp, expanded: $expanded) {
            if isAnswered {
                Text(answerSummary.map { splitLeadingGlyph($0).text } ?? "Answered")
                    .foregroundStyle(.tertiary)
            } else if !isExpired, case .choice(let options, _) = event.kind {
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
            VStack(alignment: .leading, spacing: 4) {
                Text(event.prompt)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
            }
        }
    }
}
