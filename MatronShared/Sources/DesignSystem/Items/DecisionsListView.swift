import SwiftUI
import MatronModels

/// The For you list, on two tabs. Open: every open item awaiting the
/// user, across every conversation, newest first, with its origin
/// conversation (app shell, spec §2). Closed: every closed question and
/// decision, ordered by the user's own last input on each, newest first.
/// Notices — things to read, not decide — draw lighter, with a
/// one-tap "Seen" button and swipe action. A pure leaf
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
        /// The Open tab's rows.
        public var rows: [Row]
        /// The Closed tab's VISIBLE window, in `ItemsPanelViewModel.decided`
        /// order — already sliced by the host from `decided`/
        /// `decidedVisibleCount`, and left empty while the Open tab shows
        /// so the open list never pays for building it.
        public var closed: [Row]
        /// Every locally-known closed question and decision, independent
        /// of how many `closed` currently shows.
        public var closedTotalCount: Int
        public var tab: ForYouTab
        /// Whether "Show more" should render under the visible window —
        /// purely local (`ItemsPanelViewModel.hasMoreDecided`); there is no
        /// server page to reach for.
        public var hasMoreClosed: Bool
        /// `false` shows the unsupported-journal message; `nil` (not yet
        /// known) and `true` both show the list.
        public var isSupported: Bool?
        public var isRefreshing: Bool
        public init(rows: [Row], closed: [Row] = [], closedTotalCount: Int = 0, tab: ForYouTab = .open,
                    hasMoreClosed: Bool = false, isSupported: Bool?, isRefreshing: Bool) {
            self.rows = rows; self.closed = closed; self.closedTotalCount = closedTotalCount
            self.tab = tab; self.hasMoreClosed = hasMoreClosed
            self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
    }

    let model: Model
    /// Reused for both tabs — a closed item's thread opens exactly the
    /// same way an open one's does.
    let onSelect: (String) -> Void
    let onOpenConversation: (String) -> Void
    /// Pull to refresh (iOS) and the header button (Mac) both call this —
    /// the host wires it to `ItemsPanelViewModel.refresh()`.
    let onRefresh: () async -> Void
    /// The Needs you | Done control — the host writes it to
    /// `ItemsPanelViewModel.forYouTab`. Defaulted (in `init` below) so a
    /// snapshot test of one tab needs no callback.
    let onSelectTab: (ForYouTab) -> Void
    /// "Show more" under the Closed tab — purely a local window grow
    /// (`ItemsPanelViewModel.showMoreDecided()`), so this is synchronous.
    let onShowMoreClosed: () -> Void
    /// Clock for the Closed rows' "Answered · 2h ago" captions — defaults
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
    /// A notice row's "Seen" button or swipe action, with the item id —
    /// the host wires it to `ItemsPanelViewModel.markSeen`. Defaulted so
    /// existing call sites keep compiling.
    let onSeen: (String) -> Void

    /// The list's name: the iPhone tab, the Mac nav entry and the Mac
    /// list header all read it.
    public static let title = "For you"
    public static let emptyTitle = "Nothing needs you"
    public static let emptyDescription = "Questions, things to read and secret requests from every conversation appear here."
    public static let closedEmptyTitle = "Nothing done yet"
    public static let closedEmptyDescription = "Questions and decisions move here once they are closed, newest first by your last reply."

    public init(model: Model, onSelect: @escaping (String) -> Void, onOpenConversation: @escaping (String) -> Void,
                onRefresh: @escaping () async -> Void, onSelectTab: @escaping (ForYouTab) -> Void = { _ in },
                onShowMoreClosed: @escaping () -> Void = {}, now: Date = Date(),
                onSeen: @escaping (String) -> Void = { _ in }) {
        self.model = model; self.onSelect = onSelect; self.onOpenConversation = onOpenConversation; self.onRefresh = onRefresh
        self.onSelectTab = onSelectTab; self.onShowMoreClosed = onShowMoreClosed; self.now = now
        self.onSeen = onSeen
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The Mac list column has no pull-to-refresh, so the header
            // carries the refresh button; iOS uses `.refreshable` below.
            HStack {
                Text(Self.title).font(.headline)
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
            } else {
                tabPicker
                switch model.tab {
                case .open:
                    if model.rows.isEmpty {
                        placeholder(nothingNeedsYou)
                    } else {
                        list {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                openRow(row, hideTopSeparator: index == 0)
                            }
                        }
                    }
                case .closed:
                    if model.closedTotalCount == 0 {
                        placeholder(ContentUnavailableView(Self.closedEmptyTitle, systemImage: "tray",
                                                           description: Text(Self.closedEmptyDescription)))
                    } else {
                        list {
                            ForEach(Array(model.closed.enumerated()), id: \.element.id) { index, row in
                                closedRow(row, hideTopSeparator: index == 0, now: now)
                            }
                            if model.hasMoreClosed { showMoreRow }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        // Same cream ground as the chat and the item thread — the grouped
        // list's own backdrop is solid black in dark mode.
        .background(MatronTimelineBackground())
        #endif
    }

    /// The Needs you | Done control, above whichever tab's list shows. A
    /// segmented control rather than a section under the open list: with
    /// many open items the closed ones were a long scroll away.
    private var tabPicker: some View {
        Picker("Show", selection: Binding(get: { model.tab }, set: { onSelectTab($0) })) {
            ForEach(ForYouTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("decisions.tabs")
        .padding(.horizontal)
        #if os(macOS)
        .padding(.bottom, 8)
        #else
        .padding(.vertical, 8)
        #endif
    }

    /// Both tabs' list chrome.
    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
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

    private var nothingNeedsYou: some View {
        ContentUnavailableView(Self.emptyTitle, systemImage: "checkmark.seal",
                               description: Text(Self.emptyDescription))
    }

    /// One open ("needs you") row. A notice offering "Seen" carries the
    /// button beside the row and as a swipe action; every other row is
    /// unchanged from before notices existed.
    private func openRow(_ row: Row, hideTopSeparator: Bool) -> some View {
        openRowContent(row, hideTopSeparator: hideTopSeparator)
            .contextMenu {
                if row.item.offersSeen {
                    Button(TrackerItem.seenAction) { onSeen(row.item.id) }
                }
                Button("Open conversation") { onOpenConversation(row.item.originConvoID) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if row.item.offersSeen {
                    Button { onSeen(row.item.id) } label: {
                        Label(TrackerItem.seenAction, systemImage: "checkmark")
                    }
                    .tint(.accentColor)
                }
            }
    }

    /// The row itself: the select button, plus — for a notice offering
    /// "Seen" — the Seen button at its trailing edge.
    ///
    /// On the Mac the gutter chrome stays on the select button, exactly as
    /// on a Closed row, so a tap on the strip beside the separator still
    /// opens the item. Full-width separators are a Mac-only affordance;
    /// iOS keeps its insetGrouped style and default row insets. `ItemRow`
    /// itself stays untouched since `ItemsListView` also renders it.
    /// `macInboxRow` zeroes the list row insets, so the vertical breathing
    /// room `ItemRow` doesn't provide itself has to be added back here.
    /// The Seen button rides in an overlay, which wins its own hit area
    /// over the select button beneath; a hidden copy in the select
    /// button's label keeps the row's text clear of it.
    @ViewBuilder
    private func openRowContent(_ row: Row, hideTopSeparator: Bool) -> some View {
        #if os(macOS)
        selectButton(row, reservesSeen: row.item.offersSeen)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if row.item.offersSeen {
                    seenButton(row)
                }
            }
            .macInboxRow(hideTopSeparator: hideTopSeparator)
        #else
        if row.item.offersSeen {
            HStack(alignment: .center, spacing: 8) {
                selectButton(row)
                seenButton(row)
            }
        } else {
            selectButton(row)
        }
        #endif
    }

    /// Its own explicit style, so a row with two buttons still hit-tests
    /// each one separately.
    private func seenButton(_ row: Row) -> some View {
        Button(TrackerItem.seenAction) { onSeen(row.item.id) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("decisions.seen")
            .accessibilityLabel("Seen: \(row.item.title)")
    }

    private func selectButton(_ row: Row, reservesSeen: Bool = false) -> some View {
        Button { onSelect(row.item.id) } label: {
            HStack(alignment: .center, spacing: 8) {
                ItemRow(item: row.item, showsOrigin: row.originTitle ?? "Another chat")
                if reservesSeen {
                    // Space for the Seen button overlaid on the Mac row.
                    seenButton(row)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
    }

    /// A Closed row: the same `ItemRow` layout, with its closed caption
    /// replaced by `ItemGlyph.closedCaption` ("Answered · 2h ago") instead
    /// of the bare resolution label. The time is the one the tab is
    /// ordered by, so the list reads in order.
    private func closedRow(_ row: Row, hideTopSeparator: Bool, now: Date) -> some View {
        Button { onSelect(row.item.id) } label: {
            ItemRow(item: row.item, showsOrigin: row.originTitle ?? "Another chat",
                    closedCaption: ItemGlyph.closedCaption(row.item, at: row.item.closedSortDate, now: now))
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

    private var showMoreRow: some View {
        Button { onShowMoreClosed() } label: {
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
    /// the pane.
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
