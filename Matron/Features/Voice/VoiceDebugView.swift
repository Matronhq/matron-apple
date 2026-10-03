import AVFoundation
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronVoice

/// Hidden (Session sheet ▸ "Speak a reply", shown under `MatronDebug` or
/// the hidden switch in Settings ▸ Voice mode): says any
/// turn's spoken line, so the voices can be judged before voice mode can
/// listen. Plays straight to the speaker with a `.playback` session; voice
/// mode itself plays through the capture engine.
struct VoiceDebugView: View {
    let convoID: String
    let store: JournalStore
    let synth: any SpeechSynthesising
    let settings: VoiceSettings

    struct Line: Identifiable, Equatable {
        let id: String
        let title: String
        let text: String
    }

    @State private var lines: [Line] = []
    @State private var player: SpeechPlayer?
    @State private var lastSource: String?

    /// Newest first: the last reply through the cleaner, then every turn's
    /// spoken line and its longer version.
    static func lines(convoID: String, store: JournalStore) -> [Line] {
        var out: [Line] = []
        if let reply = try? store.lastAgentReply(convoID: convoID) {
            let short = SpeechCleaner.fallbackShort(reply.body)
            if !short.isEmpty { out.append(Line(id: "cleaner", title: "Last reply, through the cleaner", text: short)) }
        }
        for entry in ((try? store.summaryEntries(convoID: convoID)) ?? []).prefix(30) {
            if let spoken = entry.spoken {
                out.append(Line(id: "s\(entry.seq)", title: entry.toc, text: spoken))
            }
            if let more = entry.spokenMore {
                out.append(Line(id: "m\(entry.seq)", title: "\(entry.toc) (more)", text: more))
            }
        }
        return out
    }

    var body: some View {
        List {
            if let lastSource {
                Section { Text("Last spoken by: \(lastSource)").font(.footnote) }
            }
            Section("Tap a line to hear it") {
                if lines.isEmpty {
                    Text("No spoken lines in this conversation yet.").foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    Button { speak(line.text) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.title).font(.footnote).foregroundStyle(.secondary)
                            Text(line.text)
                        }
                    }
                    .foregroundStyle(Color.primary)
                }
            }
            Section("Sounds") {
                ForEach(VoiceModeEngine.Earcon.allCases, id: \.self) { earcon in
                    Button(earcon.rawValue) {
                        activate()
                        player?.play(earcon)
                    }
                }
            }
        }
        .navigationTitle("Speak a reply")
        .task {
            lines = Self.lines(convoID: convoID, store: store)
            let made = SpeechPlayer(synth: synth, cache: .standard(), output: PlayerClipOutput(),
                                    local: SynthesizerLocalVoice(), settings: settings)
            player = made
            await made.refreshVoices()
        }
        .onDisappear {
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activate() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func speak(_ text: String) {
        guard let player else { return }
        activate()
        Task {
            let source = await player.speak(text)
            lastSource = source.rawValue
        }
    }
}
