import SwiftUI
import MatronModels

/// Running green / waiting amber / done grey (spec §3.2).
public struct DashboardStateDot: View {
    let state: DashboardSessionState
    public init(state: DashboardSessionState) { self.state = state }

    public var body: some View {
        Circle().fill(Self.color(state)).frame(width: 8, height: 8)
            .accessibilityLabel(Self.label(state))
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
    @Environment(\.colorScheme) private var colorScheme

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

    /// Room tag, then the single-box tag, then a bare box chip for a
    /// conversation this device never synced — the chat rows' fallback
    /// order. Never restyled (that would flatten the per-box colour).
    @ViewBuilder private var tag: some View {
        if let tagText { tagText.font(.caption) } else if let box = session.boxName { BoxChip(box) }
    }

    private var tagText: Text? {
        guard let tag = session.tag else { return nil }
        return SessionTagText.room(letters: tag.roomBoxShorts, names: tag.roomBoxNames,
                                   sessionShort: tag.sessionShort, colorScheme: colorScheme)
            ?? SessionTagText.run(boxLetter: tag.boxLetter, boxName: tag.boxName,
                                  sessionShort: tag.sessionShort, colorScheme: colorScheme)
    }
}
