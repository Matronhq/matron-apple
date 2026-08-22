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

    /// How much of the stream tail a COLLAPSED pane renders. The timeline
    /// caps delivered text at 64 KiB (JournalTimelineMapper.toolStreamText),
    /// and re-parsing + re-laying-out all of it on every append is what a
    /// live command's card cost the main thread several times a second —
    /// while the collapsed pane is 76pt tall and shows ~5 lines. 4 KiB is
    /// hundreds of terminal lines, far more than the pane can scroll into
    /// view before the next append lands. Expanding renders the full tail.
    static let collapsedDisplayCapChars = 4096

    /// The slice of `text` a collapsed pane renders: the last
    /// `collapsedDisplayCapChars` characters, opened at a line boundary.
    /// `cut` reports whether anything was dropped (the caller shows the
    /// truncation notice). Internal + static so tests can pin the cap
    /// and the line-boundary contract without a snapshot.
    static func collapsedSlice(of text: String) -> (text: Substring, cut: Bool) {
        // `index(_:offsetBy:limitedBy:)` walks at most cap+1 graphemes instead
        // of counting the whole 64 KiB live buffer on every streamed chunk.
        // Exactly equivalent to `text.count > collapsedDisplayCapChars`: a nil
        // result means shorter than the cap, and landing on `endIndex` means
        // exactly the cap.
        let overCap = text.index(text.startIndex, offsetBy: collapsedDisplayCapChars,
                                 limitedBy: text.endIndex).map { $0 < text.endIndex } ?? false
        guard overCap else { return (text[...], false) }
        var shown = text.suffix(collapsedDisplayCapChars)
        // Drop the (almost certainly partial) first line so the cut never
        // opens mid-word or inside a split ANSI escape sequence — but only
        // when that line ends within the first few hundred characters.
        // Terminal lines are short; a newline that far in means the tail is
        // effectively one giant line, and trimming through it would throw
        // away most (or, when the only newline is the final character, ALL)
        // of the visible text (Bugbot, PR #130).
        let scanEnd = shown.index(shown.startIndex, offsetBy: min(512, shown.count))
        if let newline = shown[..<scanEnd].firstIndex(of: "\n") {
            shown = shown[shown.index(after: newline)...]
        }
        return (shown, true)
    }

    /// Full re-parse per text change: a stateful incremental parse isn't
    /// worth carrying UI-side state for at these sizes (collapsed 4 KiB,
    /// expanded 64 KiB max).
    private var rendered: AttributedString {
        var shown = text[...]
        var cut = headTruncated
        if !expanded {
            let sliced = Self.collapsedSlice(of: text)
            shown = sliced.text
            cut = cut || sliced.cut
        }
        var out = AttributedString()
        if cut {
            var notice = AttributedString("… earlier output truncated\n")
            // Fixed dim gray, not semantic .secondary: the pane's palette is
            // hard-coded dark in both app themes, so a semantic color would
            // render near-black-on-black in light mode.
            notice.foregroundColor = Color(red: 0.55, green: 0.55, blue: 0.55)
            out += notice
        }
        var parser = AnsiSGRParser()
        out += parser.append(String(shown))
        return out
    }
}
