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
    /// An agent-chat room this conversation takes part in, open in the
    /// same split pane (the header's "Rooms · n").
    case room(id: String)

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

    var roomID: String? {
        if case .room(let id) = self { return id }
        return nil
    }

    /// The route the chat view's local states describe. The panes share
    /// one slot — opening one closes the others — so mid-transaction a
    /// sub-chat wins, then a room, then the items pane.
    static func from(itemsOpen: Bool, path: [String], subChatID: String?, roomID: String? = nil) -> MacChatPaneRoute? {
        if let subChatID { return .subChat(id: subChatID) }
        if let roomID { return .room(id: roomID) }
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
    /// sub-chat (a child belongs to its parent) or a room (the other
    /// chat may not be in it).
    func route(for id: String?) -> MacChatPaneRoute? {
        guard let id else { return nil }
        if id == owner { return route }
        return route?.isItems == true ? .items(path: []) : nil
    }
}

/// What the Memories entry's detail shows: one memory's editor (by name —
/// names are the key) or the new-memory form. `nil` where it's used is
/// "Select a memory".
enum MacMemorySelection: Equatable {
    case memory(String)
    case new

    var name: String? {
        if case .memory(let name) = self { return name }
        return nil
    }
}

/// Where the user is in a window (spec §1): the shell's selection state,
/// normalised so fields that do not apply to the selected nav entry are
/// absent and cannot mint a spurious history entry.
struct MacPlace: Equatable {
    enum Detail: Equatable {
        /// The Coordinator page. `id` is the Coordinator it showed (`nil`:
        /// the chooser), so a restore after the Coordinator changed never
        /// hands the old one's pane route to the new one (CodeRabbit, #239).
        case coordinator(id: String?, pane: MacChatPaneRoute?)
        /// `nil` id is the "Select a chat" empty state.
        case conversation(id: String?, pane: MacChatPaneRoute?)
        case mission(id: String?)
        /// A project page (spec 2026-09-30 §2), under the Projects entry.
        case project(id: String)
        case decision(id: String?)
        case memory(MacMemorySelection?)
    }

    var detail: Detail

    var nav: MacNav {
        switch detail {
        case .coordinator: return .coordinator
        case .conversation: return .conversations
        case .mission, .project: return .missions
        case .decision: return .decisions
        case .memory: return .memories
        }
    }

    var pane: MacChatPaneRoute? {
        switch detail {
        case .coordinator(_, let pane): return pane
        case .conversation(_, let pane): return pane
        case .mission, .project, .decision, .memory: return nil
        }
    }

    /// The conversation the chat detail shows at this place, if any: the
    /// Coordinator's own on its page.
    var displayedConversationID: String? {
        switch detail {
        case .coordinator(let id, _): return id
        case .conversation(let id, _): return id
        case .mission, .project, .decision, .memory: return nil
        }
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

    /// Replaces `current` in place: no new entry, `back`/`forward`
    /// untouched. For a page's own redirect (spec 2026-09-30 §4.2 project
    /// merge): the shell already landed on the place being replaced, so the
    /// new one takes its spot in history rather than being `visit`ed as a
    /// fresh move — otherwise Back would restore the place this redirected
    /// from, which redirects right back, trapping Back on it forever.
    func replaceCurrent(_ place: MacPlace) {
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
/// accessory). On the Coordinator and Missions entries the sidebar is the
/// 72 pt nav column alone, with no toolbar room at all, so there the shell
/// leaves these out and the chat header draws
/// `MacCoordinatorPageHeaderCluster` instead.
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

/// The Coordinator page's sidebar toolbar: one invisible 1 pt item. With NO
/// items SwiftUI drops the window's NSToolbar and the title bar shrinks from
/// 52 to 32 pt, cropping the 52 pt chat header top and bottom (#2608). A 1 pt
/// item keeps the toolbar and is too small to be clipped into the » overflow
/// (both measured in `MacHistoryToolbarTests`).
struct MacCoordinatorToolbarPlaceholder: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        }
    }
}
