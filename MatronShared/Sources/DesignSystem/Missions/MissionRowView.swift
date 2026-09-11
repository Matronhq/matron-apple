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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(mission.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(mission.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if let last = mission.lastMilestone {
                    HStack(spacing: 5) {
                        Image(systemName: MissionGlyph.symbol(last.kind))
                            .font(.caption2)
                            .foregroundStyle(MissionGlyph.tint(last.kind))
                        Text(last.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        RelativeMinuteTimeView(last.createdAt)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if mission.state == .open {
                    Text("No milestones yet").font(.subheadline).foregroundStyle(.tertiary)
                }
                if mission.state == .closed, let summary = mission.closeSummary, !summary.isEmpty {
                    Text(summary.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            NeedsYouBadge(count: mission.needsYou)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mission \(mission.num), \(mission.title)\(mission.needsYou > 0 ? ", \(mission.needsYou) need you" : "")")
    }
}
