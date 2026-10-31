import SwiftUI
import AppKit
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

// The window's readers of live data. Each is its own view so that a change
// re-evaluates that view alone: read in `MacChatListView.body`, the same
// value made SwiftUI re-evaluate and lay out the whole window — the
// sidebar, the detail, the chat and its composer — on every chat-list
// snapshot, items emission and missions change, many times a minute on a
// busy account, and that is what made scrolling judder.

/// The nav column with its badges, read from the view models here.
struct MacNavColumnHost: View {
    let chats: ChatListViewModel
    let decisions: ItemsPanelViewModel?
    let missions: MissionsDashboardViewModel?
    @Binding var selection: MacNav
    var missionsSupported: Bool
    var pins: [ConvoPin]
    var successorHints: [String: String]
    var onPinAction: ((MacPinAction) -> Void)?
    var onSearch: (() -> Void)?
    var searchShown: Bool

    var body: some View {
        MacNavColumn(selection: $selection,
                     badges: MacChatListView.navBadges(decisions: decisions?.awaitingYouCount ?? 0,
                                                       missions: missions?.needsYouTotal ?? 0,
                                                       coordinator: chats.hiddenCounts,
                                                       desks: chats.pinnedCounts),
                     missionsSupported: missionsSupported,
                     needsYou: MacChatListView.navNeedsYou(coordinator: chats.hiddenCounts, desks: chats.pinnedCounts),
                     pins: pins,
                     successorHints: successorHints,
                     onPinAction: onPinAction,
                     onSearch: onSearch,
                     searchShown: searchShown)
    }
}

/// Mirrors the chat list's running unread total onto the Dock tile.
/// `nil` removes the badge, so a zero count draws no overlay. No
/// `initial: true`: firing on first appear with a still-zero total would
/// clear a badge a push notification set while the app was in the
/// background (see the iOS `ChatListView`).
struct MacDockBadgeFeed: View {
    let viewModel: ChatListViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: viewModel.totalUnread) { _, newValue in
                NSApp.dockTile.badgeLabel = newValue > 0 ? "\(newValue)" : nil
            }
    }
}

/// The origin labels the Decisions rows draw. Owned by the window for the
/// session, so the column opens with them already loaded, and observed
/// only by the column that draws them — never by the window's own body.
@Observable
final class MacOriginLabels {
    var labels = ItemOriginLabels()
}

/// Keeps `MacOriginLabels` current for the Decisions view model's origins,
/// whichever page is on screen.
struct MacOriginLabelsFeed: View {
    let vm: ItemsPanelViewModel
    let labels: MacOriginLabels
    let load: () async -> ItemOriginLabels

    /// Origins whose labels the rows draw. A `Set`, not an array: see the
    /// iOS twin (`DecisionsTabRoot.originConvoIDs`) for why.
    private var originConvoIDs: Set<String> {
        vm.awaitingOriginConvoIDs.union(vm.decidedOriginConvoIDs)
            .union(vm.spareAllowance.map(\.originConvoID))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: originConvoIDs) {
                let loaded = await load()
                // A cancelled task's read still completes (GRDB's async read
                // does not honour cancellation); it must not overwrite what
                // its successor wrote.
                guard !Task.isCancelled else { return }
                if labels.labels != loaded { labels.labels = loaded }
            }
    }
}

/// The Decisions list column: the AppKit For you list
/// (`MacDecisionsAppKitList`) on the session's Decisions view model.
struct MacDecisionsColumn: View {
    let vm: ItemsPanelViewModel
    let originLabels: MacOriginLabels
    /// The item open on the right, which the list shows selected.
    var selectedID: String?
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void

    var body: some View {
        MacDecisionsAppKitList(vm: vm, originLabels: originLabels, selectedID: selectedID, onSelect: onSelect,
                               onOpenConversation: onOpenConversation)
    }
}
