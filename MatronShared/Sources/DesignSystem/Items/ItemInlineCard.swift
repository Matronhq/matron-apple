import SwiftUI
import MatronModels
import MatronEvents

/// Inline timeline rendering of a tracker marker event (spec 2026-09-08,
/// PR B / Task 13). `created`/`closed` render as a compact card;
/// `commented`/`reopened` render as `ItemInlineNote`, a one-line muted
/// summary — both share this type so a caller can switch on `marker.action`
/// once and get the right shape (`TimelineItemView`/`MacTimelineItemView`
/// just drop this straight into the row, no branching of their own).
/// `reordered`/`updated` never reach here — `JournalTimelineMapper` hides
/// them before a `TimelineItem` is even built.
public struct ItemInlineCard: View {
    let marker: ItemMarkerEvent
    let onOpen: () -> Void
    public init(marker: ItemMarkerEvent, onOpen: @escaping () -> Void) { self.marker = marker; self.onOpen = onOpen }

    public var body: some View {
        switch marker.action {
        case .created, .closed: card
        default: note
        }
    }

    /// Status pill under the title. Closed markers show "Done" (plus the
    /// resolution label, when the payload carries one); open markers show
    /// who the ball is in whose court — "Needs you" is deliberately the
    /// only urgent-colored state, matching `TrackerItem.needsUser`'s
    /// definition of the badge the rest of the tracker UI uses.
    private var pill: (String, Color)? {
        if marker.action == .closed {
            return ("Done" + (marker.resolution.map { " · \(ItemGlyph.label($0))" } ?? ""), .secondary)
        }
        if marker.awaiting == .user { return ("Needs you", .orange) }
        if marker.awaiting == .agent { return ("With the agent", .secondary) }
        return nil
    }

    private var card: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ItemGlyph.symbol(marker.kind)).foregroundStyle(ItemGlyph.tint(marker.kind))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("#\(marker.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(marker.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    if let (text, color) = pill {
                        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(marker.awaiting == .user && marker.action != .closed ? Color.orange.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ItemGlyph.label(marker.kind)) \(marker.num), \(marker.title). \(pill?.0 ?? "")")
    }

    /// Author word for the one-line note — "You" for the local user,
    /// "Agent" for the bot, matching how the rest of the tracker UI
    /// refers to the two `ItemAuthor` cases.
    private var noteText: String {
        let who = marker.by == .user ? "You" : "Agent"
        switch marker.action {
        case .commented: return "\(who) replied on #\(marker.num) · \(marker.title)"
        case .reopened: return "\(who) reopened #\(marker.num) · \(marker.title)"
        default: return "#\(marker.num) · \(marker.title)"
        }
    }

    private var note: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: ItemGlyph.symbol(marker.kind)).font(.caption2)
                Text(noteText).font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(noteText)
    }
}
