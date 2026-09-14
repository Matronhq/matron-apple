import SwiftUI
import MatronModels
import MatronViewModels

/// The `MissionRoute` push destination, shared by every `[String]` stack
/// that can carry one — the Conversations tab (`ChatListView`) and the
/// Coordinator tab (`CoordinatorTabView`). A title tap or a milestone card
/// pushes the same route onto whichever tab the chat happens to be mounted
/// on, so the page it opens must not depend on which tab that was (Bugbot:
/// the Coordinator's decoder never tried `MissionRoute` at all and opened
/// the id as a chat instead — a nonexistent room). One `MissionDetailHost`
/// construction, called from both tabs, so they cannot drift on it again.
struct MissionRouteDestination: View {
    let route: MissionRoute
    let session: UserSession?
    let deps: AppDependencies?
    let vmCache: ChatVMCache
    /// Opens a conversation on the caller's own stack — each tab pops or
    /// appends by its own rule (the Conversations tab pops back to the
    /// chat underneath; the Coordinator clears to its root when the
    /// target IS that root), so this stays the caller's closure rather
    /// than shared logic.
    let onOpenConversation: (String) -> Void
    let onOpenItem: (String) -> Void

    var body: some View {
        if let session, let deps {
            MissionDetailHost(
                missionID: route.id, session: session,
                onOpenMilestone: { convoID, seq in
                    onOpenConversation(convoID)
                    let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
                    Task { await chat.jumpToMilestone(seq: seq) }
                },
                onOpenItem: onOpenItem,
                onOpenConversation: onOpenConversation)
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Sign in again to open this mission."))
        }
    }
}
