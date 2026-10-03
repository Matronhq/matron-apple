import SwiftUI
import MatronJournal
import MatronVoice

/// Settings ▸ Voice mode (spec 2026-10-03 §6): the voice, its speed,
/// whether talking over the agent interrupts it, and whether "more" is
/// offered after a reply.
struct VoiceSettingsSection: View {
    @Bindable var settings: VoiceSettings
    /// Asks the journal which voices it has. `nil` (previews, tests) keeps
    /// the built-in pair.
    var synth: (any SpeechSynthesising)? = nil

    @State private var voices: [TTSVoice] = VoiceSettings.builtInVoices
    @State private var defaultVoiceID: String?
    @State private var cloudUnavailable = false

    /// The picker's selection: the user's choice, else the journal's
    /// default, else the first voice on offer. On-device when the journal
    /// has no cloud voice.
    static func selection(stored: String?, defaultVoiceID: String?, voices: [TTSVoice], cloudUnavailable: Bool) -> String {
        if cloudUnavailable || stored == VoiceSettings.onDevice { return VoiceSettings.onDevice }
        if let stored, voices.contains(where: { $0.id == stored }) { return stored }
        if let defaultVoiceID, voices.contains(where: { $0.id == defaultVoiceID }) { return defaultVoiceID }
        return voices.first?.id ?? VoiceSettings.onDevice
    }

    /// The slider's steps as stored: 1.2, not 1.2000000000000002.
    static func stepped(_ rate: Double) -> Double {
        (rate * 10).rounded() / 10
    }

    static func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f×", rate)
    }

    private var selection: Binding<String> {
        Binding(
            get: { Self.selection(stored: settings.voice, defaultVoiceID: defaultVoiceID, voices: voices,
                                  cloudUnavailable: cloudUnavailable) },
            set: { settings.voice = $0 })
    }

    private var rate: Binding<Double> {
        Binding(get: { settings.rate }, set: { settings.rate = Self.stepped($0) })
    }

    var body: some View {
        Section {
            Picker("Voice", selection: selection) {
                if !cloudUnavailable {
                    ForEach(voices) { voice in Text(voice.name).tag(voice.id) }
                }
                Text("On-device").tag(VoiceSettings.onDevice)
            }
            VStack(alignment: .leading) {
                Text("Speaking rate: \(Self.rateLabel(settings.rate))")
                Slider(value: rate, in: VoiceSettings.rateRange, step: 0.1)
                    .accessibilityLabel("Speaking rate")
            }
            Toggle("Talk over the agent", isOn: $settings.talkOver)
            Toggle("Offer \u{201C}more\u{201D} after a reply", isOn: $settings.offerMore)
        } header: {
            // A long press shows or hides "Speak a reply" in a
            // conversation's Session sheet (diagnostics).
            Text(settings.debugTools ? "Voice mode (debug tools on)" : "Voice mode")
                .onLongPressGesture { settings.debugTools.toggle() }
        } footer: {
            Text(cloudUnavailable
                 ? "This journal has no cloud voice, so the on-device voice is used. Talking over the agent stops it; anyone's voice does, a passenger's included."
                 : "Talking over the agent stops it; anyone's voice does, a passenger's included. A tap always works.")
        }
        .task {
            guard let synth else { return }
            do {
                let answer = try await synth.ttsVoices()
                if !answer.voices.isEmpty { voices = answer.voices }
                defaultVoiceID = answer.defaultVoiceID
            } catch TTSError.unavailable {
                cloudUnavailable = true
            } catch {
                // Busy or offline: keep the built-in pair and ask next time.
            }
        }
    }
}
