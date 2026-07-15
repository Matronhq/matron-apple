import SwiftUI
import MatronEvents

/// Card for a journal `diff` event — a file-edit snippet with the filename
/// in the header (tappable link to the bridge's signed viewer URL when one
/// was supplied) and prefix-colored unified-diff lines in the body, on the
/// fixed dark `TerminalStyle` surface so diffs read like the tool-output
/// result panel in both app themes.
/// Collapsed shows the first `collapsedLineCount` lines with a "+N more
/// lines" row; the chevron expands to the full diff (the bridge caps it at
/// 400 lines, so no client-side windowing is needed).
public struct DiffCard: View {
    let event: DiffEvent
    @State private var expanded: Bool

    static let collapsedLineCount = 12

    /// `expanded` defaults to false for the production tap-toggle; snapshot
    /// tests pass true to render the expanded state directly (same pattern
    /// as `ToolCallCard`).
    public init(event: DiffEvent, expanded: Bool = false) {
        self.event = event
        self._expanded = State(initialValue: expanded)
    }

    private var allLines: [Substring] {
        event.diff.isEmpty ? [] : event.diff.split(separator: "\n", omittingEmptySubsequences: false)
    }

    public var body: some View {
        let lines = allLines
        let visible = expanded ? lines : Array(lines.prefix(Self.collapsedLineCount))
        let hidden = lines.count - visible.count

        VStack(alignment: .leading, spacing: 8) {
            header
            if !visible.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(rendered(visible))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(TerminalStyle.foreground)
                        .padding(8)
                }
                // Fitting content must not rubber-band sideways — it reads
                // as the whole timeline wiggling (see CodeBlock).
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .background(TerminalStyle.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if hidden > 0 {
                Button { expanded = true } label: {
                    Text("+\(hidden) more line\(hidden == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if expanded && event.truncated {
                Text("… diff truncated")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.matronCodeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: event.newFile ? "doc.badge.plus" : "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            filenameView

            if let label = event.label {
                Text(label).font(.caption).italic().foregroundStyle(.secondary).lineLimit(1)
            }
            if event.newFile {
                Text("new file")
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.green.opacity(0.12))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
            counts
            if event.truncated {
                Text("…")
                    .font(.caption2).bold().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Filename links to the signed viewer URL when the bridge supplied
    /// one; plain text otherwise (viewer unconfigured). Separate hit
    /// target from the expand chevron. Falls back to the tool name when
    /// the payload carried no path (legacy bare shape).
    @ViewBuilder
    private var filenameView: some View {
        let name = event.filename ?? event.tool ?? "diff"
        if let url = event.viewerURL {
            Link(destination: url) {
                Text(name)
                    .font(.system(.callout, design: .monospaced)).bold()
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(name)
                .font(.system(.callout, design: .monospaced)).bold()
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 4) {
            if let added = event.added {
                Text("+\(added)").font(.caption2).bold().foregroundStyle(.green)
            }
            if let removed = event.removed {
                Text("−\(removed)").font(.caption2).bold().foregroundStyle(.red)
            }
        }
    }

    /// One AttributedString for the whole visible block — a per-line Text
    /// stack at 400 lines is exactly the kind of view-count blowup the
    /// blank-chat saga taught us to avoid.
    private func rendered(_ lines: [Substring]) -> AttributedString {
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            var run = AttributedString(String(line))
            if line.hasPrefix("+") {
                run.foregroundColor = TerminalStyle.diffAdded
            } else if line.hasPrefix("-") {
                run.foregroundColor = TerminalStyle.diffRemoved
            } else if line.hasPrefix("@@") {
                run.foregroundColor = TerminalStyle.dimForeground
            }
            out += run
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    /// Full VoiceOver summary — write/create wording plus add/remove
    /// counts. Public (and static, over `event`) so callers that wrap this
    /// card in their own `.accessibilityElement(children: .combine)` +
    /// `.accessibilityLabel` — the chat timeline rows, on both iOS and
    /// Mac — can reuse the exact same string instead of duplicating a
    /// shorter one. A row-level label silently REPLACES this card's own
    /// combined accessibility value rather than appending to it, so any
    /// duplicate string there was the timeline's only chance to say
    /// anything beyond "Edited <file>" (bugbot: "VoiceOver drops the rich
    /// diff summary").
    public static func accessibilitySummary(for event: DiffEvent) -> String {
        let verb = event.tool == "Write" ? (event.newFile ? "Created" : "Wrote") : "Edited"
        let name = event.filename ?? "file"
        var parts = ["\(verb) \(name)"]
        if let a = event.added { parts.append("\(a) addition\(a == 1 ? "" : "s")") }
        if let r = event.removed { parts.append("\(r) removal\(r == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private var accessibilitySummary: String {
        Self.accessibilitySummary(for: event)
    }
}
