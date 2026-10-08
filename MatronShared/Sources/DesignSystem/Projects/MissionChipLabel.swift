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
    /// The conversation's displayed title. A mission-named conversation's
    /// title already IS the mission's name (journal PR 136), so the chip
    /// then drops the name rather than say it twice.
    let conversationTitle: String?
    public init(missions: ConversationMissions, numberOnly: Bool = false, conversationTitle: String? = nil) {
        self.missions = missions
        self.numberOnly = numberOnly
        self.conversationTitle = conversationTitle
    }

    public static func text(_ missions: ConversationMissions, conversationTitle: String? = nil) -> String? {
        guard let headline = missions.sections.headline else { return nil }
        let others = missions.othersCount
        let name = repeatsTitle(headline.mission, conversationTitle: conversationTitle) ? "" : " \(headline.mission.title)"
        return "#\(headline.mission.num)\(name)" + (others > 0 ? " +\(others)" : "")
    }

    /// Whether `conversationTitle` already names `mission`: equal to its
    /// `name` or `title` once the `[xx]` short and any marker are peeled
    /// off and whitespace is collapsed — or the journal's cut of the title
    /// (at most 40 characters, ending "…", trailing punctuation dropped),
    /// which the full title then starts with.
    /// The rule itself lives in `SessionTitle.names(_:conversationTitle:)`
    /// so the For you origin labels (`JournalStore.itemOriginLabels()`)
    /// apply the same one.
    public static func repeatsTitle(_ mission: Mission, conversationTitle: String?) -> Bool {
        SessionTitle.names([mission.name, mission.title], conversationTitle: conversationTitle)
    }

    public var body: some View {
        if let headline = missions.sections.headline {
            let others = missions.othersCount
            HStack(spacing: 4) {
                Image(systemName: "flag.fill").font(.caption2)
                let number = "#\(headline.mission.num)"
                let hidesName = numberOnly || Self.repeatsTitle(headline.mission, conversationTitle: conversationTitle)
                Text(verbatim: hidesName ? number : "\(number) \(headline.mission.title)")
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
