import Foundation
import Observation

/// The bottom tabs (app shell, spec §3), left to right in the bar — and
/// `allCases` order is the swipe order too. The Coordinator is a sheet
/// over any tab since the Coordinator redesign (§3c), not a tab.
/// The app opens on Conversations.
enum AppTab: Hashable, CaseIterable {
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
    /// The Coordinator sheet's own stack (spec §3c): sub-chats, items and
    /// missions opened inside the sheet push here, so back returns to the
    /// Coordinator.
    var coordinatorPath: [String] = []
    /// Missions tab stack: `MissionRoute.pathValue` entries, plus
    /// `ItemRoute.pathValue` for an item opened from a mission page.
    var missionsPath: [String] = []
    /// Whether the Coordinator sheet is up. Every entry — the floating
    /// button on a tab root, the ⓘ-sheet row and tasks-page button in a
    /// chat, a notification tap or link into the Coordinator's
    /// conversation — goes through `presentCoordinator()`.
    var isCoordinatorPresented = false

    init() {}

    /// Open a top-level conversation by REPLACING the Conversations path
    /// (Dan, 2026-08-06). The Coordinator's conversation presents the
    /// sheet instead. `dismissingCoordinator: false` is for the auto-open of
    /// a freshly started session: it lands underneath and the sheet stays.
    func openChat(_ roomID: String, dismissingCoordinator: Bool = true) {
        if roomID == coordinatorConvoID {
            presentCoordinator()
            return
        }
        if dismissingCoordinator { isCoordinatorPresented = false }
        tab = .conversations
        if chatPath != [roomID] { chatPath = [roomID] }
    }

    /// The designated Coordinator conversation, mirrored from the cached
    /// setting by the shell. A new one starts the sheet at its root.
    var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            coordinatorPath = []
        }
    }

    /// Presents the Coordinator sheet at its root. The same conversation
    /// open in Conversations (from before it became the Coordinator) is
    /// cut from that stack first: two ChatViews would share one cached
    /// ChatViewModel, and the first to leave stops the other's stream
    /// (Bugbot, PR #197).
    func presentCoordinator() {
        if let coordinator = coordinatorConvoID, let index = chatPath.firstIndex(of: coordinator) {
            chatPath.removeSubrange(index...)
        }
        coordinatorPath = []
        isCoordinatorPresented = true
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
            presentCoordinator()
            return
        }
        tab = .conversations
        if chatPath.last != convoID { chatPath.append(convoID) }
    }

    /// The Conversations stack binding's setter: a push of the Coordinator
    /// (origin link, spawned-room Open) keeps only what is beneath it and
    /// presents the sheet, so it never mounts on this stack for a frame.
    func setChatPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, let index = new.firstIndex(of: coordinator) {
            chatPath = Array(new[..<index])
            presentCoordinator()
        } else {
            chatPath = new
        }
    }

    /// The sheet stack binding's setter: a second copy of the Coordinator
    /// pops the sheet to its root.
    func setCoordinatorPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, new.contains(coordinator) {
            coordinatorPath = []
        } else {
            coordinatorPath = new
        }
    }

    func pushDecision(_ itemID: String) {
        decisionsPath.append(ItemRoute(id: itemID))
    }

    /// Push onto a specific tab's stack without changing the selection.
    /// Decisions takes an `ItemRoute.pathValue` and decodes it.
    func push(_ value: String, on tab: AppTab) {
        switch tab {
        case .conversations: chatPath.append(value)
        case .decisions: if let route = ItemRoute(pathValue: value) { decisionsPath.append(route) }
        case .missions: missionsPath.append(value)
        }
    }

    /// Whether the selected tab is showing its root (nothing pushed).
    var isAtRoot: Bool {
        switch tab {
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
