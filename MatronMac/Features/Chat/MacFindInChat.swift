import Observation
import SwiftUI

/// Where Edit ▸ Find in Chat (⌘F) lands in one window.
/// Pure, so the routing is testable without a window.
enum MacFindInChatRouting {
    enum Target: Equatable {
        /// The chat in the detail column.
        case main
        /// No chat on screen: the sidebar's search-all-chats field, as ⌘F
        /// did before Find in Chat.
        case globalSearch
    }

    /// The chat on screen, else the sidebar field; `nil` when there is
    /// nothing to search.
    static func target(mainHasChat: Bool, globalSearchAvailable: Bool) -> Target? {
        if mainHasChat { return .main }
        return globalSearchAvailable ? .globalSearch : nil
    }
}

/// Whether a chat's transcript column is on screen. `MacChatView` renders
/// it in several structural branches and drops it entirely when a sub-chat
/// or the items pane takes over a narrow detail; a find opened then would
/// leave an invisible bar behind (review I3). Counts appear/disappear
/// pairs: on a branch move the new column can appear before the old one
/// disappears.
/// Observable because the Find in Chat menu item's enabled state reads the
/// column's presence in the window's body.
@MainActor @Observable
final class MacChatColumnPresence {
    private var visibleCount = 0

    var isShown: Bool { visibleCount > 0 }

    func appeared() { visibleCount += 1 }

    func disappeared() { visibleCount = max(0, visibleCount - 1) }
}

extension View {
    /// Counts this chat column in and out of `presence`.
    func reportsChatColumnPresence(_ presence: MacChatColumnPresence?) -> some View {
        onAppear { presence?.appeared() }
            .onDisappear { presence?.disappeared() }
    }
}

extension EnvironmentValues {
    /// The window's presence tracker for the detail's chat. `nil` outside
    /// a window shell (previews, tests).
    @Entry var macChatColumnPresence: MacChatColumnPresence? = nil
}
