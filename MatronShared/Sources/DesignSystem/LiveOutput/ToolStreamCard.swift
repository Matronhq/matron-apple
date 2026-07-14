import SwiftUI

/// Live tool-output tile for the journal `tool_stream` overlay — the
/// ephemeral sibling of `LiveOutputCard`, fed accumulated stream text by the
/// timeline instead of owning a socket. It has no terminal states: the tile
/// only exists while the command runs; completion replaces it with the
/// durable row's `ToolCallCard`.
public struct ToolStreamCard: View {
    private let command: String?
    private let text: String
    private let headTruncated: Bool
    @State private var expanded: Bool

    /// `initiallyExpanded` exists for previews/snapshots; product code uses
    /// the default collapsed start.
    public init(command: String?, text: String, headTruncated: Bool,
                initiallyExpanded: Bool = false) {
        self.command = command
        self.text = text
        self.headTruncated = headTruncated
        _expanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TerminalPane(output: rendered, expanded: expanded)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live command output: \(command ?? "running command"). running")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(command.map { "$ \($0.replacingOccurrences(of: "\n", with: " ⏎ "))" } ?? "live output")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("running…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse output" : "Expand output")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Full re-parse per text change: the timeline caps display text at
    /// 64 KiB (JournalTimelineMapper.toolStreamText), so a stateful
    /// incremental parse isn't worth carrying UI-side state for.
    private var rendered: AttributedString {
        var out = AttributedString()
        if headTruncated {
            var notice = AttributedString("… earlier output truncated\n")
            // Fixed dim gray, not semantic .secondary: the pane's palette is
            // hard-coded dark in both app themes, so a semantic color would
            // render near-black-on-black in light mode.
            notice.foregroundColor = Color(red: 0.55, green: 0.55, blue: 0.55)
            out += notice
        }
        var parser = AnsiSGRParser()
        out += parser.append(text)
        return out
    }
}
