import SwiftUI

/// Command bus keys for Mac menu-bar shortcuts. Each menu / keyboard-shortcut
/// posts a corresponding `Notification`; views observe via
/// `.onReceive(NotificationCenter.default.publisher(for: .matronCommand(.case)))`.
///
/// We post through `NotificationCenter` rather than holding a singleton
/// "command bus" type so the relevant view (chat-list, chat-detail,
/// settings) can register / deregister its handler with normal SwiftUI
/// lifecycle hooks. The `Notification.Name` is the contract: stable,
/// distinct, namespaced under `chat.matron.command.*`.
public enum MatronCommand: String, CaseIterable, Sendable {
    case newChat
    case signOut
    case slashCommand
    case toggleSidebar
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case refresh
    /// App shell (spec §5): nav-column selection — ⌘1 … ⌘5, top to
    /// bottom (`ChatCommands.navShortcuts`).
    case showCoordinator
    case showMissions
    case showDecisions
    case showConversations
    case showMemories
}

public extension Notification.Name {
    /// Constructs a stable, distinct `Notification.Name` per `MatronCommand`
    /// case. The key prefix scopes notifications to Matron so the global
    /// `NotificationCenter` doesn't collide with anything else (SDK,
    /// system, third parties).
    static func matronCommand(_ cmd: MatronCommand) -> Notification.Name {
        Notification.Name("chat.matron.command.\(cmd.rawValue)")
    }
}

/// Mounted on the main scene as `.commands { ChatCommands() }`. Each
/// button posts a `Notification` to the command bus; the View layer
/// listens for the cases it cares about.
///
/// Listener wiring as of Phase-2 close (QA finding #2):
///   - `.newChat`        — `MacChatListView` (toolbar `+` button mirrors the shortcut)
///   - `.signOut`        — `MatronMacApp` (clears session + caches)
///   - `.toggleSidebar`  — `MacChatListView` (flips `NavigationSplitViewVisibility`)
///   - `.slashCommand`   — `MacChatView` (toggles `composerVM.palettePinnedOpen`)
///   - `.refresh`        — `MacChatView` (triggers `viewModel.refresh()`)
///   - `.showCoordinator/.showMissions/.showDecisions/.showConversations` — `MacChatListView` (sets `nav`)
///
/// Posted-but-unhandled (placeholder menu items, listeners land later):
///   - `.increase/decrease/resetFontSize` — Phase 5+ design-system font scaling.
///
/// Find in Chat / Search All Chats are per window (`MacNavigationActions`),
/// not bus commands: a post would open the bar in every window.
///
/// Task 12 dropped the Help menu's `.verifyDevice` / `.showRecoveryKey`
/// items (and their listeners) along with the rest of the verification
/// UI — the journal stack has no verification concept yet.
struct ChatCommands: Commands {
    /// The key window's Back/Forward (spec 2026-09-23 §5), published by
    /// its `MacChatListView`. Read from the focused scene instead of posted
    /// on the bus: history is per window, and a bus post would move every
    /// open window (PR #233 review I1).
    @FocusedValue(\.macNavigation) private var navigation

    var body: some Commands {
        // File menu — `.newItem` is the system "New" group; we replace
        // it with our `New Chat` so the keyboard shortcut binds cleanly.
        // Use `.after(.newItem)` instead of replacing the whole group so
        // the system "New Window" item stays available (QA finding #20).
        CommandGroup(after: .newItem) {
            Button("New Chat") { post(.newChat) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Sign Out…") { post(.signOut) }
        }

        // Edit menu — `.pasteboard` group is "Cut/Copy/Paste"; we add
        // our chat-specific Find + Slash Command after it.
        CommandGroup(after: .pasteboard) {
            // The key window's chat with focus — per
            // window like Back/Forward, so not a bus command.
            Button("Find in Chat") { navigation?.findInChat?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(navigation?.findInChat == nil)
            // The sidebar's search-all-chats field — ⌘F's job before Find
            // in Chat took it over whenever a chat is on screen.
            Button("Search All Chats") { navigation?.searchAllChats?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(navigation?.searchAllChats == nil)
            Button("Slash Command") { post(.slashCommand) }
                .keyboardShortcut("k", modifiers: .command)
        }

        // View menu — `.sidebar` is the system sidebar group; we add
        // our toggle (mirrors ⌘⇧S) and font-size shortcuts after it.
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { post(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            ForEach(Self.navShortcuts, id: \.nav) { shortcut in
                Button(shortcut.title) { post(shortcut.command) }
                    .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: .command)
            }
            Divider()
            // TODO Phase 5: wire font-size commands to a design-system
            // scale environment; today the listeners are missing so the
            // menu items / shortcuts post into the void.
            Button("Increase Font Size") { post(.increaseFontSize) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { post(.decreaseFontSize) }
                .keyboardShortcut("-", modifiers: .command)
            // No shortcut: its listener never landed.
            Button("Reset Font Size") { post(.resetFontSize) }
        }

        // Go menu — the key window's navigation history (spec 2026-09-23
        // §5). Greyed out when that window has nothing to go back or
        // forward to, or no window is key.
        CommandMenu("Go") {
            Button("Back") { navigation?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(navigation?.canGoBack != true)
            Button("Forward") { navigation?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(navigation?.canGoForward != true)
            if let navigation, !navigation.pinnedDesks.isEmpty {
                Divider()
                ForEach(Array(Self.deskShortcuts(navigation.pinnedDesks).enumerated()), id: \.offset) { _, desk in
                    Button(desk.label) { navigation.showPinnedDesk?(desk.id) }
                        .keyboardShortcut(KeyEquivalent(desk.key), modifiers: [.control, .command])
                }
            }
        }
    }

    private func post(_ cmd: MatronCommand) {
        NotificationCenter.default.post(name: .matronCommand(cmd), object: nil)
    }

    /// Go-menu items for the pinned desks: ⌃⌘1 … ⌃⌘9 in the user's order
    /// (the journal allows five).
    static func deskShortcuts(_ desks: [(id: String, label: String)]) -> [(id: String, label: String, key: Character)] {
        desks.prefix(9).enumerated().map { index, desk in
            (desk.id, desk.label, Character(String(index + 1)))
        }
    }

    /// One View-menu item per nav entry, ⌘1 … ⌘5 top to bottom.
    struct NavShortcut {
        let nav: MacNav
        let command: MatronCommand
        let key: Character
        var title: String { nav.title }
    }

    static let navShortcuts: [NavShortcut] = [
        NavShortcut(nav: .coordinator, command: .showCoordinator, key: "1"),
        NavShortcut(nav: .missions, command: .showMissions, key: "2"),
        NavShortcut(nav: .decisions, command: .showDecisions, key: "3"),
        NavShortcut(nav: .conversations, command: .showConversations, key: "4"),
        NavShortcut(nav: .memories, command: .showMemories, key: "5"),
    ]
}

/// A window's Back/Forward, published to the menu bar with
/// `focusedSceneValue` so ⌘[ / ⌘] act on the key window only.
struct MacNavigationActions {
    var canGoBack: Bool
    var canGoForward: Bool
    var goBack: () -> Void
    var goForward: () -> Void
    /// Edit ▸ Find in Chat: the in-chat search bar on
    /// this window's chat — see `MacFindInChatRouting`.
    var findInChat: (() -> Void)? = nil
    /// Edit ▸ Search All Chats: this window's sidebar search field.
    var searchAllChats: (() -> Void)? = nil
    /// This window's pinned desk chats (id, label), in the user's order:
    /// Go ▸ one item each, ⌃⌘1 … ⌃⌘5 (⌘1 … ⌘5 are the fixed entries').
    var pinnedDesks: [(id: String, label: String)] = []
    var showPinnedDesk: ((String) -> Void)? = nil
}

extension FocusedValues {
    @Entry var macNavigation: MacNavigationActions?
}
