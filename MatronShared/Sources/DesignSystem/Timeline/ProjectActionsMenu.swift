import SwiftUI
import MatronModels

/// What a project page's "···" holds, to place inside a `Menu`: "Add a
/// mission" (the missions in no project), "Ask the Coordinator about
/// this", "Rename…", "Merge into…" (the other open projects) and "Close
/// project…". The writes are dimmed on a project that is not open and
/// until its missions and projects have loaded
/// (`ProjectActionsAvailability`). Once the question was sent the Ask
/// entry says "Asked the Coordinator" and is dimmed. The menu only says what was chosen: the
/// host asks before a merge or a close, and shows the sheet that takes the
/// new name.
public struct ProjectActionsMenu: View {
    let isOpen: Bool
    let isLoaded: Bool
    let asked: Bool
    let unfiled: [Mission]
    let mergeTargets: [Project]
    let onAddMission: (String) -> Void
    let onAsk: () -> Void
    let onRename: () -> Void
    let onMerge: (String) -> Void
    let onClose: () -> Void

    /// `isOpen` is the page's own word on the project; `isLoaded` is
    /// whether `unfiled` and `mergeTargets` have been read; `asked` is
    /// whether this page has already sent its question. `onAddMission` is
    /// given the mission's id, `onMerge` the id of the project to merge
    /// into.
    public init(isOpen: Bool, isLoaded: Bool, asked: Bool = false, unfiled: [Mission], mergeTargets: [Project],
                onAddMission: @escaping (String) -> Void,
                onAsk: @escaping () -> Void, onRename: @escaping () -> Void,
                onMerge: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.isOpen = isOpen; self.isLoaded = isLoaded; self.asked = asked
        self.unfiled = unfiled; self.mergeTargets = mergeTargets; self.onAddMission = onAddMission
        self.onAsk = onAsk; self.onRename = onRename; self.onMerge = onMerge; self.onClose = onClose
    }

    private var available: ProjectActionsAvailability {
        ProjectActionsAvailability(isOpen: isOpen, isLoaded: isLoaded, hasUnfiled: !unfiled.isEmpty,
                                   hasMergeTargets: !mergeTargets.isEmpty)
    }

    public var body: some View {
        let available = available
        // A dimmed submenu still opens (empty) on the Mac: with nothing to
        // list, the entry is a dimmed button.
        Group {
            if available.addMission {
                Menu(ProjectActionsFormat.addMission) {
                    ForEach(unfiled) { mission in
                        Button(mission.label) { onAddMission(mission.id) }
                    }
                }
            } else {
                Button(ProjectActionsFormat.addMission) {}.disabled(true)
            }
        }
        .accessibilityIdentifier("projects.actions.addMission")
        Button(ProjectActionsFormat.askLabel(asked: asked), action: onAsk)
            .disabled(asked)
            .accessibilityIdentifier("projects.actions.ask")
        Divider()
        Button(ProjectActionsFormat.rename, action: onRename)
            .disabled(!available.rename)
            .accessibilityIdentifier("projects.actions.rename")
        Group {
            if available.merge {
                Menu(ProjectActionsFormat.mergeInto) {
                    ForEach(mergeTargets) { target in
                        Button(target.title) { onMerge(target.id) }
                    }
                }
            } else {
                Button(ProjectActionsFormat.mergeInto) {}.disabled(true)
            }
        }
        .accessibilityIdentifier("projects.actions.merge")
        Button(ProjectActionsFormat.close, role: .destructive, action: onClose)
            .disabled(!available.close)
            .accessibilityIdentifier("projects.actions.close")
    }
}
