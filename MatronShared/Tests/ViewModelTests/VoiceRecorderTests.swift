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

final class VoiceRecorderTests: XCTestCase {
    @MainActor
    private func makeRecorder(permission: Bool = true,
                             fake: FakeAudioRecorder = FakeAudioRecorder()) -> VoiceRecorder {
        VoiceRecorder(requestPermission: { permission }, makeRecorder: { _ in fake })
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
