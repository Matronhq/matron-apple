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
    case findInChat
    case slashCommand
    case toggleSidebar
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case verifyDevice
    case showRecoveryKey
    case refresh
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
///
/// Posted-but-unhandled (placeholder menu items, listeners land later):
///   - `.findInChat`            — Phase 6 wires SearchService; today the
///                                Mac toolbar's search field is decorative.
///   - `.increase/decrease/resetFontSize` — Phase 5+ design-system font scaling.
///   - `.verifyDevice`, `.showRecoveryKey` — Phase 3 (E2EE + verification UX).
///
/// Help-menu items ship now so the menu-bar shape is testable end-to-end;
/// their listeners will land in Phase 3.
struct ChatCommands: Commands {
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
            // TODO Phase 6: wire `.findInChat` to focus the chat search
            // field; today the listener is missing so the menu item / ⌘F
            // post into the void.
            Button("Find in Chat") { post(.findInChat) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Slash Command") { post(.slashCommand) }
                .keyboardShortcut("k", modifiers: .command)
        }

        // View menu — `.sidebar` is the system sidebar group; we add
        // our toggle (mirrors ⌘⇧S) and font-size shortcuts after it.
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { post(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            // TODO Phase 5: wire font-size commands to a design-system
            // scale environment; today the listeners are missing so the
            // menu items / shortcuts post into the void.
            Button("Increase Font Size") { post(.increaseFontSize) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { post(.decreaseFontSize) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Font Size") { post(.resetFontSize) }
                .keyboardShortcut("0", modifiers: .command)
        }

        // Help menu — Phase 3 wires the actual flows; Phase 2 just adds
        // the items so the menu-bar shape is testable end-to-end.
        CommandGroup(replacing: .help) {
            // TODO Phase 3: wire to the verification + recovery-key flows.
            Button("Verify This Device…") { post(.verifyDevice) }
            Button("Show Recovery Key…") { post(.showRecoveryKey) }
        }
    }

    private func post(_ cmd: MatronCommand) {
        NotificationCenter.default.post(name: .matronCommand(cmd), object: nil)
    }
}
