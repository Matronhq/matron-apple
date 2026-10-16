import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → Archive: after how many idle days the journal archives a
/// conversation (`/settings` `auto_archive_days`). Synced per user. Hidden
/// on a journal without archiving, and until the first read answers.
struct AutoArchiveSettingsSection: View {
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
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Archive")
            } footer: {
                Text(UserSettingsStore.autoArchiveFooter)
            }
        }
    }
}
