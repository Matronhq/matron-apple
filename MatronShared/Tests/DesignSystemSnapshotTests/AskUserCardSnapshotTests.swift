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
}
