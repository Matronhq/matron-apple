import SwiftUI
import MatronChat
import MatronModels

/// The `String` push destination shared by every chat stack (app shell):
/// a subagent child opens the read-only `SubChatView`, anything else the
/// full `ChatView`. Extracted from `ChatListView.chatDestination(for:)` so
/// the Coordinator tab can host the same destination on its own stack.
///
/// Resolves view models from the shared `ChatVMCache` and keys each branch
/// with `.id(id)`: `openChat` REPLACES the path ([A] → [B]), which keeps
/// this destination's structural position — without the key SwiftUI
/// reuses the old instance's `@State`, so `viewModel`/`composerVM` stay
/// chat A's while the plain-`let` `chatTitle` updates to chat B (f3eb091).
/// `ChatListViewBindingTests` pins the `.id(id)` by scanning this file.
///
/// Hides the tab bar (spec §3: the bar shows only at the root of a tab);
/// the Coordinator tab's root passes `hidesTabBar: false`.
struct ChatDestinationView: View {
    let id: ChatSummary.ID
    let summary: ChatSummary?
    let vmCache: ChatVMCache
    var hidesTabBar: Bool = true

    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session

    var body: some View {
        Group {
            if let deps, let session {
                if let parentConvoID = deps.parentConvoID(of: id, for: session) {
                    let (chatVM, stripVM) = vmCache.subChatViewModels(
                        for: id, parentConvoID: parentConvoID, deps: deps, session: session)
                    SubChatView(viewModel: chatVM, stripViewModel: stripVM,
                                childID: id, fallbackTitle: "Subagent")
                        .id(id)
                } else {
                    let (chatVM, composerVM) = vmCache.viewModels(for: id, deps: deps, session: session)
                    ChatView(
                        viewModel: chatVM,
                        composerVM: composerVM,
                        stripViewModel: vmCache.stripViewModel(forParent: id, deps: deps, session: session),
                        chatTitle: summary?.title ?? "",
                        boxName: summary?.boxName,
                        sessionShort: summary?.sessionShort,
                        boxShort: summary?.boxShort,
                        roomBoxNames: summary?.roomBoxNames ?? [],
                        roomBoxShorts: summary?.roomBoxShorts ?? []
                    )
                    .id(id)
                }
            } else {
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Sign in again to open this chat.")
                )
            }
        }
        .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
    }
}
