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
/// A delivery that fails (the conversation is gone, the network dropped)
/// keeps the file and surfaces as `failure`, with Retry and Discard.
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
    public struct Failure: Equatable {
        public let target: Target
        public let message: String
    }

    public enum SessionError: LocalizedError, Equatable {
        /// A note for another place is already recording.
        case busyElsewhere(title: String)

        public var errorDescription: String? {
            switch self {
            case .busyElsewhere(let title):
                return "Already recording a voice note for \u{201C}\(title)\u{201D}. Send or cancel it first."
            }
        }
    }

    public let recorder: VoiceRecorder

    /// Where the live note goes; `nil` when nothing is recording.
    public private(set) var target: Target?
    /// The last note that failed to send, kept until Retry or Discard.
    public private(set) var failure: Failure?
    /// True while a stopped note is being uploaded.
    public var isSending: Bool { sendsInFlight > 0 }
    /// Where the most recent in-flight note is going, for the "Sending…"
    /// row; `nil` once every send has settled.
    public private(set) var sendingTarget: Target?
    private var sendsInFlight = 0

    private var deliver: Deliver?
    /// Set across `start`'s permission await, so a second start for
    /// another place can't race it and overwrite the target.
    private var startingTarget: Target?
    private var failedNote: (url: URL, duration: TimeInterval, deliver: Deliver)?
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

    /// Sends the failed note again, to the same place.
    @discardableResult
    public func retryFailed() -> Task<Void, Never>? {
        guard let note = failedNote, let failure else { return nil }
        failedNote = nil
        self.failure = nil
        return send(url: note.url, duration: note.duration, to: failure.target, via: note.deliver)
    }

    /// Gives up on the failed note and deletes its file.
    public func discardFailed() {
        if let note = failedNote { try? FileManager.default.removeItem(at: note.url) }
        failedNote = nil
        failure = nil
    }

    /// Sign-out: nothing of the old account may keep recording or sending.
    public func reset() {
        cancel()
        discardFailed()
        ownerSurfaces = [:]
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
        sendsInFlight += 1
        sendingTarget = target
        return Task { @MainActor in
            let error = await deliver(url, duration)
            sendsInFlight -= 1
            if sendsInFlight == 0 { sendingTarget = nil }
            if let error {
                // One failure slot: a newer failure replaces an older one,
                // whose file would otherwise be orphaned.
                if let old = failedNote, old.url != url { try? FileManager.default.removeItem(at: old.url) }
                failedNote = (url, duration, deliver)
                failure = Failure(target: target, message: error)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
