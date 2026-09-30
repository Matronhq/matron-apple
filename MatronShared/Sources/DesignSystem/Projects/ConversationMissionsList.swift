import SwiftUI
import MatronModels

/// Every mission a conversation touched, as Current / Also on / Earlier
/// (spec §6 "Header", mockup 04 right). The iOS sheet's content.
public struct ConversationMissionsList: View {
    let missions: ConversationMissions
    /// Project id → title, for the chips; missing ids draw no chip.
    let projectTitles: [String: String]
    let onOpenMission: (String) -> Void
    let onOpenProject: ((String) -> Void)?
    @Environment(\.timeZone) private var timeZone

    public init(missions: ConversationMissions, projectTitles: [String: String] = [:],
                onOpenMission: @escaping (String) -> Void, onOpenProject: ((String) -> Void)? = nil) {
        self.missions = missions; self.projectTitles = projectTitles
        self.onOpenMission = onOpenMission; self.onOpenProject = onOpenProject
    }

    public var body: some View {
        let sections = missions.sections
        List {
            if let current = sections.current { Section("Current") { row(current) } }
            if !sections.alsoOn.isEmpty { Section("Also on") { ForEach(sections.alsoOn) { row($0) } } }
            if !sections.earlier.isEmpty { Section("Earlier") { ForEach(sections.earlier) { row($0) } } }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Missions")
    }

    private func row(_ link: ConversationMissionLink) -> some View {
        Button { onOpenMission(link.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "#\(link.mission.num)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.mission.title).font(link.isEarlier ? .body : .body.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(ProjectsFormat.headerLine(link, timeZone: timeZone)).font(.caption).foregroundStyle(.secondary)
                        if let pid = link.mission.projectID, let title = projectTitles[pid] {
                            ProjectChip(title: title, action: onOpenProject.map { open in { open(pid) } })
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.primary)
        .accessibilityIdentifier("conversationMissions.\(link.mission.num)")
    }
}
