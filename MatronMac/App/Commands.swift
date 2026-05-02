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
/// listens for the cases it cares about. Help-menu items are placeholders
/// for Phase 3 (verification + recovery key flows) — they post their
/// notifications today, but the listeners will land in Phase 3.
struct ChatCommands: Commands {
    var body: some Commands {
        // File menu — `.newItem` is the system "New" group; we replace
        // it with our `New Chat` so the keyboard shortcut binds cleanly
        // and "Sign Out…" lands directly underneath via `.after(.newItem)`.
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { post(.newChat) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Sign Out…") { post(.signOut) }
        }

        // Edit menu — `.pasteboard` group is "Cut/Copy/Paste"; we add
        // our chat-specific Find + Slash Command after it.
        CommandGroup(after: .pasteboard) {
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
            Button("Verify This Device…") { post(.verifyDevice) }
            Button("Show Recovery Key…") { post(.showRecoveryKey) }
        }
    }

    private func post(_ cmd: MatronCommand) {
        NotificationCenter.default.post(name: .matronCommand(cmd), object: nil)
    }
}
