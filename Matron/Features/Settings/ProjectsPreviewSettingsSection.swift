import SwiftUI
import MatronViewModels

/// Settings → the Projects preview switch: the `TimelineViewModel.flagKey`
/// flag on this device. Projects reads it on its next visit.
struct ProjectsPreviewSettingsSection: View {
    @AppStorage(TimelineViewModel.flagKey) private var on = false

    var body: some View {
        Section {
            Toggle(TimelineHostState.previewTitle, isOn: $on)
                .accessibilityIdentifier("settings.projectsPreview")
        } header: {
            Text("Projects")
        } footer: {
            Text(TimelineHostState.previewFooter)
        }
    }
}
