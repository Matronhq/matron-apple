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
    var onGoToNumber: (() -> Void)?

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
                     onGoToNumber: onGoToNumber)
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

/// The Decisions list column: the shared `DecisionsListView` on the
/// session's Decisions view model, or its AppKit twin
/// (`MacDecisionsAppKitList`) when `list.appkit.decisions` is on.
struct MacDecisionsColumn: View {
    let vm: ItemsPanelViewModel
    let originLabels: MacOriginLabels
    /// The item open on the right, which the AppKit list shows selected.
    var selectedID: String?
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void

    /// Read once, when the column mounts: a change in Settings applies the
    /// next time the For you list appears.
    @State private var usesAppKitList = MacDecisionsListFlag.isOn()

    /// Ticks every 60s (via `PeriodicNow`) so the Closed tab's
    /// "Answered · 2h ago" captions stay fresh — see the iOS twin
    /// (`DecisionsTabRoot.now`) for why this is a tick rather than a
    /// `TimelineView` inside `DecisionsListView` itself, and for why
    /// `PeriodicNow` rather than a hand-rolled sleep loop.
    @State private var now = Date()

    var body: some View {
        if usesAppKitList {
            MacDecisionsAppKitList(vm: vm, originLabels: originLabels, selectedID: selectedID, onSelect: onSelect,
                                   onOpenConversation: onOpenConversation)
        } else {
            swiftUIList
        }
    }

    private var swiftUIList: some View {
        let titles = originLabels.labels
        return DecisionsListView(
            model: .init(
                rows: vm.awaitingYou.map { .init(item: $0, originTitle: titles.label(for: $0)) },
                closed: vm.forYouTab == .closed
                    ? vm.decided.prefix(vm.decidedVisibleCount)
                        .map { .init(item: $0, originTitle: titles.label(for: $0)) }
                    : [],
                closedTotalCount: vm.decided.count,
                tab: vm.forYouTab,
                hasMoreClosed: vm.hasMoreDecided,
                isSupported: vm.isSupported,
                isRefreshing: vm.isRefreshing),
            onSelect: onSelect,
            onOpenConversation: onOpenConversation,
            onRefresh: { await vm.refresh() },
            onSelectTab: { vm.forYouTab = $0 },
            onShowMoreClosed: { vm.showMoreDecided() },
            now: now,
            onSeen: { id in Task { await vm.markSeen(id) } }
        )
        .alert("Tracker", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
        .task {
            for await date in PeriodicNow().ticks() { now = date }
        }
    }
}
