import XCTest
@testable import MatronViewModels

private final class FakeRecording: AudioRecording {
    func record() -> Bool { true }
    func stop() {}
}

/// Fake interruption source, as in `VoiceRecorderTests`.
private final class FakeInterruptions {
    var handler: ((AudioInterruption) -> Void)?
    func source(_ handler: @escaping (AudioInterruption) -> Void) -> () -> Void {
        self.handler = handler
        return {}
    }
}

/// The app-wide recording (mission 5840): a note belongs to the place it
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
        return VoiceNoteSession(recorder: recorder)
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

    /// The bug: leaving the page used to cancel the note. Nothing a page
    /// does reaches the session except an explicit cancel, so stopping
    /// from anywhere (the indicator on another page) sends it to where it
    /// was started.
    func test_stopFromAnywhere_deliversToTheStartingPlace() async throws {
        let session = makeSession()
        let inboxA = Inbox()
        try await session.start(chatA, deliver: inboxA.deliver)
        // Dan wanders: the owning composer leaves the screen, another
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
        XCTAssertNil(session.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxA.delivered[0].0.path),
                       "a sent note's file is deleted")
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

        XCTAssertEqual(session.failure, .init(target: chatA, message: "Conversation not found"))
        let url = inbox.delivered[0].0
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the only copy survives")

        inbox.result = nil
        await session.retryFailed()?.value
        XCTAssertEqual(inbox.delivered.count, 2)
        XCTAssertEqual(inbox.delivered[1].0, url, "retry sends the same recording")
        XCTAssertNil(session.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_discardFailed_deletesTheFile() async throws {
        let session = makeSession()
        let inbox = Inbox()
        inbox.result = "offline"
        try await session.start(chatA, deliver: inbox.deliver)
        await session.stopAndSend()?.value
        let url = inbox.delivered[0].0

        session.discardFailed()
        XCTAssertNil(session.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(session.retryFailed())
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
        XCTAssertNotNil(session.failure)
        session.discardFailed()
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
        XCTAssertNil(session.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.delivered[0].0.path))
    }
}
