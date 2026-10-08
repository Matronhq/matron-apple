import SwiftUI

/// Shared dark-terminal palette for the legacy live-output pane
/// (`TerminalPane`) and the journal tool_output result block
/// (`ToolCallCard`): a fixed dark surface with light monospace text so the
/// terminal look reads identically in both app themes. Kept in one place so
/// the two call sites can't drift apart.
enum TerminalStyle {
    /// Dark panel background.
    static let background = Color(red: 0.12, green: 0.12, blue: 0.12)
    /// Light monospace foreground.
    static let foreground = Color(red: 0.86, green: 0.86, blue: 0.86)
    /// Diff added/removed line colors (`DiffCard`) — the same green/red the
    /// ANSI live-output palette uses (`AnsiSGRParser`), fixed rather than
    /// system `.green`/`.red` because those resolve to their dark, light-
    /// scheme variants when the app is light while this surface stays dark.
    static let diffAdded = Color(red: 0.45, green: 0.82, blue: 0.45)
    static let diffRemoved = Color(red: 0.90, green: 0.35, blue: 0.35)
    /// Dimmed foreground for structural lines (diff `@@` hunk headers) —
    /// `.secondary` is likewise scheme-adaptive and near-invisible here.
    static let dimForeground = Color(red: 0.55, green: 0.55, blue: 0.55)
}
