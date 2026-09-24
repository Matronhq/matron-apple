import Foundation
import Observation

/// The bottom tabs (app shell, spec §3), left to right in the bar — and
/// `allCases` order is the swipe order too. The Coordinator is the first
/// tab (decision #2913: a swipe or two away, never a sheet over the top).
/// The app opens on Conversations.
enum AppTab: Hashable, CaseIterable {
    case coordinator
    case missions
    case decisions
    case conversations
}

/// Navigation state of the signed-in shell: the selected tab and each
/// tab's stack path. An observable object rather than `@State` on the view
/// so the cross-tab rules (deep links land in Conversations; Decisions
/// hands off to Conversations) are plain, testable functions and so
/// tests can inject a pre-set state into `AppShellView`.
@MainActor @Observable
final class AppShellNavigation {
    var tab: AppTab = .conversations
    /// `false` once `GET /missions` 404s (set by `AppShellView` from
    /// `MissionsListViewModel.isSupported`) — the Missions tab is then
    /// absent from the `TabView`, so nothing may select its tag: the root
    /// swipe consults this (`swipeRoot` walks `Self.tabs(missionsSupported:)`,
    /// not the unconditional `AppTab.allCases`) and `openMission` no-ops.
    /// The clamp lives here, in the setter, rather than in a view
    /// `onChange`, so it is testable without one: a swipe that already
    /// landed on `.missions` in the window before a 404 answers is walked
    /// back to Conversations the instant the flag flips false.
    var missionsSupported = true {
        didSet {
            guard missionsSupported != oldValue, !missionsSupported, tab == .missions else { return }
            tab = .conversations
        }
    }

    /// The tabs actually in the bar for a given support state — the same
    /// set `AppShellView`'s `TabView` renders. `swipeRoot` walks this
    /// instead of the unconditional `AppTab.allCases`, so it can never
    /// select a tag with no matching tab.
    static func tabs(missionsSupported: Bool) -> [AppTab] {
        missionsSupported ? AppTab.allCases : AppTab.allCases.filter { $0 != .missions }
    }
    /// Conversations tab stack. `[String]` because `ChatSummary.ID == String`
    /// and the sub-chat switcher replaces entries in place.
    var chatPath: [String] = []
    var decisionsPath: [ItemRoute] = []
    /// The Coordinator tab's stack: sub-chats, items and missions opened
    /// from the Coordinator push here, so back returns to it.
    var coordinatorPath: [String] = []
    /// Missions tab stack: `MissionRoute.pathValue` entries, plus
    /// `ItemRoute.pathValue` for an item opened from a mission page.
    var missionsPath: [String] = []

    init() {}

    /// Open a top-level conversation by REPLACING the Conversations path
    /// (Dan, 2026-08-06): notification taps, search results and new chats
    /// never stack chat-on-chat. The Coordinator's conversation selects its
    /// own tab instead. A copy of the chat on the Coordinator tab's stack is
    /// cut (see `cut(_:sharingChatsWith:)`).
    func openChat(_ roomID: String) {
        if roomID == coordinatorConvoID {
            selectCoordinator()
            return
        }
        show(inConversations: [roomID])
    }

    /// The auto-open of a conversation the bridge just created (a session
    /// the Coordinator started, `/start` elsewhere). On the Coordinator tab
    /// it lands in Conversations without pulling the user off the
    /// Coordinator — and is left alone when it is already open on the
    /// Coordinator's stack, where the user is looking at it. Anywhere else
    /// it opens like any deep link.
    func autoOpenChat(_ roomID: String) {
        guard tab == .coordinator, roomID != coordinatorConvoID else {
            openChat(roomID)
            return
        }
        guard !coordinatorPath.contains(roomID) else { return }
        if chatPath != [roomID] { chatPath = [roomID] }
    }

    /// Selects Conversations showing `newPath`, cutting any chat it holds
    /// from the Coordinator tab's stack in the same write.
    private func show(inConversations newPath: [String]) {
        coordinatorPath = Self.cut(coordinatorPath, sharingChatsWith: newPath)
        tab = .conversations
        if chatPath != newPath { chatPath = newPath }
    }

    /// The designated Coordinator conversation, mirrored from the cached
    /// setting by the shell. A new one starts the Coordinator tab at its
    /// root, and is cut (with everything above it) from Conversations:
    /// "New coordinator chat…" auto-opens it there before the PUT assigns
    /// it, and Choose can pick a chat open there — two ChatViews would share
    /// one cached ChatViewModel (final review C2). The cut always happens —
    /// the `TabView` keeps the Conversations stack mounted behind other
    /// tabs — but the tab only switches when Conversations is the tab on
    /// screen (CodeRabbit): a remote assignment must not yank the user off
    /// an unrelated tab.
    var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            coordinatorPath = []
            guard let id = coordinatorConvoID, let index = chatPath.firstIndex(of: id) else { return }
            chatPath.removeSubrange(index...)
            if tab == .conversations { tab = .coordinator }
        }
    }

    /// Selects the Coordinator tab at its root. The same conversation open
    /// in Conversations (written there directly) is cut from that stack
    /// first: two ChatViews would share one cached ChatViewModel, and the
    /// first to leave stops the other's stream (Bugbot, PR #197).
    func selectCoordinator() {
        if let coordinator = coordinatorConvoID, let index = chatPath.firstIndex(of: coordinator) {
            chatPath.removeSubrange(index...)
        }
        coordinatorPath = []
        tab = .coordinator
    }

    /// "Open conversation" from a Decisions row or its detail: switch to
    /// Conversations first, then push, in that order and in one
    /// transaction so the push lands in the visible stack (spec §3).
    func openConversation(fromDecisions convoID: String) {
        handOffToConversations(convoID)
    }

    /// Open a mission from anywhere: select the tab and REPLACE the stack,
    /// so the page is never stacked on a stale copy of itself. No-op on an
    /// old journal that has no Missions tab to select.
    func openMission(_ missionID: String) {
        guard missionsSupported else { return }
        tab = .missions
        let route = MissionRoute(id: missionID).pathValue
        if missionsPath != [route] { missionsPath = [route] }
    }

    /// Push a mission onto the Missions stack without changing the tab —
    /// e.g. a `#N` that resolves to another mission from a mission page.
    /// No-op when that mission is already the top entry, mirroring
    /// `ChatView.pushMission(_:onto:)` — a double tap must not stack two
    /// identical pages.
    func pushMission(_ missionID: String) {
        let route = MissionRoute(id: missionID).pathValue
        guard missionsPath.last != route else { return }
        missionsPath.append(route)
    }

    func pushMissionItem(_ itemID: String) {
        missionsPath.append(ItemRoute(id: itemID).pathValue)
    }

    /// "Open the conversation" from a Missions row or a milestone: switch to
    /// Conversations first, then push, in that order and in one transaction
    /// so the push lands in the visible stack.
    func openConversation(fromMissions convoID: String) { handOffToConversations(convoID) }

    /// Shared body of `openConversation(fromDecisions:)` and
    /// `openConversation(fromMissions:)` — one rule, so the two entry points
    /// cannot drift on the Coordinator special case.
    private func handOffToConversations(_ convoID: String) {
        if convoID == coordinatorConvoID {
            selectCoordinator()
            return
        }
        show(inConversations: chatPath.last == convoID ? chatPath : chatPath + [convoID])
    }

    /// The Conversations stack binding's setter (Bugbot, PR #197): a chat-list
    /// link or origin link writes the whole new path here BEFORE anything
    /// mounts. A push of the Coordinator (origin link, spawned-room Open)
    /// keeps only what is beneath it and selects the Coordinator tab, so it
    /// never mounts on this stack for a frame. A chat also open on the
    /// Coordinator tab's stack is cut from there (with everything above it).
    func setChatPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, let index = new.firstIndex(of: coordinator) {
            chatPath = Array(new[..<index])
            selectCoordinator()
        } else {
            chatPath = new
            coordinatorPath = Self.cut(coordinatorPath, sharingChatsWith: new)
        }
    }

    /// The Coordinator tab's stack binding setter: a second copy of the
    /// Coordinator pops the stack to its root. A chat pushed here that is
    /// also open in Conversations (an auto-opened session, then Open or the
    /// sub-chat strip) is cut from that stack: the `TabView` keeps both
    /// mounted, two ChatViews would share one cached ChatViewModel, and the
    /// copy that disappears on a tab switch stops the stream the other one
    /// shows (Bugbot, PR #197).
    func setCoordinatorPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, new.contains(coordinator) {
            coordinatorPath = []
        } else {
            coordinatorPath = new
            chatPath = Self.cut(chatPath, sharingChatsWith: new)
        }
    }

    /// `stack` cut at its first chat id that `other` also holds, with
    /// everything above it. Item and mission routes are pages, not chats,
    /// and never count.
    private static func cut(_ stack: [String], sharingChatsWith other: [String]) -> [String] {
        let chats = Set(other.filter { !isAnyPathPrefixedRoute($0) })
        guard let index = stack.firstIndex(where: { chats.contains($0) }) else { return stack }
        return Array(stack[..<index])
    }

    func pushDecision(_ itemID: String) {
        decisionsPath.append(ItemRoute(id: itemID))
    }

    /// Push onto a specific tab's stack without changing the selection.
    /// Decisions takes an `ItemRoute.pathValue` and decodes it.
    func push(_ value: String, on tab: AppTab) {
        switch tab {
        case .coordinator: coordinatorPath.append(value)
        case .conversations: chatPath.append(value)
        case .decisions: if let route = ItemRoute(pathValue: value) { decisionsPath.append(route) }
        case .missions: missionsPath.append(value)
        }
    }

    /// Whether the selected tab is showing its root (nothing pushed).
    var isAtRoot: Bool {
        switch tab {
        case .coordinator: return coordinatorPath.isEmpty
        case .conversations: return chatPath.isEmpty
        case .decisions: return decisionsPath.isEmpty
        case .missions: return missionsPath.isEmpty
        }
    }

    /// Dan, 2026-09-09: swipe between the conversation list and the
    /// decisions list. A mostly horizontal drag past 80pt at a tab's ROOT
    /// moves one tab in bar order (left = next, right = previous). Deeper
    /// in a stack the chat's own pager and swipe-back own horizontal
    /// drags, so a non-empty path ignores it. Returns whether the tab
    /// changed, so the caller can animate only real switches.
    @discardableResult
    func swipeRoot(translation: CGSize) -> Bool {
        let tabs = Self.tabs(missionsSupported: missionsSupported)
        guard isAtRoot, abs(translation.width) > 80,
              abs(translation.width) > abs(translation.height),
              let index = tabs.firstIndex(of: tab) else { return false }
        let next = translation.width < 0 ? index + 1 : index - 1
        guard tabs.indices.contains(next) else { return false }
        tab = tabs[next]
        return true
    }
}
