import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

/// Snapshots the shared sheet body (not the per-platform wrappers —
/// the iOS detents / Mac fixed frame are presentation chrome verified
/// by the host schemes). `Binding.constant` backs the inputs: the
/// plan sketched a StatefulPreviewWrapper, but static snapshots never
/// write through the binding, and constants let each case pin a
/// selected state directly.
final class AskUserSheetSnapshotTests: XCTestCase {
    private func body(
        event: AskUserEvent,
        textInput: String = "",
        selectedChoiceIDs: Set<String> = [],
        booleanAnswer: Bool? = nil,
        isExpired: Bool = false,
        error: String? = nil
    ) -> some View {
        AskUserSheetBody(
            event: event,
            textInput: .constant(textInput),
            selectedChoiceIDs: .constant(selectedChoiceIDs),
            booleanAnswer: .constant(booleanAnswer),
            isSending: false,
            isExpired: isExpired,
            error: error,
            onSend: {}
        )
        .frame(width: 375, height: 480)
    }

    func test_text() {
        assertVariants(
            of: body(event: AskUserEvent(prompt: "What's the workdir?", kind: .text, expiresAt: nil)),
            named: "text"
        )
    }

    func test_choice_withSelectionAndOther() {
        let opts = [
            AskUserEvent.Option(id: "a", label: "src/main.rs"),
            AskUserEvent.Option(id: "b", label: "src/lib.rs"),
        ]
        assertVariants(
            of: body(
                event: AskUserEvent(
                    prompt: "Which file?",
                    kind: .choice(options: opts, allowOther: true),
                    expiresAt: nil
                ),
                selectedChoiceIDs: ["a"]
            ),
            named: "choice"
        )
    }

    func test_choice_withMixedGlyphs() {
        let opts = [
            AskUserEvent.Option(id: "s", label: "⚡ Send now"),
            AskUserEvent.Option(id: "c", label: "✕ Cancel"),
            AskUserEvent.Option(id: "o", label: "Other action"),
        ]
        assertVariants(
            of: body(
                event: AskUserEvent(
                    prompt: "Message queued. What now?",
                    kind: .choice(options: opts, allowOther: false),
                    expiresAt: nil
                )
            ),
            named: "choice_mixedGlyphs"
        )
    }

    func test_multiChoice() {
        let opts = [
            AskUserEvent.Option(id: "a", label: "Build"),
            AskUserEvent.Option(id: "b", label: "Test"),
            AskUserEvent.Option(id: "c", label: "Lint"),
        ]
        assertVariants(
            of: body(
                event: AskUserEvent(
                    prompt: "Which steps to run?",
                    kind: .multiChoice(options: opts, allowOther: false),
                    expiresAt: nil
                ),
                selectedChoiceIDs: ["a", "c"]
            ),
            named: "multiChoice"
        )
    }

    func test_boolean_withYesSelected() {
        assertVariants(
            of: body(
                event: AskUserEvent(prompt: "Proceed?", kind: .boolean, expiresAt: nil),
                booleanAnswer: true
            ),
            named: "boolean"
        )
    }

    func test_expired_disablesControls() {
        assertVariants(
            of: body(
                event: AskUserEvent(
                    prompt: "What's the workdir?",
                    kind: .text,
                    expiresAt: Date(timeIntervalSince1970: 1745000000)
                ),
                isExpired: true
            ),
            named: "expired"
        )
    }

    func test_error_showsMessage() {
        assertVariants(
            of: body(
                event: AskUserEvent(prompt: "Proceed?", kind: .boolean, expiresAt: nil),
                booleanAnswer: false,
                error: "Failed to send — network offline"
            ),
            named: "error"
        )
    }
}
