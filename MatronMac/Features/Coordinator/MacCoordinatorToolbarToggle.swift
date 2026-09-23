import SwiftUI

/// The Coordinator panel's toolbar button (Coordinator redesign §3b). In
/// the SIDEBAR column's `.toolbar` with `.automatic` placement, beside
/// Back/Forward: an item under the chat header accessory would be clipped
/// into the `»` overflow (#2608).
struct MacCoordinatorToolbarToggle: ToolbarContent {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: toggle) { Image(systemName: "person.crop.circle.badge.checkmark") }
                .help(isOpen ? "Hide Coordinator (⌘0)" : "Show Coordinator (⌘0)")
                .accessibilityLabel(isOpen ? "Hide Coordinator" : "Show Coordinator")
        }
    }
}
