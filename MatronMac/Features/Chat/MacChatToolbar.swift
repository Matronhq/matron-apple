import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat header content. Layout — separate clusters, each in its own
/// glass capsule (Dan, 2026-07-15: "separate bubbles"):
/// - Leading: model name, context gauge, host vitals (CPU/RAM)
/// - Center: title (+ workdir and account email underneath when known)
/// - Trailing: the mission chip, "Rooms · n", usage bars, then media +
///   tasks, then the subagents menu
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
    /// Every mission this conversation touched (spec 2026-09-30 §3, §6).
    let missions: ConversationMissions
    /// Project id → title, for "Open project" in the menu.
    let projectTitles: [String: String]
    /// Opens a mission's page. Inert by default so a toolbar built in a
    /// test or a preview has nowhere to navigate and doesn't need a host.
    let onOpenMission: (String) -> Void
    let onOpenProject: (String) -> Void
    /// Every agent-chat room this conversation takes part in, newest
    /// activity first (`ConversationRoomsRule`); empty draws no control.
    let rooms: [ConversationRoom]
    /// The room open in the side pane, ticked in the menu.
    let openRoomID: String?
    /// Opens a room in the side pane; `nil` closes it.
    let onOpenRoom: (String?) -> Void
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
    /// The bell's source: this conversation's level and mute, and the menu
    /// that changes them (journal spec 2026-10-01). Read in `body`, so the
    /// bell follows the store without the props republishing. `nil` (tests,
    /// previews) draws no bell.
    let notify: NotifySettingsStore?
    let convoID: String?

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
        missions: ConversationMissions = ConversationMissions(),
        projectTitles: [String: String] = [:],
        onOpenMission: @escaping (String) -> Void = { _ in },
        onOpenProject: @escaping (String) -> Void = { _ in },
        rooms: [ConversationRoom] = [],
        openRoomID: String? = nil,
        onOpenRoom: @escaping (String?) -> Void = { _ in },
        showMediaBrowser: Binding<Bool> = .constant(false),
        showItemsPane: Binding<Bool> = .constant(false),
        needsYouCount: Int = 0,
        itemsAvailable: Bool = true,
        notify: NotifySettingsStore? = nil,
        convoID: String? = nil
    ) {
        self.title = title
        self.boxName = boxName
        self.styledTitle = styledTitle
        self.accessibilityTitle = accessibilityTitle
        self.status = status
        self.stripViewModel = stripViewModel
        self.onOpenSubChat = onOpenSubChat
        self.onCompact = onCompact
        self.missions = missions
        self.projectTitles = projectTitles
        self.onOpenMission = onOpenMission
        self.onOpenProject = onOpenProject
        self.rooms = rooms
        self.openRoomID = openRoomID
        self.onOpenRoom = onOpenRoom
        self.showMediaBrowser = showMediaBrowser
        self.showItemsPane = showItemsPane
        self.needsYouCount = needsYouCount
        self.itemsAvailable = itemsAvailable
        self.notify = notify
        self.convoID = convoID
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
            missions: props.missions,
            projectTitles: props.projectTitles,
            onOpenMission: props.actions.onOpenMission,
            onOpenProject: props.actions.onOpenProject,
            rooms: props.rooms,
            openRoomID: props.openRoomID,
            onOpenRoom: props.actions.onOpenRoom,
            showMediaBrowser: props.actions.showMediaBrowser,
            showItemsPane: props.actions.showItemsPane,
            needsYouCount: props.needsYouCount,
            itemsAvailable: props.itemsAvailable,
            notify: props.notify,
            convoID: props.roomID
        )
    }

    @ViewBuilder var modelItem: some View {
        if status?.model != nil || status?.context != nil || status?.vitals != nil {
            cluster { modelContextCluster }
        }
    }

    /// The title is only a title now (spec §6: "the title stops being a
    /// hidden button"); the mission lives in `missionChipItem`.
    @ViewBuilder var titleItem: some View {
        cluster {
            titleCluster.accessibilityLabel(accessibilityTitle ?? title)
        }
    }

    /// The widest the header's mission chip label gets.
    static let missionChipMaxWidth: CGFloat = 240

    static func menuProjectID(missions: ConversationMissions, projectTitles: [String: String]) -> String? {
        guard let id = missions.sections.headline?.mission.projectID, projectTitles[id] != nil else { return nil }
        return id
    }

    /// "⚑ #4791 Promo branch +2 ▾" and its Current / Also on / Earlier menu
    /// (mockup 03 right). Its own glass capsule, like the other clusters.
    @ViewBuilder var missionChipItem: some View {
        if MissionChipLabel.text(missions) != nil {
            // The chat title comes first (Dan, 2026-10-01): the header gives
            // the chip what the title leaves, down to "#4791 +2" and up to
            // the cap (PR4 review I2: an uncapped 100-character mission
            // title ran over the left cluster). A plain button-style menu
            // draws the label as built: `.borderlessButton` flattened it to
            // its first text and image, which dropped the cap, the "+2" and
            // the chip's capsule.
            Menu { missionMenu } label: {
                HStack(spacing: 4) {
                    MacMissionChipWidth(maxWidth: Self.missionChipMaxWidth) {
                        MissionChipLabel(missions: missions).modifier(MacCollapsible())
                        MissionChipLabel(missions: missions, numberOnly: true).modifier(MacCollapsible())
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .frame(height: Self.clusterHeight)
                .modifier(MacChatHeaderGlass())
                .help("Every mission this conversation worked on")
                .accessibilityIdentifier("chatHeader.missions")
        }
    }

    @ViewBuilder private var missionMenu: some View {
        let sections = missions.sections
        if let current = sections.current { Section("Current") { missionButton(current) } }
        if !sections.alsoOn.isEmpty { Section("Also on") { ForEach(sections.alsoOn) { missionButton($0) } } }
        if !sections.earlier.isEmpty { Section("Earlier") { ForEach(sections.earlier) { missionButton($0) } } }
        if let projectID = Self.menuProjectID(missions: missions, projectTitles: projectTitles),
           let title = projectTitles[projectID] {
            Divider()
            Button("Open project \(title)") { onOpenProject(projectID) }
        }
    }

    private func missionButton(_ link: ConversationMissionLink) -> some View {
        Button { onOpenMission(link.id) } label: {
            Text(verbatim: "#\(link.mission.num) \(link.mission.title)")
            Text(ProjectsFormat.headerLine(link))
        }
    }

    /// "Rooms · 2", or `nil` for a chat that is in no room.
    var roomsLabel: String? { ConversationRoomsFormat.label(count: rooms.count) }

    /// The side pane's room after a pick in the control: the picked room,
    /// or none when it was already the open one.
    static func roomAfterPick(_ id: String, open: String?) -> String? {
        id == open ? nil : id
    }

    /// "Rooms · n" (Dan, 2026-10-01): every agent-chat room this
    /// conversation is in, each opening in the side pane the subagent
    /// chats use. One room is a plain button; several are a menu.
    @ViewBuilder var roomsItem: some View {
        if let label = roomsLabel {
            let text = Text(verbatim: label).font(.caption.weight(.medium))
                .modifier(MacChatHeaderInactiveDim(opacity: 0.7))
                .contentShape(Rectangle())
            Group {
                if rooms.count == 1, let only = rooms.first {
                    Button { onOpenRoom(Self.roomAfterPick(only.id, open: openRoomID)) } label: { text }
                        .buttonStyle(.plain)
                        .help(only.title)
                } else {
                    Menu {
                        ForEach(rooms) { room in
                            Button { onOpenRoom(Self.roomAfterPick(room.id, open: openRoomID)) } label: {
                                Label(room.title, systemImage: room.id == openRoomID ? "checkmark"
                                    : (room.state == .running ? "circle.fill" : "circle"))
                            }
                            .accessibilityLabel(ConversationRoomsFormat.rowAccessibilityLabel(room))
                        }
                    } label: { text }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("Agent chat rooms this conversation is in")
                }
            }
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: Self.clusterHeight)
            .modifier(MacChatHeaderGlass())
            .accessibilityLabel(ConversationRoomsFormat.accessibilityLabel(count: rooms.count))
            .accessibilityIdentifier("chatHeader.rooms")
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

    /// The conversation's Notifications menu. The bell turns into a
    /// bell-slash, undimmed, while nothing from it pushes (level None or a
    /// running mute) — the header's indicator and its menu in one.
    @ViewBuilder var notifyItem: some View {
        if let notify, let convoID {
            let silenced = notify.state(for: convoID).isSilenced
            Menu {
                MacConvoNotifyMenuItems(store: notify, convoID: convoID)
            } label: {
                if silenced {
                    Image(systemName: "bell.slash").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "bell").modifier(MacChatHeaderInactiveDim(opacity: 0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(silenced ? "Notifications off for this conversation" : "Notifications")
            .accessibilityLabel(silenced ? "Notifications off" : "Notifications")
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
            notifyItem
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
        let onOpenProject: (String) -> Void
        let showMediaBrowser: Binding<Bool>
        let showItemsPane: Binding<Bool>
        /// Opens a room in the side pane; `nil` closes it.
        var onOpenRoom: (String?) -> Void = { _ in }
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
    let missions: ConversationMissions
    let projectTitles: [String: String]
    var rooms: [ConversationRoom] = []
    var openRoomID: String? = nil
    let needsYouCount: Int
    let itemsAvailable: Bool
    let actions: Actions
    /// Compared by identity: the bell reads the store itself, so its
    /// changes need no new props.
    var notify: NotifySettingsStore? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.roomID == rhs.roomID
            && lhs.publisher == rhs.publisher
            && lhs.title == rhs.title
            && lhs.boxName == rhs.boxName
            && lhs.styledTitle == rhs.styledTitle
            && lhs.accessibilityTitle == rhs.accessibilityTitle
            && lhs.status == rhs.status
            && lhs.stripViewModel === rhs.stripViewModel
            && lhs.missions == rhs.missions && lhs.projectTitles == rhs.projectTitles
            && lhs.rooms == rhs.rooms && lhs.openRoomID == rhs.openRoomID
            && lhs.needsYouCount == rhs.needsYouCount
            && lhs.itemsAvailable == rhs.itemsAvailable
            && lhs.notify === rhs.notify
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

/// The mission chip's label, as wide as it is proposed between two
/// presentations: the full label — name truncating with "…" — up to
/// `maxWidth`, and number-only ("#4791 +2") as its floor. Its subviews are
/// those two, full first; it draws one and collapses the other to zero
/// width, so each must be `MacCollapsible`.
///
/// It sizes the full label itself, even under an unspecified proposal —
/// where a `.frame(maxWidth:)` would pass the nil proposal down, let the
/// child take its full ideal width and only clamp the reported size, so
/// the content overflows instead of truncating.
struct MacMissionChipWidth: Layout {
    let maxWidth: CGFloat
    /// The least of the name worth drawing: narrower than number-only plus
    /// this, the full label reads "#4791 P…" or "#47…", so the chip stays
    /// number-only.
    var minimumNameWidth: CGFloat = 40

    /// The chip's width for a proposal, given both presentations' ideal
    /// widths — `numberOnly` exactly when it draws number-only.
    static func width(proposed: CGFloat?, numberOnly: CGFloat, full: CGFloat, maxWidth: CGFloat,
                      minimumNameWidth: CGFloat) -> CGFloat {
        let widest = max(numberOnly, min(full, maxWidth))
        let width = min(max(proposed ?? widest, numberOnly), widest)
        return width < widest && width < numberOnly + minimumNameWidth ? numberOnly : width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let full = subviews[0].sizeThatFits(.unspecified)
        let numberOnly = subviews[1].sizeThatFits(.unspecified)
        let width = Self.width(proposed: proposal.width, numberOnly: numberOnly.width, full: full.width,
                               maxWidth: maxWidth, minimumNameWidth: minimumNameWidth)
        return CGSize(width: width, height: max(full.height, numberOnly.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let numberOnly = subviews[1].sizeThatFits(.unspecified).width
        // A point of slack for the pixel rounding between measuring and
        // placing: number-only is drawn at its own width, never a hair over.
        let shown = bounds.width > numberOnly + 1 ? 0 : 1
        for (index, subview) in subviews.enumerated() {
            let width = index == shown ? bounds.width : 0
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

/// Takes whatever width it is proposed, down to zero, and draws nothing
/// outside it — how `MacMissionChipWidth` hides the presentation it isn't
/// drawing. Under an unspecified proposal it is its content's ideal size.
struct MacCollapsible: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
    }
}
