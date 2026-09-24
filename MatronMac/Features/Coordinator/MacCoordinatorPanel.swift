import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Coordinator panel's content (Coordinator redesign §3b): a compact
/// header over the Coordinator's `MacChatView`, or the chooser when none is
/// set. The chat's own header props are captured here and drawn in the
/// panel header — and stopped from reaching `MacChatHeaderHost`, which must
/// show the MAIN chat (`coordinatorPanelHeaderScope`). Its pane route
/// (Tasks toggle, sub-chat) is local: the panel is not part of
/// Back/Forward.
struct MacCoordinatorPanel: View {
    let coordinatorConvoID: String?
    let chatListVM: ChatListViewModel
    /// The panel's own cache: the main detail's LRU would evict (and stop)
    /// this on-screen view model after eight other rooms.
    let vmCache: ChatVMCache
    let onChoose: () -> Void
    let onClose: () -> Void
    let onOpenConversation: (String) -> Void
    let onOpenMission: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var paneRoute: MacChatPaneRoute?
    @State private var headerProps: MacChatToolbarProps?

    var body: some View {
        VStack(spacing: 0) {
            MacCoordinatorPanelHeader(props: headerProps, chatVM: headerChatVM, onClose: onClose)
            Divider()
            content
        }
        .frame(maxHeight: .infinity)
        // A new Coordinator starts with its pane closed and a fresh header.
        .onChange(of: coordinatorConvoID) { _, _ in
            paneRoute = nil
            headerProps = nil
        }
    }

    /// The Coordinator chat's view model, for the header's Find and Your
    /// requests buttons — the same cached instance `chat(id:)` renders.
    private var headerChatVM: ChatViewModel? {
        guard let id = coordinatorConvoID, !id.isEmpty, let deps, let session else { return nil }
        return vmCache.viewModels(for: id, deps: deps, session: session).0
    }

    @ViewBuilder
    private var content: some View {
        if let id = coordinatorConvoID, !id.isEmpty, let deps, let session {
            chat(id: id, deps: deps, session: session)
                .coordinatorPanelHeaderScope { headerProps = $0 }
        } else {
            ContentUnavailableView {
                Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
            } description: {
                Text("Pick the conversation that hands out your work as missions.")
            } actions: {
                Button("Choose a conversation…", action: onChoose)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func chat(id: String, deps: AppDependencies, session: UserSession) -> some View {
        let summary = chatListVM.hiddenSummary?.id == id ? chatListVM.hiddenSummary : nil
        let (chatVM, composerVM) = vmCache.viewModels(for: id, deps: deps, session: session)
        MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            stripViewModel: vmCache.stripViewModel(forParent: id, deps: deps, session: session),
            subChatProvider: { childID in
                let parent = deps.parentConvoID(of: childID, for: session) ?? id
                return vmCache.subChatViewModels(for: childID, parentConvoID: parent, deps: deps, session: session)
            },
            paneRoute: $paneRoute,
            chatTitle: summary?.title ?? "",
            boxName: summary?.boxName,
            sessionShort: summary?.sessionShort,
            boxShort: summary?.boxShort,
            roomBoxNames: summary?.roomBoxNames ?? [],
            roomBoxShorts: summary?.roomBoxShorts ?? [],
            onOpenConversation: onOpenConversation,
            onOpenMission: onOpenMission,
            respondsToMenuCommands: false
        )
        .id(id)
    }
}

extension View {
    /// Captures the header props a chat column below publishes and stops
    /// them there: the window has ONE header (`MacChatHeaderHost`), and it
    /// belongs to the main detail. Without this the panel's chat would take
    /// the header whenever the detail shows no chat (Missions, Decisions,
    /// "Select a chat") — `MacChatToolbarPreference` keeps the first value.
    func coordinatorPanelHeaderScope(_ onChange: @escaping @MainActor (MacChatToolbarProps?) -> Void) -> some View {
        self
            .onPreferenceChange(MacChatToolbarPreference.self) { props in
                MainActor.assumeIsolated { onChange(props) }
            }
            .transformPreference(MacChatToolbarPreference.self) { $0 = nil }
    }
}

/// The panel's header row: the Coordinator's title, its media + Tasks
/// capsule (the chat's own Tasks toggle, spec §3b) and a close button.
struct MacCoordinatorPanelHeader: View {
    let props: MacChatToolbarProps?
    /// The Coordinator chat, when one is set: Find in Chat and Your
    /// requests act on it (tracker #2864).
    var chatVM: ChatViewModel? = nil
    let onClose: () -> Void

    @State private var showingRequests = false

    static func title(for props: MacChatToolbarProps?) -> String {
        guard let title = props?.title, !title.isEmpty else { return "Coordinator" }
        return title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
            Text(Self.title(for: props)).font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let chatVM {
                chatTools(chatVM)
            }
            if let props {
                MacChatToolbar(props: props).buttonsItem
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Hide Coordinator (⌘0)")
                .accessibilityLabel("Hide Coordinator")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    /// Find in Chat and Your requests (tracker #2864 A + B).
    @ViewBuilder
    private func chatTools(_ chatVM: ChatViewModel) -> some View {
        if chatVM.supportsChatSearch {
            Button { chatVM.openChatSearch() } label: { Image(systemName: "magnifyingglass") }
                .help("Find in Coordinator chat")
                .accessibilityLabel("Find in chat")
        }
        Button { showingRequests = true } label: { Image(systemName: "clock.arrow.circlepath") }
            .help("Your requests")
            .accessibilityLabel("Your requests")
            .popover(isPresented: $showingRequests, arrowEdge: .bottom) {
                MacCoordinatorRequestsPopover(chatVM: chatVM) { showingRequests = false }
            }
    }
}

/// "Your requests" in the Coordinator panel (tracker #2864 B): the user's
/// own messages in the Coordinator chat, newest first. A pick closes the
/// popover and jumps the panel's transcript to that message.
struct MacCoordinatorRequestsPopover: View {
    let chatVM: ChatViewModel
    let onDone: () -> Void

    @State private var requests: [OwnMessageSummary]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your requests")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            OwnRequestsList(requests: requests) { request in
                onDone()
                Task { await chatVM.jumpToMessage(seq: request.seq) }
            }
        }
        .frame(width: 340, height: 420)
        .task { requests = await chatVM.ownRequests() }
    }
}
