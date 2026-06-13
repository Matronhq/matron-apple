import SwiftUI
import MatronDesignSystem
import MatronEvents
import MatronViewModels

/// Mac presentation wrapper for an ask-user prompt. Mac sheets don't
/// support detents, so `MacChatView` presents this at a fixed
/// 520×400 (spec §5.9 fixed-size sheets); the content is the same
/// shared `AskUserSheetBody` the iOS half-sheet renders. Plain
/// header row + Close button instead of a NavigationStack — matches
/// the Mac chrome of the other fixed-size sheets.
struct MacAskUserSheet: View {
    @State var viewModel: AskUserSheetViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Question").font(.headline)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

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
        }
        .task(id: viewModel.promptEventID) {
            await viewModel.awaitExpiry(onExpire: onClose)
        }
    }
}
