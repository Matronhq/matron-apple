import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat detail column toolbar. Layout — three separate toolbar items,
/// each with its own macOS 26 glass capsule (Dan, 2026-07-15: "separate
/// bubbles"):
/// - Leading: model name above the context gauge
/// - Center: title (+ account email underneath when known)
/// - Trailing: usage bars
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
    /// Last-known session status for the open convo — model + context
    /// gauge render in the leading capsule, usage bars in the trailing
    /// one. Nil (no status frame yet) renders the title alone.
    let status: SessionStatus?

    var body: some ToolbarContent {
        // Each cluster gets horizontal padding so its text doesn't butt
        // against the rounded ends of its glass capsule.
        if status?.model != nil || status?.context != nil {
            ToolbarItem(placement: .navigation) {
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
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
        }
        ToolbarItem(placement: .principal) {
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
}
