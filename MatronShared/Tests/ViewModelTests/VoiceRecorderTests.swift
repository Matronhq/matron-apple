import XCTest
import AVFoundation
import MatronModels
@testable import MatronViewModels

/// Fake `AudioRecording` so the `VoiceRecorder` state machine can be
/// exercised without capturing audio or hitting the permission dialog.
private final class FakeAudioRecorder: AudioRecording {
    var recordReturn = true
    /// Whether the "microphone" is delivering sound yet.
    var capturing = true
    private(set) var recordCalls = 0
    private(set) var stopCalls = 0
    func record() -> Bool { recordCalls += 1; return recordReturn }
    func stop() { stopCalls += 1 }
    var isCapturingAudio: Bool { capturing }
    var canSwitchMicrophoneLive = true
    private(set) var usedMicrophones: [String?] = []
    var microphone: Microphone? { usedMicrophones.last.map { Microphone(id: $0 ?? "default", name: $0 ?? "Default") } }
    func useMicrophone(_ id: String?) { usedMicrophones.append(id) }
    var elapsed: TimeInterval = 0
    /// The capture's clock isn't keeping pace with real time.
    var runningSlow = false
    var isRunningSlow: Bool { runningSlow }
    /// Set to finish the file only when the test signals it, as the Mac's
    /// capture session finishes its file after `stop()`.
    var lateFinish: RecordingFinishSignal?
    func finished() async { if let lateFinish { _ = await lateFinish.wait(timeout: 3) } }
}

/// A recorder that writes its file only after `stop()` returns, when the
/// test calls `finishWritingFile()`, as the Mac's capture session does.
private final class LateFinishingAudioRecorder: AudioRecording, @unchecked Sendable {
    var url: URL?
    private let signal = RecordingFinishSignal()
    func record() -> Bool { true }
    func stop() {}
    func finished() async { _ = await signal.wait(timeout: 3) }
    func finishWritingFile() {
        if let url { try? Data("AUDIO".utf8).write(to: url) }
        signal.signal()
    }
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

    /// The duration handed to the send path is capture time, not wall time:
    /// a two-minute call in the middle of a note is silence the recorder
    /// never captured (CodeRabbit, PR #180).
    @MainActor
    func test_duration_excludesInterruptedTime_whenResumed() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var now = t0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                observeInterruptions: interruptions.source, now: { now })
        try await rec.start()
        now = t0.addingTimeInterval(10)
        interruptions.handler?(.began)
        now = t0.addingTimeInterval(15)
        interruptions.handler?(.ended(shouldResume: true))
        now = t0.addingTimeInterval(20)
        XCTAssertEqual(try XCTUnwrap(rec.stop()).duration, 15, accuracy: 0.001)
    }

    /// Not resumed: paused from the interruption until Stop, so nothing
    /// after `began` counts.
    @MainActor
    func test_duration_excludesInterruptedTime_whenNotResumed() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var now = t0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                observeInterruptions: interruptions.source, now: { now })
        try await rec.start()
        now = t0.addingTimeInterval(10)
        interruptions.handler?(.began)
        now = t0.addingTimeInterval(15)
        interruptions.handler?(.ended(shouldResume: false))
        now = t0.addingTimeInterval(20)
        XCTAssertEqual(try XCTUnwrap(rec.stop()).duration, 10, accuracy: 0.001)
    }

    /// A resume that fails leaves the recorder paused, so the pause keeps
    /// running until Stop (Bugbot, PR #180).
    @MainActor
    func test_duration_excludesTimeAfterAFailedResume() async throws {
        let fake = FakeAudioRecorder()
        let interruptions = FakeInterruptions()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var now = t0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                observeInterruptions: interruptions.source, now: { now })
        try await rec.start()
        now = t0.addingTimeInterval(10)
        interruptions.handler?(.began)
        fake.recordReturn = false
        now = t0.addingTimeInterval(15)
        interruptions.handler?(.ended(shouldResume: true))
        now = t0.addingTimeInterval(20)
        XCTAssertEqual(try XCTUnwrap(rec.stop()).duration, 10, accuracy: 0.001)
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

    /// The Mac's capture session finishes its file after `stop()` returns.
    /// Cancel can't wait for that on the main thread, so it deletes the
    /// file once the recorder says it is done: nothing is left behind.
    @MainActor
    func test_cancel_deletesAFileTheRecorderFinishesLate() async throws {
        let fake = LateFinishingAudioRecorder()
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { url in
            fake.url = url
            return fake
        })
        try await rec.start()
        let url = try XCTUnwrap(fake.url)

        rec.cancel()
        XCTAssertEqual(rec.state, .idle, "cancel never waits for the file")
        fake.finishWritingFile()

        for _ in 0..<50 where FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A stopped note's `finished()` waits for the recorder's file.
    @MainActor
    func test_stop_finishedWaitsForTheRecordersFile() async throws {
        let fake = LateFinishingAudioRecorder()
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { url in
            fake.url = url
            return fake
        })
        try await rec.start()
        let stopped = try XCTUnwrap(rec.stop())
        XCTAssertEqual(rec.state, .finished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.url.path))

        let finished = Task { await stopped.finished() }
        fake.finishWritingFile()
        await finished.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.url.path))
        try? FileManager.default.removeItem(at: stopped.url)
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

    // MARK: Microphone warm-up (record() returns before the mic is live)

    /// The bug: the bar said "recording" the moment `record()` returned,
    /// but the input took seconds to deliver sound, so the first words of
    /// every note were never captured. Until the mic is live the recorder
    /// is `.starting`, and the recording (and its clock) begins only then.
    @MainActor
    func test_start_staysStartingUntilTheMicDeliversSound() async throws {
        let fake = FakeAudioRecorder()
        fake.capturing = false
        var clock = Date(timeIntervalSince1970: 0)
        var statesWhileWaiting: [VoiceRecorder.State] = []
        var rec: VoiceRecorder!
        rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                            now: { clock },
                            pause: {
                                statesWhileWaiting.append(rec.state)
                                clock += 1
                                // The input comes up after 3 s.
                                if clock.timeIntervalSince1970 >= 3 { fake.capturing = true }
                            })
        try await rec.start()

        XCTAssertEqual(statesWhileWaiting, [.starting, .starting, .starting],
                       "never 'recording' while the mic is still silent")
        XCTAssertEqual(rec.state, .recording(start: Date(timeIntervalSince1970: 3)),
                       "the recording starts when sound does")
        clock += 5
        XCTAssertEqual(rec.stop()?.duration, 5, "the note's length counts from the live mic")
    }

    @MainActor
    func test_start_withALiveMic_recordsAtOnce() async throws {
        var pauses = 0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeAudioRecorder() },
                                pause: { pauses += 1 })
        try await rec.start()
        guard case .recording = rec.state else { return XCTFail("expected .recording") }
        XCTAssertEqual(pauses, 0)
    }

    @MainActor
    func test_cancel_duringWarmUp_abortsTheStart() async throws {
        let fake = FakeAudioRecorder()
        fake.capturing = false
        var rec: VoiceRecorder!
        rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                            pause: { rec.cancel() })
        try await rec.start()

        XCTAssertEqual(rec.state, .idle, "a cancelled warm-up never turns into a recording")
        XCTAssertEqual(fake.stopCalls, 1)
        XCTAssertNil(rec.stop())
    }

    /// A muted input delivers true silence forever: the note still starts,
    /// after the cap, rather than hanging on "Starting microphone…".
    @MainActor
    func test_start_goesLiveAfterTheCap_whenTheMicStaysSilent() async throws {
        let fake = FakeAudioRecorder()
        fake.capturing = false
        // The file is growing, with silence in it.
        fake.elapsed = 4
        var pauses = 0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                pause: { pauses += 1 })
        try await rec.start()
        XCTAssertEqual(pauses, VoiceRecorder.maxLiveChecks)
        guard case .recording = rec.state else { return XCTFail("expected .recording after the cap") }
    }

    /// The bug: an input that never delivered anything went live after the
    /// cap, and the bar showed "Recording" for 30 s over an empty file.
    /// With nothing in the file the start fails instead.
    @MainActor
    func test_start_failsWithNoAudio_whenNothingReachesTheFile() async {
        let fake = FakeAudioRecorder()
        fake.capturing = false
        fake.elapsed = 0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, pause: {})
        do {
            try await rec.start()
            XCTFail("expected .noAudio")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .noAudio)
            XCTAssertEqual(error.localizedDescription.hasPrefix("Nothing was recorded"), true)
        }
        XCTAssertEqual(rec.state, .idle, "never left looking live")
        XCTAssertEqual(fake.stopCalls, 1)
    }

    // MARK: A capture whose clock runs slow

    /// The bug (twice on a Mac whose Bluetooth headset connected as the note
    /// started): the capture counted 0.03 s in 34 s, so it was past zero
    /// and never stalled, and the bar showed "Recording" over nothing.
    /// The start now begins the capture again and goes live on the new one.
    @MainActor
    func test_start_restartsACaptureWhoseClockRunsSlow_andGoesLiveOnTheNewOne() async throws {
        let slow = FakeAudioRecorder()
        slow.capturing = false
        slow.runningSlow = true
        slow.elapsed = 0.001
        let good = FakeAudioRecorder()
        var made = [slow, good]
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in made.removeFirst() },
                                pause: {}, defaults: freshDefaults())
        try await rec.start()
        guard case .recording = rec.state else { return XCTFail("expected .recording") }
        XCTAssertEqual(slow.stopCalls, 1, "the slow capture was dropped")
        XCTAssertEqual(good.recordCalls, 1)
        XCTAssertEqual(good.stopCalls, 0)
        XCTAssertNotNil(rec.stop())
    }

    /// The restarted capture records from the microphone the user chose.
    @MainActor
    func test_start_restartingASlowCapture_keepsThePreferredMicrophone() async throws {
        let slow = FakeAudioRecorder()
        slow.capturing = false
        slow.runningSlow = true
        let good = FakeAudioRecorder()
        var made = [slow, good]
        let defaults = freshDefaults()
        defaults.set("built-in", forKey: VoiceRecorder.preferredMicrophoneKey)
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in made.removeFirst() },
                                pause: {}, defaults: defaults)
        try await rec.start()
        XCTAssertEqual(good.usedMicrophones, ["built-in"])
        XCTAssertNotNil(rec.stop())
    }

    /// Every restart comes up slow too: the start fails, so nothing is
    /// left looking live.
    @MainActor
    func test_start_failsWithNoAudio_whenEveryRestartRunsSlow() async {
        var made: [FakeAudioRecorder] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { _ in
                                    let fake = FakeAudioRecorder()
                                    fake.capturing = false
                                    fake.runningSlow = true
                                    fake.elapsed = 0.001
                                    made.append(fake)
                                    return fake
                                },
                                pause: {}, defaults: freshDefaults())
        do {
            try await rec.start()
            XCTFail("expected .noAudio")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .noAudio)
        }
        XCTAssertEqual(rec.state, .idle)
        XCTAssertEqual(made.count, 1 + VoiceRecorder.maxSlowRestarts)
        XCTAssertEqual(made.map(\.stopCalls), Array(repeating: 1, count: made.count), "every capture was stopped")
    }

    /// The clock starts running slow in the middle of a note: it still
    /// creeps forward, so the stall check passes, but the note is stopped
    /// and reported rather than left ticking.
    @MainActor
    func test_recording_whoseClockStartsRunningSlow_isStoppedAndReported() async throws {
        let fake = FakeAudioRecorder()
        fake.elapsed = 2
        let (rec, lost) = watchedRecorder(fake) { check in
            fake.elapsed += 0.0005
            if check == 4 { fake.runningSlow = true }
        }
        try await rec.start()
        await waitUntil { !lost().isEmpty }
        XCTAssertEqual(lost().count, 1)
        XCTAssertEqual(fake.stopCalls, 1)
    }

    func test_capturePace_aClockKeepingTime_isNotSlow() {
        var pace = CapturePace(start: 100)
        XCTAssertFalse(pace.check(at: 100.5, recorded: 0.4), "too soon to judge")
        XCTAssertFalse(pace.check(at: 101.1, recorded: 1.0))
        XCTAssertFalse(pace.check(at: 102.2, recorded: 2.1))
    }

    /// The readings from the failed notes: 0.03 s recorded in 34 s.
    func test_capturePace_aClockAThousandTimesTooSlow_isSlowAfterOneWindow() {
        var pace = CapturePace(start: 100)
        XCTAssertFalse(pace.check(at: 100.9, recorded: 0.0009), "too soon to judge")
        XCTAssertTrue(pace.check(at: 101.0, recorded: 0.001))
        XCTAssertTrue(pace.check(at: 101.5, recorded: 0.0015), "holds between windows")
    }

    /// A slow start that then recovers stops counting as slow, and a
    /// clock that slows mid-note is caught in the window where it does.
    func test_capturePace_judgesEachWindowOnItsOwn() {
        var pace = CapturePace(start: 0)
        XCTAssertTrue(pace.check(at: 1, recorded: 0.001))
        XCTAssertFalse(pace.check(at: 2, recorded: 1.0))
        XCTAssertFalse(pace.check(at: 12, recorded: 11.0))
        XCTAssertTrue(pace.check(at: 13, recorded: 11.001))
    }

    /// The main thread stalling between readings doesn't make a healthy
    /// capture look slow: the window is as long as the gap.
    func test_capturePace_aLateReading_isJudgedOverTheWholeGap() {
        var pace = CapturePace(start: 0)
        XCTAssertFalse(pace.check(at: 15, recorded: 14.9))
    }

    // MARK: Watchdog (capture dying while the note shows as recording)

    @MainActor
    private func watchedRecorder(_ fake: FakeAudioRecorder, onCheck: @escaping (Int) -> Void)
        -> (VoiceRecorder, () -> [VoiceRecorder.CaptureLost]) {
        var checks = 0
        var lost: [VoiceRecorder.CaptureLost] = []
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, pause: {},
                                watchPause: {
                                    await Task.yield()
                                    checks += 1
                                    onCheck(checks)
                                })
        rec.onCaptureLost = { lost.append($0) }
        return (rec, { lost })
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
    }

    /// A note whose file stops growing (the input went away mid-note) is
    /// stopped and reported, rather than ticking on over nothing.
    @MainActor
    func test_recording_whoseFileStopsGrowing_isStoppedAndReported() async throws {
        let fake = FakeAudioRecorder()
        fake.elapsed = 1
        let (rec, lost) = watchedRecorder(fake) { check in
            // Grows for five checks, then stalls at 5 s.
            if check <= 5 { fake.elapsed += 1 }
        }
        try await rec.start()
        await waitUntil { !lost().isEmpty }

        XCTAssertEqual(lost().count, 1)
        XCTAssertEqual(rec.state, .finished)
        XCTAssertEqual(fake.stopCalls, 1)
        XCTAssertNil(rec.stop(), "already stopped")
    }

    @MainActor
    func test_recording_whoseRecorderFails_isStoppedAndReported() async throws {
        let fake = FailingMidNoteRecorder()
        var lost: [VoiceRecorder.CaptureLost] = []
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, pause: {},
                                watchPause: { await Task.yield(); fake.failed = true })
        rec.onCaptureLost = { lost.append($0) }
        try await rec.start()
        await waitUntil { !lost.isEmpty }
        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(rec.state, .finished)
    }

    @MainActor
    func test_recording_thatKeepsGrowing_isLeftAlone() async throws {
        let fake = FakeAudioRecorder()
        var done = false
        let (rec, lost) = watchedRecorder(fake) { check in
            fake.elapsed += 0.5
            if check == 30 { done = true }
        }
        try await rec.start()
        await waitUntil { done }
        XCTAssertTrue(done)
        XCTAssertTrue(lost().isEmpty)
        guard case .recording = rec.state else { return XCTFail("expected .recording") }
        XCTAssertNotNil(rec.stop())
    }

    /// An interruption is not a stall: the recorder is paused on purpose.
    @MainActor
    func test_recording_pausedByAnInterruption_isLeftAlone() async throws {
        let fake = FakeAudioRecorder()
        fake.elapsed = 2
        let interruptions = FakeInterruptions()
        var checks = 0
        var lost: [VoiceRecorder.CaptureLost] = []
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                observeInterruptions: interruptions.source, pause: {},
                                watchPause: { await Task.yield(); checks += 1 })
        rec.onCaptureLost = { lost.append($0) }
        try await rec.start()
        interruptions.handler?(.began)
        await waitUntil { checks > 50 }
        XCTAssertGreaterThan(checks, VoiceRecorder.maxStalledChecks * 2, "the watchdog kept checking")
        XCTAssertTrue(lost.isEmpty)
        XCTAssertNotNil(rec.stop())
    }

    /// The clock runs but the file on disk stopped growing: the writer
    /// has stopped, so the note stops rather than ticking on.
    @MainActor
    func test_recording_whoseFileStopsGrowingOnDisk_isStoppedAndReported() async throws {
        let fake = FakeAudioRecorder()
        var bytes = 1_000
        var lost: [VoiceRecorder.CaptureLost] = []
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, pause: {},
                                watchPause: {
                                    await Task.yield()
                                    fake.elapsed += 0.5
                                    // Written for three checks, then stuck.
                                    if fake.elapsed <= 1.5 { bytes += 4_000 }
                                },
                                fileSize: { _ in bytes })
        rec.onCaptureLost = { lost.append($0) }
        try await rec.start()
        await waitUntil { !lost.isEmpty }
        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(rec.state, .finished)
    }

    /// A writer that holds everything until Stop never counts as stalled.
    @MainActor
    func test_recording_whoseWriterHoldsTheAudioUntilStop_isLeftAlone() async throws {
        let fake = FakeAudioRecorder()
        var checks = 0
        var lost: [VoiceRecorder.CaptureLost] = []
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, pause: {},
                                watchPause: { await Task.yield(); fake.elapsed += 0.5; checks += 1 },
                                fileSize: { _ in 600 })
        rec.onCaptureLost = { lost.append($0) }
        try await rec.start()
        await waitUntil { checks > VoiceRecorder.maxUnwrittenChecks * 2 }
        XCTAssertTrue(lost.isEmpty)
        XCTAssertNotNil(rec.stop())
    }

    /// After a hand-over the live recorder's clock starts near zero:
    /// that is a new file growing, not a stall.
    @MainActor
    func test_recording_afterAHandover_isNotTakenForAStall() async throws {
        let old = FakeAudioRecorder()
        old.canSwitchMicrophoneLive = false
        old.elapsed = 20
        let fresh = FakeAudioRecorder()
        var made = 0
        var checks = 0
        var lost: [VoiceRecorder.CaptureLost] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { _ in made += 1; return made == 1 ? old : fresh },
                                pause: {},
                                watchPause: {
                                    await Task.yield()
                                    checks += 1
                                    old.elapsed += 0.5
                                    fresh.elapsed += 0.5
                                })
        rec.onCaptureLost = { lost.append($0) }
        try await rec.start()
        // The watchdog has seen the old file's clock before the switch.
        await waitUntil { checks >= 3 }
        rec.selectMicrophone("usb")
        await waitUntil { checks > VoiceRecorder.maxStalledChecks * 4 }
        XCTAssertGreaterThan(checks, VoiceRecorder.maxStalledChecks * 4)
        XCTAssertEqual(made, 2, "the note was handed over")
        XCTAssertTrue(lost.isEmpty, "a growing new file is not a stall")
        guard case .recording = rec.state else { return XCTFail("expected .recording") }
        XCTAssertNotNil(rec.stop())
    }

    // MARK: Files older decoders reject

    func test_versionedChannelLayout_isFoundInsideMoov() {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + body.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + body
        }
        let chnl1 = box("chnl", [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        let chnl0 = box("chnl", [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        let ftyp = box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
        func file(_ chnl: [UInt8]) -> Data {
            Data(ftyp + box("mdat", Array("chnl".utf8) + [1, 1, 1, 1]) + box("moov", box("trak", box("mdia", chnl))))
        }
        XCTAssertTrue(MP4Boxes.hasVersionedChannelLayout(file(chnl1)))
        XCTAssertFalse(MP4Boxes.hasVersionedChannelLayout(file(chnl0)))
        XCTAssertFalse(MP4Boxes.hasVersionedChannelLayout(Data(ftyp + box("moov", box("trak", [])))))
        XCTAssertFalse(MP4Boxes.hasVersionedChannelLayout(Data("AUDIO".utf8)))
    }

    /// A call during the warm-up holds the start (it doesn't use up the
    /// cap); with the resume hint the recorder is started again and the
    /// note goes live once the mic delivers sound.
    @MainActor
    func test_interruptionDuringWarmUp_resumesThenGoesLive() async throws {
        let fake = FakeAudioRecorder()
        fake.capturing = false
        let interruptions = FakeInterruptions()
        var pauses = 0
        var rec: VoiceRecorder!
        rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                            observeInterruptions: interruptions.source,
                            pause: {
                                pauses += 1
                                if pauses == 1 { interruptions.handler?(.began) }
                                // A long call: far more checks than the cap.
                                if pauses == VoiceRecorder.maxLiveChecks + 50 {
                                    interruptions.handler?(.ended(shouldResume: true))
                                }
                                if pauses == VoiceRecorder.maxLiveChecks + 52 { fake.capturing = true }
                            })
        try await rec.start()
        XCTAssertEqual(fake.recordCalls, 2, "record() again after the interruption")
        guard case .recording = rec.state else { return XCTFail("expected .recording") }
    }

    /// Without the resume hint another app has the mic and nothing was
    /// captured: the start fails rather than showing a dead recording.
    @MainActor
    func test_interruptionDuringWarmUp_withoutResume_failsTheStart() async {
        let fake = FakeAudioRecorder()
        fake.capturing = false
        let interruptions = FakeInterruptions()
        var keepAwake: [Bool] = []
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                setKeepScreenAwake: { keepAwake.append($0) },
                                observeInterruptions: interruptions.source,
                                pause: {
                                    interruptions.handler?(.began)
                                    interruptions.handler?(.ended(shouldResume: false))
                                })
        do {
            try await rec.start()
            XCTFail("expected .recordFailed")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .recordFailed)
        }
        XCTAssertEqual(rec.state, .idle)
        XCTAssertEqual(keepAwake, [true, false])
        XCTAssertEqual(interruptions.cancelCalls, 1, "unsubscribed")
    }

    // MARK: Choosing the microphone

    private func freshDefaults() -> UserDefaults {
        let name = "VoiceRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The remembered pick is applied before capture starts, and the bar
    /// can name the microphone from the first moment.
    @MainActor
    func test_start_recordsFromTheRememberedMicrophone() async throws {
        let defaults = freshDefaults()
        defaults.set("usb-1", forKey: VoiceRecorder.preferredMicrophoneKey)
        let fake = FakeAudioRecorder()
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, defaults: defaults)
        XCTAssertEqual(rec.preferredMicrophoneID, "usb-1")
        try await rec.start()
        XCTAssertEqual(fake.usedMicrophones, ["usb-1"])
        XCTAssertEqual(rec.microphone?.id, "usb-1")
        _ = rec.stop()
        XCTAssertNil(rec.microphone, "nothing is recording")
    }

    @MainActor
    func test_selectMicrophone_isRememberedForLaterNotes() {
        let defaults = freshDefaults()
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeAudioRecorder() }, defaults: defaults)
        rec.selectMicrophone("airpods")
        XCTAssertEqual(rec.preferredMicrophoneID, "airpods")
        let later = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeAudioRecorder() }, defaults: defaults)
        XCTAssertEqual(later.preferredMicrophoneID, "airpods")
        later.selectMicrophone(nil)
        XCTAssertNil(VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeAudioRecorder() },
                                   defaults: defaults).preferredMicrophoneID, "back to the default")
    }

    /// Picking mid-note moves a recorder that can switch, in place.
    @MainActor
    func test_selectMicrophone_whileRecording_switchesLive() async throws {
        let fake = FakeAudioRecorder()
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        XCTAssertEqual(fake.usedMicrophones, [nil, "built-in"])
        XCTAssertEqual(rec.microphone?.id, "built-in")
        XCTAssertEqual(fake.stopCalls, 0, "the same recording carries on")
    }

    /// A recorder that can't switch, still waiting for sound, starts over
    /// on the new microphone: nothing was captured, so nothing is lost.
    @MainActor
    func test_selectMicrophone_whileStarting_restartsARecorderThatCantSwitch() async throws {
        let first = FakeAudioRecorder()
        first.capturing = false
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        var made: [FakeAudioRecorder] = [first, second]
        var rec: VoiceRecorder!
        rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in made.removeFirst() },
                            pause: { if rec.microphone?.id != "built-in" { rec.selectMicrophone("built-in") } },
                            defaults: freshDefaults())
        try await rec.start()
        XCTAssertEqual(first.stopCalls, 1)
        XCTAssertEqual(second.usedMicrophones, ["built-in"])
        XCTAssertEqual(second.recordCalls, 1)
        guard case .recording = rec.state else { return XCTFail("live on the new microphone") }
        XCTAssertEqual(rec.microphone?.id, "built-in")
    }

    /// A late pick restarts the capture with the whole warm-up allowance,
    /// not what was left of the first one.
    @MainActor
    func test_selectMicrophone_lateInWarmUp_restartsTheAllowance() async throws {
        let first = FakeAudioRecorder()
        first.capturing = false
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.capturing = false
        var made: [FakeAudioRecorder] = [first, second]
        var pauses = 0
        var rec: VoiceRecorder!
        let lateCheck = VoiceRecorder.maxLiveChecks - 10
        rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in made.removeFirst() },
                            pause: {
                                pauses += 1
                                if pauses == lateCheck { rec.selectMicrophone("built-in") }
                                // The new mic is live 50 checks after the pick.
                                if pauses == lateCheck + 50 { second.capturing = true }
                            },
                            defaults: freshDefaults())
        try await rec.start()
        XCTAssertEqual(pauses, lateCheck + 50, "went live on sound, not on the old cap")
    }

    /// Once recording, a recorder that can't move (the Mac's) hands over
    /// to a new one on the picked microphone. The old one keeps recording
    /// until the new one delivers sound, so nothing said in between is
    /// lost; Stop joins the two parts into one note, without the new
    /// part's silent lead-in.
    @MainActor
    func test_selectMicrophone_whileRecording_onARecorderThatCantSwitch_handsOverWithoutLosingAudio() async throws {
        let first = FakeAudioRecorder()
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.canSwitchMicrophoneLive = false
        second.capturing = false
        var made: [FakeAudioRecorder] = [first, second]
        var urls: [URL] = []
        var joined: [(parts: [AudioSegment], into: URL)] = []
        var rec: VoiceRecorder!
        rec = VoiceRecorder(requestPermission: { true },
                            makeRecorder: { urls.append($0); return made.removeFirst() },
                            pause: {
                                // The new mic is live after half a second.
                                second.elapsed = 0.5
                                second.capturing = true
                            },
                            joinSegments: { joined.append(($0, $1)) },
                            defaults: freshDefaults())
        let firstPartFinished = RecordingFinishSignal()
        first.lateFinish = firstPartFinished
        try await rec.start()
        rec.selectMicrophone("built-in")
        XCTAssertEqual(second.usedMicrophones, ["built-in"])
        XCTAssertEqual(second.recordCalls, 1, "the new microphone starts at once")
        XCTAssertEqual(first.stopCalls, 0, "the old one records until the new one hears sound")
        XCTAssertEqual(rec.microphone?.id, "built-in", "the bar names the pick straight away")
        await rec.microphoneHandover?.value
        XCTAssertEqual(first.stopCalls, 1, "handed over once the new microphone is live")
        guard case .recording = rec.state else { return XCTFail("the same note carries on") }

        let result = try XCTUnwrap(rec.stop())
        XCTAssertEqual(second.stopCalls, 1)
        // The first part's file isn't finished yet: nothing is joined
        // until it is.
        let finished = Task { await result.finished() }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(joined.isEmpty, "the parts are joined only once every file is finished")
        firstPartFinished.signal()
        await finished.value
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined.first?.parts, [AudioSegment(url: urls[0], trimStart: 0),
                                             AudioSegment(url: urls[1], trimStart: 0.5)])
        XCTAssertEqual(joined.first?.into, result.url)
        XCTAssertFalse(urls.contains(result.url), "the note is a new file made of the parts")
    }

    /// A join that fails sends the longest part rather than nothing, at
    /// the note's own URL (the one `stop()` already handed out).
    @MainActor
    func test_stop_afterAHandover_whenTheJoinFails_sendsTheLongestPart() async throws {
        let first = FakeAudioRecorder()
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.canSwitchMicrophoneLive = false
        second.capturing = false
        var made: [FakeAudioRecorder] = [first, second]
        var urls: [URL] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { urls.append($0); return made.removeFirst() },
                                pause: { second.capturing = true },
                                joinSegments: { _, _ in throw CocoaError(.fileReadCorruptFile) },
                                defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        await rec.microphoneHandover?.value
        try Data("LONG FIRST PART".utf8).write(to: urls[0])
        try Data("short".utf8).write(to: urls[1])

        let result = try XCTUnwrap(rec.stop())
        await result.finished()

        XCTAssertEqual(try Data(contentsOf: result.url), Data("LONG FIRST PART".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))
        try? FileManager.default.removeItem(at: result.url)
    }

    /// Stop before the new microphone hears anything: the new part is
    /// silence, so the note is the old recording on its own.
    @MainActor
    func test_stop_duringAMicrophoneHandover_keepsTheOldRecording() async throws {
        let first = FakeAudioRecorder()
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.capturing = false
        var made: [FakeAudioRecorder] = [first, second]
        var urls: [URL] = []
        var joins = 0
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { urls.append($0); return made.removeFirst() },
                                pause: { await Task.yield() },
                                joinSegments: { _, _ in joins += 1 },
                                defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        let result = try XCTUnwrap(rec.stop())
        XCTAssertEqual(first.stopCalls, 1)
        XCTAssertEqual(second.stopCalls, 1)
        XCTAssertEqual(result.url, urls[0])
        XCTAssertEqual(joins, 0)
        await rec.microphoneHandover?.value
        XCTAssertEqual(rec.state, .finished)
    }

    /// Cancel mid-handover stops both recorders.
    @MainActor
    func test_cancel_duringAMicrophoneHandover_stopsBothRecorders() async throws {
        let first = FakeAudioRecorder()
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.capturing = false
        var made: [FakeAudioRecorder] = [first, second]
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in made.removeFirst() },
                                pause: { await Task.yield() }, defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        rec.cancel()
        XCTAssertEqual(first.stopCalls, 1)
        XCTAssertEqual(second.stopCalls, 1)
        XCTAssertEqual(rec.state, .idle)
    }

    /// If the new microphone won't start, the note stays on the old one.
    @MainActor
    func test_selectMicrophone_whileRecording_keepsTheOldRecorderWhenTheNewOneWontStart() async throws {
        let first = FakeAudioRecorder()
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.recordReturn = false
        var made: [FakeAudioRecorder] = [first, second]
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in made.removeFirst() },
                                defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        XCTAssertNil(rec.microphoneHandover)
        XCTAssertEqual(first.stopCalls, 0)
        XCTAssertEqual(rec.microphone?.id, "default")
        XCTAssertEqual(rec.preferredMicrophoneID, "built-in", "still remembered for the next note")
    }

    /// A new microphone still silent when the warm-up cap runs out (a
    /// Bluetooth input slower than about 4 s) doesn't take over: the old
    /// one is still recording the voice, so the note stays on it.
    @MainActor
    func test_selectMicrophone_whileRecording_staysOnTheOldRecorderWhenTheNewOneStaysSilent() async throws {
        let first = FakeAudioRecorder()
        first.canSwitchMicrophoneLive = false
        let second = FakeAudioRecorder()
        second.capturing = false
        var made: [FakeAudioRecorder] = [first, second]
        var urls: [URL] = []
        let rec = VoiceRecorder(requestPermission: { true },
                                makeRecorder: { urls.append($0); return made.removeFirst() },
                                pause: {}, defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        await rec.microphoneHandover?.value

        XCTAssertEqual(first.stopCalls, 0, "the old microphone keeps recording")
        XCTAssertEqual(second.stopCalls, 1, "the silent new one is dropped")
        XCTAssertEqual(rec.microphone?.id, "default")
        XCTAssertEqual(rec.preferredMicrophoneID, "built-in", "still remembered for the next note")
        XCTAssertEqual(try XCTUnwrap(rec.stop()).url, urls[0])
    }

    /// The real join: two AAC parts become one file as long as both,
    /// less the trimmed lead-in.
    func test_joinAudioSegments_concatenatesThePartsAndTrimsTheLeadIn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.m4a"), b = dir.appendingPathComponent("b.m4a")
        try writeTone(to: a, seconds: 1.0)
        try writeTone(to: b, seconds: 1.5)
        let out = dir.appendingPathComponent("note.m4a")
        try joinAudioSegments([AudioSegment(url: a, trimStart: 0), AudioSegment(url: b, trimStart: 0.5)], into: out)
        let file = try AVAudioFile(forReading: out)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(seconds, 2.0, accuracy: 0.1)
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                               AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 1])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(seconds * rate)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(2 * .pi * 440 * Double(i) / rate)) * 0.25 }
        try file.write(from: buffer)
    }

    /// A capture that dies before sound arrives fails the start.
    @MainActor
    func test_start_failsWhenTheRecorderGivesUp() async {
        let fake = FailingRecorder()
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, pause: {})
        do {
            try await rec.start()
            XCTFail("expected .recordFailed")
        } catch {
            XCTAssertEqual(error as? VoiceRecorder.RecorderError, .recordFailed)
        }
        XCTAssertEqual(rec.state, .idle)
    }
}

private final class FailingRecorder: AudioRecording {
    func record() -> Bool { true }
    func stop() {}
    var isCapturingAudio: Bool { false }
    var hasFailed: Bool { true }
}

private final class FailingMidNoteRecorder: AudioRecording {
    var failed = false
    func record() -> Bool { true }
    func stop() {}
    var hasFailed: Bool { failed }
    var elapsed: TimeInterval { 1 }
}
