import SwiftUI
import MatronEvents

/// A bulky timeline card folded to one quiet line, styled like
/// `SystemNoticeRow`: chevron, icon, summary, status, time. Tap (click on
/// Mac) the line to show `detail`, the whole card; actions that still need
/// the user (`trailing`, e.g. a reminder's Send now) stay on the line.
/// Expansion belongs to the card that owns the row, so it can render the
/// open state directly in snapshots.
public struct CompactCardRow<Trailing: View, Detail: View>: View {
    let line: CompactCardLine
    let timestamp: Date?
    @Binding var expanded: Bool
    let trailing: Trailing
    let detail: Detail
    #if os(macOS)
    /// True while we owe AppKit's cursor stack a pop (see `ToolCallCard`).
    @State private var cursorPushed = false
    #endif

    public init(line: CompactCardLine, timestamp: Date?, expanded: Binding<Bool>,
                @ViewBuilder trailing: () -> Trailing, @ViewBuilder detail: () -> Detail) {
        self.line = line
        self.timestamp = timestamp
        self._expanded = expanded
        self.trailing = trailing()
        self.detail = detail()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([line.summary, line.status].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
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
                trailing
                    .font(.caption)
                if let timestamp {
                    Text(timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if expanded {
                detail.padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(line.icon).font(.caption)
            Text(line.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let status = line.status {
                // The outcome is what the line is for: the summary gives way.
                Text("· \(status)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}
