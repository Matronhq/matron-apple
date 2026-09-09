import Foundation
import Observation

/// The bottom tabs (app shell, spec §3), in bar order — `allCases` order
/// is the swipe order too (`AppShellNavigation.swipeRoot`).
enum AppTab: Hashable, CaseIterable {
    case conversations
    case decisions
}

/// Navigation state of the signed-in shell: the selected tab and each
/// tab's stack path. An observable object rather than `@State` on the view
/// so the cross-tab rules (deep links land in Conversations; Decisions
/// hands off to Conversations) are plain, testable functions and so
/// tests can inject a pre-set state into `AppShellView`.
@MainActor @Observable
final class AppShellNavigation {
    var tab: AppTab = .conversations
    /// Conversations tab stack. `[String]` because `ChatSummary.ID == String`
    /// and the sub-chat switcher replaces entries in place.
    var chatPath: [String] = []
    var decisionsPath: [ItemRoute] = []

    init() {}

    /// Open a top-level conversation by REPLACING the whole Conversations
    /// path, never appending: notification taps, search results and
    /// auto-opened new conversations used to stack chat-on-chat. Back from
    /// a conversation always returns to the chat list (Dan, 2026-08-06).
    /// No-op on the path when the target is already the sole open chat.
    func openChat(_ roomID: String) {
        tab = .conversations
        if chatPath != [roomID] { chatPath = [roomID] }
    }

    /// "Open conversation" from a Decisions row or its detail: switch to
    /// Conversations first, then push, in that order and in one
    /// transaction so the push lands in the visible stack (spec §3).
    func openConversation(fromDecisions convoID: String) {
        tab = .conversations
        if chatPath.last != convoID { chatPath.append(convoID) }
    }

    func pushDecision(_ itemID: String) {
        decisionsPath.append(ItemRoute(id: itemID))
    }

    /// Whether the selected tab is showing its root (nothing pushed).
    var isAtRoot: Bool {
        switch tab {
        case .conversations: return chatPath.isEmpty
        case .decisions: return decisionsPath.isEmpty
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
        guard isAtRoot, abs(translation.width) > 80,
              abs(translation.width) > abs(translation.height),
              let index = AppTab.allCases.firstIndex(of: tab) else { return false }
        let next = translation.width < 0 ? index + 1 : index - 1
        guard AppTab.allCases.indices.contains(next) else { return false }
        tab = AppTab.allCases[next]
        return true
    }
}
