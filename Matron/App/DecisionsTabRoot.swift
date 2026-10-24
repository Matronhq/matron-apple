import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels

/// The For you list at the root of its tab. Its own view, as
/// `MacDecisionsColumn` is on the Mac, so that the items it draws, their
/// origin labels and the once-a-minute tick re-evaluate this view alone:
/// read in `AppShellView`'s tab content, each item emission and each tick
/// re-ran the whole shell, every tab included.
struct DecisionsTabRoot: View {
    let vm: ItemsPanelViewModel
    let loadOriginLabels: () async -> ItemOriginLabels
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void

    @State private var originTitles = ItemOriginLabels()
    /// Ticks every 60s (via `PeriodicNow`) so the Closed tab's
    /// "Answered · 2h ago" captions stay fresh across a long-open
    /// Decisions tab (review, 2026-09-29) — NOT a `TimelineView` inside
    /// `DecisionsListView` itself: `TimelineView(.periodic(from:by:))`
    /// doesn't freeze at a past `from:`, so that approach silently broke
    /// snapshot-test determinism (see that view's own `now` doc comment).
    /// `PeriodicNow.ticks()` yields immediately, so this is never stale by
    /// up to a whole interval the way a hand-rolled "sleep, then write"
    /// loop was (Bugbot, PR #273) — the very first write lands as soon as
    /// the `.task` below starts, not 60s later.
    @State private var now = Date()

    /// Origins whose labels the rows draw — a typed property, not an
    /// inline expression, for CI's Xcode 16.4 type-checker. A `Set`, not an
    /// array (review, 2026-09-29): `decided` is unbounded (every closed
    /// item ever), but `decidedOriginConvoIDs` is already the
    /// distinct-origins Set the VM maintains, so folding it in here costs
    /// nothing extra — and `Set`'s content-based `Equatable` (unlike an
    /// array's, which also cares about order) is what makes this a safe
    /// `.task(id:)` key: two builds of the same distinct origins never look
    /// like a change just because of iteration order.
    private var originConvoIDs: Set<String> {
        vm.awaitingOriginConvoIDs.union(vm.decidedOriginConvoIDs)
            .union(vm.spareAllowance.map(\.originConvoID))
    }

    var body: some View {
        DecisionsListView(
            model: .forYou(
                awaiting: vm.awaitingYou, decided: vm.decided, decidedVisibleCount: vm.decidedVisibleCount,
                hasMoreDecided: vm.hasMoreDecided, spare: vm.spareAllowance, tab: vm.forYouTab, isSupported: vm.isSupported,
                isRefreshing: vm.isRefreshing, query: vm.forYouQuery,
                origin: { originTitles.label(for: $0) }),
            onSelect: onSelect,
            onOpenConversation: onOpenConversation,
            onRefresh: { await vm.refresh() },
            onSelectTab: { vm.forYouTab = $0 },
            onShowMoreClosed: { vm.showMoreDecided() },
            now: now,
            onSeen: { id in Task { await vm.markSeen(id) } }
        )
        // The same field as the Conversations search, always showing under
        // the large title; it filters whichever tab is on show.
        .searchable(text: Binding(get: { vm.forYouQuery }, set: { vm.forYouQuery = $0 }),
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: DecisionsListView.searchPrompt)
        .task(id: originConvoIDs) {
            let labels = await loadOriginLabels()
            // See the Mac twin in `MacOriginLabelsFeed`: a cancelled task's
            // read still completes and must not overwrite its successor.
            guard !Task.isCancelled else { return }
            originTitles = labels
        }
        // Refresh failures surface through the VM's `error` — the same
        // alert the tracker uses (spec §7).
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
