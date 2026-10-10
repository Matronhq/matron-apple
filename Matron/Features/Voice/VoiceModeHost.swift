import SwiftUI
import UIKit
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
import MatronVoice

/// Engine state as the screen draws it. Not availability-gated, so tests
/// and older systems can still compile against it.
enum VoiceModeScreenMapping {
    static func model(_ state: VoiceModeEngine.State, unsentCount: Int) -> VoiceModeScreen.Model {
        let phase: VoiceModeScreen.Model.Phase
        switch state.phase {
        case .idle, .waiting: phase = state.isAgentWorking ? .working : .waiting
        case .listening: phase = .listening
        case .sending: phase = .sending
        // "Did you mean Go?" sends on "yes" only; "Sending: Go" sends
        // unless he says "cancel". The screen must not mix them up.
        case .confirming: phase = state.confirm?.kind == .didYouMean ? .asking : .confirming
        case .speaking: phase = .speaking
        }
        return VoiceModeScreen.Model(title: state.title, boxName: state.current?.boxName ?? state.boxName, phase: phase,
                                     caption: state.caption ?? confirmCaption(state), labels: state.labels,
                                     unsentCount: unsentCount)
    }

    /// The engine clears its caption when a confirmation's clip ends, but
    /// the question is still open: what is about to be sent stays on the
    /// screen until it is answered.
    private static func confirmCaption(_ state: VoiceModeEngine.State) -> String? {
        guard state.phase == .confirming, let confirm = state.confirm else { return nil }
        switch confirm.kind {
        case .sending: return VoicePhrases.sending(confirm.label)
        case .didYouMean: return VoicePhrases.didYouMean(confirm.label)
        }
    }
}

// The sitting and its screen need `VoiceCapture`, which only an Xcode with
// the iOS 26 SDK compiles (see `VoiceCapture.swift`).
#if compiler(>=6.2)

/// Everything one voice-mode sitting owns: the audio engine, the
/// microphone, the voice, the feed and the runner that ties them to the
/// engine. Built when the screen appears, torn down when it ends.
@available(iOS 26, *)
@MainActor
@Observable
final class VoiceModeSession {
    let runner: VoiceModeRunner
    @ObservationIgnored private let feed: JournalVoiceFeed
    @ObservationIgnored private let player: SpeechPlayer
    @ObservationIgnored private var connectionTask: Task<Void, Never>?

    /// - Parameter keepsScreenAwake: `false` for a sitting on the car's
    ///   display, which has no business with the iPhone's idle timer.
    init(entry: VoiceModeEntry, session: UserSession, deps: AppDependencies, settings: VoiceSettings,
         keepsScreenAwake: Bool = true) {
        let audio = VoiceAudioEngine()
        let scope: JournalVoiceFeed.Scope
        switch entry {
        case .conversation(let id, _, _): scope = .conversation(id)
        case .queue: scope = .everything
        }
        feed = JournalVoiceFeed(store: deps.journalStore(for: session), text: .cleaner, scope: scope)
        player = SpeechPlayer(synth: deps.speechSynthesiser(for: session), cache: .standard(), output: audio,
                              local: EngineLocalVoice(audio: audio), settings: settings)
        runner = VoiceModeRunner(
            capture: VoiceCapture(audio: audio), audio: VoiceAudioSession(engine: audio), player: player,
            sender: deps.voiceSender(for: session), feed: feed, settings: settings,
            setScreenAwake: { if keepsScreenAwake { UIApplication.shared.isIdleTimerDisabled = $0 } })
        // A note kept while offline goes as soon as the socket is back.
        let sync = deps.syncService(for: session)
        connectionTask = Task { [weak runner] in
            for await state in await sync.stateStream() {
                if case .running = state { runner?.connectionRestored() }
            }
        }
    }

    func start(_ entry: VoiceModeEntry) {
        // Clips are kept only under a known voice id, so the journal is
        // asked which voice is its default as voice mode opens. Not
        // waited for: a line said before the answer is simply not kept.
        Task { [player] in await player.refreshVoices() }
        switch entry {
        case .conversation(let id, let title, let boxName):
            runner.start(.conversation(id: id, title: title, boxName: boxName))
        case .queue:
            let entries = feed.initialQueue()
            let last = feed.lastConversation()
            runner.start(.queue(entries: entries, lastConvoID: last?.id, lastTitle: last?.title ?? "",
                                lastBoxName: last?.boxName))
        }
        feed.startWatchingNeeds()
    }

    func end() {
        runner.send(.end)
        connectionTask?.cancel()
        connectionTask = nil
    }
}

/// The full-screen voice mode (spec 2026-10-03 §6). Phase 1 works while
/// the app is in front: leaving it pauses, coming back says what landed.
@available(iOS 26, *)
struct VoiceModeHost: View {
    let entry: VoiceModeEntry
    let session: UserSession
    let deps: AppDependencies
    let settings: VoiceSettings
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(VoiceNoteSession.self) private var voiceNotes: VoiceNoteSession?
    @State private var voice: VoiceModeSession?

    var body: some View {
        content
            .statusBarHidden()
            .task { begin() }
            .onChange(of: scenePhase) { _, phase in
                // `.inactive` (Control Centre, a system prompt) is not leaving.
                if phase == .background { voice?.runner.send(.appBackgrounded) }
                if phase == .active { voice?.runner.send(.appForegrounded) }
            }
            .onChange(of: settings.talkOver) { _, _ in voice?.runner.settingsChanged() }
            .onChange(of: settings.offerMore) { _, _ in voice?.runner.settingsChanged() }
            .onDisappear(perform: close)
    }

    @ViewBuilder private var content: some View {
        if let voice {
            VoiceModeScreen(
                model: VoiceModeScreenMapping.model(voice.runner.state, unsentCount: voice.runner.unsentCount),
                onTap: { voice.runner.send(.tap) },
                onSend: { voice.runner.send(.sendTapped) },
                onAction: { voice.runner.send(.actionTapped($0)) },
                onEnd: { voice.runner.send(.end) })
        } else {
            ProgressView()
        }
    }

    private func begin() {
        guard voice == nil else { return }
        // One microphone. A voice note being recorded owns the audio
        // session: voice mode does not open over it (the buttons are
        // hidden then; this is the same rule for any other way in).
        guard voiceNotes?.isRecording != true else {
            onClose()
            return
        }
        // A note still waiting on its permission prompt is not recording
        // yet: it is dropped, and none can start while voice mode is on.
        voiceNotes?.cancel()
        voiceNotes?.isVoiceModeOn = true
        let made = VoiceModeSession(entry: entry, session: session, deps: deps, settings: settings)
        made.runner.onEnded = { _ in onClose() }
        voice = made
        made.start(entry)
    }

    /// Only a sitting that began ends: one refused because a note was
    /// recording never set `isVoiceModeOn`, and has nothing to give back.
    private func close() {
        guard let voice else { return }
        voice.end()
        voiceNotes?.isVoiceModeOn = false
    }
}

#endif

/// The cover the shell presents. Its own view so the availability check
/// stays out of `AppShellView`'s body.
struct VoiceModeCover: View {
    let entry: VoiceModeEntry
    let session: UserSession
    let deps: AppDependencies
    let settings: VoiceSettings
    let onClose: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            VoiceModeHost(entry: entry, session: session, deps: deps, settings: settings, onClose: onClose)
        } else {
            unavailable
        }
        #else
        unavailable
        #endif
    }

    private var unavailable: some View {
        ContentUnavailableView("Voice mode needs iOS 26", systemImage: "waveform")
            .onTapGesture(perform: onClose)
    }
}
