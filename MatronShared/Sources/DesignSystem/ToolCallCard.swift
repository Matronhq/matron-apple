import SwiftUI
import MatronEvents

/// Collapsible card for a `chat.matron.tool_call` event (spec §4.1).
///
/// Collapsed: status icon + tool name + one-line arg summary. Tap (click on
/// Mac) to expand into the full pretty-printed arguments and result blocks.
/// On macOS only, hovering a collapsed card surfaces a "Click to expand"
/// hint and a pointing-hand cursor (spec §5.9) — iOS has no hover state, so
/// that branch is compiled out there.
public struct ToolCallCard: View {
    let event: ToolCallEvent
    @State private var expanded: Bool
    @State private var isHovering: Bool
    /// True while we owe AppKit's cursor stack a pop — set on the hover
    /// push, cleared by the unhover/onDisappear pop. See the `.onHover`
    /// doc-comment for why this isn't just `isHovering`.
    @State private var cursorPushed = false

    /// `expanded` defaults to `false` for production tap-toggle behaviour.
    /// Callers (notably snapshot tests) may pass `true` to render the
    /// expanded state directly. `forceHovered` forces the Mac hover hint on
    /// for deterministic snapshot rendering — production callers leave it at
    /// `false`. Ignored on iOS (no hover state).
    public init(event: ToolCallEvent, expanded: Bool = false, forceHovered: Bool = false) {
        self.event = event
        self._expanded = State(initialValue: expanded)
        self._isHovering = State(initialValue: forceHovered)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    statusIcon
                    Text(event.tool).font(.system(.callout, design: .monospaced)).bold()
                    if let badge = outcomeBadge {
                        Text(badge)
                            .font(.caption2).bold()
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.red.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text(event.argSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    #if os(macOS)
                    if !expanded && isHovering {
                        Text("Click to expand")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    #endif
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            // `.pointerStyle(.link)` would be the modern spelling but needs
            // macOS 15; the package targets macOS 14, so push/pop the cursor
            // by hand on hover. SwiftUI doesn't guarantee a final
            // `onHover(false)` when the view leaves the hierarchy mid-hover
            // (scrolled off, or the row replaced by an `m.replace` update
            // landing on a hovered running card), so `cursorPushed` tracks
            // the unbalanced push and `.onDisappear` pops it. `isHovering`
            // can't double as the flag: `forceHovered` seeds it true with
            // no matching push.
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                } else if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            #endif

            if expanded {
                if !event.argsJSON.isEmpty && event.argsJSON != "{}" {
                    // Bash shape shows the raw command; other tools keep the
                    // pretty-printed JSON under the same "Command" heading.
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("Command")
                        codeView(event.commandString ?? event.argsJSON)
                    }
                }
                if event.expired {
                    // Binding client rule (matron-journal protocol.md): the
                    // output was purged after the 24h tool-log TTL — command
                    // and exit code stay, no snippet area, no fetch button.
                    Label("Output expired", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else if let result = event.resultText {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("Result\(event.resultTruncated ? " (truncated)" : "")")
                        terminalView(result)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.matronCodeBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch event.status {
        case .running: ProgressView().scaleEffect(0.7).frame(width: 12, height: 12)
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .error:   Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
        }
    }

    /// "denied" / "exit N" pill next to the tool name for failed commands.
    /// A zero exit code shows nothing — the green check already says it.
    private var outcomeBadge: String? {
        if event.denied { return "denied" }
        if let code = event.exitCode, code != 0 { return "exit \(code)" }
        return nil
    }

    /// Section heading. No `.padding(.top, …)` — the heading and its block
    /// are grouped in a tight `spacing: 2` VStack by the caller, and the
    /// outer VStack's `spacing: 8` supplies the gap between sections.
    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary)
    }

    /// Light-surfaced code block — the "Command" block's home.
    private func codeView(_ s: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(s).font(.system(.caption, design: .monospaced))
                .padding(8)
        }
        .background(Color.matronCardInnerBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Terminal-style result block: light monospace on the shared dark
    /// `TerminalStyle` palette, matching the legacy live-output pane.
    private func terminalView(_ s: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(s).font(.system(.caption, design: .monospaced))
                .foregroundStyle(TerminalStyle.foreground)
                .padding(8)
        }
        .background(TerminalStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private extension Color {
    /// Inner code-block background that contrasts with the card's
    /// `matronCodeBg` surface. `Color(.systemBackground)` is iOS-only,
    /// same cross-platform split as the aliases in MarkdownText.swift.
    #if canImport(UIKit) && !os(macOS)
    static let matronCardInnerBg = Color(.systemBackground)
    #elseif os(macOS)
    static let matronCardInnerBg = Color(nsColor: .textBackgroundColor)
    #endif
}
