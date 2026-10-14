import SwiftUI
import MatronModels
import MatronViewModels

/// The `ProjectRoute` push destination on the stacks other than Projects'
/// own (Conversations, For you, the Coordinator): a project link tapped in
/// a chat or an item pushes its page where the user is, so Back returns
/// to the chat or item the link sat in, rather than the Projects tab
/// coming forward with no way back. What the page opens rides the same
/// stack, through the caller's closures (each tab opens a conversation by
/// its own rule, as with `MissionRouteDestination`).
struct ProjectRouteDestination: View {
    let route: ProjectRoute
    let session: UserSession?
    let deps: AppDependencies?
    let vmCache: ChatVMCache
    let onOpenConversation: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenMission: (String) -> Void

    /// The shell's Projects view model, which the project page reads its
    /// mission rows from (`AppShellView` puts it in the environment).
    @Environment(MissionsDashboardViewModel.self) private var missionsViewModel: MissionsDashboardViewModel?

    var body: some View {
        if let session, let deps, let missionsViewModel {
            ProjectDetailHost(
                projectID: route.id, session: session, missionsViewModel: missionsViewModel,
                onOpenMission: onOpenMission, onOpenItem: onOpenItem, onOpenSession: onOpenConversation,
                onOpenMilestone: { convoID, seq in
                    onOpenConversation(convoID)
                    let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
                    Task { await chat.jumpToMilestone(seq: seq) }
                })
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Sign in again to open this project."))
        }
    }
}
