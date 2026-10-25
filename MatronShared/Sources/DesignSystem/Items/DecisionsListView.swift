import SwiftUI
import MatronModels

/// The For you list, on three tabs. Open: every open item awaiting the
/// user, across every conversation, newest first, with its origin
/// conversation (app shell, spec §2). Closed: every closed question and
/// decision, ordered by the user's own last input on each, newest first.
/// Spare allowance: the backlog of open tasks labelled `spare-allowance`,
/// next first.
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
        /// The Spare allowance tab's rows, in backlog order — left empty by
        /// the host while another tab shows.
        public var spare: [Row]
        public var tab: ForYouTab
        /// Whether "Show more" should render under the visible window —
        /// purely local (`ItemsPanelViewModel.hasMoreDecided`); there is no
        /// server page to reach for.
        public var hasMoreClosed: Bool
        /// `false` shows the unsupported-journal message; `nil` (not yet
        /// known) and `true` both show the list.
        public var isSupported: Bool?
        public var isRefreshing: Bool
        /// The search field's text. `rows`, `closed` and `spare` are already
        /// filtered by it; a non-blank query only changes the empty state.
        public var query: String
        public init(rows: [Row], closed: [Row] = [], closedTotalCount: Int = 0, spare: [Row] = [],
                    tab: ForYouTab = .open, hasMoreClosed: Bool = false, isSupported: Bool?, isRefreshing: Bool,
                    query: String = "") {
            self.rows = rows; self.closed = closed; self.closedTotalCount = closedTotalCount; self.spare = spare
            self.tab = tab; self.hasMoreClosed = hasMoreClosed
            self.isSupported = isSupported; self.isRefreshing = isRefreshing
            self.query = query
        }

        /// Whether the search field holds anything to filter by.
        public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// The For you model from the view model's lists, as every host
        /// builds it. While searching, the Done tab filters everything it
        /// knows rather than the visible window, so a match further down
        /// is not hidden behind "Show more".
        public static func forYou(awaiting: [TrackerItem], decided: [TrackerItem], decidedVisibleCount: Int,
                                  hasMoreDecided: Bool, spare: [TrackerItem] = [], tab: ForYouTab,
                                  isSupported: Bool?, isRefreshing: Bool, query: String,
                                  origin: (TrackerItem) -> String?) -> Model {
            func row(_ item: TrackerItem) -> Row { Row(item: item, originTitle: origin(item)) }
            func keep(_ row: Row) -> Bool { DecisionsListView.matches(row, query: query) }
            let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let rows = awaiting.map(row).filter(keep)
            switch tab {
            case .open:
                return Model(rows: rows, closedTotalCount: decided.count, tab: tab, hasMoreClosed: hasMoreDecided,
                             isSupported: isSupported, isRefreshing: isRefreshing, query: query)
            case .spare:
                return Model(rows: rows, closedTotalCount: decided.count, spare: spare.map(row).filter(keep),
                             tab: tab, hasMoreClosed: hasMoreDecided, isSupported: isSupported,
                             isRefreshing: isRefreshing, query: query)
            case .closed:
                if searching {
                    let closed = decided.map(row).filter(keep)
                    return Model(rows: rows, closed: closed, closedTotalCount: closed.count, tab: tab,
                                 hasMoreClosed: false, isSupported: isSupported, isRefreshing: isRefreshing,
                                 query: query)
                }
                return Model(rows: rows, closed: decided.prefix(decidedVisibleCount).map(row),
                             closedTotalCount: decided.count, tab: tab, hasMoreClosed: hasMoreDecided,
                             isSupported: isSupported, isRefreshing: isRefreshing, query: query)
            }
        }
    }

    /// Whether every word of `query` appears in the row's number, title,
    /// text or origin conversation — the For you search field's filter,
    /// the same rule the web and Android apply. A blank query matches all.
    public static func matches(_ row: Row, query: String) -> Bool {
        matches(row.item, origin: row.originTitle, query: query)
    }

    public static func matches(_ item: TrackerItem, origin: String?, query: String) -> Bool {
        let words = ForYouSearchText.words(query)
        if words.isEmpty { return true }
        let haystack = ForYouSearchText.shared.haystack(for: item, origin: origin)
        return words.allSatisfy { ForYouSearchText.contains(haystack, $0) }
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
    /// each tick — see `DecisionsTabRoot.now` and `MacDecisionsColumn`.
    let now: Date
    /// A notice row's "Seen" button or swipe action, with the item id —
    /// the host wires it to `ItemsPanelViewModel.markSeen`. Defaulted so
    /// existing call sites keep compiling.
    let onSeen: (String) -> Void
    /// A consent ask's Approve, Accept or Decline under its row, with the
    /// item id and the label — the host wires it to
    /// `ItemsPanelViewModel.answer`. Defaulted like `onSeen`.
    let onAnswer: (String, String) -> Void
    /// The Mac search field's edits — the host writes them to
    /// `ItemsPanelViewModel.forYouQuery`. On iOS the host puts a
    /// `.searchable` field on its navigation stack instead.
    let onQueryChange: (String) -> Void

    /// The list's name: the iPhone tab, the Mac nav entry and the Mac
    /// list header all read it.
    public static let title = "For you"
    public static let emptyTitle = "Nothing needs you"
    public static let emptyDescription = "Questions, things to read and secret requests from every conversation appear here."
    public static let closedEmptyTitle = "Nothing done yet"
    public static let closedEmptyDescription = "Questions and decisions move here once they are closed, and notices once you have seen them. Newest first by your last reply."
    public static let spareEmptyTitle = "The backlog is empty"
    public static let spareEmptyDescription = "Tasks labelled spare-allowance run on a box whose weekly limit is about to reset with room left, in this order."
    /// The search field's prompt, on every platform.
    public static let searchPrompt = "Search For you"

    public init(model: Model, onSelect: @escaping (String) -> Void, onOpenConversation: @escaping (String) -> Void,
                onRefresh: @escaping () async -> Void, onSelectTab: @escaping (ForYouTab) -> Void = { _ in },
                onShowMoreClosed: @escaping () -> Void = {}, now: Date = Date(),
                onSeen: @escaping (String) -> Void = { _ in }, onQueryChange: @escaping (String) -> Void = { _ in },
                onAnswer: @escaping (String, String) -> Void = { _, _ in }) {
        self.model = model; self.onSelect = onSelect; self.onOpenConversation = onOpenConversation; self.onRefresh = onRefresh
        self.onSelectTab = onSelectTab; self.onShowMoreClosed = onShowMoreClosed; self.now = now
        self.onSeen = onSeen; self.onQueryChange = onQueryChange; self.onAnswer = onAnswer
    }

    public var body: some View {
        let _ = StallCauseRecorder.shared.note("DecisionsList.body")
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
                #if os(macOS)
                ForYouSearchField(text: Binding(get: { model.query }, set: { onQueryChange($0) }))
                #endif
                tabPicker
                switch model.tab {
                case .open:
                    if model.rows.isEmpty && model.isSearching {
                        placeholder(ContentUnavailableView.search(text: model.query))
                    } else if model.rows.isEmpty {
                        placeholder(nothingNeedsYou)
                    } else {
                        list {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                openRow(row, hideTopSeparator: index == 0)
                            }
                        }
                    }
                case .closed:
                    if model.closedTotalCount == 0 && model.isSearching {
                        placeholder(ContentUnavailableView.search(text: model.query))
                    } else if model.closedTotalCount == 0 {
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
                case .spare:
                    if model.spare.isEmpty && model.isSearching {
                        placeholder(ContentUnavailableView.search(text: model.query))
                    } else if model.spare.isEmpty {
                        placeholder(ContentUnavailableView(Self.spareEmptyTitle, systemImage: "hourglass",
                                                           description: Text(Self.spareEmptyDescription)))
                    } else {
                        list {
                            ForEach(Array(model.spare.enumerated()), id: \.element.id) { index, row in
                                openRow(row, hideTopSeparator: index == 0)
                            }
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

    /// The Needs you | Done | Spare allowance control, above whichever
    /// tab's list shows. A
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
    /// button beside the row and as a swipe action; a consent ask with
    /// one-tap answers carries them on a line under it; every other row is
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
        let answers = row.item.rowConsentAnswers
        #if os(macOS)
        VStack(alignment: .leading, spacing: Self.answersSpacing) {
            selectButton(row, reservesSeen: row.item.offersSeen)
            if !answers.isEmpty { consentAnswers(row, answers) }
        }
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
        } else if !answers.isEmpty {
            VStack(alignment: .leading, spacing: Self.answersSpacing) {
                selectButton(row)
                consentAnswers(row, answers)
            }
        } else {
            selectButton(row)
        }
        #endif
    }

    /// Between the row and its answers.
    static let answersSpacing: CGFloat = 6
    /// The answers line up with the row's text: `ItemRow`'s 20 pt glyph
    /// column and its 10 pt spacing.
    static let answersIndent: CGFloat = 30

    /// A consent ask's answers, on their own line under the row so a long
    /// title keeps its width: Approve (or Accept) filled, as the request
    /// card draws its Approve, and Decline bordered. Each its own button
    /// with its own style, so it hit-tests apart from the row.
    private func consentAnswers(_ row: Row, _ answers: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(answers, id: \.self) { label in
                answerButton(row, label)
            }
        }
        .padding(.leading, Self.answersIndent)
    }

    @ViewBuilder
    private func answerButton(_ row: Row, _ label: String) -> some View {
        let button = Button(label) { onAnswer(row.item.id, label) }
        Group {
            if TrackerItem.isAffirmativeAnswer(label) {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .accessibilityIdentifier("decisions.answer.\(label)")
        .accessibilityLabel("\(label): \(row.item.title)")
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

#if os(macOS)
/// The Mac For you search field: the Conversations sidebar field's look
/// (`MacSearchView`), above the Needs you | Done control. Shared by the
/// SwiftUI list and the AppKit-hosted one. Escape clears it.
public struct ForYouSearchField: View {
    @Binding var text: String

    public init(text: Binding<String>) { self._text = text }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(DecisionsListView.searchPrompt, text: $text)
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.matronBubbleBot))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityIdentifier("decisions.search")
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
#endif

/// Each item's search text, lower-cased and in one Unicode form, built
/// once per version of the item rather than on every keystroke, and
/// searched byte by byte: the standard `contains` compares character by
/// character and took most of a keystroke on a long Done tab. An entry
/// stands while the item's number, title, body and origin label are the
/// ones it was built from; an unchanged item shares its strings' storage,
/// so that check is cheap.
final class ForYouSearchText: @unchecked Sendable {
    static let shared = ForYouSearchText()

    private struct Entry {
        let num: Int
        let title: String
        let body: String
        let origin: String?
        let haystack: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func haystack(for item: TrackerItem, origin: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[item.id], entry.num == item.num, entry.title == item.title,
           entry.body == item.body, entry.origin == origin {
            return entry.haystack
        }
        let haystack = Self.folded("#\(item.num) \(item.title) \(item.body) \(origin ?? "Another chat")")
        entries[item.id] = Entry(num: item.num, title: item.title, body: item.body, origin: origin, haystack: haystack)
        return haystack
    }

    /// Lower-cased, composed: the form both sides are compared in.
    static func folded(_ text: String) -> String {
        text.lowercased().precomposedStringWithCanonicalMapping
    }

    /// The query's words, folded like the haystacks.
    static func words(_ query: String) -> [String] {
        folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether `word` occurs in `haystack`. A byte search is exact here:
    /// both are folded the same way, and UTF-8 never matches part-way
    /// through a character.
    static func contains(_ haystack: String, _ word: String) -> Bool {
        var haystack = haystack, word = word
        return haystack.withUTF8 { hay in
            word.withUTF8 { needle in
                needle.isEmpty || memmem(hay.baseAddress, hay.count, needle.baseAddress, needle.count) != nil
            }
        }
    }
}
