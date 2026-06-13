import SwiftUI
import MatronDesignSystem
import MatronEvents
import MatronViewModels

/// iOS presentation wrapper for an ask-user prompt: half-sheet
/// (presented from `ChatView` with `.presentationDetents([.medium,
/// .large])`) around the shared `AskUserSheetBody`. The Mac
/// equivalent is `MacAskUserSheet` — same ViewModel and body, only
/// the presentation chrome differs.
struct AskUserSheet: View {
    @State var viewModel: AskUserSheetViewModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            AskUserSheetBody(
                event: viewModel.event,
                textInput: $viewModel.textInput,
                selectedChoiceIDs: $viewModel.selectedChoiceIDs,
                booleanAnswer: $viewModel.booleanAnswer,
                isSending: viewModel.isSending,
                isExpired: viewModel.isExpired,
                error: viewModel.error,
                onSend: { Task { await viewModel.send() } }
            )
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            // Auto-dismiss when `expires_at` is reached. Keyed on the
            // prompt event ID so a new prompt restarts the timer.
            .task(id: viewModel.promptEventID) {
                await viewModel.awaitExpiry(onExpire: onClose)
            }
        }
    }
}
