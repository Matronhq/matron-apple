import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Mac chat detail column toolbar (per spec §5.9). Layout:
/// - Left: sidebar toggle (mirrors ⌘⇧S — the menu item in Task 14e fires
///   the same `.toggleSidebar` notification, so trackpad-only Macs without
///   the hardware shortcut still have a click-target)
/// - Center: chat title + `session_meta` strip (model · workdir, etc) —
///   the metadata strip is a placeholder until Phase 5 wires session meta
/// - Right: refresh button (⌘R), search field placeholder, ⓘ info button
///
/// Refresh fires the same `NotificationCenter.matronCommand(.refresh)` the
/// menu bar uses, but also calls `viewModel.refresh()` directly so the
/// trackpad path doesn't depend on the listener being attached. Search is
/// a placeholder text field — full search lands in Phase 6.
@MainActor
struct MacChatToolbar: ToolbarContent {
    let title: String
    let viewModel: ChatViewModel
    let onShowBotProfile: () -> Void
    @State private var searchText: String = ""

    var body: some ToolbarContent {
        // Left: sidebar toggle. Posts to the command bus so the menu-bar
        // entry (Task 14e) and this button stay in sync via a single
        // observer site (typically `MatronMacApp` on `MacChatListView`'s
        // `NavigationSplitView` column visibility — Phase 5+ wiring).
        ToolbarItem(placement: .navigation) {
            Button {
                NotificationCenter.default.post(name: .matronCommand(.toggleSidebar), object: nil)
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar (⌘⇧S)")
        }

        // Center: chat title + session_meta strip placeholder.
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text("Session metadata appears here in Phase 5")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        // Right: refresh + search + ⓘ.
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            // Phase 6 wires `.matronCommand(.findInChat)` (Task 14e) to
            // focus this field. Until then the field is decorative — but
            // present so the toolbar layout matches §5.9.
            TextField("Search chat…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 200)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { onShowBotProfile() } label: {
                Image(systemName: "info.circle")
            }
            .help("Bot profile")
        }
    }
}
