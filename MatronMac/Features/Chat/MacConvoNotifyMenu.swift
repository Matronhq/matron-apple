import SwiftUI
import MatronJournal
import MatronViewModels

/// A conversation's Notifications menu items (journal spec 2026-10-01): its
/// own level (All / Needs me / None, or Default to follow the mode) and a
/// mute. Mac analogue of iOS `ConvoNotifyMenu`; hosted as a "Notifications"
/// submenu in the sidebar's right-click menu (`MacConvoNotifyMenu`) and as
/// the bell in the chat header (`MacChatToolbar.notifyItem`). Writes go
/// through `NotifySettingsStore`, which shows them at once and takes them
/// back if the journal refuses.
struct MacConvoNotifyMenuItems: View {
    let store: NotifySettingsStore
    let convoID: String

    private var state: ConvoNotifyState { store.state(for: convoID) }

    var body: some View {
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
        Divider()
        if let mutedUntil = state.mutedUntil {
            Button("Unmute (muted until \(ConvoNotifyState.time(mutedUntil)))") {
                Task { await store.unmute(convoID: convoID) }
            }
        }
        ForEach(NotifyMuteDuration.allCases, id: \.self) { duration in
            Button(duration.title) {
                Task { await store.mute(convoID: convoID, for: duration) }
            }
        }
    }
}

/// The sidebar row's "Notifications" submenu.
struct MacConvoNotifyMenu: View {
    let store: NotifySettingsStore
    let convoID: String

    var body: some View {
        Menu("Notifications") {
            MacConvoNotifyMenuItems(store: store, convoID: convoID)
        }
    }
}

/// The bell-slash a row or header shows when nothing from the conversation
/// pushes: level None, or a mute still running.
struct MacConvoNotifySilencedIcon: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .foregroundStyle(.secondary)
            .help("Notifications off for this conversation")
            .accessibilityLabel("Notifications off")
    }
}
