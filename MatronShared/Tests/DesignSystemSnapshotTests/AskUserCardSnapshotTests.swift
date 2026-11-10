import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

final class AskUserCardSnapshotTests: XCTestCase {
    private func card(
        event: AskUserEvent,
        isAnswered: Bool = false,
        answerSummary: String? = nil,
        textInput: String = "",
        selectedChoiceIDs: Set<String> = [],
        booleanAnswer: Bool? = nil,
        isExpired: Bool = false,
        error: String? = nil
    ) -> some View {
        AskUserCard(
            event: event,
            isAnswered: isAnswered,
            answerSummary: answerSummary,
            textInput: .constant(textInput),
            selectedChoiceIDs: .constant(selectedChoiceIDs),
            booleanAnswer: .constant(booleanAnswer),
            isSending: false,
            isExpired: isExpired,
            error: error,
            onSend: {}
        )
        .frame(width: 360)
        .padding()
    }

    private var buttonsEvent: AskUserEvent {
        AskUserEvent(
            prompt: "Message queued. Send now or cancel?",
            kind: .choice(options: [
                AskUserEvent.Option(id: "s", label: "Send", value: "send:0"),
                AskUserEvent.Option(id: "c", label: "Cancel", value: "cancel:0"),
            ], allowOther: false),
            expiresAt: nil,
            replyChannel: .buttonResponse
        )
    }

    func test_unanswered_buttons() {
        assertVariants(of: card(event: buttonsEvent), named: "unanswered_buttons")
    }

    func test_answered_echoesChoice() {
        assertVariants(
            of: card(event: buttonsEvent, isAnswered: true, answerSummary: "Send"),
            named: "answered"
        )
    }

    func test_expired() {
        assertVariants(
            of: card(
                event: AskUserEvent(prompt: "Proceed?", kind: .boolean,
                                    expiresAt: Date(timeIntervalSince1970: 1745000000)),
                isExpired: true
            ),
            named: "expired"
        )
    }

    // MARK: - Editing a queued message

    private var queuedEvent: AskUserEvent {
        AskUserEvent(
            prompt: "Send this queued message now, or cancel it?",
            kind: .choice(options: [
                AskUserEvent.Option(id: "send", label: "⚡ Send now", value: "send"),
                AskUserEvent.Option(id: "cancel", label: "✕ Cancel", value: "cancel"),
            ], allowOther: false),
            expiresAt: nil, replyChannel: .buttonResponse, queuedReleasePromptID: "pr_1",
            queuedEdit: AskUserEvent.QueuedEdit(text: "Run the migration on staging first", holdSeconds: 600)
        )
    }

    private func queuedCard(editing: Bool, text: String = "Run the migration on staging first, then prod") -> some View {
        AskUserCard(
            event: queuedEvent, isAnswered: false, answerSummary: nil,
            textInput: .constant(""), selectedChoiceIDs: .constant([]), booleanAnswer: .constant(nil),
            isSending: false, isExpired: false, error: nil, onSend: {},
            edit: AskUserCard.QueuedEditControls(
                text: .constant(text), isEditing: editing, isBusy: false, canSave: true, error: nil,
                holdMinutes: 10, onEdit: {}, onSave: {}, onCancel: {})
        )
        .frame(width: 360)
        .padding()
    }

    func test_queued_offersEdit() {
        assertVariants(of: queuedCard(editing: false), named: "queued_edit")
    }

    func test_queued_editorOpen() {
        assertVariants(of: queuedCard(editing: true), named: "queued_editing")
    }

    func test_queued_editSaved() {
        assertVariants(of: card(event: queuedEvent, isAnswered: true, answerSummary: "✎ Edited"), named: "queued_edited")
    }
}
