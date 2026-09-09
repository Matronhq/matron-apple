import SwiftUI

/// The Coordinator tab's root when no coordinator conversation is set
/// (app shell, spec §3): a short explanation and the chooser button.
struct CoordinatorSetupView: View {
    let onChoose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
        } description: {
            Text("Pick one conversation to act as your coordinator. It keeps its own tab; everything else about it stays the same.")
        } actions: {
            Button("Choose a conversation…", action: onChoose)
                .buttonStyle(.borderedProminent)
        }
    }
}
