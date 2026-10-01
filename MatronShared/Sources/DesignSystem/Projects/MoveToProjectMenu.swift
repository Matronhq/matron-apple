import SwiftUI
import MatronModels

/// "Move to project…" (spec §6 "Filing"): every open project, the current
/// one ticked. No "Not in a project": every mission has a project, and the
/// journal refuses taking one out (409).
public struct MoveToProjectMenu: View {
    let currentProjectID: String?
    let targets: [Project]
    let onMove: (String) -> Void
    public init(currentProjectID: String?, targets: [Project], onMove: @escaping (String) -> Void) {
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
        } label: {
            Label("Move to project…", systemImage: ProjectGlyph.symbol)
        }
        .disabled(!targets.contains { $0.id != currentProjectID })
        .accessibilityIdentifier("missions.moveToProject")
    }
}
