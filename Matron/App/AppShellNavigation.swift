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
    /// Whether another sheet covers the shell right now (search, ⓘ,
    /// Settings…) — or is still animating away. SwiftUI drops a sheet
    /// presented while another is up or dismissing, so the Coordinator
    /// waits (final review I2). The shell installs a UIKit-backed check;
    /// tests set their own.
    var isShellCovered: @MainActor () -> Bool = { false }
    /// A Coordinator presentation parked until the shell is uncovered.
    private(set) var isCoordinatorPresentationPending = false
    /// Bumped when a parked presentation needs covering sheets gone: views
    /// that own a closable sheet close it on change (`shellUncoverRequest`).
    private(set) var uncoverRequest = 0
    /// Covering sheets deliberately keeping a parked presentation waiting
    /// (New Chat mid-start or with a typed path, Create Item with a draft).
    /// While any holds, the give-up clock stops (Bugbot, PR #234).
    private var coordinatorHolds: Set<UUID> = []
    /// Unheld 100 ms ticks spent waiting for the current parking.
    private var unheldWaitTicks = 0
    /// 30 s of unheld waiting: an unknown or unresponsive blocker.
    static let uncoverGiveUpTicks = 300

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
        // Already open inside the sheet the user is looking at: landing it
        // underneath too would mount a second ChatView on the same cached
        // ChatViewModel (Bugbot, PR #197).
        if !dismissingCoordinator, isCoordinatorPresented, coordinatorPath.contains(roomID) { return }
        if dismissingCoordinator {
            isCoordinatorPresented = false
            isCoordinatorPresentationPending = false
        }
        tab = .conversations
        if chatPath != [roomID] { chatPath = [roomID] }
    }

    /// The designated Coordinator conversation, mirrored from the cached
    /// setting by the shell. A new one starts the sheet at its root, and is
    /// cut (with everything above it) from Conversations: "New coordinator
    /// chat…" auto-opens it underneath before the PUT assigns it, and Choose
    /// can pick the chat under the sheet — two ChatViews would share one
    /// cached ChatViewModel (final review C2). Like the Mac's
    /// `landingAfterCoordinatorChange`, a cut chat moves into the sheet.
    /// The cut always happens — the `TabView` keeps the Conversations stack
    /// mounted behind Decisions or Missions — but the sheet only goes up
    /// when Conversations is the tab actually on screen (CodeRabbit): a
    /// remote assignment must not shove it over an unrelated tab.
    var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            coordinatorPath = []
            guard let id = coordinatorConvoID, let index = chatPath.firstIndex(of: id) else { return }
            let wasOnScreen = tab == .conversations
            chatPath.removeSubrange(index...)
            if wasOnScreen { presentCoordinator() }
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
        if !isCoordinatorPresented, isShellCovered() {
            if !isCoordinatorPresentationPending { unheldWaitTicks = 0 }
            isCoordinatorPresentationPending = true
            uncoverRequest &+= 1
            return
        }
        isCoordinatorPresented = true
    }

    /// The shell is no longer covered: a parked presentation goes up now.
    func shellDidUncover() {
        guard isCoordinatorPresentationPending else { return }
        isCoordinatorPresentationPending = false
        isCoordinatorPresented = true
    }

    /// A parked presentation whose covering sheet never left (one nobody
    /// can close programmatically) is dropped rather than left armed.
    func abandonPendingCoordinatorPresentation() {
        isCoordinatorPresentationPending = false
    }

    /// A covering sheet reports whether it is holding a parked
    /// presentation (keyed by its own token; `false` on disappear).
    func setCoordinatorHold(_ token: UUID, holding: Bool) {
        if holding { coordinatorHolds.insert(token) } else { coordinatorHolds.remove(token) }
    }

    /// One 100 ms tick of the shell's wait for a parked presentation.
    /// Presents once uncovered; gives up after `uncoverGiveUpTicks` ticks
    /// in which no sheet was holding. Returns whether the wait is over.
    func uncoverWaitTick() -> Bool {
        guard isCoordinatorPresentationPending else { return true }
        if !isShellCovered() {
            shellDidUncover()
            return true
        }
        guard coordinatorHolds.isEmpty else { return false }
        unheldWaitTicks += 1
        guard unheldWaitTicks >= Self.uncoverGiveUpTicks else { return false }
        abandonPendingCoordinatorPresentation()
        return true
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
    /// While the sheet is up, a chat also open on its stack is cut from
    /// there (with everything above it), so one chat never mounts twice.
    func setChatPath(_ new: [String]) {
        if let coordinator = coordinatorConvoID, let index = new.firstIndex(of: coordinator) {
            chatPath = Array(new[..<index])
            presentCoordinator()
        } else {
            chatPath = new
            if isCoordinatorPresented { coordinatorPath = Self.cut(coordinatorPath, sharingChatsWith: new) }
        }
    }

    /// The sheet stack binding's setter: a second copy of the Coordinator
    /// pops the sheet to its root. A chat pushed here that is also open in
    /// Conversations underneath (an auto-opened session, then Open or the
    /// sub-chat strip) is cut from that stack, mirroring
    /// `presentCoordinator`'s eviction: two ChatViews would share one
    /// cached ChatViewModel, and dismissing the sheet would stop the
    /// stream the Conversations copy still shows (Bugbot, PR #197).
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
