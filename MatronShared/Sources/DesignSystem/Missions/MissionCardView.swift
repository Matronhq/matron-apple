import SwiftUI
import MatronModels

/// Rounded card chrome shared by mission and loose-session cards.
struct DashboardCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }
}

/// One open mission (spec §3.2): header, status, latest step, needs-you
/// rows, sessions. Tapping the card's background opens the mission page;
/// the item and session rows are their own buttons. Split into small
/// computed views for CI's type-checker budget.
public struct MissionCardView: View {
    let card: DashboardMissionCard
    let now: Date
    let onAction: (MissionsDashboardAction) -> Void

    public init(card: DashboardMissionCard, now: Date, onAction: @escaping (MissionsDashboardAction) -> Void) {
        self.card = card; self.now = now; self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusBlock
            latestStepBlock
            needsYouBlock
            sessionsBlock
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DashboardCardChrome())
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onAction(.openMission(card.id)) }
        // Not `.accessibilityAddTraits(.isButton)`: this container is not
        // itself an accessibility element (its needs-you/session rows are
        // their own buttons underneath it), so the trait had nowhere to
        // attach and never actually announced "button". A named action
        // lets VoiceOver open the mission from anywhere on the card
        // without claiming a false element/trait.
        .accessibilityAction(named: Text("Open mission")) { onAction(.openMission(card.id)) }
        .accessibilityIdentifier("missions.card.\(card.mission.num)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("#\(card.mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.mission.title).font(.headline).lineLimit(2)
                if let attribution = card.attribution {
                    Text(attribution).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            NeedsYouPill(count: card.needsYouCount)
        }
    }

    /// Nothing at all when unset — no placeholder (spec §3.2).
    @ViewBuilder private var statusBlock: some View {
        if let status = card.mission.status {
            VStack(alignment: .leading, spacing: 3) {
                Text(MissionsDashboardFormat.statusText(status)).font(.subheadline).lineLimit(4)
                if let byline = MissionsDashboardFormat.statusByline(updatedAt: card.mission.statusUpdatedAt,
                                                                     by: card.mission.statusBy, now: now) {
                    Text(byline).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var latestStepBlock: some View {
        if let step = card.latestStep {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: MissionGlyph.symbol(step.kind))
                        .font(.caption2).foregroundStyle(MissionGlyph.tint(step.kind))
                    Text(step.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(MissionsDashboardFormat.relative(step.createdAt, now: now))
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                }
                if !step.body.isEmpty {
                    Text(step.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            Text("No milestones yet").font(.subheadline).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var needsYouBlock: some View {
        if !card.needsYouItems.isEmpty || card.moreNeedsYou > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.needsYouItems) { item in
                    Button { onAction(.openItem(item.id)) } label: { needsYouRow(item) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
                if card.moreNeedsYou > 0 {
                    Button("+\(card.moreNeedsYou) more") { onAction(.openMission(card.id)) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func needsYouRow(_ item: DashboardNeedsYouItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ItemGlyph.symbol(item.kind)).font(.caption).foregroundStyle(ItemGlyph.tint(item.kind))
            Text("#\(item.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(item.title).font(.subheadline).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var sessionsBlock: some View {
        if !card.sessions.isEmpty || card.roomCount > 0 {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.sessions) { session in
                    Button { onAction(.openSession(session.id)) } label: { DashboardSessionRow(session: session) }
                        .buttonStyle(.plain).foregroundStyle(Color.primary)
                }
                if card.moreSessions > 0 {
                    Button(MissionsDashboardFormat.moreSessions(card.moreSessions)) { onAction(.openMission(card.id)) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                if card.roomCount > 0 {
                    Button(MissionsDashboardFormat.rooms(card.roomCount)) { onAction(.openMission(card.id)) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
