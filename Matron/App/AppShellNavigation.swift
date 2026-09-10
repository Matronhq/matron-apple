import Foundation
import Observation

/// The bottom tabs (app shell, spec §3), left to right in the bar — and
/// `allCases` order is the swipe order too (`AppShellNavigation.swipeRoot`).
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
    /// Coordinator tab stack: sub-chats and items opened from the
    /// coordinator push here, so back returns to it.
    var coordinatorPath: [String] = []
    /// Missions tab stack: `MissionRoute.pathValue` entries, plus
    /// `ItemRoute.pathValue` for an item opened from a mission page.
    var missionsPath: [String] = []

    init() {}

    /// Open a top-level conversation by REPLACING the whole Conversations
    /// path, never appending: notification taps, search results and
    /// auto-opened new conversations used to stack chat-on-chat. Back from
    /// a conversation always returns to the chat list (Dan, 2026-08-06).
    /// No-op on the path when the target is already the sole open chat.
    func openChat(_ roomID: String) {
        if roomID == coordinatorConvoID {
            // The coordinator has its own tab (spec §5b); never mount it
            // in Conversations as well — the two ChatViews would share one
            // cached ChatViewModel and the first to leave would stop the
            // other's stream (Bugbot, PR #197).
            tab = .coordinator
            coordinatorPath = []
            return
        }
        tab = .conversations
        if chatPath != [roomID] { chatPath = [roomID] }
    }

    /// The designated coordinator conversation, mirrored from
    /// `CoordinatorSetting` by the shell so the rules below can route to
    /// its tab. `nil` when none is set.
    var coordinatorConvoID: String? {
        didSet { if coordinatorConvoID != oldValue { redirectCoordinatorPush() } }
    }

    /// Chat-list rows (`NavigationLink`) and origin links from an open
    /// chat push straight onto `chatPath`, so the coordinator can land on
    /// that stack: cut the stack back to just below its first entry and
    /// hand off to the Coordinator tab instead of mounting it twice
    /// (Bugbot, PR #197 — the entries beneath stay, so back in
    /// Conversations is unchanged). Anywhere on the stack, not only on
    /// top: assigning the coordinator to a chat that is ALREADY open (with,
    /// say, an item detail above it) must evict it too, which is why
    /// `coordinatorConvoID`'s `didSet` runs this as well as every
    /// `chatPath` change. An origin link on the Coordinator stack can
    /// likewise push the coordinator id onto `coordinatorPath`, stacking a
    /// second copy over the root — that stack is popped to its root. Both
    /// copies would share one cached `ChatViewModel`, and the first to
    /// disappear stops the other's stream. Returns whether anything moved.
    @discardableResult
    func redirectCoordinatorPush() -> Bool {
        guard let coordinator = coordinatorConvoID else { return false }
        var moved = false
        if coordinatorPath.contains(coordinator) {
            coordinatorPath = []
            moved = true
        }
        if let index = chatPath.firstIndex(of: coordinator) {
            chatPath.removeSubrange(index...)
            tab = .coordinator
            coordinatorPath = []
            moved = true
        }
        return moved
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
    func pushMission(_ missionID: String) {
        missionsPath.append(MissionRoute(id: missionID).pathValue)
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
    /// cannot drift on the coordinator special case.
    private func handOffToConversations(_ convoID: String) {
        if convoID == coordinatorConvoID {
            tab = .coordinator
            coordinatorPath = []
            return
        }
        tab = .conversations
        if chatPath.last != convoID { chatPath.append(convoID) }
    }

    /// The setters behind the two `NavigationStack(path:)` bindings
    /// (Bugbot, PR #197): a chat-list `NavigationLink` or an origin link
    /// writes the whole new path here BEFORE anything mounts, so the
    /// coordinator id is redirected on the way in and a second
    /// `ChatDestinationView` for it never appears — not even for one
    /// frame, whose `onDisappear` would stop the stream the Coordinator
    /// root is showing. Reads still go through `chatPath`/`coordinatorPath`.
    func setChatPath(_ new: [String]) {
        chatPath = new
        redirectCoordinatorPush()
    }

    func setCoordinatorPath(_ new: [String]) {
        coordinatorPath = new
        redirectCoordinatorPush()
    }

    func pushDecision(_ itemID: String) {
        decisionsPath.append(ItemRoute(id: itemID))
    }

    /// Push onto a specific tab's stack without changing the selection.
    /// Decisions takes an `ItemRoute.pathValue` and decodes it.
    func push(_ value: String, on tab: AppTab) {
        switch tab {
        case .conversations: chatPath.append(value)
        case .coordinator: coordinatorPath.append(value)
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
