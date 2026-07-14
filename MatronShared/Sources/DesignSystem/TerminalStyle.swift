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
}
