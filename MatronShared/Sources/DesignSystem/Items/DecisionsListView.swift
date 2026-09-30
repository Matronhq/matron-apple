import SwiftUI
import MatronModels

/// Every open item awaiting the user, across every conversation, newest
/// first, with its origin conversation (app shell, spec §2). A pure leaf
/// view: the host maps `ItemsPanelViewModel.awaitingYou` into `Model` so
/// this is snapshot-testable without a view model. Rows reuse `ItemRow`
/// with the origin subtitle always on — the same rendering `ItemsListView`
/// uses in its "All" scope.
public struct DecisionsListView: View {
    public struct Row: Equatable, Identifiable {
        public let item: TrackerItem
        public let originTitle: String?
        public var id: String { item.id }
        public init(item: TrackerItem, originTitle: String?) {
            self.item = item; self.originTitle = originTitle
        }
    }

    public struct Model: Equatable {
        public var rows: [Row]
        /// The Decided section's VISIBLE window, newest-closed first —
        /// already sliced by the host from `ItemsPanelViewModel.decided`/
        /// `decidedVisibleCount` (Dan, 2026-09-29: answered/decided items
        /// stay findable below the open list instead of vanishing).
        public var decided: [Row]
        /// Every locally-known decided item, independent of how many
        /// `decided` currently shows — the section header's count.
        public var decidedTotalCount: Int
        public var isDecidedExpanded: Bool
        /// Whether "Show more" should render under the visible window —
        /// purely local (`ItemsPanelViewModel.hasMoreDecided`); there is no
        /// server page to reach for.
        public var hasMoreDecided: Bool
        /// `false` shows the unsupported-journal message; `nil` (not yet
        /// known) and `true` both show the list.
        public var isSupported: Bool?
        public var isRefreshing: Bool
        public init(rows: [Row], decided: [Row] = [], decidedTotalCount: Int = 0, isDecidedExpanded: Bool = false,
                    hasMoreDecided: Bool = false, isSupported: Bool?, isRefreshing: Bool) {
            self.rows = rows; self.decided = decided; self.decidedTotalCount = decidedTotalCount
            self.isDecidedExpanded = isDecidedExpanded; self.hasMoreDecided = hasMoreDecided
            self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
    }

    let model: Model
    /// Reused for both the open list and the Decided section — a decided
    /// item's thread opens exactly the same way an open one's does.
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void
    /// Pull to refresh (iOS) and the header button (Mac) both call this —
    /// the host wires it to `ItemsPanelViewModel.refresh()`.
    let onRefresh: () async -> Void
    /// The Decided section's disclosure header — toggles and persists
    /// `ItemsPanelViewModel.isDecidedExpanded`. Defaulted (in `init` below)
    /// so existing call sites and every current snapshot test keep
    /// compiling unchanged.
    let onToggleDecided: () -> Void
    /// "Show more" under the Decided section — purely a local window grow
    /// (`ItemsPanelViewModel.showMoreDecided()`), so this is synchronous.
    let onShowMoreDecided: () -> Void
    /// Clock for the Decided rows' "Answered · 2h ago" captions — defaults
    /// to `Date()` for the live app, overridable so snapshot tests render a
    /// fixed relative time. Deliberately a plain stored value, not a
    /// `TimelineView`-driven tick: `TimelineView(.periodic(from:by:))`
    /// does NOT freeze at a past `from:` — it walks forward to the nearest
    /// tick of REAL current time, which silently broke snapshot
    /// determinism when tried here (a fixed test date rendered against
    /// actual wall-clock time instead). The host shells instead refresh
    /// their OWN `now` on a timer and hand this view a fresh value on
    /// each tick — see `AppShellView`/`MacChatListView`'s `decisionsNow`.
    let now: Date

    public init(model: Model, onSelect: @escaping (String) -> Void, onOpenConversation: @escaping (String) -> Void,
                onRefresh: @escaping () async -> Void, onToggleDecided: @escaping () -> Void = {},
                onShowMoreDecided: @escaping () -> Void = {}, now: Date = Date()) {
        self.model = model; self.onSelect = onSelect; self.onOpenConversation = onOpenConversation; self.onRefresh = onRefresh
        self.onToggleDecided = onToggleDecided; self.onShowMoreDecided = onShowMoreDecided; self.now = now
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The Mac list column has no pull-to-refresh, so the header
            // carries the refresh button; iOS uses `.refreshable` below.
            HStack {
                Text("Decisions").font(.headline)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                }
                Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .padding(.horizontal).padding(.vertical, 8)
            #endif
            if model.isSupported == false {
                placeholder(ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                                   description: Text("Update the journal server to use items.")))
            } else if model.rows.isEmpty && model.decidedTotalCount == 0 {
                placeholder(nothingNeedsYou)
            } else {
                List {
                    // No open items, but the Decided section below has
                    // something — an inline row, not the full-screen
                    // placeholder above (which would hide the Decided
                    // section entirely). Same copy either way (Dan,
                    // 2026-09-29).
                    if model.rows.isEmpty {
                        nothingNeedsYou
                            .listRowSeparator(.hidden)
                            #if os(macOS)
                            .listRowBackground(Color.clear)
                            #endif
                    } else {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            openRow(row, hideTopSeparator: index == 0)
                        }
                    }
                    // Below the open list, newest-closed first (Dan,
                    // 2026-09-29): once a question is answered or a
                    // decision is decided it stays findable here instead
                    // of vanishing. Collapsed by default (and remembered —
                    // `ItemsPanelViewModel.isDecidedExpanded`), same as the
                    // Missions tab's own closed section.
                    if model.decidedTotalCount > 0 {
                        Section {
                            if model.isDecidedExpanded {
                                ForEach(Array(model.decided.enumerated()), id: \.element.id) { index, row in
                                    decidedRow(row, hideTopSeparator: index == 0, now: now)
                                }
                                if model.hasMoreDecided { showMoreRow }
                            }
                        } header: {
                            decidedHeader
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await onRefresh() }
                #else
                // `.inset` insets the separators; `.plain` draws one
                // hairline per row edge-to-edge, like Mail.
                .listStyle(.plain)
                // `.plain` paints an opaque list background; hide it so the
                // column keeps the same material backdrop as Conversations.
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        #if os(iOS)
        // Same cream ground as the chat and the item thread — the grouped
        // list's own backdrop is solid black in dark mode.
        .background(MatronTimelineBackground())
        #endif
    }

    /// Single source of truth for the "nothing open" copy — shown either
    /// full-screen (nothing at all, open or decided) or inline above a
    /// non-empty Decided section (Dan, 2026-09-29).
    private var nothingNeedsYou: some View {
        ContentUnavailableView("Nothing needs you", systemImage: "checkmark.seal",
                               description: Text("Questions and decisions waiting on you, from every conversation, appear here."))
    }

    /// One open ("needs you") row — unchanged from before the Decided
    /// section existed, just factored out so `body` reads the same for
    /// both sections.
    private func openRow(_ row: Row, hideTopSeparator: Bool) -> some View {
        Button { onSelect(row.item.id) } label: {
            ItemRow(item: row.item, showsOrigin: row.originTitle ?? "Another chat")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .contextMenu {
            Button("Open conversation") { onOpenConversation(row.item.originConvoID) }
        }
        // Full-width separators are a Mac-only affordance; iOS keeps its
        // insetGrouped style and default row insets. `ItemRow` itself
        // stays untouched since `ItemsListView` also renders it.
        // `macInboxRow` zeroes the list row insets, so the vertical
        // breathing room `ItemRow` doesn't provide itself has to be added
        // back here.
        #if os(macOS)
        .padding(.vertical, 6)
        // The gutter is part of the row: without this the strip beside
        // the separator would not hit-test.
        .contentShape(Rectangle())
        .macInboxRow(hideTopSeparator: hideTopSeparator)
        #endif
    }

    /// A Decided row: the same `ItemRow` layout, with its closed caption
    /// replaced by `ItemGlyph.closedCaption` ("Answered · 2h ago") instead
    /// of the bare resolution label.
    private func decidedRow(_ row: Row, hideTopSeparator: Bool, now: Date) -> some View {
        Button { onSelect(row.item.id) } label: {
            ItemRow(item: row.item, showsOrigin: row.originTitle ?? "Another chat",
                    closedCaption: ItemGlyph.closedCaption(row.item, now: now))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .contextMenu {
            Button("Open conversation") { onOpenConversation(row.item.originConvoID) }
        }
        #if os(macOS)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .macInboxRow(hideTopSeparator: hideTopSeparator)
        #endif
    }

    /// The Decided section's disclosure header, tappable on both
    /// platforms (unlike `MissionsListView`'s Mac-only toggle button — this
    /// view keeps `.insetGrouped`/`.plain` list styles rather than
    /// `.sidebar`, which is what would otherwise draw a system chevron for
    /// `Section(isExpanded:)` on iOS).
    private var decidedHeader: some View {
        Button { onToggleDecided() } label: {
            HStack {
                Text("Decided (\(model.decidedTotalCount))")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(model.isDecidedExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("decisions.decidedToggle")
        .accessibilityLabel(model.isDecidedExpanded ? "Hide decided items" : "Show decided items")
    }

    private var showMoreRow: some View {
        Button { onShowMoreDecided() } label: {
            HStack {
                Spacer()
                Text("Show more")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("decisions.showMoreDecided")
    }

    /// The empty / unsupported states. On iOS there is no header refresh
    /// button (Bugbot, PR #191), so the placeholder sits in a scroll view
    /// that still answers pull-to-refresh — a stale cache or a journal
    /// that gains tracker support later would otherwise have no way to
    /// re-fetch. The Mac keeps its header button in every state.
    ///
    /// Both branches fill the column. With rows the `List` does that and
    /// the header sits at the top; without the fill frame the Mac stack
    /// shrank to header + placeholder and the column centred the lot, so
    /// answering the last question dropped "Decisions" to the middle of
    /// the pane (item #79).
    @ViewBuilder
    private func placeholder<Content: View>(_ content: Content) -> some View {
        #if os(iOS)
        GeometryReader { geo in
            ScrollView {
                content.frame(width: geo.size.width, height: geo.size.height)
            }
            .refreshable { await onRefresh() }
        }
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
