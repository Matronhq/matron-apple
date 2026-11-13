import MatronModels
import MatronViewModels

/// Bounded per-room cache of (ChatViewModel, ComposerViewModel) pairs —
/// see the `vmCache` doc comments on `ChatListView` (iOS) and
/// `MacChatListView`. LRU so a session that visits many rooms doesn't pin
/// every timeline's items forever; the limit mirrors
/// `AppDependencies.timelineCacheLimit`'s intent but stays smaller because
/// each VM holds a mapped item array.
@MainActor
final class ChatVMCache {
    private var entries: [String: (chat: ChatViewModel, composer: ComposerViewModel)] = [:]
    private var order: [String] = []
    private let limit = 8
    /// Running-subagent strip view models, keyed by PARENT convo id. Shared
    /// between a parent chat's strip and its children's switchers, so all
    /// surfaces observing the same parent's children stay in lockstep off
    /// one subscription. Not LRU-bounded — one lightweight VM per parent
    /// visited, which tracks the (small) `entries` working set.
    private var stripEntries: [String: SubChatStripViewModel] = [:]

    func viewModels(
        for roomID: String, deps: AppDependencies, session: UserSession
    ) -> (ChatViewModel, ComposerViewModel) {
        if let cached = entries[roomID] {
            order.removeAll { $0 == roomID }
            order.append(roomID)
            return cached
        }
        let timelineSvc = deps.timelineService(for: session, roomID: roomID)
        let mediaSvc = deps.mediaService(for: session)
        // The composer reads the chat half's session status for the palette's
        // session-derived suggestions (`/model`, `/effort`). Weakly: this
        // cache owns both, and the closure must not keep the chat VM alive
        // past an eviction.
        let chat = ChatViewModel(roomID: roomID, timeline: timelineSvc, media: mediaSvc,
                                 agentChat: deps.agentChatService(for: session),
                                 agentSpawn: deps.agentSpawnService(for: session),
                                 sessionStopper: deps.sessionStopper(for: session),
                                 grantAnswering: deps.grantAnsweringService(for: session),
                                 search: deps.searchService(for: session))
        chat.seen = deps.seenTracker(for: session)
        let pair = (
            chat: chat,
            composer: ComposerViewModel(roomID: roomID, timeline: timelineSvc,
                                        commands: BotCommandCatalog.claudeBridge,
                                        sessionStatus: { [weak chat] in chat?.sessionStatus })
        )
        entries[roomID] = pair
        order.append(roomID)
        if order.count > limit, let evicted = order.first {
            order.removeFirst()
            entries[evicted]?.chat.stop()
            entries.removeValue(forKey: evicted)
        }
        return pair
    }

    /// The running-subagent strip VM for a parent conversation. Shared, so
    /// the parent chat's strip and every child's switcher read one stream.
    func stripViewModel(
        forParent parentConvoID: String, deps: AppDependencies, session: UserSession
    ) -> SubChatStripViewModel {
        if let cached = stripEntries[parentConvoID] { return cached }
        let vm = SubChatStripViewModel(chat: deps.chatService(for: session), parentConvoID: parentConvoID)
        stripEntries[parentConvoID] = vm
        return vm
    }

    /// The (read-only timeline VM, switcher strip VM) pair for a subagent
    /// child. The timeline VM is keyed by the child id (reusing the pair
    /// cache; its composer is unused — the viewer has no composer), and the
    /// switcher strip is the SHARED VM for the child's parent so it lists
    /// siblings.
    func subChatViewModels(
        for childID: String, parentConvoID: String, deps: AppDependencies, session: UserSession
    ) -> (ChatViewModel, SubChatStripViewModel) {
        let chat = viewModels(for: childID, deps: deps, session: session).0
        let strip = stripViewModel(forParent: parentConvoID, deps: deps, session: session)
        return (chat, strip)
    }
}
