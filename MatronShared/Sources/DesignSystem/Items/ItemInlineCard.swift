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
        case .created:
            card
        case .closed:
            // The closed card itself is unchanged; a closing comment (body
            // and/or attachments) renders as its own block underneath, not
            // inside the card's Button — same reasoning as the note case
            // below, just without the header-alignment indent since a card
            // has no single leading text run to line up under.
            VStack(alignment: .leading, spacing: 6) {
                card
                if hasVisibleComment {
                    commentBlock.padding(.leading, 10)
                }
            }
        default:
            // `note` renders unchanged when there's nothing to show below
            // it (design requirement 3) — wrapping it in this VStack adds
            // no visible spacing when the comment block is absent, since a
            // single-child VStack has nothing to space against.
            VStack(alignment: .leading, spacing: 4) {
                note
                if hasVisibleComment {
                    commentBlock.padding(.leading, Self.noteTextIndent)
                }
            }
        }
    }

    /// Whether `marker.comment` has anything worth rendering as a block —
    /// an empty comment (e.g. a bare status transition) still parses with a
    /// `Comment` payload but has nothing to show beyond the note/card.
    private var hasVisibleComment: Bool {
        guard let comment = marker.comment else { return false }
        return !comment.body.isEmpty || !comment.attachments.isEmpty
    }

    /// Leading indent for the comment block under `note`, lining its text
    /// up under the note's own text rather than its leading glyph — the
    /// note's icon renders at `.caption2` (~14pt) with 6pt of HStack
    /// spacing before the text, matching the fixed-width glyph slots used
    /// elsewhere in the design system (`AskUserSheetBody.glyphSlot`).
    private static let noteTextIndent: CGFloat = 20

    /// The reply body (in full — no line limit) and one caption line per
    /// attachment. Deliberately NOT wrapped in a tap gesture: it sits below
    /// `note`/`card`'s own `Button`, so `[#65](matron://item/65)`-style
    /// links inside the body (handled by the timeline's `trackerItemLinks`
    /// modifier higher up the view tree) stay tappable instead of being
    /// swallowed by a block-wide open gesture.
    @ViewBuilder
    private var commentBlock: some View {
        if let comment = marker.comment {
            VStack(alignment: .leading, spacing: 3) {
                if !comment.body.isEmpty {
                    MarkdownText(comment.body, theme: .matronMessage)
                }
                ForEach(comment.attachments, id: \.blobRef) { attachment in
                    Text(Self.attachmentLine(attachment)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Pure formatter for one attachment's caption line under a reply —
    /// public/static so `ItemInlineCardTests` can pin it directly without
    /// standing up a view.
    public static func attachmentLine(_ attachment: TrackerAttachment) -> String {
        let name = attachment.name.isEmpty ? "attachment" : attachment.name
        if attachment.isAudio {
            var line = "Voice note: \(name)"
            if let transcript = attachment.transcript, !transcript.isEmpty {
                line += " — \(transcript)"
            }
            return line
        }
        return "Attachment: \(name)"
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
