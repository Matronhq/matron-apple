import SwiftUI
import MatronModels

/// "Move to project…" (spec §6 "Filing"): every open project, the current
/// one ticked, and "Not in a project" when it is filed.
public struct MoveToProjectMenu: View {
    let currentProjectID: String?
    let targets: [Project]
    let onMove: (String?) -> Void
    public init(currentProjectID: String?, targets: [Project], onMove: @escaping (String?) -> Void) {
        self.currentProjectID = currentProjectID; self.targets = targets; self.onMove = onMove
    }

    public var body: some View {
        Menu {
            ForEach(targets) { project in
                Button { onMove(project.id) } label: {
                    if project.id == currentProjectID { Label(project.title, systemImage: "checkmark") } else { Text(project.title) }
                }
                .disabled(project.id == currentProjectID)
            }
            if currentProjectID != nil {
                Divider()
                Button("Not in a project") { onMove(nil) }
            }
        } label: {
            Label("Move to project…", systemImage: ProjectGlyph.symbol)
        }
        .disabled(targets.isEmpty && currentProjectID == nil)
        .accessibilityIdentifier("missions.moveToProject")
    }
}
