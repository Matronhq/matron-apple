import Foundation
import Observation

/// The app's one voice-note recording, owned above every page (Dan,
/// 2026-10-01: a note used to die the moment you moved to another page
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
    public struct Target: Equatable, Sendable {
        public enum Kind: Hashable, Sendable {
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
    /// Set across `start`'s permission await, so a second start for
    /// another place can't race it and overwrite the target.
    private var startingTarget: Target?
    private var failedNotes: [UUID: (url: URL, duration: TimeInterval, deliver: Deliver)] = [:]
    /// Bumped by `reset()`: a send still uploading for the signed-out
    /// account settles into nothing rather than into the next account's
    /// failures.
    private var generation = 0
    /// Surfaces currently showing the owning composer's own recording bar
    /// (`ownerAppeared(_:)`): the app-wide indicator hides while one is on
    /// screen rather than doubling up the controls.
    private var ownerSurfaces: [UUID: Target.Kind] = [:]

    public init(recorder: VoiceRecorder) {
        self.recorder = recorder
    }

    public convenience init() {
        self.init(recorder: VoiceRecorder())
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

    /// Whether the app-wide indicator should show: something is recording
    /// and the composer it belongs to isn't on screen showing its own bar.
    public var showsIndicator: Bool {
        guard let target, isRecording else { return false }
        return !ownerSurfaces.values.contains(target.kind)
    }

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

    /// Stops the live note and sends it to the place it was started for.
    /// Returns the upload task (tests await it), or `nil` when nothing was
    /// recording.
    @discardableResult
    public func stopAndSend() -> Task<Void, Never>? {
        guard let target, let deliver, let result = recorder.stop() else { return nil }
        self.target = nil
        self.deliver = nil
        return send(url: result.url, duration: result.duration, to: target, via: deliver)
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
              let note = failedNotes[id] else { return nil }
        forget(id)
        return send(url: note.url, duration: note.duration, to: failure.target, via: note.deliver)
    }

    /// Gives up on a failed note and deletes its file.
    public func discard(_ id: Failure.ID) {
        if let note = failedNotes[id] { try? FileManager.default.removeItem(at: note.url) }
        forget(id)
    }

    /// Sign-out: nothing of the old account may keep recording or sending.
    public func reset() {
        cancel()
        failures.map(\.id).forEach(discard)
        generation &+= 1
        deliveries.values.forEach { $0.cancel() }
        deliveries = [:]
        sendingTarget = nil
        ownerSurfaces = [:]
    }

    private func forget(_ id: Failure.ID) {
        failedNotes[id] = nil
        failures.removeAll { $0.id == id }
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

    private func send(url: URL, duration: TimeInterval, to target: Target, via deliver: @escaping Deliver) -> Task<Void, Never> {
        sendingTarget = target
        let generation = self.generation
        let deliveryID = UUID()
        let task = Task { @MainActor in
            // Cancelled by `reset()` before it began: never reaches the
            // signed-out account's upload at all.
            let error = Task.isCancelled ? "Cancelled" : await deliver(url, duration)
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
                if canRetry { failedNotes[id] = (url, duration, deliver) }
                failures.append(Failure(id: id, target: target, message: error, canRetry: canRetry))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        deliveries[deliveryID] = task
        return task
    }
}
