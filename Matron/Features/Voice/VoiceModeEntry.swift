import SwiftUI
import MatronVoice

/// How voice mode was opened (spec 2026-10-03 §5): from inside a
/// conversation it talks to that conversation; from anywhere else it
/// opens on what needs the user.
enum VoiceModeEntry: Equatable, Identifiable {
    case conversation(id: String, title: String, boxName: String?)
    case queue

    var id: String {
        switch self {
        case .conversation(let id, _, _): return "conversation:\(id)"
        case .queue: return "queue"
        }
    }
}

enum VoiceModeAvailability {
    /// Voice mode needs iOS 26 (the on-device speech APIs) and a device
    /// whose recogniser is available. Below that its buttons are hidden;
    /// the app's floor stays where it is. Asked once a launch: the shell
    /// reads it every time its body runs.
    @MainActor static let isSupported: Bool = {
        if #available(iOS 26, *) { return VoiceCapture.isSupported }
        return false
    }()

    /// Whether voice mode may open right now. One microphone: a voice
    /// note being recorded owns the audio session, and voice mode does
    /// not take it from under the note (the other half of the rule is
    /// `VoiceNoteSession.isVoiceModeOn`).
    static func canOpen(supported: Bool, recordingVoiceNote: Bool) -> Bool {
        supported && !recordingVoiceNote
    }
}

/// The app shell's way in (spec §6, "Entry"): opens voice mode on what
/// needs the user. Draws nothing where voice mode cannot run.
struct VoiceModeQueueButton: ToolbarContent {
    @Environment(\.openVoiceMode) private var openVoiceMode

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let openVoiceMode {
                Button { openVoiceMode(.queue) } label: { Image(systemName: "waveform") }
                    .accessibilityLabel("Voice mode")
                    .accessibilityIdentifier("voice-mode-queue")
            }
        }
    }
}

extension EnvironmentValues {
    /// Opens voice mode over the whole shell. Set by `AppShellView`; `nil`
    /// (previews, tests, an unsupported device, a voice note being
    /// recorded) draws no button.
    @Entry var openVoiceMode: ((VoiceModeEntry) -> Void)? = nil
}
