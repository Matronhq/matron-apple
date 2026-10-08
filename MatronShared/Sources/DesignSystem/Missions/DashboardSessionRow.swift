import SwiftUI
import MatronModels

/// Running green / waiting amber / done grey (spec §3.2); stalled on a
/// usage limit red, whatever the state says (`DashboardSession.isStalled`).
public struct DashboardStateDot: View {
    let state: DashboardSessionState
    let isStalled: Bool
    public init(state: DashboardSessionState, isStalled: Bool = false) {
        self.state = state; self.isStalled = isStalled
    }

    public var body: some View {
        Circle().fill(isStalled ? Self.stalledColor : Self.color(state)).frame(width: 8, height: 8)
            .accessibilityLabel(Self.label(state, isStalled: isStalled))
    }

    public static let stalledColor = Color.red

    public static func label(_ state: DashboardSessionState, isStalled: Bool) -> String {
        isStalled ? "Stalled" : label(state)
    }

    public static func color(_ state: DashboardSessionState) -> Color {
        switch state {
        case .running: return .green
        case .waiting: return .orange
        case .done: return .gray
        }
    }

    public static func label(_ state: DashboardSessionState) -> String {
        switch state {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .done: return "Done"
        }
    }
}

/// One session: tag, title, state dot, then two lines of summary.
public struct DashboardSessionRow: View {
    let session: DashboardSession
    /// Loose-session cards show the chat's needs-you count; mission cards
    /// list the items themselves, so they don't.
    let showsNeedsYou: Bool

    public init(session: DashboardSession, showsNeedsYou: Bool = false) {
        self.session = session; self.showsNeedsYou = showsNeedsYou
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if let summary = session.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: session, showsNeedsYou: showsNeedsYou))
    }

    /// The row's full VoiceOver announcement. Static and pure so the rule is
    /// pinned without rendering, mirroring `ItemRow.accessibilityLabel(for:)`
    /// and `MissionDetailView.milestoneRow`: `.accessibilityElement(children:
    /// .combine)` followed by an explicit `.accessibilityLabel(...)` on the
    /// same container REPLACES the auto-generated combined text, so every
    /// fact VoiceOver should announce must be folded into this one string —
    /// left to `.combine` alone, a room session's tag read as the glyph run
    /// ("D↔M") letter by letter instead of the box names, AND (fix round 2)
    /// the loose-session card's `NeedsYouBadge` count silently dropped out
    /// once this label started overriding `.combine`'s own merge of it.
    public static func accessibilityLabel(for session: DashboardSession, showsNeedsYou: Bool) -> String {
        var parts = [session.title]
        if let tagLabel = plainTagLabel(for: session) { parts.append(tagLabel) }
        if showsNeedsYou, session.needsYou > 0 { parts.append(needsYouLabel(session.needsYou)) }
        parts.append(DashboardStateDot.label(session.state).lowercased())
        if let summary = session.summary, !summary.isEmpty { parts.append(summary) }
        return parts.joined(separator: ", ")
    }

    /// Same room-first fallback as the visual `tag` below, but the plain-
    /// text mirror: room box NAMES (not the visual run's single-letter
    /// glyphs), or the bare `boxName` chip's name when there is no cached
    /// `tag` at all — same gate `SessionTagText.plainLabel` documents.
    private static func plainTagLabel(for session: DashboardSession) -> String? {
        if let tag = session.tag {
            return SessionTagText.plainLabel(boxName: tag.boxName, sessionShort: tag.sessionShort,
                                             roomBoxNames: tag.roomBoxNames)
        }
        return session.boxName
    }

    /// Same wording as `NeedsYouBadge`'s own `.accessibilityLabel` —
    /// duplicated here (the badge exposes no static accessor) so the row's
    /// explicit label keeps speaking the count VoiceOver used to hear only
    /// because `.combine` merged the badge's own label in before this row
    /// grew an explicit one.
    private static func needsYouLabel(_ count: Int) -> String {
        count == 1 ? "1 item needs you" : "\(count) items need you"
    }

    private var header: some View {
        HStack(spacing: 6) {
            tag
            Text(session.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            if showsNeedsYou { NeedsYouBadge(count: session.needsYou) }
            DashboardStateDot(state: session.state)
        }
    }

    private var tag: some View { DashboardSessionTag(session: session) }
}

/// A session's tag: the room tag, then the single-box tag, then a bare box
/// chip for a conversation this device never synced — the chat rows'
/// fallback order. Never restyled (that would flatten the per-box colour).
public struct DashboardSessionTag: View {
    let session: DashboardSession
    let font: Font
    @Environment(\.colorScheme) private var colorScheme

    public init(session: DashboardSession, font: Font = .caption) {
        self.session = session; self.font = font
    }

    public var body: some View {
        if let tagText { tagText.font(font) } else if let box = session.boxName { BoxChip(box) }
    }

    private var tagText: Text? {
        guard let tag = session.tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
    }
}
