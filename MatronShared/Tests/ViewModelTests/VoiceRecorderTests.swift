import XCTest
import AVFoundation
@testable import MatronViewModels

/// Fake `AudioRecording` so the `VoiceRecorder` state machine can be
/// exercised without capturing audio or hitting the permission dialog.
private final class FakeAudioRecorder: AudioRecording {
    var recordReturn = true
    private(set) var recordCalls = 0
    private(set) var stopCalls = 0
    func record() -> Bool { recordCalls += 1; return recordReturn }
    func stop() { stopCalls += 1 }
}

/// Fake interruption source: captures the recorder's handler so a test can
/// deliver began/ended events, and counts how often the subscription was
/// torn down.
private final class FakeInterruptions {
    var handler: ((AudioInterruption) -> Void)?
    private(set) var cancelCalls = 0
    func source(_ handler: @escaping (AudioInterruption) -> Void) -> () -> Void {
        self.handler = handler
        return { [self] in cancelCalls += 1 }
    }
}

final class VoiceRecorderTests: XCTestCase {
    @MainActor
    private func makeRecorder(permission: Bool = true,
                             fake: FakeAudioRecorder = FakeAudioRecorder(),
                             interruptions: FakeInterruptions? = nil) -> VoiceRecorder {
        if let interruptions {
            return VoiceRecorder(requestPermission: { permission }, makeRecorder: { _ in fake },
                                 observeInterruptions: interruptions.source)
        }
        return VoiceRecorder(requestPermission: { permission }, makeRecorder: { _ in fake })
    }

    // MARK: Interruptions (calls, Siri, another app taking the mic)

    /// iOS pauses the recorder for the interruption; when it ends with the
    /// resume hint, capture must pick up again — otherwise the note would
    /// silently stop at the call while the UI still says "recording".
    @MainActor
    func test_interruptionEnded_withResumeHint_resumesTheRecorder() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let rec = makeRecorder(fake: fake, interruptions: interruptions)
        try await rec.start()
        XCTAssertEqual(fake.recordCalls, 1)
        XCTAssertNotNil(interruptions.handler, "subscribed for the life of the recording")

        interruptions.handler?(.began)
        interruptions.handler?(.ended(shouldResume: true))
        XCTAssertEqual(fake.recordCalls, 2, "record() again resumes the paused AVAudioRecorder")
        guard case .recording = rec.state else { return XCTFail("still recording") }
    }

    /// Without the hint iOS does not want us back on the mic (another app
    /// took it). The recorder stays paused; Stop still delivers what was
    /// captured up to the interruption.
    @MainActor
    func test_interruptionEnded_withoutResumeHint_leavesRecorderPaused() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let rec = makeRecorder(fake: fake, interruptions: interruptions)
        try await rec.start()
        interruptions.handler?(.began)
        interruptions.handler?(.ended(shouldResume: false))
        XCTAssertEqual(fake.recordCalls, 1)
        XCTAssertNotNil(rec.stop(), "the captured part is still delivered")
    }

    /// An `ended` with no matching `began` is noise (a stale notification
    /// from a previous session), not a reason to poke the recorder.
    @MainActor
    func test_interruptionEnded_withoutBegan_isIgnored() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let rec = makeRecorder(fake: fake, interruptions: interruptions)
        try await rec.start()
        interruptions.handler?(.ended(shouldResume: true))
        XCTAssertEqual(fake.recordCalls, 1)
    }

    @MainActor
    func test_stopAndCancel_unsubscribeFromInterruptions() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let rec = makeRecorder(fake: fake, interruptions: interruptions)
        try await rec.start()
        _ = rec.stop()
        XCTAssertEqual(interruptions.cancelCalls, 1)
        interruptions.handler?(.began)
        interruptions.handler?(.ended(shouldResume: true))
        XCTAssertEqual(fake.recordCalls, 1, "a finished recording never resumes")

        try await rec.start()
        rec.cancel()
        XCTAssertEqual(interruptions.cancelCalls, 2)
    }

    @MainActor
    func test_start_transitionsIdleToRecording() async throws {
        let rec = makeRecorder()
        XCTAssertEqual(rec.state, .idle)
        try await rec.start()
        guard case .recording = rec.state else { return XCTFail("expected .recording") }
    }

    @MainActor
    func test_stop_returnsM4AURLAndDurationThenFinishes() async throws {
        let rec = makeRecorder()
        try await rec.start()
        let result = rec.stop()
        XCTAssertEqual(rec.state, .finished)
        XCTAssertEqual(result?.url.pathExtension, "m4a")
        XCTAssertGreaterThanOrEqual(result?.duration ?? -1, 0)
    }

    @MainActor
    func test_cancel_returnsToIdleAndDiscardsRecording() async throws {
        let fake = FakeAudioRecorder()
        let rec = makeRecorder(fake: fake)
        try await rec.start()
        rec.cancel()
        XCTAssertEqual(rec.state, .idle)
        XCTAssertEqual(fake.stopCalls, 1)
    }

    @MainActor
    func test_start_whileRecording_throwsAlreadyRecording() async throws {
        let rec = makeRecorder()
        try await rec.start()
        do {
            try await rec.start()
            XCTFail("expected alreadyRecording")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .alreadyRecording)
        }
    }

    @MainActor
    func test_start_permissionDenied_throwsAndStaysIdle() async {
        let rec = makeRecorder(permission: false)
        do {
            try await rec.start()
            XCTFail("expected permissionDenied")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .permissionDenied)
        }
        XCTAssertEqual(rec.state, .idle)
    }

    @MainActor
    func test_start_recordFailure_throwsRecordFailed() async {
        let fake = FakeAudioRecorder()
        fake.recordReturn = false
        let rec = makeRecorder(fake: fake)
        do {
            try await rec.start()
            XCTFail("expected recordFailed")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .recordFailed)
        }
    }

    @MainActor
    func test_stop_whenIdle_returnsNil() {
        let rec = makeRecorder()
        XCTAssertNil(rec.stop())
    }

    @MainActor
    func test_start_afterFinish_beginsAnotherRecording() async throws {
        // A second voice note: stop() leaves the recorder .finished, and
        // start() must accept that (only an in-flight recording is rejected).
        let rec = makeRecorder()
        try await rec.start()
        _ = rec.stop()
        XCTAssertEqual(rec.state, .finished)
        try await rec.start()
        guard case .recording = rec.state else { return XCTFail("expected a second .recording") }
    }

    @MainActor
    func test_cancel_duringPermissionAwait_abortsTheStart() async throws {
        // cancel() landing while start() is suspended at the permission
        // prompt must win: no capture may begin after the user backed out.
        let fake = FakeAudioRecorder()
        var releasePermission: CheckedContinuation<Bool, Never>?
        let rec = VoiceRecorder(
            requestPermission: {
                await withCheckedContinuation { releasePermission = $0 }
            },
            makeRecorder: { _ in fake })

        async let starting: Void = rec.start()
        // Let start() reach and suspend on the permission await.
        while releasePermission == nil { await Task.yield() }
        rec.cancel()
        releasePermission?.resume(returning: true)
        try await starting

        XCTAssertEqual(rec.state, .idle, "a cancelled start must not begin capturing")
        XCTAssertEqual(fake.recordCalls, 0)
    }

    @MainActor
    func test_secondStart_duringPermissionAwait_throwsAlreadyRecording() async throws {
        var releasePermission: CheckedContinuation<Bool, Never>?
        let rec = VoiceRecorder(
            requestPermission: {
                await withCheckedContinuation { releasePermission = $0 }
            },
            makeRecorder: { _ in FakeAudioRecorder() })

        async let first: Void = rec.start()
        while releasePermission == nil { await Task.yield() }
        // State is still .idle here — the isStarting flag must reject the
        // overlapping second tap anyway.
        do {
            try await rec.start()
            XCTFail("expected .alreadyRecording for an overlapping start")
        } catch let error as VoiceRecorder.RecorderError {
            XCTAssertEqual(error, .alreadyRecording)
        }
        releasePermission?.resume(returning: true)
        try await first
        guard case .recording = rec.state else { return XCTFail("first start should have completed") }
    }

    @MainActor
    func test_start_disablesIdleTimerWhileRecording() async throws {
        var keepAwakeCalls: [Bool] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { _ in FakeAudioRecorder() },
                                setKeepScreenAwake: { keepAwakeCalls.append($0) })
        try await rec.start()
        XCTAssertEqual(keepAwakeCalls, [true])
    }

    @MainActor
    func test_stop_reenablesIdleTimer() async throws {
        var keepAwakeCalls: [Bool] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { _ in FakeAudioRecorder() },
                                setKeepScreenAwake: { keepAwakeCalls.append($0) })
        try await rec.start()
        _ = rec.stop()
        XCTAssertEqual(keepAwakeCalls, [true, false])
    }

    @MainActor
    func test_cancel_reenablesIdleTimer() async throws {
        var keepAwakeCalls: [Bool] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { _ in FakeAudioRecorder() },
                                setKeepScreenAwake: { keepAwakeCalls.append($0) })
        try await rec.start()
        rec.cancel()
        XCTAssertEqual(keepAwakeCalls, [true, false])
    }

    @MainActor
    func test_start_recordFailure_neverDisablesIdleTimer() async {
        // The screen-awake claim must only be taken once capture is truly
        // running — a failed record() start must not leave the idle timer off.
        let fake = FakeAudioRecorder()
        fake.recordReturn = false
        var keepAwakeCalls: [Bool] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { _ in fake },
                                setKeepScreenAwake: { keepAwakeCalls.append($0) })
        try? await rec.start()
        XCTAssertEqual(keepAwakeCalls, [])
    }

    @MainActor
    func test_start_recordFailure_staysIdleAndRecoverable() async {
        // AVAudioRecorder.record() returning false must surface
        // `.recordFailed`, leave the state machine .idle, and not poison a
        // retry (session/temp-file cleanup is exercised on-device; here we
        // pin the observable state contract).
        let fake = FakeAudioRecorder()
        fake.recordReturn = false
        let rec = makeRecorder(fake: fake)
        do {
            try await rec.start()
            XCTFail("expected .recordFailed")
        } catch let error as VoiceRecorder.RecorderError {
            XCTAssertEqual(error, .recordFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(rec.state, .idle)

        // A subsequent start succeeds once record() cooperates.
        fake.recordReturn = true
        try? await rec.start()
        guard case .recording = rec.state else { return XCTFail("expected recovery to .recording") }
    }
}
