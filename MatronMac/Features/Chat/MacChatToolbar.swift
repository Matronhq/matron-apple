import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat detail column toolbar. Layout — three separate toolbar items,
/// each in its own glass capsule (Dan, 2026-07-15: "separate bubbles"):
/// - Leading: model name, context gauge, host vitals (CPU/RAM)
/// - Center: title (+ workdir and account email underneath when known)
/// - Trailing: usage bars
///
/// The capsules are the SYSTEM's per-item glass. Round 2 replaced them
/// with hand-drawn `glassEffect` capsules (to control corner radius);
/// round 3 reverted that — inside toolbar items the custom glass didn't
/// composite as live glass and the header read as a flat grey bar
/// (Dan, 2026-07-15: "why have we lost the glass effect in the
/// header?"). Alignment survives the revert a simpler way: all three
/// clusters share one fixed content height, so the system capsules —
/// which hug their content — come out equal and vertically centred as a
/// row. Corner radius stays the system pill; that's the price of real
/// glass. The 12pt horizontal padding keeps "Session" and friends off
/// the capsule edge.
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
struct MacChatToolbar: ToolbarContent {
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
    private static let clusterHeight: CGFloat = 38

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

    /// Builds the toolbar from the chat column's published props — the form
    /// `MacChatListView` uses, see `MacChatToolbarProps`.
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

    var body: some ToolbarContent {
        if status?.model != nil || status?.context != nil || status?.vitals != nil {
            ToolbarItem(placement: .navigation) {
                cluster { modelContextCluster }
            }
        }
        ToolbarItem(placement: .principal) {
            cluster {
                // Tappable title → this conversation's mission, same
                // affordance as iOS's tappable title. `.buttonStyle(.plain)`
                // is mandatory here (see header) — the default button style
                // breaks the system glass capsule this cluster renders
                // inside.
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
        if let limits = status?.limits, !limits.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                cluster { UsageBarsView(limits: limits, scale: .compact) }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showMediaBrowser.wrappedValue = true } label: {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .help("Media, files & links")
            .accessibilityLabel("Media browser")
        }
        if itemsAvailable {
            ToolbarItem(placement: .primaryAction) {
                Button { showItemsPane.wrappedValue.toggle() } label: {
                    Image(systemName: "checklist")
                        .overlay(alignment: .topTrailing) {
                            NeedsYouBadge(count: needsYouCount)
                                .scaleEffect(0.8)
                                .offset(x: 8, y: -8)
                        }
                }
                .help("Tasks & decisions")
                .accessibilityLabel("Tasks and decisions" + (needsYouCount > 0 ? ", \(needsYouCount) need you" : ""))
                // Minor (Mac fix wave, part 1): the shortcut itself moved
                // to an always-mounted hidden button in `MacChatView` —
                // this toolbar item lives inside `chatColumn`, which isn't
                // rendered in the narrow-takeover branch, so a shortcut
                // registered here couldn't close the pane it opened.
            }
        }
        if !stripViewModel.children.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(stripViewModel.children) { child in
                        Button {
                            onOpenSubChat(child.id)
                        } label: {
                            Label(
                                child.title,
                                systemImage: child.isRunning
                                    ? "circle.dashed" : "checkmark.circle"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .accessibilityLabel("Subagents")
            }
        }
    }

    /// Uniform cluster chrome: fixed-height, centred content with enough
    /// horizontal padding that text clears the system capsule's rounded
    /// ends.
    private func cluster(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(height: Self.clusterHeight)
    }

    private var modelContextCluster: some View {
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
/// a preference so the toolbar itself can live outside the per-room identity.
///
/// `MacChatView` is `.id(roomID)`-keyed, and a `.toolbar` declared inside it
/// takes that identity with it: every conversation switch destroyed every
/// `NSToolbarItem` and built new ones, and NSToolbar answers each insertion by
/// re-tiling and forcing a whole-window layout — with a mounted transcript
/// that was the largest single cost of a switch (2026-09-17, optimized build
/// on a 7,300-conversation store: worst main-thread stall per switch ~1.25 s
/// with the toolbar inside the identity, ~0.3 s with it outside). Declared
/// once in `MacChatListView`, the items persist and only their content
/// updates.
///
/// Equality covers what is DRAWN. The actions are closures over the
/// publishing view's `@State`, which outlive any one body evaluation, so
/// they are deliberately left out — but `roomID` is in, so a switch always
/// republishes and the toolbar never keeps acting on the room that left.
struct MacChatToolbarProps: Equatable {
    struct Actions {
        let onOpenSubChat: (String) -> Void
        let onCompact: () -> Void
        let onOpenMission: (String) -> Void
        let showMediaBrowser: Binding<Bool>
        let showItemsPane: Binding<Bool>
    }

    let roomID: String
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

/// Carries the on-screen chat column's toolbar props to `MacChatListView`.
/// `nil` when no chat column is mounted (another tab, the empty state, the
/// narrow pane-takeover branch) — the toolbar is empty there, as it was when
/// the chat column owned it. Only the chat column publishes, so the first
/// value is the only one; `reduce` keeps it rather than guessing.
struct MacChatToolbarPreference: PreferenceKey {
    static let defaultValue: MacChatToolbarProps? = nil
    static func reduce(value: inout MacChatToolbarProps?, nextValue: () -> MacChatToolbarProps?) {
        value = value ?? nextValue()
    }
}

/// Declares the chat toolbar around the detail column, OUTSIDE the per-room
/// identity, from whatever the mounted chat column publishes. The props live
/// in this view's own `@State` on purpose: held by `MacChatListView` instead,
/// every title / badge / status change would re-evaluate that whole root view,
/// sidebar included.
struct MacChatToolbarHost<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var props: MacChatToolbarProps?

    var body: some View {
        content
            .onPreferenceChange(MacChatToolbarPreference.self) { props = $0 }
            .toolbar {
                if let props {
                    MacChatToolbar(props: props)
                }
            }
    }
}
