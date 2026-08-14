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
    /// Presents the summaries TOC popover — the title cluster becomes a
    /// button that flips this on. Owned by `MacChatView` (this struct
    /// stays a plain `ToolbarContent` without the view model, so it's
    /// still property-testable without rendering); defaults to an inert
    /// constant binding so the existing title/status tests above don't
    /// need to know about it.
    let showSummaries: Binding<Bool>
    /// Builds the popover's content lazily. `AnyView`-erased so this
    /// struct doesn't need to import `MacSummariesPanel`'s dependencies —
    /// `MacChatView` supplies the real closure; the default keeps every
    /// other call site (and the existing tests) compiling unchanged.
    let popoverContent: () -> AnyView
    /// Presents the per-chat media & links browser sheet.
    let showMediaBrowser: Binding<Bool>

    /// One height for all three clusters so the system's content-hugging
    /// glass capsules come out equal and align as a row. Sized to the
    /// tallest content: three compact usage rows (3 × ~11pt lines +
    /// 2 × 2pt spacing ≈ 37pt).
    private static let clusterHeight: CGFloat = 38

    /// Explicit init (not the synthesized memberwise one) — a stored
    /// property's own default value is NOT exposed as a defaulted
    /// parameter by Swift's memberwise synthesis; it drops the parameter
    /// entirely instead. `showSummaries`/`popoverContent` need real
    /// caller-settable defaults so the existing title/status tests and
    /// `MacChatView`'s call site both keep compiling.
    init(
        title: String,
        boxName: String? = nil,
        status: SessionStatus?,
        stripViewModel: SubChatStripViewModel,
        onOpenSubChat: @escaping (String) -> Void,
        onCompact: @escaping () -> Void,
        showSummaries: Binding<Bool> = .constant(false),
        popoverContent: @escaping () -> AnyView = { AnyView(EmptyView()) },
        showMediaBrowser: Binding<Bool> = .constant(false)
    ) {
        self.title = title
        self.boxName = boxName
        self.status = status
        self.stripViewModel = stripViewModel
        self.onOpenSubChat = onOpenSubChat
        self.onCompact = onCompact
        self.showSummaries = showSummaries
        self.popoverContent = popoverContent
        self.showMediaBrowser = showMediaBrowser
    }

    var body: some ToolbarContent {
        if status?.model != nil || status?.context != nil || status?.vitals != nil {
            ToolbarItem(placement: .navigation) {
                cluster { modelContextCluster }
            }
        }
        ToolbarItem(placement: .principal) {
            cluster {
                // Tappable title → summaries TOC popover (jump-to-point
                // nav), same affordance as iOS's tappable title → sheet.
                // `.buttonStyle(.plain)` is mandatory here (see header) —
                // the default button style breaks the system glass
                // capsule this cluster renders inside.
                Button { showSummaries.wrappedValue = true } label: { titleCluster }
                    .buttonStyle(.plain)
                    .help("Show conversation summaries")
                    .accessibilityHint("Shows conversation summaries")
                    .popover(isPresented: showSummaries, arrowEdge: .bottom) {
                        popoverContent()
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
            if let model = status?.model {
                Text(model)
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
            Text(title)
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
