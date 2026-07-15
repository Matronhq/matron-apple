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
/// On macOS 26 the system's per-item glass is replaced with our own
/// `glassEffect` capsule (Dan, 2026-07-15 round 2): the three clusters
/// share one fixed height so their capsules vertically centre as a row
/// (the system capsules hug content, so the taller usage cluster hung
/// below the other two), the corner radius comes down from the system
/// pill to 10pt (matching the composer), and the content gets real
/// horizontal padding so "Session" doesn't touch the capsule edge.
/// Those APIs (`glassEffect`, `sharedBackgroundVisibility`) need the
/// macOS 26 SDK, which ships with Swift 6.2 — the `#if compiler` guard
/// keeps CI (Xcode 16.4 / macOS 15 SDK) compiling the plain layout.
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

    /// One height for all three clusters so their capsules align as a
    /// row. Sized to the tallest content: three compact usage rows
    /// (3 × ~11pt lines + 2 × 2pt spacing ≈ 37pt).
    private static let capsuleHeight: CGFloat = 38

    var body: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassItems
        } else {
            plainItems
        }
        #else
        plainItems
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    @ToolbarContentBuilder
    private var glassItems: some ToolbarContent {
        if status?.model != nil || status?.context != nil {
            ToolbarItem(placement: .navigation) {
                capsule { modelContextCluster }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem(placement: .principal) {
            capsule { titleCluster }
        }
        .sharedBackgroundVisibility(.hidden)
        if let limits = status?.limits, !limits.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                capsule { UsageBarsView(limits: limits, scale: .compact) }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// The custom capsule: fixed-height, centred content with enough
    /// horizontal padding that text clears the rounded corners.
    @available(macOS 26.0, *)
    private func capsule(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(height: Self.capsuleHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    }
    #endif

    /// Pre-macOS 26 fallback (and the CI-compiled shape): the same three
    /// items with plain padding, letting the system draw whatever item
    /// chrome the OS has.
    @ToolbarContentBuilder
    private var plainItems: some ToolbarContent {
        if status?.model != nil || status?.context != nil {
            ToolbarItem(placement: .navigation) {
                modelContextCluster
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
            }
        }
        ToolbarItem(placement: .principal) {
            titleCluster
                .padding(.horizontal, 12)
        }
        if let limits = status?.limits, !limits.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                UsageBarsView(limits: limits, scale: .compact)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
            }
        }
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
