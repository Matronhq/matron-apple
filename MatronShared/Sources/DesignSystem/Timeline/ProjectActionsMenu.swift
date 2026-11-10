import SwiftUI
import MatronModels

/// What a project page's "···" holds, to place inside a `Menu`: "Add a
/// mission" (the missions in no project), "Ask the Coordinator about
/// this", "Rename…", "Merge into…" (the other open projects) and "Close
/// project…". The menu only says what was chosen: the host asks before a
/// merge or a close, and shows the sheet that takes the new name.
public struct ProjectActionsMenu: View {
    let unfiled: [Mission]
    let mergeTargets: [Project]
    let onAddMission: (String) -> Void
    let onAsk: () -> Void
    let onRename: () -> Void
    let onMerge: (String) -> Void
    let onClose: () -> Void

    /// `onAddMission` is given the mission's id, `onMerge` the id of the
    /// project to merge into.
    public init(unfiled: [Mission], mergeTargets: [Project], onAddMission: @escaping (String) -> Void,
                onAsk: @escaping () -> Void, onRename: @escaping () -> Void,
                onMerge: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.unfiled = unfiled; self.mergeTargets = mergeTargets; self.onAddMission = onAddMission
        self.onAsk = onAsk; self.onRename = onRename; self.onMerge = onMerge; self.onClose = onClose
    }

    public var body: some View {
        Menu(ProjectActionsFormat.addMission) {
            ForEach(unfiled) { mission in
                Button(mission.label) { onAddMission(mission.id) }
            }
        }
        .disabled(unfiled.isEmpty)
        .accessibilityIdentifier("projects.actions.addMission")
        Button(ProjectActionsFormat.ask, action: onAsk)
            .accessibilityIdentifier("projects.actions.ask")
        Divider()
        Button(ProjectActionsFormat.rename, action: onRename)
            .accessibilityIdentifier("projects.actions.rename")
        Menu(ProjectActionsFormat.mergeInto) {
            ForEach(mergeTargets) { target in
                Button(target.title) { onMerge(target.id) }
            }
        }
        .disabled(mergeTargets.isEmpty)
        .accessibilityIdentifier("projects.actions.merge")
        Button(ProjectActionsFormat.close, role: .destructive, action: onClose)
            .accessibilityIdentifier("projects.actions.close")
    }
}
