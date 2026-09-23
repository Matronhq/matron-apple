import Foundation
import Observation
import SwiftUI

/// What the chat detail shows beside (or instead of) the timeline (spec
/// §1). Hoisted to the shell per window so it is part of a place and
/// survives the per-conversation `MacChatView` being torn down.
enum MacChatPaneRoute: Equatable {
    /// The tasks-and-decisions pane is open; `path` is its push stack
    /// (empty = the list).
    case items(path: [String])
    /// A subagent child open in the split pane.
    case subChat(id: String)

    var isItems: Bool {
        if case .items = self { return true }
        return false
    }

    var itemsPath: [String]? {
        if case .items(let path) = self { return path }
        return nil
    }

    var subChatID: String? {
        if case .subChat(let id) = self { return id }
        return nil
    }

    /// The route the chat view's three local states describe. The two
    /// panes share one slot — opening either closes the other — so a
    /// sub-chat wins when both are set mid-transaction.
    static func from(itemsOpen: Bool, path: [String], subChatID: String?) -> MacChatPaneRoute? {
        if let subChatID { return .subChat(id: subChatID) }
        return itemsOpen ? .items(path: path) : nil
    }
}

/// The window's pane route, tagged with the conversation that set it
/// (spec §3). A chat reads its route through `route(for:)`, so a chat
/// that doesn't own the route sees the conversation-switch reset (the
/// pane's list, no sub-chat) from its first frame. There is no
/// asynchronous reset for a freshly mounted chat to race: it could
/// otherwise pick up the previous chat's pushed item or sub-chat.
struct MacOwnedPaneRoute: Equatable {
    /// The conversation the route belongs to; `nil` once the window has
    /// left every chat (Missions, Decisions, "Select a chat"), so coming
    /// back resets like a click.
    var owner: String?
    var route: MacChatPaneRoute?

    /// The route chat `id` shows. The owner sees it as set. Any other
    /// chat keeps an open pane on its list and never inherits a
    /// sub-chat (a child belongs to its parent).
    func route(for id: String?) -> MacChatPaneRoute? {
        guard let id else { return nil }
        if id == owner { return route }
        return route?.isItems == true ? .items(path: []) : nil
    }
}

/// Where the user is in a window (spec §1): the shell's selection state,
/// normalised so fields that do not apply to the selected nav entry are
/// absent and cannot mint a spurious history entry.
struct MacPlace: Equatable {
    enum Detail: Equatable {
        /// `nil` id is the "Select a chat" empty state.
        case conversation(id: String?, pane: MacChatPaneRoute?)
        case mission(id: String?)
        case decision(id: String?)
    }

    var detail: Detail

    var nav: MacNav {
        switch detail {
        case .conversation: return .conversations
        case .mission: return .missions
        case .decision: return .decisions
        }
    }

    var pane: MacChatPaneRoute? {
        if case .conversation(_, let pane) = detail { return pane }
        return nil
    }

    /// The conversation the chat detail shows at this place, if any. The
    /// Coordinator panel is not part of a place (spec §3b).
    var displayedConversationID: String? {
        if case .conversation(let id, _) = detail { return id }
        return nil
    }
}

/// The window's Back/Forward history (spec §2). Pure: the shell reports
/// every place it lands on through `visit`, and restores what `goBack` /
/// `goForward` return. Both set `current` to the returned place BEFORE
/// the shell restores it, so the restore's own `visit` is a no-op and no
/// "restoring" flag is needed. Only `canGoBack` / `canGoForward` are read
/// from SwiftUI bodies (the two buttons); everything else is written from
/// `onChange` handlers.
@MainActor
@Observable
final class MacNavigationHistory {
    static let capacity = 50

    private(set) var current: MacPlace?
    private(set) var back: [MacPlace] = []
    private(set) var forward: [MacPlace] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// No-op when `place` is already current. Otherwise the current place
    /// moves onto `back`, `forward` is dropped (a new branch, as in a
    /// browser) and `back` is capped at `capacity`.
    func visit(_ place: MacPlace) {
        guard place != current else { return }
        if let current {
            back.append(current)
            if back.count > Self.capacity { back.removeFirst(back.count - Self.capacity) }
        }
        forward.removeAll()
        current = place
    }

    /// The place to restore, or `nil` with nothing to go back to.
    func goBack() -> MacPlace? {
        guard let previous = back.popLast() else { return nil }
        if let current { forward.append(current) }
        current = previous
        return previous
    }

    /// The place to restore, or `nil` with nothing to go forward to.
    func goForward() -> MacPlace? {
        guard let next = forward.popLast() else { return nil }
        if let current { back.append(current) }
        current = next
        return next
    }
}

/// The window's Back/Forward chevrons (spec §5), always present and greyed
/// out when there's nothing to go to. Mounted in the SIDEBAR column's
/// toolbar with `.automatic` placement, which keeps them in the sidebar
/// section just right of the traffic lights. `.navigation` placement
/// looked right but lands in the DETAIL section, which the chat header
/// accessory leaves zero-width, so AppKit folded the chevrons into its
/// `»` overflow however wide the window was (Dan, #2608; PR #228 for the
/// accessory).
struct MacHistoryToolbarItems: ToolbarContent {
    let history: MacNavigationHistory
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button { goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!history.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")
            Button { goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!history.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
        }
    }
}
