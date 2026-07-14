import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat detail column toolbar. Layout:
/// - Center: context gauge (left of title) — title — usage bars (right of title)
///
/// The refresh button was dropped after the journal rewire: it only ran
/// `ChatViewModel.refresh()` (= `paginateBackward`, an OLDER-history
/// fetch) while new messages ride the live socket — a Matrix-era leftover
/// with no user-visible effect. The menu bar's ⌘R still posts
/// `.matronCommand(.refresh)` for the listener in `MacChatView`. The
/// decorative "Search chat…" placeholder field went with it — real search
/// lives at the top of the sidebar, and a second dead field in the header
/// only invited clicks that did nothing. The "session metadata" caption
/// placeholder is gone too; if `session_meta` lands, it can return under
/// the title with real content.
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
    /// Last-known session status for the open convo — context gauge
    /// renders left of the title, usage bars right of it. Nil (no status
    /// frame yet) renders the title alone.
    let status: SessionStatus?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 14) {
                if let context = status?.context {
                    ContextGaugeLabel(context: context)
                        .layoutPriority(1)
                }
                // Horizontal padding so the title doesn't butt against the
                // rounded ends of the macOS 26 glass toolbar-item capsule.
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let limits = status?.limits, !limits.isEmpty {
                    UsageBarsView(limits: limits, scale: .compact)
                        .layoutPriority(1)
                }
            }
        }
    }
}
