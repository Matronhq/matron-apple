// Needs `VoiceCapture`, which only an Xcode with the iOS 26 SDK compiles
// (see `VoiceCapture.swift`).
#if compiler(>=6.2)
import SwiftUI
import UIKit
import MatronJournal
import MatronViewModels
import MatronVoice

/// THROWAWAY (deleted at the end of PR 3). The phase-0 spike of spec
/// 2026-10-03 §13: plays a minute of speech through the capture engine at
/// whatever volume the phone is set to, with the microphone open under it,
/// and logs what the detector and recogniser make of it. The question it
/// answers: does the app's own voice trigger talking-over?
@available(iOS 26, *)
@MainActor
@Observable
final class VoiceSpike {
    static let clip = """
    This is the talking over test. For the next minute I will keep speaking at a steady pace, and nobody in the room \
    should say anything. The app is listening to its own microphone while I talk. If echo cancellation is working, \
    it hears silence, and nothing below changes. If it is not, it hears me, and the counts below go up. \
    The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. \
    How razorback jumping frogs can level six piqued gymnasts. Sphinx of black quartz, judge my vow. \
    The five boxing wizards jump quickly. We promptly judged antique ivory buckles for the next prize. \
    That is the end of the pangrams. I am still talking, and you are still quiet. A few more seconds. \
    The last part of the test is yours. When I say now, say the word stop, once, in your normal voice. Now.
    """

    private(set) var log: [String] = []
    private(set) var running = false
    private(set) var speechWindows = 0
    private(set) var longWindows = 0
    private(set) var echoWordEvents = 0
    private(set) var otherWordEvents = 0
    private(set) var source = ""

    private var started = Date()
    private var windowStart: Date?
    /// The run in progress, and what it holds, so `stop()` can end it.
    private var task: Task<Void, Never>?
    private var player: SpeechPlayer?
    private var session: VoiceAudioSession?

    var summary: String {
        "speech windows \(speechWindows) · of 300 ms or more \(longWindows) · own words heard \(echoWordEvents) · other words \(otherWordEvents) · voice \(source)"
    }

    private func note(_ line: String) {
        log.append(String(format: "%6.2f  %@", Date().timeIntervalSince(started), line))
    }

    func start(synth: any SpeechSynthesising, settings: VoiceSettings, voiceProcessing: Bool) {
        guard !running else { return }
        running = true
        task = Task { await run(synth: synth, settings: settings, voiceProcessing: voiceProcessing) }
    }

    /// The screen went away: the clip stops and the audio session is
    /// given back now; the run then closes the microphone and ends.
    func stop() {
        task?.cancel()
        player?.stop()
        session?.release()
    }

    private func run(synth: any SpeechSynthesising, settings: VoiceSettings, voiceProcessing: Bool) async {
        log = []
        speechWindows = 0; longWindows = 0; echoWordEvents = 0; otherWordEvents = 0
        started = Date()
        let audio = VoiceAudioEngine(voiceProcessing: voiceProcessing)
        let session = VoiceAudioSession(engine: audio)
        let capture = VoiceCapture(audio: audio)
        // A minute of speech can take the journal longer than the two
        // seconds a reply is given, and the run would then only ever try
        // the on-device voice. Here the cloud clip is waited for; choose
        // "On-device" in Settings ▸ Voice mode to try that voice instead.
        let player = SpeechPlayer(synth: synth, cache: .standard(), output: audio, local: EngineLocalVoice(audio: audio),
                                  settings: settings, firstAudioTimeout: .seconds(20))
        self.session = session
        self.player = player
        // A run is a minute of nobody touching the phone: it must not lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            self.session = nil
            self.player = nil
            task = nil
            running = false
        }
        do {
            try session.activate()
            note("route \(session.routeName) voiceProcessing=\(voiceProcessing)")
            try await capture.start(.monitor)
        } catch {
            note("FAILED to start: \(error)")
            session.release()
            return
        }
        let events = capture.events
        let listening = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .speechStarted:
                    self.speechWindows += 1
                    self.windowStart = Date()
                    self.note("speech started")
                case .speechEnded:
                    let length = self.windowStart.map { Date().timeIntervalSince($0) } ?? 0
                    if length >= 0.3 { self.longWindows += 1 }
                    self.note(String(format: "speech ended after %.2f s", length))
                case .words(let text):
                    if VoiceModeEngine.isEcho(text, of: Self.clip) {
                        self.echoWordEvents += 1
                        self.note("OWN WORDS: \(text)")
                    } else if !text.isEmpty {
                        self.otherWordEvents += 1
                        self.note("words: \(text)")
                    }
                case .failed:
                    self.note("capture FAILED")
                }
            }
        }
        // The recogniser can take a while to start (its model may need
        // installing): the screen may have gone in the meantime.
        if !Task.isCancelled {
            source = (await player.speak(Self.clip)).rawValue
            note("clip finished (\(source))")
            try? await Task.sleep(for: .seconds(4))
        }
        listening.cancel()
        _ = await capture.stop(keep: false)
        session.release()
        note(Task.isCancelled ? "stopped: the screen was closed" : summary)
    }
}

@available(iOS 26, *)
struct VoiceSpikeView: View {
    let synth: any SpeechSynthesising
    let settings: VoiceSettings
    @State private var spike = VoiceSpike()
    @Environment(VoiceNoteSession.self) private var voiceNotes: VoiceNoteSession?

    /// A voice note being recorded owns the audio session: the spike does
    /// not take it until the note is sent or discarded.
    private var recordingVoiceNote: Bool { voiceNotes?.isRecording == true }

    var body: some View {
        List {
            if recordingVoiceNote {
                Section { Text("A voice note is being recorded. Finish it to run the spike.").font(.footnote) }
            }
            Section {
                Button("Run with voice processing") { run(voiceProcessing: true) }
                Button("Run WITHOUT voice processing (comparison)") { run(voiceProcessing: false) }
            }
            .disabled(spike.running || recordingVoiceNote)
            Section("Result") {
                Text(spike.summary).font(.footnote.monospaced())
                Button("Copy log") { UIPasteboard.general.string = spike.log.joined(separator: "\n") }
            }
            Section("Log") {
                ForEach(Array(spike.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Talking-over spike")
        .onDisappear { spike.stop() }
    }

    private func run(voiceProcessing: Bool) {
        guard !recordingVoiceNote else { return }
        spike.start(synth: synth, settings: settings, voiceProcessing: voiceProcessing)
    }
}
#endif
