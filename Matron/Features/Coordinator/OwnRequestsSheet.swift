import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Coordinator's "Your requests" on iOS (tracker #2864 B): the user's
/// own messages in the Coordinator chat, newest first. A pick reports the
/// message's seq and dismisses; `ChatView` jumps from the sheet's
/// `onDismiss`, once the transcript is uncovered.
struct OwnRequestsSheet: View {
    let chatViewModel: ChatViewModel
    let onPick: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requests: [OwnMessageSummary]?

    var body: some View {
        NavigationStack {
            OwnRequestsList(requests: requests) { request in
                // Order matters: arm the jump, THEN dismiss.
                onPick(request.seq)
                dismiss()
            }
            .navigationTitle("Your requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { requests = await chatViewModel.ownRequests() }
    }
}
