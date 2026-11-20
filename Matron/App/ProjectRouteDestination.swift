import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The project page's push destination on the stacks other than Projects'
/// own (Conversations, For you, Search, the Coordinator): a project link
/// tapped in a chat or an item pushes its page where the user is, so Back
/// returns to the chat or item the link sat in, rather than the Projects
/// tab coming forward with no way back. What the page opens rides the same
/// stack, through the caller's closures (each tab opens a conversation by
/// its own rule, as with `MissionRouteDestination`). The page's sections
/// are pushed onto this stack too.
struct ProjectRouteDestination: View {
    let route: ProjectPageTarget
    let session: UserSession?
    let deps: AppDependencies?
    let vmCache: ChatVMCache
    let onOpenConversation: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenMission: (String) -> Void

    /// The shell's Projects view model, which the project page reads its
    /// mission rows from (`AppShellView` puts it in the environment).
    @Environment(MissionsDashboardViewModel.self) private var missionsViewModel: MissionsDashboardViewModel?
    /// The stack this page is on: a section pushes onto it.
    @Environment(\.chatNavigationPath) private var path

    var body: some View {
        if let session, let deps, let missionsViewModel {
            let openMilestone: (String, Int64) -> Void = { convoID, seq in
                onOpenConversation(convoID)
                let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
                Task { await chat.jumpToMilestone(seq: seq) }
            }
            TimelineStoryHost(
                projectID: route.projectID, section: route.section, session: session,
                missionsViewModel: missionsViewModel, onOpenSection: pushSection,
                onOpenMission: onOpenMission, onOpenItem: onOpenItem, onOpenSession: onOpenConversation,
                onOpenMilestone: openMilestone)
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Sign in again to open this project."))
        }
    }

    /// A section of the page, one level down; a double tap never stacks two.
    private func pushSection(_ section: ProjectSection) {
        let value = ProjectSectionRoute(projectID: route.projectID, section: section).pathValue
        guard let path, path.wrappedValue.last != value else { return }
        path.wrappedValue.append(value)
    }
}
