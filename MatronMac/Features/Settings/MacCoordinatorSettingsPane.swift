#if os(macOS)
import SwiftUI
import MatronModels
import MatronViewModels

/// Settings → Coordinator: the Coordinator conversation and what it may
/// approve, the pinned chats, For you, and the agent chat requests still
/// waiting on a decision.
struct MacCoordinatorSettingsPane: View {
    let session: UserSession
    let deps: AppDependencies

    var body: some View {
        Form {
            MacCoordinatorSettingRow(session: session, deps: deps)
            MacPinnedChatsSection(session: session, deps: deps, store: deps.pinsStore(for: session))
            MacForYouSettingsSection(store: deps.userSettings(for: session))
            MacAgentChatRequestsSection(api: deps.agentChatService(for: session))
        }
        .formStyle(.grouped)
        // Fits a few pinned chats and an empty request list; more of either
        // scrolls.
        .frame(width: 480, height: 780)
    }
}
#endif
