import SwiftUI

/// The Coordinator tab's root when no coordinator conversation is set
/// (app shell, spec §3): a short explanation and the chooser button.
struct CoordinatorSetupView: View {
    let onChoose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
        } description: {
            Text("Pick one conversation to be your Coordinator. It hands work out as missions and never does the work itself.")
        } actions: {
            Button("Choose a conversation…", action: onChoose)
                .buttonStyle(.borderedProminent)
        }
    }
}
