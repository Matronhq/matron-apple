import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Mac chat detail column toolbar (per spec §5.9). Layout:
/// - Center: chat title + `session_meta` strip (model · workdir, etc) —
///   the metadata strip is a placeholder until Phase 5 wires session meta
/// - Right: refresh button (⌘R), search field placeholder, ⓘ info button
///
/// Refresh fires the same `NotificationCenter.matronCommand(.refresh)` the
/// menu bar uses, but also calls `viewModel.refresh()` directly so the
/// trackpad path doesn't depend on the listener being attached. Search is
/// a placeholder text field — full search lands in Phase 6.
///
/// Wave 6 / live-test #4: removed the leading `ToolbarItem(.navigation)`
/// sidebar-toggle button. `NavigationSplitView` already renders its own
/// system sidebar-toggle button inside the sidebar column on macOS;
/// duplicating it on the detail column's toolbar produced two toggle
/// buttons in the window header. The menu-bar entry (`Commands.swift`)
/// + the ⌘⇧S shortcut still reach the same `.toggleSidebar` listener on
/// `MacChatListView`.
@MainActor
struct MacChatToolbar: ToolbarContent {
    let title: String
    let viewModel: ChatViewModel
    let onShowBotProfile: () -> Void
    // TODO Phase 6: wire this to `SearchService`. Today the binding is
    // intentionally non-functional — the toolbar field exists so the §5.9
    // layout is observable end-to-end. Reviewers seeing an unused
    // `@State` should not "clean it up" (QA finding #14).
    @State private var searchText: String = ""

    var body: some ToolbarContent {
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
