import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → the For you notices switch (`/settings`): whether agents file
/// things the user should read as items with a Seen button. Synced per
/// user, so a change here shows on the Mac at once. Hidden entirely on a
/// journal without the route, and until the first read answers.
struct ForYouSettingsSection: View {
    let store: UserSettingsStore

    var body: some View {
        Group {
            if store.showsNoticesSwitch {
                Section {
                    Toggle(UserSettingsStore.noticesTitle, isOn: Binding(
                        get: { store.settings?.notices ?? true },
                        set: { on in Task { await store.setNotices(on) } }
                    ))
                    if let error = store.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("For you")
                } footer: {
                    Text(UserSettingsStore.noticesFooter)
                }
            }
        }
        // On screen entry as well as on every connect.
        .task { await store.refresh() }
    }
}
