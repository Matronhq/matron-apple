import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// The Coordinator sheet (Coordinator redesign §3c): its own
/// `NavigationStack` whose root is the Coordinator's chat, or
/// `CoordinatorSetupView` when none is set. Presented over any screen with
/// detents `.large` and `.medium`; pushes land on `path`.
struct CoordinatorSheet: View {
    enum Root: Equatable {
        case setup
        case chat(String)
    }

    let session: UserSession
    let deps: AppDependencies
    let chatListVM: ChatListViewModel
    let vmCache: ChatVMCache
    @Binding var path: [String]
    /// Read-only: the cache follows the journal; picks go through
    /// `deps.setCoordinator`.
    let convoID: String?

    @State private var showingChooser = false
    @State private var detent: PresentationDetent = .large
    @State private var saveError: String?

    static func root(for convoID: String?) -> Root {
        guard let convoID, !convoID.isEmpty else { return .setup }
        return .chat(convoID)
    }

    /// The outcome of "open conversation" (or a milestone jump — the
    /// jump itself always fires underneath, via `MissionRouteDestination`)
    /// from the Coordinator mission page. `target == current` (the chat
    /// already underneath the mission page, or the coordinator root via
    /// the `current` fallback) pops the mission page to reveal it —
    /// mirroring `ChatListView.missionDestination`'s `removeLast()`, and
    /// the case a plain no-op (copied from the `ItemRoute` branch, which
    /// has no jump to reveal) left the mission page on screen even though
    /// `jumpToMilestone` had already fired (Bugbot, PR #209). `target ==
    /// coordinatorConvoID` but not `current` (the mission was opened from
    /// a DIFFERENT chat) clears all the way to the root instead of
    /// stacking a second copy (Bugbot, PR #197). A pure decision so a
    /// test can pin the coordinator's same-room round trip without a
    /// live `NavigationStack`.
    enum MissionConversationOutcome: Equatable {
        case popMission
        case clearToRoot
        case push(String)
    }
    static func missionOpenConversationOutcome(
        target: String, current: String?, coordinatorConvoID: String?
    ) -> MissionConversationOutcome {
        if target == current { return .popMission }
        if target == coordinatorConvoID { return .clearToRoot }
        return .push(target)
    }

    private func summary(for id: String) -> ChatSummary? {
        if let hidden = chatListVM.hiddenSummary, hidden.id == id { return hidden }
        return chatListVM.groups.flatMap(\.summaries).first { $0.id == id }
    }

    var body: some View {
        InsideCoordinatorSheet {
            stack
        }
        .environment(\.chatNavigationPath, $path)
        .sheet(isPresented: $showingChooser) {
            CoordinatorChooserSheet(deps: deps, session: session) { id in
                showingChooser = false
                Task { @MainActor in saveError = await deps.setCoordinator(id, for: session) }
            }
        }
        .alert("Coordinator", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .presentationDetents([.large, .medium], selection: $detent)
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            Group {
                switch Self.root(for: convoID) {
                case .setup:
                    CoordinatorSetupView(onChoose: { showingChooser = true })
                        .navigationTitle("Coordinator")
                case .chat(let id):
                    ChatDestinationView(id: id, summary: summary(for: id), vmCache: vmCache, hidesTabBar: false)
                        .navigationBarBackButtonHidden(true)
                }
            }
            .navigationDestination(for: String.self) { value in
                if let mission = MissionRoute(pathValue: value) {
                    // Same fallback `ItemRoute` uses just below: the chat
                    // underneath is the nearest non-item entry on this
                    // stack, falling back to the coordinator root (Bugbot:
                    // this branch was missing entirely, so a title tap or
                    // milestone card in the coordinator chat opened the
                    // mission's id as if it were a conversation).
                    let current = path.last(where: { !isAnyPathPrefixedRoute($0) }) ?? convoID
                    MissionRouteDestination(
                        route: mission, session: session, deps: deps, vmCache: vmCache,
                        onOpenConversation: { target in
                            switch Self.missionOpenConversationOutcome(
                                target: target, current: current, coordinatorConvoID: convoID
                            ) {
                            case .popMission: path.removeLast()
                            case .clearToRoot: path = []
                            case .push(let id): path.append(id)
                            }
                        },
                        onOpenItem: { path.append(ItemRoute(id: $0).pathValue) })
                } else if let route = ItemRoute(pathValue: value) {
                    // The chat underneath is the nearest non-item entry on
                    // this stack, falling back to the coordinator root —
                    // same rule as the Conversations stack (Bugbot, PR #197).
                    let current = path.last(where: { !isAnyPathPrefixedRoute($0) }) ?? convoID
                    ItemDetailHost(itemID: route.id, session: session, currentConvoID: current,
                                   onOpenConversation: { target in
                                       guard target != current else { return }
                                       // The coordinator itself is this
                                       // stack's root: pop to it rather than
                                       // stack a second copy (Bugbot, PR #197).
                                       if target == convoID { path = [] } else { path.append(target) }
                                   },
                                   // An item link inside a body/comment
                                   // pushes onto this same stack (item
                                   // #115). No list fallback here: below
                                   // this sits the coordinator chat, whose
                                   // tracker is a page inside it.
                                   onOpenItem: { path.append(ItemRoute(id: $0).pathValue) })
                } else {
                    ChatDestinationView(id: value, summary: summary(for: value), vmCache: vmCache)
                }
            }
        }
    }
}
