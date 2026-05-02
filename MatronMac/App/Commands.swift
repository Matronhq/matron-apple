import SwiftUI

/// Command bus keys for Mac menu-bar shortcuts. Each menu/keyboard-shortcut
/// posts a corresponding `Notification`; views observe via
/// `.onReceive(NotificationCenter.default.publisher(for: .matronCommand(.case)))`.
///
/// Task 14c landed `.refresh`; Task 14d adds `.toggleSidebar` for the
/// chat-toolbar sidebar button. Task 14e expands the enum to the full
/// set (newChat, signOut, findInChat, slashCommand, font-size cases,
/// verifyDevice, showRecoveryKey) and adds the `ChatCommands` struct +
/// `.commands { … }` mounting on the main scene.
public enum MatronCommand: String, CaseIterable, Sendable {
    case refresh
    case toggleSidebar
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
