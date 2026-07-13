import SwiftUI
import MatronEvents

/// Inline live command-output tile — the journal-protocol port of
/// matron-web's `MLiveOutputBody`. Header shows `$ <command>` with a
/// status label and an expand/collapse toggle; below it a pinned-dark
/// monospace pane streams the command's output live (ANSI colors
/// applied). Collapsed shows the last ~3 lines; expanded grows to a
/// bounded height and scrolls.
public struct LiveOutputCard: View {
    private let session: LiveOutputSession
    /// When the announcing event landed. Only tiles young enough that
    /// the command is plausibly STILL RUNNING auto-connect; historical
    /// tiles wait for the user to expand. Without this gate, scrolling
    /// through a command-heavy chat mounted a burst of tiles that each
    /// opened a viewer socket and replayed its whole log — visible as
    /// scroll lag.
    private let eventTimestamp: Date
    /// Auto-connect window. 10 minutes comfortably covers a long-running
    /// command that's still streaming when the user opens the chat.
    private static let autoConnectWindow: TimeInterval = 600
    @State private var expanded = false

    public init(session: LiveOutputSession, eventTimestamp: Date) {
        self.session = session
        self.eventTimestamp = eventTimestamp
    }

    private var command: String { session.event.command }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsPane {
                pane
            } else if let placeholder {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .task(id: session.event.toolUseID) {
            if Date().timeIntervalSince(eventTimestamp) < Self.autoConnectWindow {
                session.startIfNeeded()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command output: \(command). \(statusLabel)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("$ \(command.replacingOccurrences(of: "\n", with: " ⏎ "))")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            statusView
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                // Historical tiles defer loading until the user asks —
                // expanding is the ask. No-op if already started/terminal.
                if expanded { session.startIfNeeded() }
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

    /// Terminal-style pane: fixed dark palette in both app themes so
    /// ANSI colors read the same everywhere. `defaultScrollAnchor(.bottom)`
    /// gives sticky-tail behavior: pinned to the newest output unless the
    /// user scrolls up, matching the web tile.
    private var pane: some View {
        ScrollView {
            Text(session.output)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.86, green: 0.86, blue: 0.86))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: expanded ? 600 : 76)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7))
    }

    private var showsPane: Bool {
        if session.hasOutput { return true }
        // While live, show the (empty) pane so output has somewhere to
        // land without a layout jump; placeholder states take over once
        // we know nothing is coming.
        switch session.phase {
        case .connecting, .streaming: return true
        case .idle, .complete, .expired, .disconnected: return false
        }
    }

    private var placeholder: String? {
        switch session.phase {
        case .complete(_, let denied, _) where denied: return "Command not executed"
        case .complete: return "No output"
        case .expired: return "Output expired"
        case .disconnected: return "Output unavailable"
        default: return nil
        }
    }

    private var statusLabel: String {
        switch session.phase {
        case .idle: return "expand to view"
        case .connecting: return "connecting…"
        case .streaming: return "running…"
        case .complete(_, let denied, _) where denied: return "not executed"
        case .complete(let exitCode, _, let truncated):
            let base = (exitCode ?? 0) == 0 ? "✓ exit \(exitCode ?? 0)" : "✗ exit \(exitCode ?? -1)"
            return truncated ? base + " · truncated" : base
        case .expired: return "expired"
        case .disconnected: return "⚠ disconnected"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch session.phase {
        case .idle:
            // Deferred-load tile: no spinner — nothing is happening
            // until the user expands.
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .connecting, .streaming:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(statusLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .complete(let exitCode, let denied, _):
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(denied || (exitCode ?? 0) != 0 ? Color.orange : Color.secondary)
        case .expired, .disconnected:
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
