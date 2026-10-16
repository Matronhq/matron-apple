#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Mac twin of `AutoArchiveSettingsSection`, on the Settings scene's
/// General tab: after how many idle days the journal archives a
/// conversation. Hidden on a journal without archiving, and until the first
/// read answers.
struct MacAutoArchiveSettingsSection: View {
    let store: UserSettingsStore

    var body: some View {
        if store.showsAutoArchive {
            Section {
                Picker(UserSettingsStore.autoArchiveTitle, selection: Binding(
                    get: { store.settings?.autoArchiveDays ?? 0 },
                    set: { days in Task { await store.setAutoArchiveDays(days) } }
                )) {
                    ForEach(store.autoArchiveChoices, id: \.self) { days in
                        Text(UserSettings.autoArchiveLabel(days)).tag(days)
                    }
                }
                if let error = store.autoArchiveErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Archive")
            } footer: {
                Text(UserSettingsStore.autoArchiveFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
