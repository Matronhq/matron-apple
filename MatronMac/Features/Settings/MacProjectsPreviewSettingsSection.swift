#if os(macOS)
import SwiftUI
import MatronViewModels

/// Mac twin of `ProjectsPreviewSettingsSection`: the Projects preview
/// switch, the `TimelineViewModel.flagKey` flag on this Mac.
struct MacProjectsPreviewSettingsSection: View {
    @AppStorage(TimelineViewModel.flagKey) private var on = false

    var body: some View {
        Section {
            Toggle(TimelineHostState.previewTitle, isOn: $on)
        } header: {
            Text("Projects")
        } footer: {
            Text(TimelineHostState.previewFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
