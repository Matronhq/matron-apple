import SwiftUI
import MatronModels

public struct ItemRow: View {
    let item: TrackerItem
    let origin: String?
    let thumbnail: Image?
    /// Overrides the default bare resolution label ("Decided", or "Closed"
    /// for a `nil` resolution — review, 2026-09-29) a closed item shows
    /// with a fuller caption that also says when it closed ("Decided ·
    /// 2h ago") — used by the Decisions view's "Decided" section
    /// (`ItemGlyph.closedCaption`). `nil` for every other
    /// caller keeps the plain resolution/"Closed" label.
    let closedCaption: String?
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif
    public init(item: TrackerItem, showsOrigin origin: String? = nil, thumbnail: Image? = nil, closedCaption: String? = nil) {
        self.item = item; self.origin = origin; self.thumbnail = thumbnail; self.closedCaption = closedCaption
    }

    /// `#61` when the item belongs to a mission, else `nil`. Static so the
    /// copy is testable without rendering — and deliberately bare: `#61` may
    /// name an item, a mission or a milestone, and prefixing it with a type
    /// word would be the only place in the app that pretends otherwise.
    ///
    /// An item can carry a `missionNum` for a mission this device cannot
    /// read (protocol, "Accepted exception — numbers, never words"), so the
    /// chip must never try to resolve a title.
    public static func missionChipText(for item: TrackerItem) -> String? {
        item.missionNum.map { "#\($0)" }
    }

    /// The row's full VoiceOver announcement. Static and pure so the rule is
    /// pinned without rendering: `.accessibilityElement(children: .combine)`
    /// followed by an explicit `.accessibilityLabel(...)` on the same
    /// container REPLACES the auto-generated combined text — a child's own
    /// `.accessibilityLabel` (e.g. on the mission chip) never merges in. So
    /// every fact VoiceOver should announce, including the mission chip,
    /// must be folded into this one string.
    public static func accessibilityLabel(for item: TrackerItem, caption: String? = nil) -> String {
        "\(ItemGlyph.label(item.kind)) \(item.num), \(item.title)"
            + (item.needsUser ? ", needs you" : "")
            + (caption.map { ", \($0)" } ?? "")
            + (Self.missionChipText(for: item).map { ", mission \($0)" } ?? "")
            + (item.isConsentAsk ? ", consent ask" : "")
    }

    /// The row's words are plain strings (`Text(verbatim:)` and `String`
    /// labels), not localized keys: the app has no translations, and each
    /// key was looked up again for every row scrolled on screen.
    static let consentLabel = "Consent"

    /// How much of the body the one-line preview is built from: more than
    /// the widest row shows.
    static let previewLength = 400

    /// The body as the row's one-line preview: attachment refs as their
    /// captions, line breaks as spaces, cut to `previewLength` characters.
    /// `nil` for an empty body. A row typeset the whole body for that one
    /// line, which on a long report cost the For you list frames as its
    /// rows scrolled on screen.
    public static func bodyPreview(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        // Room past the cut for refs, which shorten to their captions; a
        // start so full of refs that the room runs out reads the whole body.
        let cut = body.prefix(previewLength * 4)
        var text = inlineAttachmentPlainText(String(cut))
        if text.count < previewLength, cut.endIndex < body.endIndex { text = inlineAttachmentPlainText(body) }
        return String(text.prefix(previewLength)).replacingOccurrences(of: "\n", with: " ")
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            #if os(macOS)
            Image(systemName: ItemGlyph.symbol(item.kind))
                .foregroundStyle(ItemGlyph.tint(item.kind))
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if let preview = Self.bodyPreview(item.body) {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                metaLine
            }
            #if os(iOS)
            // The list's separator starts under the text column, not under
            // whichever text in the row the list happens to find first.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            #endif
            Spacer(minLength: 0)
            if let thumbnail {
                // `.foregroundStyle` is a no-op on a real bitmap thumbnail
                // (the common case), but without it a template-rendered
                // image (e.g. an SF Symbol placeholder passed in while a
                // real thumbnail is still loading) renders with no tint at
                // all in this target's default environment — effectively
                // invisible against a light background.
                thumbnail.resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6)).foregroundStyle(.tertiary)
            }
            #if os(macOS)
            // The Mac's native For you cell draws the same stand-in and
            // is pinned to this row's layout.
            if thumbnail == nil, item.hasImage {
                Image(systemName: "photo").foregroundStyle(.tertiary).frame(width: 40, height: 40)
            }
            #endif
            // On iPhone there is no stand-in for an item that has a picture
            // but no thumbnail to show: a generic photo symbol said nothing
            // about the item and took 40 points from every title beside it.
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: item, caption: closedCaption))
    }
}

extension ItemRow {
    /// The number and the title. On iPhone the kind glyph, the number and
    /// the title run together as one text, so a title that wraps goes back
    /// to the row's leading edge and gets its full width; a glyph column
    /// and a number column beside the title squeezed every title into the
    /// space left over. The Mac keeps both columns, which its native For
    /// you cell is pinned to.
    /// A notice is something to read, not decide: it draws lighter than
    /// the questions around it.
    @ViewBuilder var titleLine: some View {
        let weight: Font.Weight = item.kind == .notice ? .regular : .medium
        #if os(iOS)
        (Text(Image(systemName: ItemGlyph.symbol(item.kind))).font(.subheadline).foregroundStyle(ItemGlyph.tint(item.kind))
            + Text(verbatim: " #\(item.num)  ").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            + Text(item.title).font(.body.weight(weight)))
            .lineLimit(2)
            .lighterForNotice(item.kind == .notice)
        #else
        HStack(spacing: 6) {
            Text(verbatim: "#\(item.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(item.title).font(.body.weight(weight)).lineLimit(2)
                .lighterForNotice(item.kind == .notice)
        }
        #endif
    }

    /// The meta line: where the item came from, then its mission, status
    /// and comments. On iPhone at accessibility text sizes the two halves
    /// take a line each, so the chips that keep their full width still
    /// fit inside the row.
    @ViewBuilder var metaLine: some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { metaSource }
                HStack(spacing: 8) { metaState }
            }
        } else {
            HStack(spacing: 8) { metaSource; metaState }
        }
        #else
        HStack(spacing: 8) { metaSource; metaState }
        #endif
    }

    @ViewBuilder var metaSource: some View {
        // A consent ask — a spawn or chat card
        // mirrored into the tracker — told apart from an
        // ordinary question at a glance. Decided by the item's
        // consent link, never by its labels.
        if item.isConsentAsk {
            Label(Self.consentLabel, systemImage: "hand.raised")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .keepsWholeOnPhone()
        }
        if let origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).shortensFirstOnPhone() }
    }

    @ViewBuilder var metaState: some View {
        if let chip = Self.missionChipText(for: item) { missionChip(chip) }
        if item.needsUser && item.kind == .notice {
            Text(ItemGlyph.label(.notice)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        } else if item.needsUser {
            Text(verbatim: "Needs you").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        } else if item.state == .closed {
            // A `nil` resolution still gets a caption — "Closed"
            // — rather than showing nothing at all, which made
            // a closed item indistinguishable from an open one
            // with no badge (review, 2026-09-29).
            Text(closedCaption ?? item.resolution.map(ItemGlyph.label) ?? "Closed")
                .font(.caption2).foregroundStyle(.tertiary)
        } else if let closedCaption {
            // An answered item on the Done tab that is still open.
            Text(closedCaption).font(.caption2).foregroundStyle(.tertiary)
        } else if item.awaiting == .agent {
            Text(verbatim: "With the agent").font(.caption2).foregroundStyle(.tertiary)
        }
        if item.commentCount > 0 { commentCountLabel }
    }

    /// How many comments the item has. On iPhone the count sits right
    /// beside its glyph rather than a Label's wide gap away.
    @ViewBuilder var commentCountLabel: some View {
        #if os(iOS)
        HStack(spacing: 3) {
            Image(systemName: "bubble.left")
            Text(verbatim: String(item.commentCount))
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .fixedSize(horizontal: true, vertical: false)
        #else
        Label(String(item.commentCount), systemImage: "bubble.left").font(.caption2).foregroundStyle(.tertiary)
        #endif
    }

    /// The mission chip. On iPhone it never wraps: a narrow row wrapped a
    /// mission number digit by digit.
    @ViewBuilder func missionChip(_ chip: String) -> some View {
        #if os(iOS)
        HStack(spacing: 3) {
            Image(systemName: MissionGlyph.symbol())
            Text(verbatim: chip).lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: true, vertical: false)
        #else
        Label(chip, systemImage: MissionGlyph.symbol())
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        #endif
    }
}

private extension View {
    /// On iPhone, a chip on the row's meta line keeps its full width; the
    /// origin conversation's title is what shortens instead.
    @ViewBuilder func keepsWholeOnPhone() -> some View {
        #if os(iOS)
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
        #else
        self
        #endif
    }

    @ViewBuilder func shortensFirstOnPhone() -> some View {
        #if os(iOS)
        layoutPriority(-1)
        #else
        self
        #endif
    }

    /// Secondary foreground for a notice's title; every other row keeps
    /// whatever foreground it inherits (a selected Mac row's included).
    @ViewBuilder func lighterForNotice(_ isNotice: Bool) -> some View {
        if isNotice { foregroundStyle(.secondary) } else { self }
    }
}
