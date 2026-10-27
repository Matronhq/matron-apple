import Foundation
import AVFoundation
import os
import MatronModels
#if os(iOS)
import UIKit
#endif

/// An audio-session interruption as the recorder sees it: a phone call,
/// Siri, or another app taking the microphone. iOS pauses the
/// `AVAudioRecorder` on `began`; `ended` says whether the system wants us
/// back on the mic (`shouldResume`). Platform-neutral so the resume logic
/// is testable where `AVAudioSession` doesn't exist (macOS, the shared
/// package's test host).
public enum AudioInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

/// Records a short voice note to a temporary AAC `.m4a` file for sending as
/// an `audio/*` attachment. Works on both iOS and macOS (the base
/// deployment targets — iOS 17 / macOS 14 — both ship
/// `AVAudioApplication.requestRecordPermission()` and `AVAudioRecorder`).
///
/// The `AVAudioRecorder` is reached through the `AudioRecording` seam and
/// the permission prompt through an injectable closure so the state machine
/// (idle → recording → finished / cancel, no double-start) is unit-testable
/// without touching the microphone or the (device-only) permission dialog.
@MainActor
@Observable
public final class VoiceRecorder {
    public enum State: Equatable {
        case idle
        /// The recorder is running but the microphone has not delivered
        /// sound yet. Input hardware can take seconds to come up (a
        /// Bluetooth headset switching to its call profile, an input device
        /// waking), and `record()` returns long before that. Anything said
        /// in this window is not in the file, so the UI must not say
        /// "recording" yet.
        case starting
        /// Actively capturing; `start` is the instant recording began, which
        /// the composer UI ticks against to show elapsed time.
        case recording(start: Date)
        case finished
    }

    public enum RecorderError: Error, Equatable {
        case permissionDenied
        case alreadyRecording
        case recordFailed
    }

    public private(set) var state: State = .idle

    /// The microphone the note in progress records from, once it is
    /// starting; `nil` when idle or when the platform can't say.
    public private(set) var microphone: Microphone?

    /// The user's pick, remembered across notes and launches. `nil` means
    /// the default: the system's input on the Mac, the built-in
    /// microphone on iPhone. A pick that isn't connected falls back to
    /// the default for that note.
    public private(set) var preferredMicrophoneID: String?

    /// Breadcrumbs for the "note came back silent" class of report
    /// (2026-09-06: three notes in a row carried no voice at all while the
    /// mic still heard taps on the phone body — the input route at the
    /// time was the unanswerable question). Read on-device with Console or
    /// `log collect --device`, subsystem chat.matron.
    private static let logger = os.Logger(subsystem: "chat.matron", category: "voice-recorder")

    private let requestPermission: () async -> Bool
    private let makeRecorder: (URL) throws -> AudioRecording
    /// `true` while capture is live, `false` once it ends — keeps the screen
    /// from auto-locking mid-recording (locking suspends the app and kills
    /// the capture). Injectable so tests can observe the claim/release pair.
    private let setKeepScreenAwake: (Bool) -> Void
    /// Subscribes a handler to interruption events for the life of one
    /// recording and returns the unsubscribe. Injectable so tests can
    /// deliver events; the real source maps `AVAudioSession`'s notification.
    private let observeInterruptions: (@escaping @MainActor (AudioInterruption) -> Void) -> () -> Void
    private var stopObservingInterruptions: (() -> Void)?
    /// True between an interruption's `began` and its `ended` — the only
    /// window in which an `ended` may resume capture. An `ended` with no
    /// `began` is a stale notification, not a reason to poke the recorder.
    private var isInterrupted = false
    /// An interruption during the warm-up ended without the resume hint:
    /// the start gives up.
    private var warmUpRefused = false
    /// Interruption bookkeeping for the reported duration: capture time,
    /// not wall time — a call in the middle of a note is silence the
    /// recorder never captured. `pausedSince` is set on `began` and cleared
    /// only by a resume; an unresumed pause runs until `stop()`.
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0
    private let now: () -> Date
    /// How `start()` waits between checks that the microphone is live.
    /// Injectable so tests drive the warm-up without real time passing.
    private let pause: () async -> Void
    private let listMicrophones: () -> [Microphone]
    private let defaults: UserDefaults
    static let preferredMicrophoneKey = "voiceNote.preferredMicrophoneID"
    private var recorder: AudioRecording?
    private var fileURL: URL?
    /// Parts of the note ended by mid-note microphone switches, oldest
    /// first, each with the recorder that may still be finishing its file;
    /// `stop()` joins them with the current part.
    private var finishedParts: [(segment: AudioSegment, recorder: AudioRecording)] = []
    /// The current part's lead-in to drop when the parts are joined.
    private var currentTrimStart: TimeInterval = 0
    /// A recorder on a microphone picked mid-note that hasn't heard sound
    /// yet. `recorder` keeps recording until it does, so nothing said
    /// while the new microphone comes up is lost.
    private var incoming: (recorder: AudioRecording, url: URL)?
    /// Waits for `incoming` to go live, then hands the note over to it.
    private(set) var microphoneHandover: Task<Void, Never>?
    private let joinSegments: @Sendable ([AudioSegment], URL) throws -> Void
    private var startedAt: Date?
    /// True from `start()`'s entry until it settles — rejects a second tap
    /// racing the permission `await` (state is still `.idle` in that gap, so
    /// the state check alone can't).
    private var isStarting = false
    /// Bumped by `cancel()`. `start()` snapshots it before the permission
    /// `await` and aborts quietly if it moved — a cancel that lands while
    /// the permission dialog is up (composer disappeared, second view
    /// teardown) must win over the in-flight start, or capture would begin
    /// with no recording UI. Everything after the single `await` is
    /// synchronous on the main actor, so one check suffices.
    private var cancelGeneration = 0

    /// Injectable seam used by `VoiceRecorderTests` to drive the state
    /// machine with a fake recorder and a granted-permission stub. The
    /// public `init()` wires the real AVFoundation implementations.
    init(requestPermission: @escaping () async -> Bool,
         makeRecorder: @escaping (URL) throws -> AudioRecording,
         setKeepScreenAwake: @escaping (Bool) -> Void = { _ in },
         observeInterruptions: @escaping (@escaping @MainActor (AudioInterruption) -> Void) -> () -> Void = { _ in {} },
         now: @escaping () -> Date = Date.init,
         pause: @escaping () async -> Void = { try? await Task.sleep(for: VoiceRecorder.liveCheckInterval) },
         listMicrophones: @escaping () -> [Microphone] = { [] },
         joinSegments: @escaping @Sendable ([AudioSegment], URL) throws -> Void = joinAudioSegments,
         defaults: UserDefaults = .standard) {
        self.requestPermission = requestPermission
        self.makeRecorder = makeRecorder
        self.setKeepScreenAwake = setKeepScreenAwake
        self.observeInterruptions = observeInterruptions
        self.now = now
        self.pause = pause
        self.listMicrophones = listMicrophones
        self.joinSegments = joinSegments
        self.defaults = defaults
        self.preferredMicrophoneID = defaults.string(forKey: Self.preferredMicrophoneKey)
    }

    /// The inputs a note can record from right now.
    public func availableMicrophones() -> [Microphone] {
        listMicrophones()
    }

    /// iOS moves the route a moment after `setPreferredInput`; read the
    /// name again once it has settled so the bar doesn't show the old mic.
    private func refreshMicrophoneSoon() {
        Task { [weak self] in
            for delay in [300, 1_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, self.recorder != nil else { return }
                self.microphone = self.displayedRecorder?.microphone
            }
        }
    }

    /// The recorder whose microphone the bar names: a pick mid-note shows
    /// at once, while the old microphone still records the hand-over.
    private var displayedRecorder: AudioRecording? { incoming?.recorder ?? recorder }

    /// Remembers `id` (`nil`: the default) for every note from now on and,
    /// when a note is starting or recording, moves it to that microphone
    /// straight away.
    public func selectMicrophone(_ id: String?) {
        preferredMicrophoneID = id
        defaults.set(id, forKey: Self.preferredMicrophoneKey)
        guard let recorder, let fileURL else { return }
        if recorder.canSwitchMicrophoneLive {
            recorder.useMicrophone(id)
        } else if case .starting = state {
            // Nothing has been captured yet, so the note starts over on
            // the new microphone and loses nothing. The old recorder may
            // still be finishing its file, so the fresh one gets its own.
            discard(recorder, file: fileURL)
            let freshURL = Self.newFileURL()
            guard let fresh = try? makeRecorder(freshURL) else { return }
            fresh.useMicrophone(id)
            guard fresh.record() else { return }
            self.recorder = fresh
            self.fileURL = freshURL
        } else if isRecordingState {
            handOver(to: id)
        }
        microphone = displayedRecorder?.microphone
        refreshMicrophoneSoon()
        Self.logger.info("microphone: now \(self.microphone?.name ?? "unknown", privacy: .public)")
    }

    /// Recording, on a recorder that can't move (the Mac's): a second
    /// recorder starts on the new microphone, and the first carries on
    /// until the second delivers sound. Then the first part is finished
    /// and the note continues in the second; `stop()` joins the parts,
    /// dropping the second's silent lead-in. If the new microphone won't
    /// start, or stays silent past the warm-up cap, the note stays where it
    /// is and the pick applies next time.
    private func handOver(to id: String?) {
        abandonHandover()
        let url = Self.newFileURL()
        guard let fresh = try? makeRecorder(url) else {
            Self.logger.error("microphone: couldn't make a recorder to switch to")
            return
        }
        fresh.useMicrophone(id)
        guard fresh.record() else {
            discard(fresh, file: url)
            Self.logger.error("microphone: the new microphone wouldn't start; staying on the old one")
            return
        }
        incoming = (fresh, url)
        microphoneHandover = Task { [weak self] in
            await self?.completeHandover(to: fresh)
        }
    }

    private func completeHandover(to fresh: AudioRecording) async {
        var checks = 0
        while incoming?.recorder === fresh, !fresh.isCapturingAudio, !fresh.hasFailed,
              checks < Self.maxLiveChecks, !Task.isCancelled {
            await pause()
            checks += 1
        }
        guard let incoming, incoming.recorder === fresh, isRecordingState,
              let recorder, let fileURL else { return }
        microphoneHandover = nil
        // Unlike a note's start, a hand-over never goes live on silence:
        // the old microphone is still recording the voice.
        if fresh.hasFailed || !fresh.isCapturingAudio {
            Self.logger.error("microphone: the new microphone failed or stayed silent; staying on the old one")
            abandonHandover()
            microphone = recorder.microphone
            return
        }
        let leadIn = fresh.elapsed
        // Finishes its file in the background; `stop()` waits for it
        // before the parts are joined.
        recorder.stop()
        finishedParts.append((AudioSegment(url: fileURL, trimStart: currentTrimStart), recorder))
        self.recorder = fresh
        self.fileURL = incoming.url
        self.incoming = nil
        currentTrimStart = leadIn
        microphone = fresh.microphone
        Self.logger.info("microphone: handed over to \(self.microphone?.name ?? "unknown", privacy: .public) leadIn=\(leadIn, format: .fixed(precision: 2))s after=\(checks) checks")
    }

    /// Drops a hand-over still waiting for sound: its part holds nothing.
    private func abandonHandover() {
        microphoneHandover?.cancel()
        microphoneHandover = nil
        guard let incoming else { return }
        self.incoming = nil
        discard(incoming.recorder, file: incoming.url)
    }

    static let liveCheckInterval: Duration = .milliseconds(20)
    /// Checks before `start()` stops waiting for sound and goes live
    /// anyway (about 4 s): a muted input delivers true silence forever,
    /// and a note that never starts is worse than one with a quiet lead-in.
    static let maxLiveChecks = 200

    public convenience init() {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains(SyntheticToneRecording.launchArgument) {
            self.init(requestPermission: VoiceRecorder.requestSystemPermission,
                      makeRecorder: { SyntheticToneRecording(url: $0) },
                      setKeepScreenAwake: VoiceRecorder.setSystemKeepScreenAwake,
                      observeInterruptions: VoiceRecorder.observeSystemInterruptions,
                      listMicrophones: { SyntheticToneRecording.microphones })
            return
        }
        #endif
        self.init(requestPermission: VoiceRecorder.requestSystemPermission,
                  makeRecorder: VoiceRecorder.makeSystemRecorder,
                  setKeepScreenAwake: VoiceRecorder.setSystemKeepScreenAwake,
                  observeInterruptions: VoiceRecorder.observeSystemInterruptions,
                  listMicrophones: VoiceRecorder.systemMicrophones)
    }

    /// Requests microphone permission (once), then starts recording to a
    /// fresh temp `.m4a`, and returns once the microphone is really
    /// delivering sound (`.starting` until then, `.recording` after).
    /// Throws `.alreadyRecording` if a recording is in progress,
    /// `.permissionDenied` if the user declines, `.recordFailed` if
    /// `AVAudioRecorder` won't start.
    public func start() async throws {
        // Reject only an in-flight recording or start; a fresh start from
        // `.idle` or a prior `.finished` (a second voice note) is allowed.
        if case .recording = state { throw RecorderError.alreadyRecording }
        guard !isStarting else { throw RecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        let generation = cancelGeneration
        guard await requestPermission() else { throw RecorderError.permissionDenied }
        // A cancel() landed while the permission prompt was up — the start
        // is abandoned before any session/recorder work. Quiet no-op: the
        // user asked for silence, not an error.
        guard generation == cancelGeneration else { return }
        #if os(iOS)
        // macOS has no AVAudioSession; on iOS the session must be put into a
        // record category and activated before AVAudioRecorder will capture.
        // Hands-free Bluetooth is allowed so AirPods show up as a pick;
        // which input is used is set by `useMicrophone` (the built-in mic
        // unless the user chose another), so connecting AirPods alone
        // doesn't move a note onto them.
        let session = AVAudioSession.sharedInstance()
        #if compiler(>=6.2)
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        #else
        try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        #endif
        try session.setActive(true)
        Self.logSessionState(session, at: "start")
        #endif
        let url = Self.newFileURL()
        do {
            let recorder = try makeRecorder(url)
            recorder.useMicrophone(preferredMicrophoneID)
            guard recorder.record() else { throw RecorderError.recordFailed }
            self.recorder = recorder
            self.fileURL = url
            finishedParts = []
            currentTrimStart = 0
            microphone = recorder.microphone
            state = .starting
            setKeepScreenAwake(true)
            isInterrupted = false
            pausedSince = nil
            pausedTotal = 0
            warmUpRefused = false
            // Subscribed from the warm-up on: a call that lands before the
            // mic is live pauses the recorder just the same.
            stopObservingInterruptions = observeInterruptions { [weak self] event in
                self?.handle(interruption: event)
            }
        } catch {
            // The session was already activated above — a failed recorder
            // construction or start must not leave it captured, nor leave an
            // orphan temp file behind.
            deactivateSession()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let requested = now()
        var checks = 0
        var watched = recorder
        // An interruption holds the warm-up (its time doesn't count
        // towards the cap) until it ends; the mic is checked again after.
        while let recorder, isInterrupted || !recorder.isCapturingAudio, checks < Self.maxLiveChecks {
            await pause()
            if self.recorder !== watched {
                // A mic pick started the capture over: it gets the whole
                // warm-up allowance again.
                watched = self.recorder
                checks = 0
            } else if !isInterrupted {
                checks += 1
            }
            // A route settles after the fact (iOS applies a preferred
            // input asynchronously): keep the bar's name current.
            microphone = self.recorder?.microphone
            // cancel() during the warm-up already tore everything down.
            guard generation == cancelGeneration else { return }
            if warmUpRefused || recorder.hasFailed { break }
        }
        guard generation == cancelGeneration, case .starting = state else { return }
        if recorder?.hasFailed == true {
            // The capture never got going (the device vanished, or it
            // refused to start): there is no note to show as live.
            Self.logger.error("live: the recorder failed to start")
            cancel()
            throw RecorderError.recordFailed
        }
        if warmUpRefused {
            // Another app took the microphone before anything was
            // captured: there is no note, so none is left looking live.
            Self.logger.info("live: refused, interruption ended without resume during warm-up")
            cancel()
            throw RecorderError.recordFailed
        }
        let started = now()
        microphone = recorder?.microphone
        Self.logger.info("live: after=\(started.timeIntervalSince(requested), format: .fixed(precision: 2))s timedOut=\(checks >= Self.maxLiveChecks) microphone=\(self.microphone?.name ?? "unknown", privacy: .public)")
        #if os(iOS)
        Self.logSessionState(AVAudioSession.sharedInstance(), at: "live")
        #endif
        self.startedAt = started
        state = .recording(start: started)
    }

    /// A stopped note: its file and its elapsed duration. The file may
    /// still be being finished when `stop()` returns (the Mac's capture
    /// session completes it a moment later, and a note that changed
    /// microphone is joined from its parts); read it only after
    /// `finished()`.
    public struct Stopped {
        public let url: URL
        public let duration: TimeInterval
        private let waitForFile: @MainActor () async -> Void

        init(url: URL, duration: TimeInterval, waitForFile: @escaping @MainActor () async -> Void) {
            self.url = url
            self.duration = duration
            self.waitForFile = waitForFile
        }

        /// Returns once the file is complete on disk.
        @MainActor
        public func finished() async { await waitForFile() }
    }

    /// Stops recording and hands back the note's file plus its elapsed
    /// duration, without waiting for the file to be finished (see
    /// `Stopped.finished()`). Returns `nil` (a no-op) when not currently
    /// recording.
    public func stop() -> Stopped? {
        guard case .recording = state, let recorder, let currentURL = fileURL, let startedAt else { return nil }
        // A microphone still coming up has recorded only silence.
        abandonHandover()
        recorder.stop()
        let parts = finishedParts + [(AudioSegment(url: currentURL, trimStart: currentTrimStart), recorder)]
        finishedParts = []
        currentTrimStart = 0
        let noteURL = parts.count > 1 ? Self.newFileURL() : currentURL
        let stoppedAt = now()
        let stillPaused = pausedSince.map { stoppedAt.timeIntervalSince($0) } ?? 0
        let duration = stoppedAt.timeIntervalSince(startedAt) - pausedTotal - stillPaused
        Self.logger.info("stop: duration=\(duration, format: .fixed(precision: 2))s paused=\(self.pausedTotal + stillPaused, format: .fixed(precision: 2))s parts=\(parts.count)")
        #if os(iOS)
        Self.logSessionState(AVAudioSession.sharedInstance(), at: "stop")
        #endif
        self.recorder = nil
        self.fileURL = nil
        self.startedAt = nil
        microphone = nil
        state = .finished
        setKeepScreenAwake(false)
        unsubscribeInterruptions()
        deactivateSession()
        // The closure keeps the recorders alive until their files are done.
        let join = joinSegments
        return Stopped(url: noteURL, duration: duration) {
            let began = Date()
            for part in parts { await part.recorder.finished() }
            if parts.count > 1 {
                await Self.join(parts.map(\.segment), into: noteURL, using: join)
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: noteURL.path)[.size] as? Int) ?? -1
            Self.logger.info("finished: after=\(Date().timeIntervalSince(began), format: .fixed(precision: 3))s bytes=\(bytes)")
        }
    }

    /// Joins a note that changed microphone into `url`, off the main
    /// thread (it decodes and re-encodes every part). If the join fails,
    /// the longest part is sent rather than nothing, moved to `url`.
    private static func join(_ parts: [AudioSegment], into url: URL,
                             using join: @escaping @Sendable ([AudioSegment], URL) throws -> Void) async {
        let logger = Self.logger
        await Task.detached(priority: .userInitiated) {
            do {
                try join(parts, url)
                for part in parts { try? FileManager.default.removeItem(at: part.url) }
            } catch {
                logger.error("stop: joining \(parts.count) parts failed: \(error.localizedDescription, privacy: .public)")
                let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
                let kept = parts.max { size($0.url) < size($1.url) }?.url
                try? FileManager.default.removeItem(at: url)
                if let kept { try? FileManager.default.moveItem(at: kept, to: url) }
                for part in parts where part.url != kept { try? FileManager.default.removeItem(at: part.url) }
            }
        }.value
    }

    /// Aborts recording, discards the temp file, and returns to `.idle`.
    /// Also invalidates any start() suspended at its permission prompt.
    public func cancel() {
        cancelGeneration &+= 1
        abandonHandover()
        if let recorder, let fileURL {
            discard(recorder, file: fileURL)
        } else {
            recorder?.stop()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
        for part in finishedParts { discard(part.recorder, file: part.segment.url) }
        finishedParts = []
        currentTrimStart = 0
        recorder = nil
        fileURL = nil
        startedAt = nil
        microphone = nil
        state = .idle
        setKeepScreenAwake(false)
        unsubscribeInterruptions()
        deactivateSession()
    }

    private static func newFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
    }

    /// Stops `recorder` and deletes its file without waiting for it. A
    /// recorder that finishes its file after `stop()` (the Mac's capture
    /// session) may put it back, so it is deleted again once that's done.
    private func discard(_ recorder: AudioRecording, file url: URL) {
        recorder.stop()
        try? FileManager.default.removeItem(at: url)
        Task { @MainActor in
            await recorder.finished()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// iOS has already paused the recorder on `began`; on `ended` with the
    /// resume hint, re-activating the session and calling `record()` picks
    /// capture up in the same file. Without the hint the system doesn't
    /// want us back on the mic (another app took it): the recorder stays
    /// paused, and a later `stop()` still delivers what was captured. A
    /// failed resume is left alone for the same reason.
    private func handle(interruption: AudioInterruption) {
        Self.logger.info("interruption: \(String(describing: interruption), privacy: .public) state=\(String(describing: self.state), privacy: .public) wasInterrupted=\(self.isInterrupted)")
        let warmingUp = state == .starting
        guard warmingUp || isRecordingState, let recorder else { return }
        switch interruption {
        case .began:
            isInterrupted = true
            // Before the mic is live there is no clock to pause yet.
            if !warmingUp, pausedSince == nil { pausedSince = now() }
        case .ended(let shouldResume):
            guard isInterrupted else { return }
            isInterrupted = false
            guard shouldResume else {
                if warmingUp { warmUpRefused = true }
                return
            }
            reactivateSession()
            // A failed resume leaves the recorder paused: the pause keeps
            // running until stop(), so it stays open here too.
            guard recorder.record() else {
                if warmingUp { warmUpRefused = true }
                return
            }
            if let pausedSince {
                pausedTotal += now().timeIntervalSince(pausedSince)
                self.pausedSince = nil
            }
        }
    }

    private var isRecordingState: Bool {
        if case .recording = state { return true }
        return false
    }

    private func unsubscribeInterruptions() {
        stopObservingInterruptions?()
        stopObservingInterruptions = nil
        isInterrupted = false
        pausedSince = nil
        pausedTotal = 0
    }

    private func reactivateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
        } catch {
            Self.logger.error("resume: setActive failed: \(error.localizedDescription, privacy: .public)")
        }
        Self.logSessionState(session, at: "resume")
        #endif
    }

    #if os(iOS)
    /// One line per recording milestone with everything that decides what
    /// the file will contain: the input route iOS actually chose (a
    /// connected accessory can override the built-in mic), input
    /// availability and gain, and the permission state. Strings are marked
    /// public on purpose: os.Logger redacts interpolated strings as
    /// `<private>` on a real device, which would hide the very route names
    /// this line exists to show. Port types and names are not sensitive.
    private static func logSessionState(_ session: AVAudioSession, at milestone: String) {
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        logger.info("\(milestone, privacy: .public): inputs=[\(inputs, privacy: .public)] outputs=[\(outputs, privacy: .public)] inputAvailable=\(session.isInputAvailable) gain=\(session.inputGain, format: .fixed(precision: 2)) channels=\(session.inputNumberOfChannels) sampleRate=\(session.sampleRate, format: .fixed(precision: 0)) permission=\(AVAudioApplication.shared.recordPermission.rawValue) otherAudio=\(session.isOtherAudioPlaying)")
    }
    #endif

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    // MARK: Real AVFoundation implementations

    private static func requestSystemPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// While recording, the device must not auto-lock: locking suspends the
    /// app mid-capture and the note is cut short. macOS has no idle-lock
    /// equivalent that interrupts capture, so this is iOS-only.
    private static func setSystemKeepScreenAwake(_ keepAwake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        #endif
    }

    /// Maps `AVAudioSession.interruptionNotification` onto
    /// `AudioInterruption`, delivered on the main actor. macOS has no
    /// audio session and no interruptions of this kind: no-op there.
    private static func observeSystemInterruptions(
        _ handler: @escaping @MainActor (AudioInterruption) -> Void
    ) -> () -> Void {
        #if os(iOS)
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let event: AudioInterruption
            switch type {
            case .began:
                event = .began
            case .ended:
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                event = .ended(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return
            }
            MainActor.assumeIsolated { handler(event) }
        }
        return { NotificationCenter.default.removeObserver(token) }
        #else
        return {}
        #endif
    }

    private static func makeSystemRecorder(url: URL) throws -> AudioRecording {
        #if os(macOS)
        // AVAudioRecorder on the Mac can only use the system's default
        // input. A note for a microphone the user picked (and that is
        // connected) records through a capture session instead.
        if let picked = UserDefaults.standard.string(forKey: preferredMicrophoneKey),
           CaptureSessionRecording.microphones().contains(where: { $0.id == picked }) {
            return CaptureSessionRecording(url: url)
        }
        #endif
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        // Metering is how `isCapturingAudio` tells real input from the
        // digital silence an input still coming up delivers.
        recorder.isMeteringEnabled = true
        return recorder
    }

    /// Every input a note can record from right now.
    static func systemMicrophones() -> [Microphone] {
        #if os(iOS)
        return (AVAudioSession.sharedInstance().availableInputs ?? [])
            .map { Microphone(id: $0.uid, name: $0.portName) }
        #else
        return CaptureSessionRecording.microphones()
        #endif
    }
}

/// The slice of `AVAudioRecorder` `VoiceRecorder` drives. Abstracted so the
/// state machine can be tested against a fake without capturing audio.
protocol AudioRecording: AnyObject {
    @discardableResult func record() -> Bool
    /// Ends capture and returns without waiting for the file to be
    /// finished on disk; `finished()` says when it is.
    func stop()
    /// Returns once the file `stop()` ended is complete and can be read.
    func finished() async
    /// Whether the microphone is delivering sound into the file yet.
    var isCapturingAudio: Bool { get }
    /// The capture gave up before going live (its device vanished).
    var hasFailed: Bool { get }
    /// The input this recording takes sound from.
    var microphone: Microphone? { get }
    /// Records from `id` (`nil`: the platform default). Called before
    /// `record()`, and again mid-note when the user picks another mic.
    func useMicrophone(_ id: String?)
    /// Whether `useMicrophone` moves a recording already under way. One
    /// that can't is handed over to a new recorder instead.
    var canSwitchMicrophoneLive: Bool { get }
    /// How much the file holds so far, in seconds.
    var elapsed: TimeInterval { get }
}

extension AudioRecording {
    /// `AVAudioRecorder.stop()` finishes the file before it returns.
    func finished() async {}
    var isCapturingAudio: Bool { true }
    var hasFailed: Bool { false }
    var microphone: Microphone? { nil }
    func useMicrophone(_ id: String?) {}
    var canSwitchMicrophoneLive: Bool { true }
    var elapsed: TimeInterval { 0 }
}

extension AVAudioRecorder: AudioRecording {
    #if os(iOS)
    /// The input the shared audio session is routed from.
    var microphone: Microphone? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first
            .map { Microphone(id: $0.uid, name: $0.portName) }
    }

    /// Routes the shared session's input. With no pick (or a pick that
    /// isn't connected) the built-in microphone, as before pickers
    /// existed: a connected headset doesn't take over on its own.
    func useMicrophone(_ id: String?) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let port = inputs.first { $0.uid == id } ?? inputs.first { $0.portType == .builtInMic }
        do {
            try session.setPreferredInput(port)
        } catch {
            os.Logger(subsystem: "chat.matron", category: "voice-recorder")
                .error("microphone: setPreferredInput failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #else
    /// The Mac's default input, which is all AVAudioRecorder records from.
    var microphone: Microphone? {
        AVCaptureDevice.default(for: .audio).map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// It can't move: a pick restarts a note that is still starting, or
    /// hands a recording note over to a new recorder
    /// (`VoiceRecorder.selectMicrophone`).
    var canSwitchMicrophoneLive: Bool { false }
    #endif

    var elapsed: TimeInterval { currentTime }

    /// Live once the file has advanced and the meter reads above digital
    /// silence. Any real microphone has a noise floor far above
    /// `liveFloor`; an input that is still switching on delivers exact
    /// zeros (the meter's −160 dB floor) or nothing at all.
    var isCapturingAudio: Bool {
        guard currentTime > 0 else { return false }
        updateMeters()
        return peakPower(forChannel: 0) > Self.liveFloor
    }

    static let liveFloor: Float = -120
}

#if targetEnvironment(simulator)
/// Stands in for the microphone in the e2e smoke tests (`tests/e2e`). The
/// simulator records from the host's default audio input, and on a Mac with
/// none (a headless Mac mini) `AVAudioRecorder.record()` returns false, so
/// no voice note can start. Launched with `-MatronSyntheticMic`, the app
/// writes a tone as long as the recording lasted, in the real recorder's
/// format; everything around the capture (permission, audio session, the
/// recording bar, the upload) runs as usual. Simulator builds only.
final class SyntheticToneRecording: AudioRecording {
    static let launchArgument = "-MatronSyntheticMic"
    static let microphones = [Microphone(id: "synthetic", name: "Synthetic tone")]

    var microphone: Microphone? { Self.microphones[0] }

    private let url: URL
    private var startedAt: Date?

    init(url: URL) {
        self.url = url
    }

    func record() -> Bool {
        // A resume after an interruption calls this again; the tone still
        // spans the whole note.
        if startedAt == nil { startedAt = Date() }
        return true
    }

    func stop() {
        guard let startedAt else { return }
        self.startedAt = nil
        let sampleRate = 44_100.0
        let seconds = max(0.5, Date().timeIntervalSince(startedAt))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        // The file is closed when `file` goes out of scope, before the
        // caller reads it.
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(seconds * sampleRate)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * 0.25
        }
        try? file.write(from: buffer)
    }
}
#endif
