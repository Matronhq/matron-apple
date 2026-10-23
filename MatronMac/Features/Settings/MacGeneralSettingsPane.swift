#if os(macOS)
import SwiftUI
import MatronModels
import MatronDesignSystem
import MatronViewModels

/// Settings → General: how the app looks and behaves day to day —
/// appearance, the voice note key, the defaults for new chats and
/// auto-archive.
struct MacGeneralSettingsPane: View {
    @AppStorage(VoiceNoteHotkeyKey.storageKey) private var voiceHotkeyRaw = VoiceNoteHotkeyKey.default.rawValue
    let session: UserSession
    let deps: AppDependencies

    var body: some View {
        Form {
            Section("Appearance") {
                // Writes MatronAppearance.storageKey; MatronMacApp's root
                // @AppStorage observes the same key and applies it via
                // NSApp.appearance, so the switch is live app-wide.
                AppearancePicker()
            }
            Section {
                // Same pattern: MatronMacApp's root observes the key and
                // re-registers the Carbon hotkey live.
                Picker("Voice note key", selection: $voiceHotkeyRaw) {
                    ForEach(VoiceNoteHotkeyKey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
            } header: {
                Text("Voice notes")
            } footer: {
                Text("Press the key from any app to start a voice note in the open chat, and again to send it. On Apple keyboards F5 is the Dictation key: turn off the Dictation shortcut in System Settings → Keyboard, or pick another key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MacNewChatDefaultsSection(store: deps.newChatDefaults(for: session))
            MacAutoArchiveSettingsSection(store: deps.userSettings(for: session))
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        // On opening as well as on every connect: a `defaults` frame missed
        // while the socket was down is caught here.
        .task { await deps.newChatDefaults(for: session).refresh() }
    }
}
#endif
