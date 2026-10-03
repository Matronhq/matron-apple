import AVFoundation
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronViewModels
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
    @State private var output: PlayerClipOutput?
    @State private var lastSource: String?
    /// Whether this view took the audio session, so it only gives back
    /// what it took.
    @State private var tookAudioSession = false
    @Environment(VoiceNoteSession.self) private var voiceNotes: VoiceNoteSession?

    /// A voice note being recorded owns the audio session: nothing here
    /// plays until it is sent or discarded.
    private var recordingVoiceNote: Bool { voiceNotes?.isRecording == true }

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
            if recordingVoiceNote {
                Section { Text("A voice note is being recorded. Finish it to hear a line.").font(.footnote) }
            } else if let lastSource {
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
            #if compiler(>=6.2)
            if #available(iOS 26, *) {
                Section("Spike") {
                    NavigationLink("Talking-over spike") { VoiceSpikeView(synth: synth, settings: settings) }
                }
            }
            #endif
            Section("Sounds") {
                ForEach(VoiceModeEngine.Earcon.allCases, id: \.self) { earcon in
                    Button(earcon.rawValue) {
                        guard activate() else { return }
                        player?.play(earcon)
                    }
                }
            }
        }
        .navigationTitle("Speak a reply")
        .task {
            lines = Self.lines(convoID: convoID, store: store)
            let clips = PlayerClipOutput()
            let made = SpeechPlayer(synth: synth, cache: .standard(), output: clips,
                                    local: SynthesizerLocalVoice(), settings: settings)
            output = clips
            player = made
            await made.refreshVoices()
        }
        .onDisappear {
            player?.stop()
            output?.stopEffects()
            guard tookAudioSession, !recordingVoiceNote else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// False while a voice note is being recorded.
    private func activate() -> Bool {
        guard !recordingVoiceNote else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        tookAudioSession = true
        return true
    }

    private func speak(_ text: String) {
        guard let player, activate() else { return }
        Task {
            let source = await player.speak(text)
            // An overtaken line ends as `stopped` after the line that
            // overtook it has begun: it is not what was last spoken.
            if source != .stopped { lastSource = source.rawValue }
        }
    }
}
