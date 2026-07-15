import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat detail column toolbar. Layout — three separate toolbar items,
/// each in its own glass capsule (Dan, 2026-07-15: "separate bubbles"):
/// - Leading: model name above the context gauge
/// - Center: title (+ account email underneath when known)
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

    /// One height for all three clusters so the system's content-hugging
    /// glass capsules come out equal and align as a row. Sized to the
    /// tallest content: three compact usage rows (3 × ~11pt lines +
    /// 2 × 2pt spacing ≈ 37pt).
    private static let clusterHeight: CGFloat = 38

    var body: some ToolbarContent {
        if status?.model != nil || status?.context != nil {
            ToolbarItem(placement: .navigation) {
                cluster { modelContextCluster }
            }
        }
        ToolbarItem(placement: .principal) {
            cluster { titleCluster }
        }
        if let limits = status?.limits, !limits.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                cluster { UsageBarsView(limits: limits, scale: .compact) }
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
            if let model = status?.model {
                Text(model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let context = status?.context {
                ContextGaugeLabel(context: context)
            }
        }
    }

    private var titleCluster: some View {
        // The bridge machine's logged-in account email rides under
        // the title when the status frame carries it.
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            if let email = status?.email {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
