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
        onSend: @escaping () -> Void
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
    }

    public var body: some View {
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
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
        )
    }
}
