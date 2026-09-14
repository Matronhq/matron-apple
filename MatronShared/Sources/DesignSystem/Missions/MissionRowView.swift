import SwiftUI
import MatronModels

/// One row in the Missions list: `#num`, title, the last milestone with its
/// relative age, and the needs-you badge.
public struct MissionRowView: View {
    let mission: Mission
    public init(mission: Mission) { self.mission = mission }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: MissionGlyph.symbol(mission.state))
                .foregroundStyle(MissionGlyph.tint(mission.state))
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(mission.title).font(.body.weight(.medium)).lineLimit(2)
                if let last = mission.lastMilestone {
                    HStack(spacing: 5) {
                        numberPrefix
                        Image(systemName: MissionGlyph.symbol(last.kind))
                            .font(.caption2)
                            .foregroundStyle(MissionGlyph.tint(last.kind))
                        Text(last.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        RelativeMinuteTimeView(last.createdAt)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                } else {
                    // The number must survive every state: a closed
                    // mission with no milestone still needs its `#num`.
                    HStack(spacing: 5) {
                        numberPrefix
                        Text(mission.state == .open ? "No milestones yet" : MissionGlyph.label(.closed))
                            .font(.subheadline).foregroundStyle(.tertiary)
                    }
                }
                if mission.state == .closed, let summary = mission.closeSummary, !summary.isEmpty {
                    Text(summary.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            NeedsYouBadge(count: mission.needsYou)
                .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Mission \(mission.num), \(mission.title)"
            + (mission.needsYou > 0
               ? ", \(mission.needsYou) \(mission.needsYou == 1 ? "item needs" : "items need") you"
               : "")
        )
    }

    /// `#num ·` — leads the meta line in both the has-milestone and
    /// "No milestones yet" states.
    private var numberPrefix: some View {
        Group {
            Text("#\(mission.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("·").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
