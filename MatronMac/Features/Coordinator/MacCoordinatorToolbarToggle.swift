import SwiftUI
import MatronChat

/// The Coordinator panel's toolbar button (Coordinator redesign §3b). In
/// the SIDEBAR column's `.toolbar` with `.automatic` placement, beside
/// Back/Forward: an item under the chat header accessory would be clipped
/// into the `»` overflow (#2608).
struct MacCoordinatorToolbarToggle: ToolbarContent {
    let isOpen: Bool
    /// The Coordinator is hidden from Conversations, so its unread signal
    /// rides here — the dot iOS's floating button has (final review I4).
    var hasUnread: Bool = false
    let toggle: () -> Void

    static func hasUnread(_ coordinatorSummary: ChatSummary?) -> Bool {
        (coordinatorSummary?.unreadCount ?? 0) > 0
    }

    static func accessibilityLabel(isOpen: Bool, hasUnread: Bool) -> String {
        let base = isOpen ? "Hide Coordinator" : "Show Coordinator"
        return hasUnread ? base + ", unread messages" : base
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: toggle) { MacCoordinatorToggleIcon(hasUnread: hasUnread) }
                .help(isOpen ? "Hide Coordinator (⌘0)" : "Show Coordinator (⌘0)")
                .accessibilityLabel(Self.accessibilityLabel(isOpen: isOpen, hasUnread: hasUnread))
        }
    }
}

/// The toggle's icon, with a red unread dot at its top trailing corner.
struct MacCoordinatorToggleIcon: View {
    let hasUnread: Bool

    var body: some View {
        Image(systemName: "person.crop.circle.badge.checkmark")
            .overlay(alignment: .topTrailing) {
                if hasUnread {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                        .offset(x: 3, y: -2)
                }
            }
    }
}
