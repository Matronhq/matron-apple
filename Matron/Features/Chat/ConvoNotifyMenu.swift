import SwiftUI
import MatronJournal
import MatronViewModels

/// A conversation's "Notifications" submenu (journal spec 2026-10-01): its
/// own level (All / Needs me / None, or Default to follow the mode) and a
/// mute. Shared by the chat-list row's long-press menu and the chat's ⓘ
/// sheet. Writes go through `NotifySettingsStore`, which shows them at once
/// and takes them back if the journal refuses.
struct ConvoNotifyMenu: View {
    let store: NotifySettingsStore
    let convoID: String

    private var state: ConvoNotifyState { store.state(for: convoID) }

    var body: some View {
        Menu {
            Picker("Level", selection: Binding(
                get: { state.level },
                set: { level in Task { await store.setLevel(level, convoID: convoID) } }
            )) {
                ForEach(NotifySettings.ConvoLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(Optional(level))
                }
                Text(ConvoNotifyState.defaultLevelTitle).tag(NotifySettings.ConvoLevel?.none)
            }
            .pickerStyle(.inline)
            Section {
                if let mutedUntil = state.mutedUntil {
                    Button {
                        Task { await store.unmute(convoID: convoID) }
                    } label: {
                        Label("Unmute (muted until \(ConvoNotifyState.time(mutedUntil)))", systemImage: "bell")
                    }
                }
                ForEach(NotifyMuteDuration.allCases, id: \.self) { duration in
                    Button(duration.title) {
                        Task { await store.mute(convoID: convoID, for: duration) }
                    }
                }
            }
        } label: {
            Label("Notifications", systemImage: state.isSilenced ? "bell.slash" : "bell")
        }
    }
}

/// The bell-slash a row or header shows when nothing from the conversation
/// pushes: level None, or a mute still running.
struct ConvoNotifySilencedIcon: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Notifications off")
    }
}
