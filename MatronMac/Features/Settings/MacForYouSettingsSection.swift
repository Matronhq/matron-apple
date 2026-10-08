#if os(macOS)
import SwiftUI
import MatronJournal
import MatronViewModels

/// Mac twin of `ForYouSettingsSection`, on the Settings scene's General tab:
/// the For you notices switch (`/settings`). Hidden on a journal without
/// the route, and until the first read answers.
struct MacForYouSettingsSection: View {
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
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("For you")
                } footer: {
                    Text(UserSettingsStore.noticesFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // On screen entry as well as on every connect.
        .task { await store.refresh() }
    }
}
#endif
