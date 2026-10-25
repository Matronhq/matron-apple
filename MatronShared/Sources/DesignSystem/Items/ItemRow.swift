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
            Image(systemName: ItemGlyph.symbol(item.kind))
                .foregroundStyle(ItemGlyph.tint(item.kind))
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(item.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    // A notice is something to read, not decide: it
                    // draws lighter than the questions around it.
                    Text(item.title).font(.body.weight(item.kind == .notice ? .regular : .medium)).lineLimit(2)
                        .lighterForNotice(item.kind == .notice)
                }
                if let preview = Self.bodyPreview(item.body) {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    // A consent ask — a spawn or chat card
                    // mirrored into the tracker — told apart from an
                    // ordinary question at a glance. Decided by the item's
                    // consent link, never by its labels.
                    if item.isConsentAsk {
                        Label(Self.consentLabel, systemImage: "hand.raised")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if let chip = Self.missionChipText(for: item) {
                        Label(chip, systemImage: MissionGlyph.symbol())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
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
                    if item.commentCount > 0 {
                        Label(String(item.commentCount), systemImage: "bubble.left").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let thumbnail {
                // `.foregroundStyle` is a no-op on a real bitmap thumbnail
                // (the common case), but without it a template-rendered
                // image (e.g. an SF Symbol placeholder passed in while a
                // real thumbnail is still loading) renders with no tint at
                // all in this target's default environment — effectively
                // invisible against a light background. Matches the
                // `.tertiary` tint used by the `item.hasImage` fallback
                // below so a loading-placeholder and the no-thumbnail
                // fallback read the same.
                thumbnail.resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6)).foregroundStyle(.tertiary)
            } else if item.hasImage {
                Image(systemName: "photo").foregroundStyle(.tertiary).frame(width: 40, height: 40)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: item, caption: closedCaption))
    }
}

private extension View {
    /// Secondary foreground for a notice's title; every other row keeps
    /// whatever foreground it inherits (a selected Mac row's included).
    @ViewBuilder func lighterForNotice(_ isNotice: Bool) -> some View {
        if isNotice { foregroundStyle(.secondary) } else { self }
    }
}
