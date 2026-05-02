import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Mac chat detail column toolbar. Phase 2 lands a minimal scaffold here
/// in Task 14c; Task 14d expands it with the sidebar toggle, search
/// placeholder, and ⓘ profile button per spec §5.9.
@MainActor
struct MacChatToolbar: ToolbarContent {
    let title: String
    let viewModel: ChatViewModel
    let onShowBotProfile: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(title).font(.headline)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { onShowBotProfile() } label: {
                Image(systemName: "info.circle")
            }
            .help("Bot profile")
        }
    }
}
