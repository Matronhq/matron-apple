import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat header content. Layout — separate clusters, each in its own
/// glass capsule (Dan, 2026-07-15: "separate bubbles"):
/// - Leading: model name, context gauge, host vitals (CPU/RAM)
/// - Center: title (+ workdir and account email underneath when known)
/// - Trailing: usage bars, then media + tasks, then the subagents menu
///
/// This is NOT a SwiftUI `.toolbar` any more, though it sits in the same
/// title-bar strip and draws the same capsules. SwiftUI's NSToolbar bridge
/// answers any change under the `NavigationSplitView` detail by removing
/// and re-adding the chat's `NSToolbarItem`s over two or three run-loop
/// turns, each dragging a whole-window layout; with a mounted transcript
/// that was most of the cost of switching conversation (2026-09-17, tracker
/// #1434: 8 switches stalled main ~3.5 s with the toolbar, ~0.6 s without,
/// three interleaved rounds). Hoisting the toolbar out of the per-room
/// identity, explicit item ids and fixed item slots all still churned. So
/// the clusters are plain views, `MacChatHeaderBar` lays them out, and
/// `MacChatHeaderAccessory` hosts that bar in a native title-bar accessory.
///
/// The capsules are hand-drawn `glassEffect` (`MacChatHeaderGlass`). An
/// earlier attempt at that INSIDE toolbar items didn't composite as live
/// glass (Dan, 2026-07-15: "why have we lost the glass effect in the
/// header?"); in the accessory, outside the system's own item glass, it
/// does. All clusters share one fixed height so the capsules come out
/// equal and vertically centred as a row. The 12pt horizontal padding
/// keeps "Session" and friends off the capsule edge.
///
/// The refresh button was dropped after the journal rewire: it only ran
/// `ChatViewModel.refresh()` (= `paginateBackward`, an OLDER-history
/// fetch) while new messages ride the live socket — a Matrix-era leftover
/// with no user-visible effect. The menu bar's ⌘R still posts
/// `.matronCommand(.refresh)` for the listener in `MacChatView`. The
/// decorative "Search chat…" placeholder field went with it — real search
/// lives at the top of the sidebar, and a second dead field in the header
/// only invited clicks that did nothing.
///
/// Wave 6 / live-test #4: removed the leading `ToolbarItem(.navigation)`
/// sidebar-toggle button. `NavigationSplitView` already renders its own
/// system sidebar-toggle button inside the sidebar column on macOS;
/// duplicating it on the detail column's toolbar produced two toggle
/// buttons in the window header. The menu-bar entry (`Commands.swift`)
/// + the ⌘⇧S shortcut still reach the same `.toggleSidebar` listener on
/// `MacChatListView`.
///
/// The ⓘ button and the bot-profile sheet it presented are gone: the
/// header now carries the live context gauge and usage bars inline
/// instead of a tap-through sheet.
@MainActor
struct MacChatToolbar {
    let title: String
    /// Which agent box this session runs on, or `nil` when the user has
    /// fewer than two boxes (resolved by `JournalChatService.boxName`).
    /// Leads the subtitle: it answers "which machine am I talking to",
    /// which outranks the path and the account.
    let boxName: String?
    /// The title with the colored `A:bc` (or `A↔B:bc` room) tag composed
    /// ahead of it, ready-made by `MacChatView` — a `ToolbarContent` is not
    /// a View, so the environment the tag's colors need lives with the
    /// caller. Nil falls back to the plain `title`.
    let styledTitle: Text?
    /// VoiceOver's reading of the visible tag + title (box names, session
    /// short spelled out — `SessionTag.accessibilityTitle`). Nil reads the
    /// plain title.
    let accessibilityTitle: String?
    /// Last-known session status for the open convo — model + context
    /// gauge render in the leading capsule, usage bars in the trailing
    /// one. Nil (no status frame yet) renders the title alone.
    let status: SessionStatus?
    /// Sub-chat switcher source. The button shows whenever the chat has
    /// ANY children — running or finished. The running strip hides itself
    /// the moment the last subagent finishes, so this is the permanent
    /// entry point back into finished sub-chats (Dan, 2026-07-15).
    /// Reading `children` in `body` installs `@Observable` tracking.
    let stripViewModel: SubChatStripViewModel
    let onOpenSubChat: (String) -> Void
    /// Sends "/compact" for the user — the button rides next to the
    /// context gauge so the action sits beside the number that motivates
    /// it (Dan, 2026-07-16: "so you don't have to type it").
    let onCompact: () -> Void
    /// The mission this conversation belongs to, or `nil` when it has none
    /// (or the host hasn't resolved one yet). The title is a button only
    /// when there is something to open — spec: "With no mission the title
    /// is not a button" — which is `Self.titleOpensMission(missionID:)`.
    let missionID: String?
    /// Opens `missionID`'s page. Inert by default so a toolbar built in a
    /// test or a preview has nowhere to navigate and doesn't need a host.
    let onOpenMission: (String) -> Void
    /// Presents the per-chat media & links browser sheet.
    let showMediaBrowser: Binding<Bool>
    /// Presents/dismisses `MacItemsPane` (Task 10) in the sub-chat slot.
    /// Defaults to an inert constant binding, same reasoning as
    /// `showMediaBrowser` above.
    let showItemsPane: Binding<Bool>
    /// Live "needs you" count for the badge on the pane's toolbar button.
    let needsYouCount: Int
    /// Whether the signed-in journal server supports the tracker at all
    /// (`ItemsPanelViewModel.isSupported`). `false` hides the button
    /// entirely rather than showing a permanently-disabled one.
    let itemsAvailable: Bool

    /// One height for all three clusters so the system's content-hugging
    /// glass capsules come out equal and align as a row. Sized to the
    /// tallest content: three compact usage rows (3 × ~11pt lines +
    /// 2 × 2pt spacing ≈ 37pt).
    static let clusterHeight: CGFloat = 38

    /// Explicit init (not the synthesized memberwise one) — a stored
    /// property's own default value is NOT exposed as a defaulted
    /// parameter by Swift's memberwise synthesis; it drops the parameter
    /// entirely instead. `missionID`/`onOpenMission` need real
    /// caller-settable defaults so the existing title/status tests and
    /// `MacChatView`'s call site both keep compiling.
    init(
        title: String,
        boxName: String? = nil,
        styledTitle: Text? = nil,
        accessibilityTitle: String? = nil,
        status: SessionStatus?,
        stripViewModel: SubChatStripViewModel,
        onOpenSubChat: @escaping (String) -> Void,
        onCompact: @escaping () -> Void,
        missionID: String? = nil,
        onOpenMission: @escaping (String) -> Void = { _ in },
        showMediaBrowser: Binding<Bool> = .constant(false),
        showItemsPane: Binding<Bool> = .constant(false),
        needsYouCount: Int = 0,
        itemsAvailable: Bool = true
    ) {
        self.title = title
        self.boxName = boxName
        self.styledTitle = styledTitle
        self.accessibilityTitle = accessibilityTitle
        self.status = status
        self.stripViewModel = stripViewModel
        self.onOpenSubChat = onOpenSubChat
        self.onCompact = onCompact
        self.missionID = missionID
        self.onOpenMission = onOpenMission
        self.showMediaBrowser = showMediaBrowser
        self.showItemsPane = showItemsPane
        self.needsYouCount = needsYouCount
        self.itemsAvailable = itemsAvailable
    }

    /// Builds the header from the chat column's published props — the form
    /// `MacChatHeaderBar` uses, see `MacChatToolbarProps`.
    init(props: MacChatToolbarProps) {
        self.init(
            title: props.title,
            boxName: props.boxName,
            styledTitle: props.styledTitle,
            accessibilityTitle: props.accessibilityTitle,
            status: props.status,
            stripViewModel: props.stripViewModel,
            onOpenSubChat: props.actions.onOpenSubChat,
            onCompact: props.actions.onCompact,
            missionID: props.missionID,
            onOpenMission: props.actions.onOpenMission,
            showMediaBrowser: props.actions.showMediaBrowser,
            showItemsPane: props.actions.showItemsPane,
            needsYouCount: props.needsYouCount,
            itemsAvailable: props.itemsAvailable
        )
    }

    /// Whether the title renders as a button. Only a real mission id counts:
    /// an empty string is treated as absent rather than producing a button
    /// that navigates nowhere.
    static func titleOpensMission(missionID: String?) -> Bool {
        guard let missionID else { return false }
        return !missionID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder var modelItem: some View {
        if status?.model != nil || status?.context != nil || status?.vitals != nil {
            cluster { modelContextCluster }
        }
    }

    @ViewBuilder var titleItem: some View {
        cluster {
            if Self.titleOpensMission(missionID: missionID), let missionID {
                Button { onOpenMission(missionID) } label: { titleCluster }
                    .buttonStyle(.plain)
                    .help("Open this conversation's mission")
                    .accessibilityLabel(accessibilityTitle ?? title)
                    .accessibilityHint("Opens this conversation's mission")
            } else {
                titleCluster
                    .accessibilityLabel(accessibilityTitle ?? title)
            }
        }
    }

    @ViewBuilder var usageItem: some View {
        if let limits = status?.limits, !limits.isEmpty {
            cluster {
                UsageBarsView(limits: limits, scale: .compact)
                    .modifier(MacChatHeaderInactiveDim(opacity: 0.8))
            }
        }
    }

    @ViewBuilder var mediaItem: some View {
        Button { showMediaBrowser.wrappedValue = true } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .modifier(MacChatHeaderInactiveDim(opacity: 0.5))
        }
        .help("Media, files & links")
        .accessibilityLabel("Media browser")
    }

    @ViewBuilder var tasksItem: some View {
        if itemsAvailable {
            Button { showItemsPane.wrappedValue.toggle() } label: {
                Image(systemName: "checklist")
                    .modifier(MacChatHeaderInactiveDim(opacity: 0.5))
                    .overlay(alignment: .topTrailing) {
                        NeedsYouBadge(count: needsYouCount)
                            .scaleEffect(0.8)
                            .offset(x: 8, y: -8)
                    }
            }
            .help("Tasks & decisions")
            .accessibilityLabel("Tasks and decisions" + (needsYouCount > 0 ? ", \(needsYouCount) need you" : ""))
        }
    }

    @ViewBuilder var subagentsItem: some View {
        if !stripViewModel.children.isEmpty {
            Menu {
                ForEach(stripViewModel.children) { child in
                    Button {
                        onOpenSubChat(child.id)
                    } label: {
                        Label(child.title, systemImage: child.isRunning ? "circle.dashed" : "checkmark.circle")
                    }
                }
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .accessibilityLabel("Subagents")
        }
    }

    /// Uniform cluster chrome: fixed-height, centred content with enough
    /// horizontal padding that text clears the system capsule's rounded
    /// ends.
    private func cluster(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(height: Self.clusterHeight)
            .modifier(MacChatHeaderGlass())
    }

    /// Media + tasks share one capsule, as the system toolbar grouped them.
    @ViewBuilder var buttonsItem: some View {
        HStack(spacing: 14) {
            mediaItem
            tasksItem
        }
        .font(.system(size: 15))
        .padding(.horizontal, 10.5)
        .frame(height: Self.clusterHeight)
        .modifier(MacChatHeaderGlass())
    }

    @ViewBuilder var subagentsCapsule: some View {
        if !stripViewModel.children.isEmpty {
            subagentsItem
                .font(.system(size: 15))
                .modifier(MacChatHeaderInactiveDim(opacity: 0.5))
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 6.5)
                .frame(height: Self.clusterHeight)
                .modifier(MacChatHeaderGlass())
        }
    }

    private var modelContextCluster: some View {
        modelContextLines.modifier(MacChatHeaderInactiveDim(opacity: 0.8))
    }

    private var modelContextLines: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let modelLine {
                Text(modelLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let context = status?.context {
                HStack(spacing: 6) {
                    ContextGaugeLabel(context: context)
                    Button(action: onCompact) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Compact the conversation — sends /compact")
                    .accessibilityLabel("Compact conversation")
                }
            }
            // Bridge-host CPU/RAM as a third quiet line — text, not bars,
            // so machine metrics never read as account subscription meters
            // (the bridge keeps them out of limits[] for the same reason).
            // Three caption lines match the cluster height budget, which
            // was already sized for three compact usage rows. Same
            // `.secondary` as the model/context lines above — `.tertiary`
            // was hard to read against the toolbar (Dan, 2026-08-03).
            if let vitals = status?.vitals, let line = UsageMetersFormat.vitalsLine(vitals) {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Bridge host CPU and RAM")
                    .accessibilityLabel("Bridge host: \(line)")
            }
        }
    }

    private var titleCluster: some View {
        // The session's workdir (home-abbreviated — it's the BRIDGE
        // machine's path) and the logged-in account email ride under the
        // title on one quiet line when the status frame carries them.
        VStack(spacing: 0) {
            (styledTitle ?? Text(title))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(MacChatHeaderInactiveDim(opacity: 0.7))
            if let subtitle = titleSubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// The leading cluster's first line: the model, with the session's
    /// effort beside it when the bridge is tracking one. Effort shares the
    /// model's line rather than taking a fourth — the cluster's height is
    /// budgeted for three caption lines and all three are spoken for. `nil`
    /// when no model is known, so the line is dropped rather than rendered
    /// empty. Internal (not private) so MacChatToolbarTests can pin it
    /// without rendering, as with `titleSubtitle`.
    var modelLine: String? {
        guard let model = status?.model else { return nil }
        return UsageMetersFormat.modelLine(model: model, effort: status?.effort)
    }

    /// Internal (not private) so MacChatToolbarTests can pin the join
    /// format without rendering.
    var titleSubtitle: String? {
        var parts: [String] = []
        if let boxName {
            parts.append(boxName)
        }
        if let workdir = status?.workdir {
            parts.append(UsageMetersFormat.homeAbbreviated(workdir))
        }
        if let email = status?.email {
            parts.append(email)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Everything `MacChatToolbar` renders, published UP from the chat column as
/// a preference: the header is drawn in the window's title bar
/// (`MacChatHeaderAccessory`), outside the chat column's view tree, so the
/// column hands its header over as a value.
///
/// Equality covers what is DRAWN. The actions are closures over the
/// publishing view's `@State`, which outlive any one body evaluation, so
/// they are deliberately left out — but `roomID` and `publisher` are in, so a
/// switch always republishes and the header never keeps acting on the room
/// that left. `publisher` is the publishing view INSTANCE: the same room can
/// be remounted with nothing drawn differently (Conversations ↔ Coordinator
/// on the coordinator's own conversation swaps sibling branches in one
/// transaction), and without it the header would keep the dead instance's
/// bindings.
struct MacChatToolbarProps: Equatable {
    struct Actions {
        let onOpenSubChat: (String) -> Void
        let onCompact: () -> Void
        let onOpenMission: (String) -> Void
        let showMediaBrowser: Binding<Bool>
        let showItemsPane: Binding<Bool>
    }

    let roomID: String
    /// One per mounted chat column — a `@State` UUID in the publisher.
    let publisher: UUID
    let title: String
    let boxName: String?
    let styledTitle: Text?
    let accessibilityTitle: String?
    let status: SessionStatus?
    let stripViewModel: SubChatStripViewModel
    let missionID: String?
    let needsYouCount: Int
    let itemsAvailable: Bool
    let actions: Actions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.roomID == rhs.roomID
            && lhs.publisher == rhs.publisher
            && lhs.title == rhs.title
            && lhs.boxName == rhs.boxName
            && lhs.styledTitle == rhs.styledTitle
            && lhs.accessibilityTitle == rhs.accessibilityTitle
            && lhs.status == rhs.status
            && lhs.stripViewModel === rhs.stripViewModel
            && lhs.missionID == rhs.missionID
            && lhs.needsYouCount == rhs.needsYouCount
            && lhs.itemsAvailable == rhs.itemsAvailable
    }
}

/// Carries the on-screen chat column's header props to `MacChatHeaderHost`.
/// `nil` when no chat column is mounted (another tab, the empty state, the
/// narrow pane-takeover branch) — the header is empty there, as the toolbar
/// was when the chat column owned one. Only the chat column publishes, so the
/// first value is the only one; `reduce` keeps it rather than guessing.
struct MacChatToolbarPreference: PreferenceKey {
    static let defaultValue: MacChatToolbarProps? = nil
    static func reduce(value: inout MacChatToolbarProps?, nextValue: () -> MacChatToolbarProps?) {
        value = value ?? nextValue()
    }
}
