import SwiftUI
import MatronJournal
import MatronViewModels

/// Settings → General → New chats: the user's default model and effort,
/// which every bridge applies to a chat started without a choice of its own
/// (journal `GET`/`PUT /defaults`). Mac analogue of iOS
/// `NewChatDefaultsSection`, and a port of matron-web's SettingsSheet group.
/// Every pick shows at once and goes back if the journal refuses it
/// (`NewChatDefaultsStore`).
struct MacNewChatDefaultsSection: View {
    let store: NewChatDefaultsStore

    var body: some View {
        Section {
            if store.isSupported == false {
                Text(NewChatDefaults.unsupportedText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(NewChatDefaults.Key.allCases, id: \.self) { key in
                    row(key)
                }
            }
        } header: {
            Text("New chats")
        } footer: {
            if store.isSupported != false {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NewChatDefaults.helpText)
                        .foregroundStyle(.secondary)
                    if let error = store.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
        }
    }

    /// A picker once the first read has answered; until then a placeholder
    /// that says whether it is still loading or the read failed.
    @ViewBuilder
    private func row(_ key: NewChatDefaults.Key) -> some View {
        if let defaults = store.defaults {
            Picker(key.title, selection: Binding(
                get: { defaults[key] },
                set: { value in Task { await store.set(key, to: value) } }
            )) {
                ForEach(key.choices(stored: defaults[key]), id: \.self) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
        } else {
            LabeledContent(key.title, value: store.errorMessage == nil ? "Loading…" : "Unavailable")
        }
    }
}
