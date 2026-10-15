import SwiftUI
import MatronEvents

/// The timeline row for a bridge notice about a turn it injected (a
/// consent request, a routine fire, a room message…): one quiet line —
/// chevron, icon, summary, time — styled like `CoordinatorNotice`. Tap
/// (click on Mac) to show the full text, line breaks kept; lines written
/// only for the agent stay out of sight until then. Expansion is the row's
/// own state, like `ToolCallCard`.
public struct SystemNoticeRow: View {
    let notice: SystemNoticeEvent
    let timestamp: Date?
    @State private var expanded: Bool
    #if os(macOS)
    /// True while we owe AppKit's cursor stack a pop (see `ToolCallCard`).
    @State private var cursorPushed = false
    #endif

    /// `expanded` defaults to `false`; snapshot tests pass `true` to render
    /// the open state directly.
    public init(notice: SystemNoticeEvent, timestamp: Date? = nil, expanded: Bool = false) {
        self.notice = notice
        self.timestamp = timestamp
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(notice.icon).font(.caption)
                    Text(notice.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let timestamp {
                        Text(timestamp, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(notice.summary)
            .accessibilityHint(expanded ? "Hides the full text" : "Shows the full text")
            #if os(macOS)
            .onHover { hovering in
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

            if expanded && !notice.body.isEmpty {
                Text(notice.body)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                    }
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }
}
