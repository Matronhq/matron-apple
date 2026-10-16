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
        var pauses = 0
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                pause: { pauses += 1 })
        try await rec.start()
        XCTAssertEqual(pauses, VoiceRecorder.maxLiveChecks)
        guard case .recording = rec.state else { return XCTFail("expected .recording after the cap") }
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

    /// Once recording, a recorder that can't switch keeps going; the pick
    /// waits for the next note.
    @MainActor
    func test_selectMicrophone_whileRecording_onARecorderThatCantSwitch_appliesNextTime() async throws {
        let fake = FakeAudioRecorder()
        fake.canSwitchMicrophoneLive = false
        let rec = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake }, defaults: freshDefaults())
        try await rec.start()
        rec.selectMicrophone("built-in")
        XCTAssertEqual(fake.usedMicrophones, [nil])
        XCTAssertEqual(fake.stopCalls, 0)
        XCTAssertEqual(rec.preferredMicrophoneID, "built-in")
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
