import SwiftUI
import MatronModels

/// Names the microphone a voice note is recording from and lets the user
/// pick another. Sits in the recording bar while a note starts and
/// records. The pick is remembered for later notes. With a
/// `defaultTitle` the list starts with that row, meaning "follow the
/// system" (the Mac's default input); without one the microphone in use
/// is ticked until the user picks (iPhone, where the default is simply
/// the built-in microphone, already in the list).
///
/// Values only: the app shells bind it to `VoiceRecorder`.
public struct MicrophoneMenu: View {
    let current: Microphone?
    let available: [Microphone]
    let preferredID: String?
    let defaultTitle: String?
    let onSelect: (String?) -> Void

    public init(current: Microphone?, available: [Microphone], preferredID: String?,
                defaultTitle: String?, onSelect: @escaping (String?) -> Void) {
        self.current = current
        self.available = available
        self.preferredID = preferredID
        self.defaultTitle = defaultTitle
        self.onSelect = onSelect
    }

    private var selection: String? {
        defaultTitle == nil ? preferredID ?? current?.id : preferredID
    }

    public var body: some View {
        Menu {
            Picker("Microphone", selection: Binding(get: { selection }, set: onSelect)) {
                if let defaultTitle {
                    Text(defaultTitle).tag(String?.none)
                }
                ForEach(available) { mic in
                    Text(mic.name).tag(Optional(mic.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                Text(current?.name ?? "Microphone")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Microphone: \(current?.name ?? "unknown")")
        .accessibilityHint("Choose which microphone records")
        .accessibilityIdentifier("voiceNote.microphone")
    }
}
