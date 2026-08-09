import SwiftUI
import MatronChat

/// TOC popover content for the Mac title cluster (see `MacChatToolbar`):
/// one row per bridge summary pass, newest first. Rows expand to the
/// fuller rolling summary; tapping a row calls `onSelect` with the
/// entry's seq so the caller can jump the transcript there. Mirrors the
/// iOS `SummariesSheet` row layout (toc line, chevron-expand detail, date
/// caption, empty state) but as fixed-size popover content instead of a
/// pushed sheet — dismissal is the caller's job (`MacChatView` flips
/// `showSummaries` off in `onSelect`).
///
/// `ScrollView` + eager `VStack`, NOT `List` — a `List`'s NSTableView
/// backing composites its translucent row material against the live
/// window stack, which a headless `NSHostingView` snapshot (no real
/// window behind it) renders as a solid opaque fill with the row content
/// invisible underneath (verified against this file's own recorded
/// baselines before the switch). Same pattern `MacChatView`'s timeline
/// already uses for exactly this reason.
struct MacSummariesPanel: View {
    let entries: [ConversationSummaryEntry]
    let onSelect: (Int64) -> Void
    @State private var expandedSeq: Int64?

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No summaries yet")
                        .font(.headline)
                    Text("They appear as the conversation grows.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(for: entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 420)
        .background(.background)
    }

    private func row(for entry: ConversationSummaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.toc)
                Spacer()
                if !entry.detail.isEmpty {
                    Image(systemName: expandedSeq == entry.seq ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .onTapGesture { toggle(entry.seq) }
                }
            }
            if expandedSeq == entry.seq, !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(entry.date, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(entry.seq)
        }
    }

    private func toggle(_ seq: Int64) { expandedSeq = expandedSeq == seq ? nil : seq }
}
