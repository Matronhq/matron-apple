import XCTest
import AVFoundation
import MatronModels
@testable import MatronViewModels

private final class FakeRecording: AudioRecording {
    var capturing = true
    func record() -> Bool { true }
    func stop() {}
    var isCapturingAudio: Bool { capturing }
}

/// A recording whose file is finished on disk some time after `stop()`
/// returns, as the Mac's capture session finishes its file: AVFoundation
/// reports the finish later, on the main thread. `finished()` waits
/// until the test calls `finish()`.
private final class LateFinishingRecording: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false
    func record() -> Bool { true }
    func stop() {}
    func finished() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if isFinished {
                lock.unlock()
                waiter.resume()
            } else {
                waiters.append(waiter)
                lock.unlock()
            }
        }
    }
    func finish() {
        lock.lock()
        isFinished = true
        let ready = waiters
        waiters = []
        lock.unlock()
        ready.forEach { $0.resume() }
    }
}

/// Fake interruption source, as in `VoiceRecorderTests`.
private final class FakeInterruptions {
    var handler: ((AudioInterruption) -> Void)?
    func source(_ handler: @escaping (AudioInterruption) -> Void) -> () -> Void {
        self.handler = handler
        return {}
    }
}

/// The app-wide recording: a note belongs to the place it
/// was started in, survives everything a page can do, and is sent there.
@MainActor
final class VoiceNoteSessionTests: XCTestCase {
    private let chatA = VoiceNoteSession.Target(kind: .conversation("A"), title: "Chat A")
    private let chatB = VoiceNoteSession.Target(kind: .conversation("B"), title: "Chat B")
    private let item7 = VoiceNoteSession.Target(kind: .item("7"), title: "Item 7")

    private var interruptions = FakeInterruptions()

    /// The recorder never writes a file (fake `AVAudioRecorder`), so each
    /// test that needs bytes on disk writes them to the URL `stop()` hands
    /// back — the URL is the recorder's own temp path.
    private func makeSession(permission: @escaping () async -> Bool = { true }) -> VoiceNoteSession {
        let recorder = VoiceRecorder(requestPermission: permission,
                                     makeRecorder: { _ in FakeRecording() },
                                     observeInterruptions: interruptions.source)
        return VoiceNoteSession(recorder: recorder, measureAudio: { _ in 5 })
    }

    /// Records what each delivery received, answering with `result`.
    private final class Inbox {
        var delivered: [(URL, TimeInterval)] = []
        var result: String?
        func deliver(_ url: URL, _ duration: TimeInterval) async -> String? {
            // Stands in for the upload reading the file.
            try? Data("AUDIO".utf8).write(to: url)
            delivered.append((url, duration))
            return result
        }
    }

    func test_start_recordsForItsTarget() async throws {
        let session = makeSession()
        try await session.start(chatA) { _, _ in nil }
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(session.target, chatA)
        XCTAssertTrue(session.isRecording(for: .conversation("A")))
        XCTAssertFalse(session.isRecording(for: .conversation("B")))
        XCTAssertNotNil(session.recordingStart)
    }

    /// While the mic warms up the place shows "Starting microphone…", not
    /// the recording bar, and nothing is recording yet.
    func test_start_isStartingUntilTheMicIsLive() async throws {
        let fake = FakeRecording()
        fake.capturing = false
        var seen: [(starting: Bool, recording: Bool)] = []
        var indicator: [Bool] = []
        var session: VoiceNoteSession!
        let recorder = VoiceRecorder(requestPermission: { true },
                                     makeRecorder: { _ in fake },
                                     pause: {
                                         seen.append((session.isStarting(for: .conversation("A")),
                                                      session.isRecording))
                                         indicator.append(session.showsIndicator)
                                         fake.capturing = true
                                     })
        session = VoiceNoteSession(recorder: recorder, measureAudio: { _ in 5 })
        try await session.start(chatA) { _, _ in nil }

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(indicator, [true], "with no composer on screen the pill shows the starting note")
        XCTAssertEqual(seen.first?.starting, true)
        XCTAssertEqual(seen.first?.recording, false)
        XCTAssertFalse(session.isStarting(for: .conversation("A")))
        XCTAssertTrue(session.isRecording(for: .conversation("A")))
    }

    /// The bug: leaving the page used to cancel the note. Nothing a page
    /// does reaches the session except an explicit cancel, so stopping
    /// from anywhere (the indicator on another page) sends it to where it
    /// was started.
    func test_stopFromAnywhere_deliversToTheStartingPlace() async throws {
        let session = makeSession()
        let inboxA = Inbox()
        try await session.start(chatA, deliver: inboxA.deliver)
        // The user wanders: the owning composer leaves the screen, another
        // chat's composer mounts. Neither touches the recording.
        let composerA = UUID(), composerB = UUID()
        session.ownerAppeared(composerA, kind: .conversation("A"))
        session.ownerDisappeared(composerA)
        session.ownerAppeared(composerB, kind: .conversation("B"))
        XCTAssertTrue(session.isRecording)

        await session.stopAndSend()?.value

        XCTAssertEqual(inboxA.delivered.count, 1)
        XCTAssertFalse(session.isRecording)
        XCTAssertNil(session.target)
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxA.delivered[0].0.path),
                       "a sent note's file is deleted")
    }

    /// Send must not wait for the recorder to finish its file. The Mac's
    /// capture session used to block the main thread in `stop()` until
    /// AVFoundation's finish callback — which arrives on the main thread,
    /// so every send froze the app for the full 3 s timeout. The session
    /// now leaves the recording at once and the delivery waits, off the
    /// tap, for the finished file.
    func test_stopAndSend_returnsAtOnceAndDeliversOnceTheFileIsFinished() async throws {
        let fake = LateFinishingRecording()
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                     observeInterruptions: interruptions.source)
        let session = VoiceNoteSession(recorder: recorder, measureAudio: { _ in 5 })
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)

        let task = try XCTUnwrap(session.stopAndSend())

        XCTAssertFalse(session.isRecording, "the recording bar goes the moment send is pressed")
        XCTAssertTrue(session.isSending, "the note shows as sending straight away")
        XCTAssertEqual(session.sendingTarget, chatA)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(inbox.delivered.isEmpty, "nothing reads the file before it is finished")

        fake.finish()
        await task.value

        XCTAssertEqual(inbox.delivered.count, 1)
        XCTAssertFalse(session.isSending)
        XCTAssertTrue(session.failures.isEmpty)
    }

    func test_secondStartElsewhere_isRefusedAndTheLiveNoteContinues() async throws {
        let session = makeSession()
        try await session.start(chatA) { _, _ in nil }
        do {
            try await session.start(item7) { _, _ in nil }
            XCTFail("a second place must not start while one is recording")
        } catch let error as VoiceNoteSession.SessionError {
            XCTAssertEqual(error, .busyElsewhere(title: "Chat A"))
            XCTAssertTrue(error.localizedDescription.contains("Chat A"))
        }
        XCTAssertEqual(session.target, chatA)
        XCTAssertTrue(session.isRecording)
    }

    func test_secondStartForTheSamePlace_isAlreadyRecording() async throws {
        let session = makeSession()
        try await session.start(chatA) { _, _ in nil }
        do {
            try await session.start(chatA) { _, _ in nil }
            XCTFail("expected alreadyRecording")
        } catch let error as VoiceRecorder.RecorderError {
            XCTAssertEqual(error, .alreadyRecording)
        }
    }

    /// In an item thread the mic button stays on screen
    /// while the note records, and pressing it again to finish showed
    /// "RecorderError error 1" (alreadyRecording). A second press on the
    /// place that is recording finishes the note and sends it, as the
    /// hotkey does.
    func test_pressAgainForTheRecordingPlace_stopsAndSends() async throws {
        let session = makeSession()
        let inbox = Inbox()
        try await session.press(item7, deliver: inbox.deliver)
        XCTAssertTrue(session.isRecording(for: .item("7")))
        let send = try await session.press(item7, deliver: inbox.deliver)
        await send?.value
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(inbox.delivered.count, 1)
        XCTAssertTrue(session.failures.isEmpty)
    }

    /// A press while the first is still starting (the permission prompt
    /// is up) is a quiet no-op, not an error.
    func test_pressAgainWhileStarting_isIgnored() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let session = makeSession(permission: {
            for await _ in gate.stream { break }
            return true
        })
        let first = Task { try await session.press(self.item7) { _, _ in nil } }
        await Task.yield()
        let second = try await session.press(item7) { _, _ in nil }
        XCTAssertNil(second)
        gate.continuation.yield()
        _ = try await first.value
        XCTAssertTrue(session.isRecording(for: .item("7")))
    }

    /// The composer's send is the one send: with nothing recording it
    /// sends the draft; with this place's note recording it finishes the
    /// note (whose delivery carries the text); another place's note
    /// doesn't change what this composer's send does.
    func test_composerSend_routesToTheNoteOnlyWhileItsPlaceRecords() async throws {
        let session = makeSession()
        let inbox = Inbox()
        XCTAssertEqual(session.composerSend(for: .item("7")), .draft)
        try await session.start(item7, deliver: inbox.deliver)
        XCTAssertEqual(session.composerSend(for: .item("7")), .note)
        XCTAssertEqual(session.composerSend(for: .conversation("A")), .draft)

        await session.stopAndSend()?.value
        XCTAssertEqual(inbox.delivered.count, 1)
        XCTAssertEqual(session.composerSend(for: .item("7")), .draft)
    }

    /// While the microphone starts, send waits: sending the text then
    /// would leave the note about to record behind it.
    func test_composerSend_waitsWhileTheMicStarts() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let session = makeSession(permission: {
            for await _ in gate.stream { break }
            return true
        })
        let start = Task { try await session.start(self.item7) { _, _ in nil } }
        await Task.yield()
        XCTAssertEqual(session.composerSend(for: .item("7")), .wait)
        XCTAssertEqual(session.composerSend(for: .item("8")), .draft)
        gate.continuation.yield()
        try await start.value
        XCTAssertEqual(session.composerSend(for: .item("7")), .note)
    }

    func test_pressElsewhereWhileRecording_isStillRefused() async throws {
        let session = makeSession()
        try await session.press(chatA) { _, _ in nil }
        do {
            try await session.press(item7) { _, _ in nil }
            XCTFail("expected busyElsewhere")
        } catch let error as VoiceNoteSession.SessionError {
            XCTAssertEqual(error, .busyElsewhere(title: "Chat A"))
        }
        XCTAssertEqual(session.target, chatA)
    }

    /// Two places tapping mic while the permission prompt is up: the
    /// second must not overwrite where the first note goes.
    func test_startElsewhereDuringPermissionPrompt_isRefused() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let session = makeSession(permission: {
            for await _ in gate.stream { break }
            return true
        })
        let first = Task { try await session.start(self.chatA) { _, _ in nil } }
        await Task.yield()
        do {
            try await session.start(chatB) { _, _ in nil }
            XCTFail("expected busyElsewhere")
        } catch let error as VoiceNoteSession.SessionError {
            XCTAssertEqual(error, .busyElsewhere(title: "Chat A"))
        }
        gate.continuation.yield()
        try await first.value
        XCTAssertEqual(session.target, chatA)
    }

    func test_permissionDenied_leavesNoTarget() async {
        let session = makeSession(permission: { false })
        do {
            try await session.start(chatA) { _, _ in nil }
            XCTFail("expected permissionDenied")
        } catch {}
        XCTAssertNil(session.target)
        XCTAssertFalse(session.isRecording)
        // And a later start elsewhere isn't refused as busy.
        let session2 = makeSession()
        try? await session2.start(chatB) { _, _ in nil }
        XCTAssertEqual(session2.target, chatB)
    }

    func test_cancel_discardsWithoutDelivering() async throws {
        let session = makeSession()
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        session.cancel()
        XCTAssertNil(session.stopAndSend(), "nothing left to send")
        XCTAssertTrue(inbox.delivered.isEmpty)
        XCTAssertNil(session.target)
    }

    func test_cancelIfTargeting_onlyCancelsItsOwnNote() async throws {
        let session = makeSession()
        try await session.start(chatA) { _, _ in nil }
        session.cancel(ifTargeting: .conversation("B"))
        XCTAssertTrue(session.isRecording)
        session.cancel(ifTargeting: .conversation("A"))
        XCTAssertFalse(session.isRecording)
    }

    /// The conversation was closed or deleted, or the network dropped: the
    /// note isn't lost — it waits with Retry and Discard.
    func test_failedDelivery_keepsTheNoteForRetry() async throws {
        let session = makeSession()
        let inbox = Inbox()
        inbox.result = "Conversation not found"
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value

        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertEqual(failure.target, chatA)
        XCTAssertEqual(failure.message, "Conversation not found")
        XCTAssertTrue(failure.canRetry)
        let url = inbox.delivered[0].0
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the only copy survives")

        inbox.result = nil
        await session.retry(failure.id)?.value
        XCTAssertEqual(inbox.delivered.count, 2)
        XCTAssertEqual(inbox.delivered[1].0, url, "retry sends the same recording")
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_discardFailed_deletesTheFile() async throws {
        let session = makeSession()
        let inbox = Inbox()
        inbox.result = "offline"
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        let url = inbox.delivered[0].0
        let id = try XCTUnwrap(session.failures.first?.id)

        session.discard(id)
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(session.retry(id))
    }

    /// A failure doesn't block the next note.
    func test_newNoteCanStartWhileAnEarlierOneFailed() async throws {
        let session = makeSession()
        let inbox = Inbox()
        inbox.result = "offline"
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        try await session.start(chatB) { _, _ in nil }
        XCTAssertEqual(session.target, chatB)
        XCTAssertEqual(session.failures.count, 1)
        session.reset()
    }

    /// Two failures in a row (offline): the second never throws away the
    /// first — each waits for its own Retry or Discard.
    func test_secondFailure_keepsTheFirstNote() async throws {
        let session = makeSession()
        let inbox = Inbox()
        inbox.result = "offline"
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        try await session.start(chatB, deliver: inbox.deliver)
        await session.stopAndSend()?.value

        XCTAssertEqual(session.failures.map(\.target), [chatA, chatB])
        let first = inbox.delivered[0].0, second = inbox.delivered[1].0
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        inbox.result = nil
        await session.retry(session.failures[0].id)?.value
        XCTAssertEqual(session.failures.map(\.target), [chatB])
        XCTAssertEqual(inbox.delivered[2].0, first, "Retry sends the note it belongs to")
        session.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    /// A delivery that consumed the file itself (an empty recording) can't
    /// be retried: the row offers only Dismiss.
    func test_failureWithoutAFile_isNotRetryable() async throws {
        let session = makeSession()
        try await session.start(item7) { url, _ in
            try? FileManager.default.removeItem(at: url)
            return "Voice note was empty."
        }
        await session.stopAndSend()?.value
        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertFalse(failure.canRetry)
        XCTAssertNil(session.retry(failure.id))
        session.discard(failure.id)
        XCTAssertTrue(session.failures.isEmpty)
    }

    /// Sign-out while the recorder is still finishing the file: nothing is
    /// uploaded for the old account, and the file is deleted.
    func test_resetWhileTheFileIsFinishing_deliversNothing() async throws {
        let fake = LateFinishingRecording()
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                     observeInterruptions: interruptions.source)
        let session = VoiceNoteSession(recorder: recorder, measureAudio: { _ in 5 })
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        let task = try XCTUnwrap(session.stopAndSend())

        session.reset()
        fake.finish()
        await task.value

        XCTAssertTrue(inbox.delivered.isEmpty)
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertFalse(session.isSending)
    }

    /// Sign-out mid-upload: the old account's failure must not land in the
    /// next account's pill (with a Retry that would send as the old one).
    func test_sendSettlingAfterReset_leavesNoFailure() async throws {
        let session = makeSession()
        let gate = AsyncStream<Void>.makeStream()
        let uploading = AsyncStream<Void>.makeStream()
        var deliveredURL: URL?
        var sawCancellation = false
        try await session.start(chatA) { url, _ in
            deliveredURL = url
            uploading.continuation.yield()
            for await _ in gate.stream { break }
            sawCancellation = Task.isCancelled
            return "offline"
        }
        let upload = session.stopAndSend()
        // The send first waits for the recorder's file; sign out once the
        // upload itself is under way.
        for await _ in uploading.stream { break }
        session.reset()
        gate.continuation.yield()
        await upload?.value
        XCTAssertTrue(sawCancellation, "reset() cancels the upload itself, not just its result")
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertFalse(session.isSending)
        if let deliveredURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: deliveredURL.path))
        }
    }

    /// The indicator stands in for the owning composer's own bar: hidden
    /// while that composer is on screen, shown everywhere else.
    func test_indicator_hidesOnlyWhileTheOwningComposerIsOnScreen() async throws {
        let session = makeSession()
        XCTAssertFalse(session.showsIndicator)
        let owner = UUID(), other = UUID()
        session.ownerAppeared(owner, kind: .conversation("A"))
        try await session.start(chatA) { _, _ in nil }
        XCTAssertFalse(session.showsIndicator)
        session.ownerAppeared(other, kind: .conversation("B"))
        XCTAssertFalse(session.showsIndicator)
        session.ownerDisappeared(owner)
        XCTAssertTrue(session.showsIndicator)
        session.ownerAppeared(owner, kind: .conversation("A"))
        XCTAssertFalse(session.showsIndicator)
    }

    /// A phone call mid-note pauses and resumes inside the recorder; the
    /// session's note — and where it goes — is untouched.
    func test_interruption_keepsTheNoteAndItsTarget() async throws {
        let session = makeSession()
        let inbox = Inbox()
        try await session.start(item7, deliver: inbox.deliver)
        interruptions.handler?(.began)
        XCTAssertTrue(session.isRecording)
        interruptions.handler?(.ended(shouldResume: true))
        XCTAssertEqual(session.target, item7)
        await session.stopAndSend()?.value
        XCTAssertEqual(inbox.delivered.count, 1)
    }

    func test_reset_cancelsAndDiscardsEverything() async throws {
        let session = makeSession()
        let inbox = Inbox()
        inbox.result = "offline"
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        try await session.start(chatB) { _, _ in nil }
        session.reset()
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(session.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.delivered[0].0.path))
    }

    /// Voice mode holds the microphone (spec 2026-10-03 §3): no ordinary
    /// note can start until it ends.
    func testANoteCannotStartWhileVoiceModeIsOn() async throws {
        let session = makeSession()
        session.isVoiceModeOn = true
        do {
            try await session.start(chatA) { _, _ in nil }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? VoiceNoteSession.SessionError, .voiceModeOn)
            XCTAssertEqual(error.localizedDescription, "Voice mode is on. End it to record a voice note.")
        }
        XCTAssertFalse(session.isRecording)
        session.isVoiceModeOn = false
        try await session.start(chatA) { _, _ in nil }
        XCTAssertTrue(session.isRecording(for: chatA.kind))
        session.cancel()
    }

    // MARK: Empty recordings

    /// A note with under a second of audio in its file is never sent.
    func test_aNoteWithUnderASecondOfAudio_isRefused() async throws {
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeRecording() },
                                     observeInterruptions: interruptions.source)
        let session = VoiceNoteSession(recorder: recorder, measureAudio: { _ in 0.2 })
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value

        XCTAssertTrue(inbox.delivered.isEmpty, "nothing reaches the upload")
        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertEqual(failure.message, "Nothing was recorded, try again")
        XCTAssertFalse(failure.canRetry)
    }

    /// An unreadable file counts as empty too.
    func test_aNoteWhoseFileIsNotAudio_isRefused() async throws {
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeRecording() },
                                     observeInterruptions: interruptions.source)
        let session = VoiceNoteSession(recorder: recorder)
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        XCTAssertTrue(inbox.delivered.isEmpty)
        XCTAssertEqual(session.failures.first?.message, "Nothing was recorded, try again")
    }

    func test_audioDuration_readsTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                   AVSampleRateKey: 44_100.0,
                                                                   AVNumberOfChannelsKey: 1])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 88_200))
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        }
        let measured = await VoiceNoteSession.audioDuration(of: url)
        let seconds = try XCTUnwrap(measured)
        XCTAssertEqual(seconds, 2, accuracy: 0.1)
    }

    /// The capture died mid-note: the note stops, and what was recorded
    /// waits in a failure row whose Retry sends it.
    func test_captureLost_keepsWhatWasRecordedForRetry() async throws {
        let fake = StallingRecording()
        var stall = false
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                     pause: {}, watchPause: {
                                         await Task.yield()
                                         if !stall { fake.seconds += 1 }
                                         if fake.seconds >= 4 { stall = true }
                                     })
        let session = VoiceNoteSession(recorder: recorder, measureAudio: { _ in 4 })
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        for _ in 0..<5_000 where session.failures.isEmpty { await Task.yield() }

        XCTAssertFalse(session.isRecording)
        XCTAssertNil(session.target)
        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertTrue(failure.canRetry)
        XCTAssertTrue(failure.message.hasPrefix("Desk mic stopped at 0:04."), failure.message)
        XCTAssertTrue(inbox.delivered.isEmpty, "not sent without the user asking")
        await session.retry(failure.id)?.value
        XCTAssertEqual(inbox.delivered.count, 1)
    }

    func test_captureLost_withNothingRecorded_onlyReportsIt() async throws {
        let fake = StallingRecording()
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                     pause: {}, watchPause: { await Task.yield() })
        let session = VoiceNoteSession(recorder: recorder, measureAudio: { _ in 0 })
        try await session.start(chatA) { _, _ in nil }
        for _ in 0..<5_000 where session.failures.isEmpty { await Task.yield() }

        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertFalse(failure.canRetry)
        XCTAssertTrue(failure.message.hasSuffix("Nothing was recorded, try again."), failure.message)
    }

    /// The writer saved much less than the clock showed: the note isn't
    /// sent as if it were whole. The row says so, and Retry sends what
    /// was saved.
    func test_aFileMuchShorterThanTheClock_waitsThenAsks() async throws {
        var now = Date(timeIntervalSince1970: 0)
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeRecording() },
                                     observeInterruptions: interruptions.source, now: { now })
        let measured = Counter()
        let session = VoiceNoteSession(recorder: recorder,
                                       measureAudio: { url in
                                           // Stands in for the recorder's short file.
                                           try? Data("AUDIO".utf8).write(to: url)
                                           await measured.bump()
                                           return 3
                                       },
                                       settle: {})
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        now += 23
        await session.stopAndSend()?.value

        let checks = await measured.value
        XCTAssertEqual(checks, 1 + VoiceNoteSession.shortFileRechecks, "measured again while the file might finish")
        XCTAssertTrue(inbox.delivered.isEmpty)
        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertEqual(failure.message, "Only 0:03 of 0:23 was saved. Retry sends what was saved.")
        XCTAssertTrue(failure.canRetry)
        await session.retry(failure.id)?.value
        XCTAssertEqual(inbox.delivered.count, 1, "Retry sends it as it is")
        XCTAssertTrue(session.failures.isEmpty)
    }

    /// A file that finishes while the session waits is sent normally.
    func test_aFileThatCatchesUp_isSent() async throws {
        var now = Date(timeIntervalSince1970: 0)
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeRecording() },
                                     observeInterruptions: interruptions.source, now: { now })
        let measured = Counter()
        let session = VoiceNoteSession(recorder: recorder,
                                       measureAudio: { _ in await measured.bump() >= 3 ? 23 : 3 },
                                       settle: {})
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        now += 23
        await session.stopAndSend()?.value
        XCTAssertEqual(inbox.delivered.count, 1)
        XCTAssertTrue(session.failures.isEmpty)
    }
}

extension VoiceNoteSessionTests {
    /// The recorder reported an error finishing the file: the note isn't
    /// sent as if it were whole; Retry sends what was saved.
    func test_aFileTheRecorderFailedToFinish_waitsForTheUser() async throws {
        let fake = BrokenFinishRecording()
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in fake },
                                     observeInterruptions: interruptions.source)
        let session = VoiceNoteSession(recorder: recorder, measureAudio: { url in
            try? Data("AUDIO".utf8).write(to: url)
            return 5
        })
        let inbox = Inbox()
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value

        XCTAssertTrue(inbox.delivered.isEmpty)
        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertEqual(failure.message, VoiceNoteSession.brokenMessage)
        XCTAssertTrue(failure.canRetry)
        await session.retry(failure.id)?.value
        XCTAssertEqual(inbox.delivered.count, 1)
    }

    // MARK: Failures kept across a restart

    private func makeSession(failedNotes directory: URL) -> VoiceNoteSession {
        let recorder = VoiceRecorder(requestPermission: { true }, makeRecorder: { _ in FakeRecording() },
                                     observeInterruptions: interruptions.source)
        return VoiceNoteSession(recorder: recorder, measureAudio: { _ in 5 }, failedNotesDirectory: directory)
    }

    /// A note that couldn't go back into a reply box keeps its Retry after
    /// the app restarts: its file moves out of tmp, and a new session reads
    /// the row back and sends through the place's delivery.
    func test_aRetryableFailure_survivesARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("failed-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession(failedNotes: directory)
        session.restoreSavedFailures { _ in nil }
        let inbox = Inbox()
        inbox.result = "offline"
        try await session.start(item7, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        let recorded = inbox.delivered[0].0
        let failure = try XCTUnwrap(session.failures.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.path), "moved out of tmp")

        let relaunched = makeSession(failedNotes: directory)
        XCTAssertTrue(relaunched.failures.isEmpty, "nothing is read before sign-in")
        let resolved = Inbox()
        var asked: [VoiceNoteSession.Target] = []
        relaunched.restoreSavedFailures { target in
            asked.append(target)
            return resolved.deliver
        }
        let back = try XCTUnwrap(relaunched.failures.first)
        XCTAssertEqual(back.id, failure.id)
        XCTAssertEqual(back.target, item7)
        XCTAssertEqual(back.message, "offline")
        XCTAssertTrue(back.canRetry)

        await relaunched.retry(back.id)?.value
        XCTAssertEqual(asked, [item7])
        XCTAssertEqual(resolved.delivered.count, 1)
        XCTAssertTrue(relaunched.failures.isEmpty)
        XCTAssertTrue(makeSessionAfterRestart(directory).failures.isEmpty, "a sent note is gone from disk")
    }

    /// Discard, and sign-out, delete the saved note too.
    func test_savedFailures_goOnDiscardAndOnReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("failed-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = makeSession(failedNotes: directory)
        session.restoreSavedFailures { _ in nil }
        let inbox = Inbox()
        inbox.result = "offline"
        for target in [chatA, chatB] {
            try await session.start(target, deliver: inbox.deliver)
            await session.stopAndSend()?.value
        }
        XCTAssertEqual(makeSessionAfterRestart(directory).failures.count, 2)

        session.discard(try XCTUnwrap(session.failures.first).id)
        XCTAssertEqual(makeSessionAfterRestart(directory).failures.map(\.target), [chatB])

        session.reset()
        XCTAssertTrue(makeSessionAfterRestart(directory).failures.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func makeSessionAfterRestart(_ directory: URL) -> VoiceNoteSession {
        let session = makeSession(failedNotes: directory)
        session.restoreSavedFailures { _ in nil }
        return session
    }
}

private final class BrokenFinishRecording: AudioRecording {
    private var stopped = false
    func record() -> Bool { true }
    func stop() { stopped = true }
    var hasFailed: Bool { stopped }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult func bump() -> Int { value += 1; return value }
}

private final class StallingRecording: AudioRecording {
    var seconds: TimeInterval = 1
    func record() -> Bool { true }
    func stop() {}
    var elapsed: TimeInterval { seconds }
    var microphone: Microphone? { Microphone(id: "desk", name: "Desk mic") }
}
