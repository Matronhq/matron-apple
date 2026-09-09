import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// The Coordinator tab (app shell, spec §3): its own `NavigationStack`
/// whose root is the coordinator conversation's chat — full screen, the
/// chat's own title, no back button — or `CoordinatorSetupView` when none
/// is set. Pushes from the coordinator (sub-chats via the strip, item
/// detail via `ItemRoute`, origin links) land on `path`, so back returns
/// to the coordinator. The tab bar stays visible at this root (there is
/// no other way out of the tab); pushed chats and items hide it as usual.
struct CoordinatorTabView: View {
    enum Root: Equatable {
        case setup
        case chat(String)
    }

    let session: UserSession
    let deps: AppDependencies
    let chatListVM: ChatListViewModel
    let vmCache: ChatVMCache
    @Binding var path: [String]
    @Binding var convoID: String?

    @State private var showingChooser = false

    static func root(for convoID: String?) -> Root {
        guard let convoID, !convoID.isEmpty else { return .setup }
        return .chat(convoID)
    }

    private func summary(for id: String) -> ChatSummary? {
        chatListVM.groups.flatMap(\.summaries).first { $0.id == id }
    }

    var body: some View {
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
                if let route = ItemRoute(pathValue: value) {
                    // The chat underneath is the nearest non-item entry on
                    // this stack, falling back to the coordinator root —
                    // same rule as the Conversations stack (Bugbot, PR #197).
                    let current = path.last(where: { ItemRoute(pathValue: $0) == nil }) ?? convoID
                    ItemDetailHost(itemID: route.id, session: session, currentConvoID: current,
                                   onOpenConversation: { target in
                                       guard target != current else { return }
                                       // The coordinator itself is this
                                       // stack's root: pop to it rather than
                                       // stack a second copy (Bugbot, PR #197).
                                       if target == convoID { path = [] } else { path.append(target) }
                                   })
                } else {
                    ChatDestinationView(id: value, summary: summary(for: value), vmCache: vmCache)
                }
            }
        }
        .environment(\.chatNavigationPath, $path)
        // A new coordinator (chooser pick, Settings Change/Clear) starts at
        // its root — anything pushed under the old one is gone (Bugbot, PR #197).
        .onChange(of: convoID) { _, _ in path = [] }
        .sheet(isPresented: $showingChooser) {
            CoordinatorChooserSheet(deps: deps, session: session) { id in
                convoID = id
                showingChooser = false
            }
        }
    }
}
