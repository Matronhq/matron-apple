import SwiftUI
import MatronChat
import MatronViewModels

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
///
/// `.background(.background)` (a flat fill) rather than letting the
/// popover's own vibrancy show through is deliberate for the same
/// headless-snapshot reason: real popover vibrancy composites against
/// the live window stack, which the harness has none of.
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
        HStack(alignment: .firstTextBaseline) {
            Button {
                onSelect(entry.seq)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.toc)
                    if expandedSeq == entry.seq, !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.subheadline)
                    }
                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !entry.detail.isEmpty {
                // Padding inside the label + matching negative padding outside
                // inflates the clickable shape without moving the icon; as the
                // later sibling the chevron wins hit-testing where the inflated
                // area overlaps the jump button.
                Button {
                    toggle(entry.seq)
                } label: {
                    Image(systemName: expandedSeq == entry.seq ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-12)
                .accessibilityLabel(expandedSeq == entry.seq ? "Hide detail" : "Show detail")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggle(_ seq: Int64) { expandedSeq = expandedSeq == seq ? nil : seq }
}

/// Reads `summaryEntries` in its OWN body so the popover stays
/// observation-tracked — a value snapshot taken inside the `.popover`
/// content closure never refreshes while the popover is open (see
/// SessionStatusSheet.swift:9-11).
struct MacSummariesPopoverContent: View {
    let viewModel: ChatViewModel
    let onSelect: (Int64) -> Void
    var body: some View { MacSummariesPanel(entries: viewModel.summaryEntries, onSelect: onSelect) }
}
