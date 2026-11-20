import Foundation
import Observation
import AVFoundation
import os

/// The app's one voice-note recording, owned above every page (a note used to die the moment you moved to another page
/// inside Matron, because each composer owned its own `VoiceRecorder` and
/// cancelled it on disappear). A composer or item reply field starts a note
/// here with the place it belongs to (`Target`) and a `deliver` closure that
/// sends the finished file there; from then on the note survives any
/// navigation, and Stop from anywhere — the composer's own bar, the
/// app-wide indicator, the Mac hotkey — sends it to that place, never to
/// whatever page is on screen.
///
/// One note at a time: a start for another place while one is recording is
/// refused with `SessionError.busyElsewhere`, naming where the live note is.
/// A delivery that fails (the upload is refused, the network dropped) keeps
/// the file and surfaces in `failures`, each with Retry and Discard. Once a
/// delivery succeeds the note is in the conversation's or item's own
/// outbox, which owns any later rejection or retry.
@MainActor
@Observable
public final class VoiceNoteSession {
    /// Where a note goes. `title` is what the indicator shows.
    public struct Target: Equatable, Sendable, Codable {
        public enum Kind: Hashable, Sendable, Codable {
            case conversation(String)
            case item(String)
        }
        public let kind: Kind
        public let title: String

        public init(kind: Kind, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    /// Sends a finished note to its target. Returns `nil` on success or a
    /// user-facing message on failure. The closure owns nothing: on success
    /// the session deletes the file; on failure it keeps it for Retry.
    public typealias Deliver = @MainActor (_ url: URL, _ duration: TimeInterval) async -> String?

    /// A note that was recorded but didn't arrive.
    public struct Failure: Equatable, Identifiable {
        public let id: UUID
        public let target: Target
        public let message: String
        /// `false` when the delivery itself threw the file away (an empty
        /// recording): there is nothing left to send again.
        public let canRetry: Bool
    }

    public enum SessionError: LocalizedError, Equatable {
        /// A note for another place is already recording.
        case busyElsewhere(title: String)
        /// Voice mode holds the microphone (spec 2026-10-03 §3, "Audio
        /// session").
        case voiceModeOn

        public var errorDescription: String? {
            switch self {
            case .busyElsewhere(let title):
                return "Already recording a voice note for \u{201C}\(title)\u{201D}. Send or cancel it first."
            case .voiceModeOn:
                return "Voice mode is on. End it to record a voice note."
            }
        }
    }

    public let recorder: VoiceRecorder

    /// Set while voice mode is on: it holds the microphone, so an ordinary
    /// note cannot start until it ends.
    public var isVoiceModeOn = false

    /// Where the live note goes; `nil` when nothing is recording.
    public private(set) var target: Target?
    /// Notes that failed to send, oldest first, each kept until its own
    /// Retry or Discard — a second failure never throws away the first.
    public private(set) var failures: [Failure] = []
    /// True while a stopped note is being uploaded.
    public var isSending: Bool { !deliveries.isEmpty }
    /// Where the most recent in-flight note is going, for the "Sending…"
    /// row; `nil` once every send has settled.
    public private(set) var sendingTarget: Target?
    /// Every delivery still running, so `reset()` can cancel them rather
    /// than only ignore their results.
    private var deliveries: [UUID: Task<Void, Never>] = [:]

    private var deliver: Deliver?
    /// Set across `start`'s permission await and the microphone's
    /// warm-up, so a second start for another place can't race it and
    /// overwrite the target. The indicator shows it as "Starting
    /// microphone…".
    public private(set) var startingTarget: Target?
    /// Each retryable failure's file and the delivery that started it.
    private var failedNotes: [UUID: (url: URL, duration: TimeInterval, deliver: Deliver)] = [:]
    /// Retryable failures read back from disk at launch, whose delivery
    /// didn't survive the restart: Retry asks `resolveDeliver` for it.
    private var savedNotes: [UUID: (url: URL, duration: TimeInterval)] = [:]

    /// Builds the delivery for a target whose original closure didn't
    /// survive a relaunch (`restoreSavedFailures`).
    private var resolveDeliver: ((Target) -> Deliver?)?
    /// Set once `restoreSavedFailures` has read the saved list: until
    /// then nothing writes it, so a failure can't overwrite rows not yet
    /// read back.
    private var restoredSavedFailures = false

    /// Where failures that can be retried are kept, with their files, so
    /// Retry survives the app restarting. `nil` keeps them in memory only
    /// (tests, and the stand-in sessions views make when none is in their
    /// environment).
    private let failedNotesDirectory: URL?
    /// Bumped by `reset()`: a send still uploading for the signed-out
    /// account settles into nothing rather than into the next account's
    /// failures.
    private var generation = 0
    /// Surfaces currently showing the owning composer's own recording bar
    /// (`ownerAppeared(_:)`): the app-wide indicator hides while one is on
    /// screen rather than doubling up the controls.
    private var ownerSurfaces: [UUID: Target.Kind] = [:]

    /// Shortest note worth sending, in seconds of audio in the file.
    public static let minimumAudio: TimeInterval = 1
    public static let nothingRecordedMessage = "Nothing was recorded, try again"
    private static let logger = os.Logger(subsystem: "chat.matron", category: "voice-recorder")
    static let shortFileRechecks = 6
    static let brokenMessage = "The recorder reported an error saving this note. Retry sends what was saved."

    /// The file holds under half of a note over 2 s long.
    static func isShort(_ audio: TimeInterval?, of duration: TimeInterval) -> Bool {
        guard let audio else { return false }
        return duration >= 2 && audio >= minimumAudio && audio < duration / 2
    }

    static func shortMessage(saved: TimeInterval, of duration: TimeInterval) -> String {
        func clock(_ seconds: TimeInterval) -> String {
            Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
        }
        return "Only \(clock(saved)) of \(clock(duration)) was saved. Retry sends what was saved."
    }

    /// How a short file waits before it is measured again (500 ms).
    private let settle: @Sendable () async -> Void

    /// Seconds of audio in a finished file; `nil` when it can't be read
    /// as audio at all. Injectable so tests can send placeholder files.
    private let measureAudio: @Sendable (URL) async -> TimeInterval?

    public init(recorder: VoiceRecorder,
                failedNotesDirectory: URL? = nil,
                measureAudio: @escaping @Sendable (URL) async -> TimeInterval? = { await VoiceNoteSession.audioDuration(of: $0) },
                settle: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(500)) }) {
        self.recorder = recorder
        self.measureAudio = measureAudio
        self.settle = settle
        self.failedNotesDirectory = failedNotesDirectory
        recorder.onCaptureLost = { [weak self] lost in self?.captureLost(lost) }
    }

    /// Signed in: puts back the failures an earlier launch saved, each with
    /// Retry, which sends through `resolveDeliver` (the closure that
    /// started the note didn't survive the restart). Reads the saved list
    /// once; later calls (a new account) only replace `resolveDeliver`.
    public func restoreSavedFailures(resolveDeliver: @escaping (Target) -> Deliver?) {
        self.resolveDeliver = resolveDeliver
        guard !restoredSavedFailures else { return }
        restoredSavedFailures = true
        loadSavedFailures()
    }

    public convenience init() {
        self.init(recorder: VoiceRecorder())
    }

    /// The length of the audio actually in `url`, read from the file.
    public static func audioDuration(of url: URL) async -> TimeInterval? {
        await Task.detached(priority: .userInitiated) {
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }.value
    }

    /// The microphone stopped delivering while the note showed as
    /// recording: the recorder has stopped it. What did reach the file
    /// is kept as a failure row, so the user sees what happened and can
    /// still send it; a note with nothing in it is just reported.
    private func captureLost(_ lost: VoiceRecorder.CaptureLost) {
        guard let target, let deliver else { return }
        self.target = nil
        self.deliver = nil
        let generation = self.generation
        let micName = lost.microphone?.name
        Task { @MainActor in
            await lost.stopped.finished()
            guard generation == self.generation else {
                try? FileManager.default.removeItem(at: lost.stopped.url)
                return
            }
            let url = lost.stopped.url
            let seconds = await measureAudio(url) ?? 0
            // Signed out while the file was measured: the old account's
            // note never reaches the next account's rows.
            guard generation == self.generation else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let id = UUID()
            let mic = micName ?? "The microphone"
            if seconds >= Self.minimumAudio {
                let length = Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
                keepForRetry(id, url: url, duration: seconds, deliver: deliver,
                             failure: Failure(id: id, target: target,
                                              message: "\(mic) stopped at \(length). Retry sends what was recorded.",
                                              canRetry: true))
            } else {
                try? FileManager.default.removeItem(at: url)
                failures.append(Failure(id: id, target: target,
                                        message: "\(mic) stopped. \(Self.nothingRecordedMessage).",
                                        canRetry: false))
            }
        }
    }

    /// When the live note began, for the elapsed-time display.
    public var recordingStart: Date? {
        guard target != nil, case let .recording(start) = recorder.state else { return nil }
        return start
    }

    public var isRecording: Bool { recordingStart != nil }

    public func isRecording(for kind: Target.Kind) -> Bool {
        isRecording && target?.kind == kind
    }

    /// A note for `kind` has been asked for but the microphone isn't
    /// delivering sound yet (the permission prompt, or input hardware
    /// still coming up). The composer shows "Starting microphone…" rather
    /// than the recording bar, so nobody talks into a mic that isn't on.
    public func isStarting(for kind: Target.Kind) -> Bool {
        startingTarget?.kind == kind
    }

    /// Whether the app-wide indicator should show: something is recording
    /// and the composer it belongs to isn't on screen showing its own bar.
    public var showsIndicator: Bool {
        guard let shown = isRecording ? target : startingTarget else { return false }
        return !ownerSurfaces.values.contains(shown.kind)
    }

    /// A note has been asked for anywhere and isn't live yet.
    public var isStarting: Bool { startingTarget != nil }

    /// Starts a note for `target`. Throws `busyElsewhere` while another
    /// place's note is recording or starting, `VoiceRecorder.RecorderError`
    /// for a second start of the same place, a denied permission or a
    /// recorder that won't start.
    public func start(_ target: Target, deliver: @escaping Deliver) async throws {
        guard !isVoiceModeOn else { throw SessionError.voiceModeOn }
        if let live = self.target ?? startingTarget, isRecording || startingTarget != nil {
            if live.kind != target.kind { throw SessionError.busyElsewhere(title: live.title) }
            throw VoiceRecorder.RecorderError.alreadyRecording
        }
        startingTarget = target
        defer { startingTarget = nil }
        try await recorder.start()
        // A cancel() during the permission prompt leaves the recorder idle.
        guard case .recording = recorder.state else { return }
        self.target = target
        self.deliver = deliver
    }

    /// The mic button for `target`, where it stays on screen while the
    /// note records (the item threads): starts a note, or, pressed again
    /// for the place that is recording, finishes it and sends it, as the
    /// hotkey does. A press while that place's note is still starting is
    /// ignored. Returns the upload task when it sent (tests await it).
    @discardableResult
    public func press(_ target: Target, deliver: @escaping Deliver) async throws -> Task<Void, Never>? {
        if isRecording(for: target.kind) { return stopAndSend() }
        if startingTarget?.kind == target.kind { return nil }
        try await start(target, deliver: deliver)
        return nil
    }

    /// What a composer's send does for `kind`.
    public enum ComposerSend: Equatable {
        /// Nothing is recording here: send the typed text and the tray.
        case draft
        /// A note is recording here: finish it and send it. Its delivery
        /// takes the typed text and the tray with it, as one message.
        case note
        /// The microphone is still starting here: send nothing yet, so the
        /// text doesn't leave without the note.
        case wait
    }

    /// The composer's one send for `kind`. With a note recording there,
    /// the send button (or Return) finishes it and sends everything
    /// together, the same as the recording bar's own Stop would; it never
    /// sends the text alone and leaves the note running.
    public func composerSend(for kind: Target.Kind) -> ComposerSend {
        if isRecording(for: kind) { return .note }
        if isStarting(for: kind) { return .wait }
        return .draft
    }

    /// Stops the live note and sends it to the place it was started for.
    /// Returns the upload task (tests await it), or `nil` when nothing was
    /// recording.
    @discardableResult
    public func stopAndSend() -> Task<Void, Never>? {
        guard let target, let deliver, let stopped = recorder.stop() else { return nil }
        self.target = nil
        self.deliver = nil
        // The recorder may still be finishing the file: the delivery waits
        // for it, off the tap, so the bar goes and "Sending…" shows at once.
        return send(url: stopped.url, duration: stopped.duration, to: target, via: deliver,
                    waitForFile: stopped.finishedCleanly)
    }

    /// Aborts the live note and discards its file.
    public func cancel() {
        recorder.cancel()
        target = nil
        deliver = nil
    }

    /// Aborts the live note only if it belongs to `kind`.
    public func cancel(ifTargeting kind: Target.Kind) {
        guard target?.kind == kind || startingTarget?.kind == kind else { return }
        cancel()
    }

    /// Sends a failed note again, to the same place.
    @discardableResult
    public func retry(_ id: Failure.ID) -> Task<Void, Never>? {
        guard let failure = failures.first(where: { $0.id == id }), failure.canRetry,
              let note = retryableNote(id, for: failure.target) else { return nil }
        forget(id)
        // The user has seen what the file holds: a short one goes as it is.
        return send(url: note.url, duration: note.duration, to: failure.target, via: note.deliver,
                    acceptShort: true)
    }

    /// A failed note's file and how to send it again, if it can be.
    private func retryableNote(_ id: UUID, for target: Target) -> (url: URL, duration: TimeInterval, deliver: Deliver)? {
        if let note = failedNotes[id] { return note }
        guard let saved = savedNotes[id], let resolveDeliver, let deliver = resolveDeliver(target) else { return nil }
        return (saved.url, saved.duration, deliver)
    }

    /// Gives up on a failed note and deletes its file.
    public func discard(_ id: Failure.ID) {
        if let note = failedNotes[id] { try? FileManager.default.removeItem(at: note.url) }
        if let saved = savedNotes[id] { try? FileManager.default.removeItem(at: saved.url) }
        forget(id)
    }

    /// Sign-out: nothing of the old account may keep recording or sending.
    public func reset() {
        cancel()
        failures.map(\.id).forEach(discard)
        // Including any saved rows not read back yet: the next account
        // must not get them.
        if let failedNotesDirectory {
            for file in (try? FileManager.default.contentsOfDirectory(at: failedNotesDirectory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        resolveDeliver = nil
        generation &+= 1
        deliveries.values.forEach { $0.cancel() }
        deliveries = [:]
        sendingTarget = nil
        ownerSurfaces = [:]
    }

    private func forget(_ id: Failure.ID) {
        failedNotes[id] = nil
        savedNotes[id] = nil
        failures.removeAll { $0.id == id }
        saveFailures()
    }

    /// Records a failure whose file can be sent again. With a
    /// `failedNotesDirectory` the file moves there (out of tmp, which the
    /// system may empty) and the row is saved, so Retry is still there
    /// after the app restarts.
    private func keepForRetry(_ id: UUID, url: URL, duration: TimeInterval, deliver: @escaping Deliver, failure: Failure) {
        var kept = url
        if let failedNotesDirectory {
            let destination = failedNotesDirectory.appendingPathComponent("\(id.uuidString).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)")
            try? FileManager.default.createDirectory(at: failedNotesDirectory, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: url, to: destination)) != nil { kept = destination }
        }
        failedNotes[id] = (kept, duration, deliver)
        failures.append(failure)
        saveFailures()
    }

    // MARK: Saved failures

    private struct SavedFailure: Codable {
        var id: UUID
        var target: Target
        var message: String
        var duration: TimeInterval
        /// The file's name inside `failedNotesDirectory`.
        var file: String
    }

    private var failuresFile: URL? {
        failedNotesDirectory?.appendingPathComponent("failures.json")
    }

    /// Writes the retryable failures whose files are in
    /// `failedNotesDirectory`; deletes the list when there are none.
    private func saveFailures() {
        guard restoredSavedFailures, let failedNotesDirectory, let failuresFile else { return }
        let saved: [SavedFailure] = failures.compactMap { failure in
            guard failure.canRetry,
                  let note = failedNotes[failure.id].map({ (url: $0.url, duration: $0.duration) }) ?? savedNotes[failure.id],
                  note.url.deletingLastPathComponent().standardizedFileURL == failedNotesDirectory.standardizedFileURL
            else { return nil }
            return SavedFailure(id: failure.id, target: failure.target, message: failure.message,
                                duration: note.duration, file: note.url.lastPathComponent)
        }
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: failuresFile)
            return
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: failedNotesDirectory, withIntermediateDirectories: true)
        try? data.write(to: failuresFile, options: .atomic)
    }

    /// The failures an earlier launch left, each with Retry. A file that
    /// has gone drops its row; a file no row names is deleted.
    private func loadSavedFailures() {
        guard let failedNotesDirectory, let failuresFile else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: failedNotesDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = failedNotesDirectory
        try? dir.setResourceValues(values)
        let saved = (try? Data(contentsOf: failuresFile)).flatMap { try? JSONDecoder().decode([SavedFailure].self, from: $0) } ?? []
        // Files this launch has already kept count as named too.
        var named = Set(failedNotes.values.map(\.url.lastPathComponent))
        for entry in saved {
            let url = failedNotesDirectory.appendingPathComponent(entry.file)
            guard fm.fileExists(atPath: url.path), failedNotes[entry.id] == nil, savedNotes[entry.id] == nil else { continue }
            named.insert(entry.file)
            savedNotes[entry.id] = (url, entry.duration)
            failures.append(Failure(id: entry.id, target: entry.target, message: entry.message, canRetry: true))
        }
        for file in (try? fm.contentsOfDirectory(at: failedNotesDirectory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent != failuresFile.lastPathComponent && !named.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
        saveFailures()
    }

    /// A composer for `kind` is on screen with its own recording bar.
    /// Paired with `ownerDisappeared(_:)`; `id` is the surface's identity
    /// so two mounts of one place (a chat and its sub-panel) count apart.
    public func ownerAppeared(_ id: UUID, kind: Target.Kind) {
        ownerSurfaces[id] = kind
    }

    public func ownerDisappeared(_ id: UUID) {
        ownerSurfaces[id] = nil
    }

    private func send(url: URL, duration: TimeInterval, to target: Target, via deliver: @escaping Deliver,
                      waitForFile: @escaping @MainActor () async -> Bool = { true },
                      acceptShort: Bool = false) -> Task<Void, Never> {
        sendingTarget = target
        let generation = self.generation
        let deliveryID = UUID()
        let task = Task { @MainActor in
            // Cancelled by `reset()` before it began: never reaches the
            // signed-out account's upload at all.
            let clean = await waitForFile()
            // A file with (almost) no audio in it is never sent: it would
            // arrive as a note nobody can play or transcribe.
            var audio = Task.isCancelled ? nil : await measureAudio(url)
            // Much less audio than the clock showed: give a late writer a
            // moment to finish, then measure again.
            var waited = 0
            while !acceptShort, !Task.isCancelled, Self.isShort(audio, of: duration), waited < Self.shortFileRechecks {
                await settle()
                waited += 1
                audio = await measureAudio(url)
            }
            Self.logger.notice("send: clock=\(duration, format: .fixed(precision: 2))s audio=\(audio ?? -1, format: .fixed(precision: 2))s rechecks=\(waited)")
            let empty = !Task.isCancelled && (audio ?? 0) < Self.minimumAudio
            let short = !acceptShort && !Task.isCancelled && !empty && Self.isShort(audio, of: duration)
            // The recorder reported an error finishing the file: what is
            // in it may be incomplete, so the user decides.
            let broken = !acceptShort && !Task.isCancelled && !empty && !short && !clean
            if empty { try? FileManager.default.removeItem(at: url) }
            let error = Task.isCancelled ? "Cancelled"
                : empty ? Self.nothingRecordedMessage
                : short ? Self.shortMessage(saved: audio ?? 0, of: duration)
                : broken ? Self.brokenMessage
                : await deliver(url, duration)
            guard generation == self.generation, !Task.isCancelled else {
                // Signed out meanwhile: the old account's note is dropped.
                try? FileManager.default.removeItem(at: url)
                return
            }
            deliveries[deliveryID] = nil
            if deliveries.isEmpty { sendingTarget = nil }
            if let error {
                let id = UUID()
                let canRetry = FileManager.default.fileExists(atPath: url.path)
                let failure = Failure(id: id, target: target, message: error, canRetry: canRetry)
                if canRetry {
                    keepForRetry(id, url: url, duration: duration, deliver: deliver, failure: failure)
                } else {
                    failures.append(failure)
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        deliveries[deliveryID] = task
        return task
    }
}
