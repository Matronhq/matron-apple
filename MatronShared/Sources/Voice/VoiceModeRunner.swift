import Foundation
import Observation
import os

/// Carries out the engine's effects and feeds what they produce back in
/// (spec 2026-10-03 §3). The one object a screen, the Mac's stage or a
/// CarPlay scene holds: read `state`, call `send`.
@MainActor
@Observable
public final class VoiceModeRunner {
    public private(set) var state = VoiceModeEngine.State()
    /// Called once when voice mode has ended, by the user or by itself.
    @ObservationIgnored public var onEnded: ((VoiceModeEngine.EndReason) -> Void)?

    @ObservationIgnored private let capture: any VoiceCapturing
    @ObservationIgnored private let audio: any VoiceAudioControlling
    @ObservationIgnored private let player: any SpeechPlaying
    @ObservationIgnored private let sender: any VoiceSending
    @ObservationIgnored private let feed: any VoiceFeeding
    @ObservationIgnored private let settings: VoiceSettings
    @ObservationIgnored private let setScreenAwake: (Bool) -> Void
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// How long the microphone is given to open before it is given up on.
    /// Opening it can wait on things with no end of their own: the
    /// permission prompt, and the recogniser's model being downloaded.
    @ObservationIgnored private let captureStartTimeout: TimeInterval

    @ObservationIgnored private var timers: [VoiceModeEngine.TimerID: Task<Void, Never>] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    /// Effects run one after another in the order the engine gave them.
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Bumped by every `stopPlayback`. A `play` waits its turn in the
    /// chain while `stopPlayback` acts at once, so a line can be stopped
    /// before it has begun: it then finds this moved on and says nothing.
    @ObservationIgnored private var playGeneration = 0

    private enum StartOutcome { case started, failed, timedOut, abandoned }
    /// The microphone start the chain is waiting on, if any.
    @ObservationIgnored private var pendingStart: AsyncStream<StartOutcome>.Continuation?
    /// Starts that were given up on and have not come back yet. While
    /// there is one, another start would overlap it, so none is made.
    @ObservationIgnored private var abandonedStarts = 0
    /// Voice mode has ended. One runner serves one sitting: its streams
    /// are finished and it does not start again.
    @ObservationIgnored private var ended = false

    /// The utterance last kept: its file, and its blob once uploaded.
    private struct Recording {
        let id: Int
        let url: URL
        var blob: (ref: String, size: Int)?
    }
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var nextRecordingID = 1
    /// Notes that could not leave (offline), kept until they do. Observed:
    /// a screen shows `unsentCount`, and a note leaving changes nothing in
    /// `state`.
    private var unsent: [(recording: Recording, target: VoiceModeEngine.SendTarget)] = []

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-runner")

    public init(capture: any VoiceCapturing, audio: any VoiceAudioControlling, player: any SpeechPlaying,
                sender: any VoiceSending, feed: any VoiceFeeding, settings: VoiceSettings,
                setScreenAwake: @escaping (Bool) -> Void = { _ in },
                captureStartTimeout: TimeInterval = 20,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.capture = capture
        self.audio = audio
        self.player = player
        self.sender = sender
        self.feed = feed
        self.settings = settings
        self.setScreenAwake = setScreenAwake
        self.captureStartTimeout = captureStartTimeout
        self.sleep = sleep
    }

    // MARK: In

    public func start(_ start: VoiceModeEngine.Start) {
        guard state.phase == .idle, !ended else { return }
        subscribe()
        send(.configChanged(settings.engineConfig(state.config)))
        send(.routeChanged(audio.routeName))
        send(.start(start))
    }

    /// The settings screen changed something while voice mode is on.
    public func settingsChanged() {
        send(.configChanged(settings.engineConfig(state.config)))
    }

    /// The connection is back: notes kept while offline go now.
    public func connectionRestored() {
        guard !unsent.isEmpty else { return }
        let waiting = unsent
        unsent = []
        for entry in waiting { deliver(entry.recording, to: entry.target, announceFailure: false) }
    }

    public func send(_ event: VoiceModeEngine.Event) {
        let (next, effects) = VoiceModeEngine.reduce(state, event)
        if next != state { state = next }
        for effect in effects { perform(effect) }
    }

    private func subscribe() {
        guard listeners.isEmpty else { return }
        let captureEvents = capture.events
        listeners.append(Task { [weak self] in
            for await event in captureEvents {
                switch event {
                case .speechStarted: self?.send(.speechStarted)
                case .speechEnded: self?.send(.speechEnded)
                case .words(let text): self?.send(.words(text))
                case .failed: self?.send(.captureFailed)
                }
            }
        })
        for stream in [audio.events, feed.events] {
            listeners.append(Task { [weak self] in
                for await event in stream { self?.send(event) }
            })
        }
    }

    // MARK: Out

    /// Queued effects hold the runner (`self`, not `weak self`) until they
    /// have run: voice mode's owner may let go of it the moment it sends
    /// `end`, and the microphone must still be closed, the audio given
    /// back and the feed stopped. Each one finishes, so nothing is kept
    /// for ever.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// For tests: every queued effect has been carried out.
    func settle() async {
        await chain?.value
    }

    private func perform(_ effect: VoiceModeEngine.Effect) {
        switch effect {
        case .startTimer(let id, let interval, let token):
            timers[id]?.cancel()
            let sleep = self.sleep
            timers[id] = Task { [weak self] in
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                // The token says which start this firing belongs to: the
                // engine ignores one that has been re-armed since.
                self?.send(.timerFired(id, token: token))
            }
        case .cancelTimer(let id):
            timers[id]?.cancel()
            timers[id] = nil
        case .watch(let convoID):
            feed.watch(convoID: convoID)
        case .keepScreenAwake(let awake):
            setScreenAwake(awake)
        case .duck:
            player.setDucked(true)
        case .restoreVolume:
            player.setDucked(false)
        case .stopPlayback:
            playGeneration += 1
            playTask?.cancel()
            playTask = nil
            player.stop()
        case .earcon(let earcon):
            enqueue { [player] in player.play(earcon) }
        case .activateAudio:
            enqueue { [self] in
                do {
                    try audio.activate()
                } catch {
                    Self.logger.error("activate: \(error.localizedDescription, privacy: .public)")
                    send(.captureFailed)
                }
            }
        case .releaseAudio:
            enqueue { [audio] in audio.release() }
        case .startCapture(let mode):
            enqueue { [self] in await openCapture(mode) }
        case .promoteCapture:
            enqueue { [capture] in capture.promote() }
        case .stopCapture(let keep):
            enqueue { [self] in
                let url = await capture.stop(keep: keep)
                guard keep, let url else { return }
                replaceRecording(with: url)
            }
        case .play(let utterance):
            let generation = playGeneration
            enqueue { [self] in
                // Stopped while it waited its turn: it is not said.
                guard playGeneration == generation else { return }
                playTask = Task { [weak self] in
                    guard let self else { return }
                    let source = await self.player.speak(utterance.text)
                    guard source != .stopped, !Task.isCancelled else { return }
                    // Nothing could say it. The engine still moves on (it
                    // has no other way out of `speaking`); the caption was
                    // on the screen.
                    if source == .failed { Self.logger.error("a line could not be said") }
                    self.send(.playbackFinished(utterance.id))
                }
            }
        case .upload:
            enqueue { [self] in upload() }
        case .sendVoiceNote(let target):
            enqueue { [self] in
                guard let recording else { return }
                self.recording = nil
                deliver(recording, to: target, announceFailure: recording.blob != nil)
            }
        case .discardRecording:
            enqueue { [self] in
                guard let recording else { return }
                self.recording = nil
                try? FileManager.default.removeItem(at: recording.url)
            }
        case .sendItemAction(let itemID, let label):
            Task { [sender] in await sender.sendItemAction(itemID: itemID, label: label) }
        case .sendPromptReply(let convoID, let seq, let choice, let text):
            Task { [weak self, sender] in
                do {
                    try await sender.sendPromptReply(convoID: convoID, seq: seq, choice: choice, text: text)
                } catch {
                    self?.send(.sendFailed)
                }
            }
        case .ended(let reason):
            // Ending does not wait for a microphone that is still opening,
            // and does not open one that has yet to.
            ended = true
            pendingStart?.yield(.abandoned)
            enqueue { [self] in finish(reason) }
        }
    }

    /// Opens the microphone, for at most `captureStartTimeout`. Everything
    /// queued behind this waits for it, the end of voice mode included, so
    /// a start that never returns must not be waited on for ever. One that
    /// is given up on (timed out, or voice mode ended) is left to finish
    /// by itself, and whatever it opened is closed again when it does.
    private func openCapture(_ mode: VoiceModeEngine.CaptureMode) async {
        guard !ended else { return }
        guard abandonedStarts == 0 else {
            Self.logger.error("capture: an earlier start has not come back")
            send(.captureFailed)
            return
        }
        let capture = self.capture
        let (outcomes, outcome) = AsyncStream<StartOutcome>.makeStream()
        pendingStart = outcome
        let attempt = Task { @MainActor () -> Bool in
            do {
                try await capture.start(mode)
                outcome.yield(.started)
                return true
            } catch {
                Self.logger.error("capture: \(error.localizedDescription, privacy: .public)")
                outcome.yield(.failed)
                return false
            }
        }
        let sleep = self.sleep
        let timeout = captureStartTimeout
        let clock = Task {
            do { try await sleep(timeout) } catch { return }
            outcome.yield(.timedOut)
        }
        var first = StartOutcome.failed
        for await value in outcomes {
            first = value
            break
        }
        outcome.finish()
        pendingStart = nil
        clock.cancel()
        switch first {
        case .started:
            break
        case .failed:
            send(.captureFailed)
        case .timedOut, .abandoned:
            abandonedStarts += 1
            let audio = self.audio
            Task { @MainActor [weak self] in
                if await attempt.value { _ = await capture.stop(keep: false) }
                self?.abandonedStarts -= 1
                // The late start may have set the audio engine going after
                // voice mode let go of it.
                if self?.state.audioActive != true { audio.release() }
            }
            if first == .timedOut {
                Self.logger.error("capture: no microphone after \(timeout, format: .fixed(precision: 0)) s")
                send(.captureFailed)
            }
        }
    }

    private func replaceRecording(with url: URL) {
        if let old = recording { try? FileManager.default.removeItem(at: old.url) }
        recording = Recording(id: nextRecordingID, url: url, blob: nil)
        nextRecordingID += 1
    }

    /// Uploads the current recording and asks for its words. The answer is
    /// dropped if the recording was discarded or replaced meanwhile.
    private func upload() {
        guard let recording else {
            send(.uploadFailed)
            return
        }
        let wait = Int(state.config.transcriptTimeout.rounded(.up))
        Task { [weak self, sender] in
            do {
                let data = try Data(contentsOf: recording.url)
                let ref = try await sender.upload(data)
                guard let self, self.recording?.id == recording.id else { return }
                self.recording?.blob = (ref, data.count)
                let words = await sender.transcript(blobRef: ref, waitSeconds: wait)
                guard self.recording?.id == recording.id else { return }
                self.send(.transcript(words))
            } catch {
                guard let self, self.recording?.id == recording.id else { return }
                self.send(.uploadFailed)
            }
        }
    }

    /// Sends a kept note, uploading it first when that has not happened.
    /// Offline, it is kept and goes when the connection is back; the
    /// engine is told (`sendFailed`) only when it does not already know.
    private func deliver(_ recording: Recording, to target: VoiceModeEngine.SendTarget, announceFailure: Bool) {
        Task { [weak self, sender] in
            var recording = recording
            do {
                if recording.blob == nil {
                    let data = try Data(contentsOf: recording.url)
                    recording.blob = (try await sender.upload(data), data.count)
                }
                guard let blob = recording.blob else { return }
                try await sender.sendVoiceNote(blobRef: blob.ref, size: blob.size, to: target)
                try? FileManager.default.removeItem(at: recording.url)
            } catch {
                guard let self else { return }
                self.unsent.append((recording, target))
                if announceFailure { self.send(.sendFailed) }
            }
        }
    }

    private func finish(_ reason: VoiceModeEngine.EndReason) {
        for task in timers.values { task.cancel() }
        timers = [:]
        for task in listeners { task.cancel() }
        listeners = []
        playTask?.cancel()
        playTask = nil
        feed.stop()
        onEnded?(reason)
    }

    /// Notes still waiting for a connection, for the host to show.
    public var unsentCount: Int { unsent.count }
}
