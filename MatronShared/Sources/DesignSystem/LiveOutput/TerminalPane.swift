import SwiftUI

/// Terminal-style output pane shared by `LiveOutputCard` (legacy viewer
/// WebSocket) and `ToolStreamCard` (journal tool_stream overlay): fixed dark
/// palette in both app themes so ANSI colors read the same everywhere;
/// `defaultScrollAnchor(.bottom)` gives sticky-tail behavior — pinned to the
/// newest output unless the user scrolls up, matching the web tile.
struct TerminalPane: View {
    let output: AttributedString
    let expanded: Bool

    var body: some View {
        ScrollView {
            Text(output)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TerminalStyle.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: expanded ? 600 : 76)
        .background(TerminalStyle.background)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7))
    }
}
