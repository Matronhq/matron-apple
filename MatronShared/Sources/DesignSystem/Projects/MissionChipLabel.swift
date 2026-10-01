import SwiftUI
import MatronModels

/// The conversation header's chip (spec §2, §6): the current mission and
/// "+n" for every other mission the conversation touched. Hosts wrap it in
/// a Menu (Mac) or a Button opening `ConversationMissionsList` (iOS).
public struct MissionChipLabel: View {
    let missions: ConversationMissions
    /// "⚑ #4791 +2": the mission's number without its name — the narrowest
    /// the chip gets, for a host short of room (the Mac header).
    let numberOnly: Bool
    public init(missions: ConversationMissions, numberOnly: Bool = false) {
        self.missions = missions
        self.numberOnly = numberOnly
    }

    public static func text(_ missions: ConversationMissions) -> String? {
        guard let headline = missions.sections.headline else { return nil }
        let others = missions.othersCount
        return "#\(headline.mission.num) \(headline.mission.title)" + (others > 0 ? " +\(others)" : "")
    }

    public var body: some View {
        if let headline = missions.sections.headline {
            let others = missions.othersCount
            HStack(spacing: 4) {
                Image(systemName: "flag.fill").font(.caption2)
                let number = "#\(headline.mission.num)"
                Text(verbatim: numberOnly ? number : "\(number) \(headline.mission.title)")
                    .lineLimit(1).truncationMode(.tail)
                if others > 0 { Text(verbatim: "+\(others)").fontWeight(.semibold) }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(headline.isCurrent ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mission \(headline.mission.num), \(headline.mission.title)"
                                + (others > 0 ? ", and \(others) more" : ""))
            .accessibilityHint("Shows every mission this conversation worked on")
        }
    }
}
