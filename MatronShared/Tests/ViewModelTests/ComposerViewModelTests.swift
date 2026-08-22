import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Local mirror of `Tests/ChatTests/FakeTimelineService`. Kept in this file
/// because `ViewModelTests` doesn't depend on `ChatTests` — the same plain
/// final-class pattern is used for all in-test fakes (see `FakeChatService`,
/// `FakeAuthForVM`).
/// Lets a test hold a send suspended mid-flight and release it on demand,
/// so "what does the composer look like DURING the round-trip" is a
/// deterministic question rather than a timing race.
actor SendGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var started = false

    func markStarted() { started = true }
    func isStarted() -> Bool { started }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

final class FakeTimelineService: TimelineService, @unchecked Sendable {
    var snapshotsToEmit: [[TimelineItem]] = []
    /// When non-nil, `items()` finishes by throwing this error after
    /// yielding all queued snapshots. Lets tests pin the error-flow
    /// added in QA finding #10.
    var streamError: Error?
    var sentText: [String] = []
    /// Reply target per `sentText` entry (nil for plain sends).
    var sentInReplyTo: [String?] = []
    var sentButtonResponses: [(selectedValues: [String], inReplyTo: String)] = []
    var sentImages: [(filename: String, mime: String, sizeBytes: Int, caption: String?)] = []
    var sentFiles: [(filename: String, mime: String, sizeBytes: Int, caption: String?)] = []
    var paginateCalls: Int = 0
    var markReadCalls: Int = 0
    var retrySendCalls: [String] = []
    var discardSendCalls: [String] = []
    /// When set, the next `sendText`/`sendImage`/`sendFile` call throws this error.
    var nextSendError: Error?
    /// When set, media sends succeed this many times and every one after
    /// throws. Lets a test pin a partial batch — the first photo lands,
    /// the second doesn't — which is the case where the composer has to
    /// decide whether the caption was delivered.
    var failSendsAfter: Int?
    /// When non-zero, `sendText`/`sendButtonResponse` suspend this long
    /// before recording — lets AskUserSheetViewModelTests overlap two
    /// `send()` calls to pin the double-submit guard.
    var sendDelayNanos: UInt64 = 0

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        let snapshots = snapshotsToEmit
        let err = streamError
        return AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            if let err {
                continuation.finish(throwing: err)
            } else {
                continuation.finish()
            }
        }
    }

    /// Session-state values `sessionState()` yields (then finishes) —
    /// drives `ChatViewModel.isTurnRunning` tests.
    var sessionStatesToEmit: [String] = []

    func sessionState() -> AsyncStream<String> {
        let states = sessionStatesToEmit
        return AsyncStream { continuation in
            for s in states { continuation.yield(s) }
            continuation.finish()
        }
    }

    /// Deterministic in-flight window: `sendText` parks here until the test
    /// opens the gate. A wall-clock `Task.sleep` would do the same job, but
    /// sleeping inside the suite perturbs the timer-driven
    /// `JournalTimelineServiceTests` (sweep/gap tests) into spurious
    /// timeouts — measured 3 failures in 4 runs vs 0 in 4 without it.
    var sendGate: SendGate?

    func sendText(_ body: String, inReplyTo: String?) async throws {
        if sendDelayNanos > 0 { try? await Task.sleep(nanoseconds: sendDelayNanos) }
        if let gate = sendGate {
            await gate.markStarted()
            await gate.wait()
        }
        if let err = nextSendError { nextSendError = nil; throw err }
        sentText.append(body)
        sentInReplyTo.append(inReplyTo)
    }
    func retrySend(itemID: String) async { retrySendCalls.append(itemID) }
    func discardSend(itemID: String) async { discardSendCalls.append(itemID) }
    /// True per media send when the caller supplied a progress handler —
    /// pins that the composer reaches the progress-capable protocol
    /// requirement (dynamic dispatch), not the drop-the-handler default.
    var mediaSendsWithProgressHandler: [Bool] = []
    /// Batch tag per media send (nil for untagged sends) — pins that the
    /// composer stamps multi-attachment sends and leaves singles untagged.
    var mediaSendBatchTags: [AttachmentBatchTag?] = []
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?,
                   progress: (@Sendable (Double) -> Void)?) async throws {
        mediaSendsWithProgressHandler.append(progress != nil)
        progress?(0.5)
        try await sendImage(data, filename: filename, mimeType: mimeType, caption: caption)
    }
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?,
                  progress: (@Sendable (Double) -> Void)?) async throws {
        mediaSendsWithProgressHandler.append(progress != nil)
        progress?(0.5)
        try await sendFile(data, filename: filename, mimeType: mimeType, caption: caption)
    }
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?,
                   batch: AttachmentBatchTag?,
                   progress: (@Sendable (Double) -> Void)?) async throws {
        mediaSendBatchTags.append(batch)
        try await sendImage(data, filename: filename, mimeType: mimeType, caption: caption,
                            progress: progress)
    }
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?,
                  batch: AttachmentBatchTag?,
                  progress: (@Sendable (Double) -> Void)?) async throws {
        mediaSendBatchTags.append(batch)
        try await sendFile(data, filename: filename, mimeType: mimeType, caption: caption,
                           progress: progress)
    }
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {
        if sendDelayNanos > 0 { try? await Task.sleep(nanoseconds: sendDelayNanos) }
        if let err = nextSendError { nextSendError = nil; throw err }
        sentButtonResponses.append((selectedValues, promptEventID))
    }
    /// Throws once `failSendsAfter` media sends have already succeeded.
    private func failIfPastMediaLimit() throws {
        guard let limit = failSendsAfter, sentImages.count + sentFiles.count >= limit else { return }
        throw NSError(domain: "test", code: 2)
    }
    /// Media sends honour `sendGate` for the same reason `sendText` does:
    /// it's the only way to hold a send in flight while the test types into
    /// the composer, which is the exact race the restore guard exists for.
    private func awaitGate() async {
        guard let gate = sendGate else { return }
        await gate.markStarted()
        await gate.wait()
    }
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {
        await awaitGate()
        if let err = nextSendError { nextSendError = nil; throw err }
        try failIfPastMediaLimit()
        sentImages.append((filename, mimeType, data.count, caption))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {
        await awaitGate()
        if let err = nextSendError { nextSendError = nil; throw err }
        try failIfPastMediaLimit()
        sentFiles.append((filename, mimeType, data.count, caption))
    }
    func paginateBackward(requestSize: UInt16) async throws -> Bool { paginateCalls += 1; return false }
    func markAsRead() async throws { markReadCalls += 1 }

    private let statusPair = AsyncStream<SessionStatusUpdate>.makeStream()
    var statusContinuation: AsyncStream<SessionStatusUpdate>.Continuation { statusPair.continuation }
    func sessionStatus() -> AsyncStream<SessionStatusUpdate> { statusPair.stream }

    /// Summary TOC entries `summaryEntriesStream()` yields once (then
    /// finishes) — drives `ChatViewModel.summaryEntries` tests.
    var summaryEntriesToEmit: [ConversationSummaryEntry] = []

    func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]> {
        let entries = summaryEntriesToEmit
        return AsyncStream { continuation in
            continuation.yield(entries)
            continuation.finish()
        }
    }
}

final class ComposerViewModelTests: XCTestCase {
    @MainActor
    func test_palette_isShownWhenInputStartsWithSlash() {
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "/sta"
        XCTAssertTrue(vm.showPalette)
        XCTAssertTrue(vm.filteredCommands.contains { $0.trigger == "/start" })
    }

    @MainActor
    func test_palette_isHiddenForRegularInput() {
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "hello"
        XCTAssertFalse(vm.showPalette)
    }

    @MainActor
    func test_palette_isHiddenAfterSpace() {
        // Once the user types past the trigger token, the palette should
        // hide so it doesn't cover the rest of the message.
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "/start workdir"
        XCTAssertFalse(vm.showPalette)
    }

    @MainActor
    func test_selectingCommand_replacesInput_andClosesPalette() {
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "/sta"
        vm.palettePinnedOpen = true
        let cmd = BotCommand(trigger: "/start", summary: "x", argHint: "[workdir]")
        vm.selectCommand(cmd)
        XCTAssertEqual(vm.input, "/start ")
        XCTAssertFalse(vm.palettePinnedOpen)
    }

    @MainActor
    func test_send_sendsTrimmedAndClearsInput() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        vm.input = "  hello world  "
        await vm.send()
        XCTAssertEqual(fake.sentText, ["hello world"])
        XCTAssertEqual(vm.input, "")
        XCTAssertNil(vm.sendError)
    }

    @MainActor
    func test_send_clearsInputImmediately_notAfterTheRoundTrip() async {
        // Dan, 2026-07-15 (iOS, rare but recurring): the message sends but
        // the text stays sitting in the composer. Clearing `input` only
        // AFTER `sendText` returns leaves a window — the whole network
        // round-trip long — where a focused TextField still holds the text
        // and can write its cached value back over the late clear. The
        // field must go empty in the same tick as the tap; the send is then
        // just an outcome to report.
        let fake = FakeTimelineService()
        let gate = SendGate()
        fake.sendGate = gate
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        vm.input = "ok merge pull and restart"

        let send = Task { await vm.send() }
        // Park deterministically inside the round-trip — no wall clock.
        while await !gate.isStarted() { await Task.yield() }

        XCTAssertEqual(vm.input, "", "composer must be empty WHILE the send is still in flight")
        XCTAssertTrue(fake.sentText.isEmpty, "precondition: the round-trip has not completed yet")

        await gate.open()
        await send.value
        XCTAssertEqual(fake.sentText, ["ok merge pull and restart"])
        XCTAssertEqual(vm.input, "")
        XCTAssertNil(vm.sendError)
    }

    @MainActor
    func test_send_restoresInput_andDraft_whenTheRoundTripFails() async {
        // The optimistic clear must not eat the user's text: a failed send
        // puts it back (and back into draft memory) so retry still works.
        let fake = FakeTimelineService()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        fake.nextSendError = Boom()
        ComposerDraftMemory._resetForTesting()
        let vm = ComposerViewModel(roomID: "!room:s", timeline: fake, commands: [])
        vm.input = "keep me"

        await vm.send()

        XCTAssertEqual(vm.input, "keep me", "failed send restores the text for retry")
        XCTAssertEqual(vm.sendError, "boom")
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!room:s"), "keep me",
                       "and the draft survives, so leaving the room doesn't drop it")
    }

    /// The restore must never outrank live keystrokes. Sends are slow enough
    /// to type through — that's the whole reason the optimistic clear exists —
    /// so a failure arriving after the user has started their next message
    /// must not overwrite it (bugbot, PR #55).
    @MainActor
    func test_send_doesNotClobberNewTyping_whenTheRoundTripFails() async {
        let fake = FakeTimelineService()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        fake.nextSendError = Boom()
        let gate = SendGate()
        fake.sendGate = gate
        ComposerDraftMemory._resetForTesting()
        let vm = ComposerViewModel(roomID: "!room:s", timeline: fake, commands: [])
        vm.input = "first message"

        let send = Task { await vm.send() }
        while await !gate.isStarted() { await Task.yield() }
        // The user starts typing while the doomed send is still in flight.
        vm.input = "second message"
        await gate.open()
        await send.value

        XCTAssertEqual(vm.input, "second message",
                       "a failed send must not overwrite what the user typed after it")
        XCTAssertEqual(vm.sendError, "boom", "the failure is still surfaced")
    }

    @MainActor
    func test_send_doesNothing_forEmptyInput() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        vm.input = "   "
        await vm.send()
        XCTAssertTrue(fake.sentText.isEmpty)
    }

    @MainActor
    func test_send_recordsSendError_whenServiceThrows() async {
        let fake = FakeTimelineService()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        fake.nextSendError = Boom()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        vm.input = "hi"
        await vm.send()
        XCTAssertEqual(vm.sendError, "boom")
        // Input is preserved on failure so the user can retry.
        XCTAssertEqual(vm.input, "hi")
    }

    @MainActor
    func test_palette_staysClosed_afterCommandSelection() {
        // Regression for bugbot finding #1: `selectCommand` set the input
        // to "/stop " (trailing space). The palette's old check trimmed
        // whitespace, collapsing the input back to a single token starting
        // with `/`, which re-opened the palette immediately.
        //
        // Pinned against /stop — a command with no argument suggestions —
        // because commands WITH suggestions (e.g. /start) now deliberately
        // reopen the palette in argument mode (2026-08-10 spec).
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        let cmd = BotCommand(trigger: "/stop", summary: "x")
        vm.selectCommand(cmd)
        XCTAssertEqual(vm.input, "/stop ")
        XCTAssertFalse(vm.showPalette,
                       "palette should stay closed once a suggestion-free command has been chosen")
    }

    @MainActor
    func test_palette_isHiddenForCommandWithTrailingSpace() {
        // Tightened version of the regression above: typing a command with
        // no argument suggestions followed by a space should hide the
        // palette so it doesn't cover the next character. (Commands with
        // suggestions keep it open in argument mode instead.)
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/stop "
        XCTAssertFalse(vm.showPalette)
    }

    @MainActor
    func test_send_doesNothing_forWhitespaceOnlyInput_andSendErrorStaysNil() async {
        // Tightened version of `test_send_doesNothing_forEmptyInput`. The
        // send-button binding (`ComposerView.isSendable`) mirrors this
        // trim — both must agree the input is unsendable, otherwise the
        // button looks active but `send()` no-ops.
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        vm.input = "   \t\n  "
        await vm.send()
        XCTAssertTrue(fake.sentText.isEmpty)
        XCTAssertNil(vm.sendError, "no-op send should not record an error")
    }

    @MainActor
    func test_reportAttachmentError_recordsSendError() {
        // Surfacing path used by iOS `fileImporter` security-scoped read
        // failures (bugbot finding #4). Without this method, view-layer
        // errors had no way into the view model's private(set) field and
        // were silently dropped via `try?`.
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: [])
        vm.reportAttachmentError("boom")
        XCTAssertEqual(vm.sendError, "boom")
    }

    @MainActor
    func test_dismissSendError_clearsSendError() {
        // Lets the composer banner (which renders `sendError`) offer a
        // dismiss affordance without reaching around the `private(set)`
        // invariant — same shape as `reportAttachmentError`'s write path.
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: [])
        vm.reportAttachmentError("boom")
        XCTAssertEqual(vm.sendError, "boom")
        vm.dismissSendError()
        XCTAssertNil(vm.sendError)
    }

    @MainActor
    func test_sendVoiceNote_sendsAudioFileAndDeletesTemp() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try? Data("AUDIO".utf8).write(to: tmp)
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        // Seed a stale failure from an earlier attempt — a successful voice
        // send must clear it, same as send().
        vm.reportAttachmentError("old failure")

        await vm.sendVoiceNote(url: tmp, duration: 2.5)

        XCTAssertEqual(fake.sentFiles.count, 1)
        XCTAssertEqual(fake.sentFiles.first?.filename, "voice-note.m4a")
        XCTAssertEqual(fake.sentFiles.first?.mime, "audio/mp4")
        XCTAssertEqual(fake.sentFiles.first?.sizeBytes, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "temp recording should be deleted after sending")
        XCTAssertNil(vm.sendError)
    }

    @MainActor
    func test_sendVoiceNote_recordsError_andStillDeletesTemp_whenSendFails() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try? Data("AUDIO".utf8).write(to: tmp)
        let fake = FakeTimelineService()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        fake.nextSendError = Boom()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])

        await vm.sendVoiceNote(url: tmp, duration: 1)

        XCTAssertEqual(vm.sendError, "boom")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "temp recording should be deleted even when the send fails")
    }

    @MainActor
    func test_filteredCommands_stripsLeadingWhitespace() {
        // Round 2 bugbot finding #3: typing `"  /sta"` (with leading
        // spaces) caused `showPalette` to evaluate true (it ignored
        // leading whitespace) but `filteredCommands` to return empty
        // (raw `"  /sta"` doesn't strip the leading space, so the
        // `byPrefix` filter looked for triggers starting with `"  /sta"`
        // and matched nothing). Both sides must agree.
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
        vm.input = "  /sta"
        XCTAssertTrue(vm.showPalette)
        XCTAssertFalse(vm.filteredCommands.isEmpty,
                       "leading whitespace must not blank out the palette match list")
        XCTAssertTrue(vm.filteredCommands.contains { $0.trigger == "/start" })
    }

    // MARK: - Staged attachments

    /// Writes a real file somewhere `attachFiles` can read it, standing in
    /// for what every attach route hands over: a plain, non-security-scoped
    /// URL with bytes on disk.
    private func makeTempFile(
        named name: String, contents: String = "hi"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// The behaviour change at the heart of the tray: attaching stages, it
    /// does NOT send. Before this, a picked photo uploaded instantly and
    /// reached claude as its own context-free turn.
    @MainActor
    func test_attachFiles_stagesTheFile_andSendsNothingYet() async throws {
        let url = try makeTempFile(named: "hello.txt")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])

        await vm.attachFiles([url])

        XCTAssertEqual(vm.stagedAttachments.count, 1)
        XCTAssertEqual(vm.stagedAttachments.first?.filename, "hello.txt")
        XCTAssertEqual(vm.stagedAttachments.first?.sizeBytes, 2, "the bytes should have been read")
        XCTAssertTrue(fake.sentFiles.isEmpty, "attaching must not send — that's what send() is for")
        XCTAssertNil(vm.sendError)
    }

    /// `attachFiles` copies rather than referencing: the URLs it's handed
    /// come from security-scoped importers and pasteboard temp files, none
    /// of which promise to still be readable once the user has finished
    /// typing. Deleting the original must not break the send.
    @MainActor
    func test_stagedAttachment_survivesTheOriginalBeingDeleted() async throws {
        let url = try makeTempFile(named: "doomed.txt")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])

        try FileManager.default.removeItem(at: url)
        await vm.send()

        XCTAssertEqual(fake.sentFiles.count, 1, "the staged copy should still have been sendable")
        XCTAssertEqual(fake.sentFiles.first?.sizeBytes, 2)
        XCTAssertNil(vm.sendError)
    }

    /// THE point of the feature: the photo and the sentence about it leave
    /// together, so claude gets one prompt instead of two.
    @MainActor
    func test_send_withAnImageAndText_sendsTheTextAsTheCaption() async throws {
        let url = try makeTempFile(named: "shot.png")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])
        vm.input = "what's wrong with this?"

        await vm.send()

        XCTAssertEqual(fake.sentImages.count, 1, "a .png should go via sendImage")
        XCTAssertEqual(fake.sentImages.first?.caption, "what's wrong with this?")
        XCTAssertTrue(fake.sentText.isEmpty, "the text is the caption — it must not ALSO send separately")
        XCTAssertTrue(vm.input.isEmpty)
        XCTAssertTrue(vm.stagedAttachments.isEmpty, "a successful send empties the tray")
    }

    @MainActor
    func test_send_attachmentUpload_reportsProgressAndClearsWhenDone() async throws {
        let url = try makeTempFile(named: "shot.png")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])

        await vm.send()

        XCTAssertEqual(fake.mediaSendsWithProgressHandler, [true],
                       "uploads must go through the progress-capable send")
        XCTAssertNil(vm.uploadProgress, "progress strip clears once the batch finishes")
    }

    func test_uploadProgress_labels() {
        let single = ComposerViewModel.UploadProgress(
            filename: "shot.png", index: 1, count: 1, fraction: 0.2)
        XCTAssertEqual(single.label, "Uploading shot.png…")
        let batch = ComposerViewModel.UploadProgress(
            filename: "b.png", index: 2, count: 3, fraction: 0.7)
        XCTAssertEqual(batch.label, "Uploading 2 of 3…")
    }

    /// An attachment on its own is a complete message.
    @MainActor
    func test_send_withAttachmentAndNoText_sendsWithNoCaption() async throws {
        let url = try makeTempFile(named: "shot.png")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])

        XCTAssertTrue(vm.canSend, "an attachment alone should enable the send button")
        await vm.send()

        XCTAssertEqual(fake.sentImages.count, 1)
        XCTAssertNil(fake.sentImages.first?.caption)
    }

    /// The caption rides on exactly one attachment: the bridge injects each
    /// media event as its own prompt, so repeating it would make claude read
    /// the same sentence once per photo.
    @MainActor
    func test_send_withSeveralAttachments_captionsOnlyTheFirst() async throws {
        let first = try makeTempFile(named: "a.png")
        let second = try makeTempFile(named: "b.png")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([first, second])
        vm.input = "compare these"

        await vm.send()

        XCTAssertEqual(fake.sentImages.map(\.filename), ["a.png", "b.png"], "order must be preserved")
        XCTAssertEqual(fake.sentImages.first?.caption, "compare these")
        XCTAssertNil(fake.sentImages.last?.caption)
    }

    /// A multi-attachment send stamps every upload with the same batch id
    /// and its 1-based place, so the bridge can gather the frames back into
    /// the one message the user wrote instead of injecting the first image
    /// and busy-queueing the rest.
    @MainActor
    func test_send_withSeveralAttachments_stampsOneSharedBatchTag() async throws {
        let first = try makeTempFile(named: "a.png")
        let second = try makeTempFile(named: "b.png")
        let third = try makeTempFile(named: "c.png")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([first, second, third])

        await vm.send()

        let tags = fake.mediaSendBatchTags.compactMap { $0 }
        XCTAssertEqual(tags.count, 3, "every attachment of a batch send must carry the tag")
        XCTAssertEqual(Set(tags.map(\.id)).count, 1, "one send = one batch id")
        XCTAssertEqual(tags.map(\.index), [1, 2, 3])
        XCTAssertEqual(tags.map(\.total), [3, 3, 3])
    }

    /// A retried attachment must rejoin the batch it fell out of. The
    /// bridge gathers frames by batch_id: retried under the ORIGINAL id,
    /// the frame either deposits into the still-open gather (completing
    /// the user's one message) or — batch already finalized — takes the
    /// per-frame path. A fresh id could do neither: the frame would wait
    /// forever for siblings that already went out, and the message would
    /// arrive fractured.
    @MainActor
    func test_retry_afterAMidBatchFailure_reusesTheOriginalBatchTag() async throws {
        let first = try makeTempFile(named: "a.png")
        let second = try makeTempFile(named: "b.png")
        let third = try makeTempFile(named: "c.png")
        let fake = FakeTimelineService()
        fake.failSendsAfter = 1
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([first, second, third])

        await vm.send()

        XCTAssertEqual(fake.sentImages.map(\.filename), ["a.png"], "precondition: only a.png landed")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["b.png", "c.png"],
                       "precondition: the unsent pair came back to the tray")
        let original = try XCTUnwrap(fake.mediaSendBatchTags.compactMap { $0 }.first,
                                     "precondition: the first frame carried the batch tag")

        // The network comes back and the user hits send again.
        fake.failSendsAfter = nil
        await vm.send()

        XCTAssertEqual(fake.sentImages.map(\.filename), ["a.png", "b.png", "c.png"])
        let retried = fake.mediaSendBatchTags.suffix(2).compactMap { $0 }
        XCTAssertEqual(retried.map(\.id), [original.id, original.id],
                       "retried frames must carry the ORIGINAL batch id, not a fresh one")
        XCTAssertEqual(retried.map(\.index), [2, 3], "…in their original 1-based places")
        XCTAssertEqual(retried.map(\.total), [3, 3], "…still completing a batch of three")

        // The preserved tag must not leak past the attachments that failed
        // out of it: the next send is its own batch under a new id.
        let fourth = try makeTempFile(named: "d.png")
        let fifth = try makeTempFile(named: "e.png")
        await vm.attachFiles([fourth, fifth])
        await vm.send()

        let fresh = fake.mediaSendBatchTags.suffix(2).compactMap { $0 }
        XCTAssertEqual(fresh.count, 2, "a fresh multi-attachment send is tagged as usual")
        XCTAssertNotEqual(fresh.first?.id, original.id, "a new send mints a new batch id")
        XCTAssertEqual(fresh.map(\.index), [1, 2])
        XCTAssertEqual(fresh.map(\.total), [2, 2])
    }

    /// The drops-it half of the retry bug: with only ONE attachment left to
    /// retry, the re-send used to look like a fresh single-attachment send
    /// and went out untagged — leaving the bridge no way to connect the
    /// frame to the batch its sibling had already opened.
    @MainActor
    func test_retry_ofTheLastRemainingAttachment_isNotDemotedToAnUntaggedSend() async throws {
        let first = try makeTempFile(named: "a.png")
        let second = try makeTempFile(named: "b.png")
        let fake = FakeTimelineService()
        fake.failSendsAfter = 1
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([first, second])

        await vm.send()

        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["b.png"],
                       "precondition: b.png failed and came back alone")
        let original = try XCTUnwrap(fake.mediaSendBatchTags.compactMap { $0 }.first)

        fake.failSendsAfter = nil
        await vm.send()

        let retried = try XCTUnwrap(fake.mediaSendBatchTags.last ?? nil,
                                    "the lone retry must still carry its batch tag")
        XCTAssertEqual(retried.id, original.id)
        XCTAssertEqual(retried.index, 2)
        XCTAssertEqual(retried.total, 2)
    }

    /// A single attachment goes untagged — its frame must stay
    /// byte-identical to what an older bridge already understands.
    @MainActor
    func test_send_withOneAttachment_carriesNoBatchTag() async throws {
        let url = try makeTempFile(named: "shot.png")
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])

        await vm.send()

        XCTAssertEqual(fake.mediaSendBatchTags, [nil])
    }

    /// Text with nothing attached still behaves exactly as it always did.
    @MainActor
    func test_send_withTextOnly_stillSendsPlainText() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        vm.input = "just talking"

        await vm.send()

        XCTAssertEqual(fake.sentText, ["just talking"])
        XCTAssertTrue(fake.sentImages.isEmpty)
    }

    /// An empty composer with an empty tray is still a no-op.
    @MainActor
    func test_send_withNothing_doesNothing() async {
        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])

        XCTAssertFalse(vm.canSend)
        await vm.send()

        XCTAssertTrue(fake.sentText.isEmpty)
        XCTAssertTrue(fake.sentFiles.isEmpty)
    }

    @MainActor
    func test_removeAttachment_dropsItFromTheTray() async throws {
        let first = try makeTempFile(named: "keep.png")
        let second = try makeTempFile(named: "drop.png")
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: [])
        await vm.attachFiles([first, second])
        let doomed = try XCTUnwrap(vm.stagedAttachments.last)

        vm.removeAttachment(id: doomed.id)

        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["keep.png"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: doomed.url.path),
            "removing should clean up the staged copy, not leak it into tmp"
        )
    }

    /// A failed send must not silently eat the user's photo — the whole
    /// point of restoring the text (PR #55) applies just as much to the
    /// attachment it was describing.
    @MainActor
    func test_send_whenTheAttachmentFails_keepsItStagedAndRestoresTheText() async throws {
        let url = try makeTempFile(named: "shot.png")
        let fake = FakeTimelineService()
        fake.nextSendError = NSError(domain: "test", code: 1)
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])
        vm.input = "look at this"

        await vm.send()

        XCTAssertNotNil(vm.sendError)
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["shot.png"], "the photo must come back")
        XCTAssertEqual(vm.input, "look at this", "and so must the words that went with it")
    }

    /// The asymmetric half of failure handling: if the caption-bearing
    /// attachment DID send, the text has been delivered. Restoring it would
    /// leave the user looking at words claude already has, and re-sending
    /// would duplicate them.
    @MainActor
    func test_send_whenALaterAttachmentFails_doesNotRestoreTheDeliveredCaption() async throws {
        let first = try makeTempFile(named: "a.png")
        let second = try makeTempFile(named: "b.png")
        let fake = FakeTimelineService()
        fake.failSendsAfter = 1
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([first, second])
        vm.input = "compare these"

        await vm.send()

        XCTAssertEqual(fake.sentImages.map(\.filename), ["a.png"], "only the first should have landed")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["b.png"], "the unsent one stays staged")
        XCTAssertTrue(vm.input.isEmpty, "the caption went out with a.png — don't hand it back")
        XCTAssertNotNil(vm.sendError)
    }

    /// A late failure must not overwrite a message the user has already
    /// started typing (bugbot, PR #55) — the same guard, now reached via the
    /// attachment path.
    ///
    /// The send is held open mid-flight rather than failed twice in a row:
    /// the guard only bites when the failure lands on a composer the user
    /// has since typed into, and a sequential test would just let the second
    /// send succeed and prove nothing.
    @MainActor
    func test_send_failedAttachment_doesNotOverwriteNewTyping() async throws {
        let url = try makeTempFile(named: "shot.png")
        let fake = FakeTimelineService()
        let gate = SendGate()
        fake.sendGate = gate
        fake.nextSendError = NSError(domain: "test", code: 1)
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])
        vm.input = "first message"

        let sending = Task { await vm.send() }
        while await !gate.isStarted() { await Task.yield() }
        // The user gives up waiting and starts the next message.
        vm.input = "second message"
        await gate.open()
        await sending.value

        XCTAssertEqual(vm.input, "second message", "a late failure must not clobber new typing")
        XCTAssertNotNil(vm.sendError, "the failure is still reported via the banner")
    }

    @MainActor
    func test_discardAttachments_emptiesTheTrayAndDeletesTheCopies() async throws {
        let url = try makeTempFile(named: "shot.png")
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: [])
        await vm.attachFiles([url])
        let staged = try XCTUnwrap(vm.stagedAttachments.first)

        vm.discardAttachments()

        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.url.path))
    }

    /// An unreadable URL fails while the user is still looking at the
    /// picker, rather than after they've composed a message around it.
    @MainActor
    func test_attachFiles_unreadableURL_reportsTheErrorAndStagesNothing() async {
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: [])

        await vm.attachFiles([URL(fileURLWithPath: "/nonexistent/nope.png")])

        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertNotNil(vm.sendError)
    }

    // MARK: - Recent-folder completion

    /// A recent-folder store backed by a throwaway UserDefaults suite so
    /// tests never touch `.standard`. Empty unless the test records into it.
    @MainActor
    private func emptyRecentFolders() -> RecentStartFolders {
        let suite = UserDefaults(suiteName: "test.composer.folders.\(UUID().uuidString)")!
        return RecentStartFolders(defaults: suite)
    }

    @MainActor
    func test_recentFolderArgument_uppercaseCommand_stillExtracts() {
        // Folder completion matches /START case-insensitively, so a sent
        // uppercase line must still record the path — one case rule.
        XCTAssertEqual(ComposerViewModel.recentFolderArgument(from: "/START ~/x"), "~/x")
    }

    @MainActor
    func test_recentFolderArgument_extractsPath() {
        XCTAssertEqual(ComposerViewModel.recentFolderArgument(from: "/start ~/x"), "~/x")
    }

    @MainActor
    func test_recentFolderArgument_skipsLeadingFlags() {
        XCTAssertEqual(ComposerViewModel.recentFolderArgument(from: "/start --browser ~/x"), "~/x")
    }

    @MainActor
    func test_recentFolderArgument_workdirAbsolutePath() {
        XCTAssertEqual(ComposerViewModel.recentFolderArgument(from: "/workdir /abs/path"), "/abs/path")
    }

    @MainActor
    func test_recentFolderArgument_flagOnly_isNil() {
        XCTAssertNil(ComposerViewModel.recentFolderArgument(from: "/start --claude"))
    }

    @MainActor
    func test_recentFolderArgument_acceptsBangPrefix() {
        XCTAssertEqual(ComposerViewModel.recentFolderArgument(from: "!start ~/x"), "~/x")
    }

    @MainActor
    func test_recentFolderArgument_plainText_isNil() {
        XCTAssertNil(ComposerViewModel.recentFolderArgument(from: "just a message"))
    }

    @MainActor
    func test_recentFolderArgument_commandWithoutArg_isNil() {
        XCTAssertNil(ComposerViewModel.recentFolderArgument(from: "/start"))
    }

    @MainActor
    func test_send_recordsStartFolder_thenSuggested() async {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/start ~/yearbook-app"
        await vm.send()

        // Typing the command + a matching partial surfaces the recorded folder.
        vm.input = "/start ~/y"
        XCTAssertTrue(vm.showPalette)
        XCTAssertEqual(vm.folderSuggestions, ["~/yearbook-app"])
    }

    @MainActor
    func test_folderSuggestions_emptyPartial_returnsAllRecents() {
        let store = emptyRecentFolders()
        store.record("~/one")
        store.record("~/two")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/workdir "
        XCTAssertTrue(vm.showPalette)
        // Most-recent-first: "~/two" was recorded last.
        XCTAssertEqual(vm.folderSuggestions, ["~/two", "~/one"])
    }

    @MainActor
    func test_folderSuggestions_gatedToStartAndWorkdir() {
        let store = emptyRecentFolders()
        store.record("~/proj")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        // Not a folder command: no suggestions even though a folder is stored.
        vm.input = "/status ~/p"
        XCTAssertTrue(vm.folderSuggestions.isEmpty)
        // A non-flag token before the partial doesn't qualify — the path
        // slot is already filled.
        vm.input = "/start ~/other ~/p"
        XCTAssertTrue(vm.folderSuggestions.isEmpty)
    }

    @MainActor
    func test_folderSuggestions_uppercaseCommand_stillCompletes() {
        // The command palette and the argument resolver both match
        // case-insensitively; the folder gate must agree, or "/START ~"
        // opens the palette with flags but silently zero folders.
        let store = emptyRecentFolders()
        store.record("~/proj")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/START ~"
        XCTAssertEqual(vm.folderSuggestions, ["~/proj"])
    }

    @MainActor
    func test_folderSuggestions_allowedAfterSmartDashedFlag() {
        // iOS smart dashes rewrite "--browser" to "—browser"; the bridge
        // still parses it as a flag, so the folder gate must too.
        let store = emptyRecentFolders()
        store.record("~/proj")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/start \u{2014}browser ~/p"
        XCTAssertEqual(vm.folderSuggestions, ["~/proj"])
    }

    @MainActor
    func test_recentFolderArgument_skipsSmartDashedFlags() {
        // "—browser" (em dash) is a flag the bridge normalizes, not a
        // folder — recording it would poison the recents list.
        XCTAssertEqual(ComposerViewModel.recentFolderArgument(from: "/start \u{2014}browser ~/x"), "~/x")
    }

    @MainActor
    func test_folderSuggestions_allowedAfterFlags() {
        // The bridge's grammar is `/start [flags] [workdir]`, so folder
        // completion must survive flag tokens ahead of the path
        // (2026-08-10 spec: folders become one suggestion source among
        // several, not a special case that flags disable).
        let store = emptyRecentFolders()
        store.record("~/proj")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/start --browser ~/p"
        XCTAssertEqual(vm.folderSuggestions, ["~/proj"])
    }

    // MARK: - Argument suggestions (2026-08-10 spec, phase 1)

    /// Convenience: the `.argument` values currently offered.
    @MainActor
    private func argumentValues(_ vm: ComposerViewModel) -> [String] {
        vm.paletteSuggestions.compactMap {
            if case .argument(let arg) = $0 { return arg.value }
            return nil
        }
    }

    @MainActor
    func test_completedCommand_opensPaletteInArgumentMode() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/restart "
        XCTAssertTrue(vm.showPalette)
        XCTAssertEqual(argumentValues(vm), ["--force", "--browser"])
        XCTAssertEqual(vm.paletteItemCount, 2)
    }

    @MainActor
    func test_paletteSuggestions_argumentsPrecedeFolders() {
        let store = emptyRecentFolders()
        store.record("~/proj")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/start "
        let start = BotCommandCatalog.claudeBridge.first { $0.trigger == "/start" }!
        XCTAssertEqual(vm.paletteSuggestions,
                       start.argSuggestions.map { .argument($0) } + [.folder("~/proj")],
                       "argument rows come first, folders after")
    }

    @MainActor
    func test_selectSuggestion_argument_insertsValueAndSpace_thenOffersRest() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/restart --f"
        vm.selectSuggestion(.argument(ArgSuggestion(value: "--force")))
        XCTAssertEqual(vm.input, "/restart --force ",
                       "the partial token is replaced and a trailing space readies the next argument")
        XCTAssertEqual(argumentValues(vm), ["--browser"],
                       "the palette immediately offers the remaining flag")
        XCTAssertTrue(vm.showPalette)
    }

    @MainActor
    func test_selectSuggestion_lastValue_dismissesPalette() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/switch "
        vm.selectSuggestion(.argument(ArgSuggestion(value: "claude")))
        XCTAssertEqual(vm.input, "/switch claude ")
        XCTAssertFalse(vm.showPalette,
                       "a value fills the single slot, so nothing is left to offer")
    }

    @MainActor
    func test_selectSuggestion_folder_delegatesToFolderPick() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/start ~/y"
        vm.selectSuggestion(.folder("~/yearbook-app"))
        XCTAssertEqual(vm.input, "/start ~/yearbook-app",
                       "folder picks keep the no-trailing-space caret behaviour")
    }

    @MainActor
    func test_confirmPaletteSelection_picksFromUnifiedList() {
        let store = emptyRecentFolders()
        store.record("~/proj")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/start "
        // Walk the highlight to the folder row: 3 argument rows precede it.
        vm.paletteMoveDown()
        vm.paletteMoveDown()
        vm.paletteMoveDown()
        vm.paletteMoveDown()
        XCTAssertTrue(vm.confirmPaletteSelection())
        XCTAssertEqual(vm.input, "/start ~/proj")
    }

    // MARK: - Session-derived argument suggestions (2026-08-10 spec, phase 2)

    /// Stands in for the `ChatViewModel` the composer reads its session
    /// status from — the pair is created together by the chat-list VM cache,
    /// and the composer holds a closure back to the chat half.
    @MainActor
    private final class StatusHolder {
        var status: SessionStatus?
        private(set) var reads = 0
        init(_ status: SessionStatus?) { self.status = status }
        func read() -> SessionStatus? {
            reads += 1
            return status
        }
    }

    @MainActor
    private func composer(status: StatusHolder) -> ComposerViewModel {
        ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                          commands: BotCommandCatalog.claudeBridge,
                          recentFolders: emptyRecentFolders(),
                          sessionStatus: { status.read() })
    }

    /// The status is read only once a session-derived command has matched.
    /// Reading it eagerly would have the composer observe the chat view
    /// model's `sessionStatus` on every keystroke, so every status frame
    /// would invalidate the composer's body while the user types ordinary
    /// prose.
    @MainActor
    func test_ordinaryTypingDoesNotReadTheSessionStatus() {
        let holder = StatusHolder(SessionStatus(
            modelOptions: [SessionStatus.Option(value: "opus", label: "Opus")]))
        let vm = composer(status: holder)

        vm.input = "just chatting about /model"
        _ = vm.showPalette
        vm.input = "/restart --f"
        _ = vm.showPalette
        XCTAssertEqual(holder.reads, 0,
                       "neither prose nor a statically-catalogued command needs the session")

        vm.input = "/model "
        _ = vm.showPalette
        XCTAssertGreaterThan(holder.reads, 0, "a session-derived command does read it")
    }

    @MainActor
    func test_modelAndEffort_offerTheSessionsLists() {
        let holder = StatusHolder(SessionStatus(
            modelOptions: [SessionStatus.Option(value: "opus", label: "Opus"),
                           SessionStatus.Option(value: "sonnet", label: "Sonnet")],
            effortLevels: [SessionStatus.Option(value: "high", label: "High")]))
        let vm = composer(status: holder)

        vm.input = "/model "
        XCTAssertTrue(vm.showPalette)
        XCTAssertEqual(argumentValues(vm), ["opus", "sonnet"])
        XCTAssertEqual(vm.paletteItemCount, 2)

        vm.input = "/effort "
        XCTAssertEqual(argumentValues(vm), ["high"])
    }

    /// The composer reads the status live rather than holding a copy, so a
    /// later status frame (a bridge that learns a new model) reaches the
    /// palette without anything having to push it across.
    @MainActor
    func test_laterStatusFrame_reachesThePalette() {
        let holder = StatusHolder(nil)
        let vm = composer(status: holder)
        vm.input = "/model "
        XCTAssertEqual(argumentValues(vm), [], "nothing offered before the bridge speaks")

        holder.status = SessionStatus(modelOptions: [SessionStatus.Option(value: "opus", label: "Opus")])
        XCTAssertEqual(argumentValues(vm), ["opus"])
    }

    @MainActor
    func test_selectingASessionValue_insertsItAndDismisses() {
        let holder = StatusHolder(SessionStatus(
            modelOptions: [SessionStatus.Option(value: "opus", label: "Opus")]))
        let vm = composer(status: holder)
        vm.input = "/model op"
        vm.selectSuggestion(.argument(ArgSuggestion(value: "opus", label: "Opus")))
        XCTAssertEqual(vm.input, "/model opus ",
                       "the partial is replaced and a trailing space follows, as for static values")
        XCTAssertFalse(vm.showPalette, "a value fills the single slot — nothing left to offer")
    }

    /// Keyboard selection walks the same rows as a tap.
    @MainActor
    func test_confirmPaletteSelection_picksASessionValue() {
        let holder = StatusHolder(SessionStatus(
            modelOptions: [SessionStatus.Option(value: "opus", label: "Opus"),
                           SessionStatus.Option(value: "sonnet", label: "Sonnet")]))
        let vm = composer(status: holder)
        vm.input = "/model "
        vm.paletteMoveDown()
        vm.paletteMoveDown()
        XCTAssertTrue(vm.confirmPaletteSelection())
        XCTAssertEqual(vm.input, "/model sonnet ")
    }

    /// A composer built without a status source (every test fixture, and any
    /// surface that has no chat view model) behaves exactly as it did before
    /// this feature — an older bridge lands in the same place.
    @MainActor
    func test_withoutASessionStatusSource_modelOffersNothing() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/model "
        XCTAssertEqual(argumentValues(vm), [])
        XCTAssertFalse(vm.showPalette)
    }

    @MainActor
    func test_selectFolder_replacesTrailingPartial_noTrailingSpace() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/start ~/y"
        vm.selectFolder("~/yearbook-app")
        XCTAssertEqual(vm.input, "/start ~/yearbook-app")
    }

    @MainActor
    func test_selectFolder_emptyPartial_appendsPath() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/workdir "
        vm.selectFolder("/srv/app")
        XCTAssertEqual(vm.input, "/workdir /srv/app")
    }

    @MainActor
    func test_selectFolder_dismissesPalette() {
        let store = emptyRecentFolders()
        store.record("~/yearbook-app")
        store.record("~/yearbook-api")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/start ~/y"
        XCTAssertFalse(vm.folderSuggestions.isEmpty)

        // Picking a folder must close the palette even though the completed
        // path still prefix-matches sibling recents (~/yearbook-api).
        vm.selectFolder("~/yearbook-app")
        XCTAssertTrue(vm.folderSuggestions.isEmpty)
        XCTAssertFalse(vm.showPalette)

        // ...and editing again re-enables suggestions.
        vm.input = "/start ~/year"
        XCTAssertFalse(vm.folderSuggestions.isEmpty)
    }

    @MainActor
    func test_folderSuppression_clearsOnSendAndOnEdit() async {
        let store = emptyRecentFolders()
        store.record("~/yearbook-app")
        store.record("~/yearbook-app-v2")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        vm.input = "/start ~/year"
        vm.selectFolder("~/yearbook-app")
        XCTAssertTrue(vm.folderSuggestions.isEmpty, "post-pick suppression hides the longer sibling")
        await vm.send()

        // Re-typing the identical line after a send must complete again —
        // the suppression must not outlive the send.
        vm.input = "/start ~/yearbook-app"
        vm.handleInputChange()
        XCTAssertEqual(vm.folderSuggestions, ["~/yearbook-app-v2"])

        // And a differing edit lifts suppression too.
        vm.selectFolder("~/yearbook-app-v2")
        XCTAssertTrue(vm.folderSuggestions.isEmpty)
        vm.input = "/start ~/yearbook-app"
        vm.handleInputChange()
        XCTAssertFalse(vm.folderSuggestions.isEmpty)
    }

    @MainActor
    func test_folderSuggestions_omitFullyTypedPath() {
        let store = emptyRecentFolders()
        store.record("~/yearbook-app")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        // A hand-typed complete path offers nothing to complete — the
        // palette must not linger over the composer.
        vm.input = "/start ~/YEARBOOK-APP"
        XCTAssertTrue(vm.folderSuggestions.isEmpty)
        XCTAssertFalse(vm.showPalette)
    }

    // MARK: - Palette keyboard navigation

    @MainActor
    func test_paletteSelection_startsNilAndMovesWithinBounds() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/"
        XCTAssertNil(vm.paletteSelection, "no row is highlighted until an arrow key moves")
        let count = vm.paletteItemCount
        XCTAssertGreaterThan(count, 1)

        // First Down highlights the first row; further Downs clamp at the end.
        vm.paletteMoveDown()
        XCTAssertEqual(vm.paletteSelection, 0)
        for _ in 0..<(count + 3) { vm.paletteMoveDown() }
        XCTAssertEqual(vm.paletteSelection, count - 1, "Down clamps at the last row")

        // Up steps back and clamps at the first row.
        for _ in 0..<(count + 3) { vm.paletteMoveUp() }
        XCTAssertEqual(vm.paletteSelection, 0, "Up clamps at the first row")
    }

    @MainActor
    func test_paletteMoveUp_fromNoSelection_startsAtLastRow() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/"
        vm.paletteMoveUp()
        XCTAssertEqual(vm.paletteSelection, vm.paletteItemCount - 1)
    }

    @MainActor
    func test_confirmPaletteSelection_picksHighlightedCommand() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/sta"
        let expected = vm.filteredCommands[0].trigger
        vm.paletteMoveDown()
        XCTAssertTrue(vm.confirmPaletteSelection(), "Return picks the highlighted row")
        XCTAssertEqual(vm.input, expected + " ")
        XCTAssertNil(vm.paletteSelection, "the highlight is consumed by the pick")
    }

    @MainActor
    func test_confirmPaletteSelection_withoutHighlight_fallsThroughToSend() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/start"
        XCTAssertFalse(vm.confirmPaletteSelection(),
                       "no highlight means Return should send the typed input")
        XCTAssertEqual(vm.input, "/start", "input is untouched")
    }

    @MainActor
    func test_confirmPaletteSelection_picksHighlightedFolder() {
        let store = emptyRecentFolders()
        store.record("~/one")
        store.record("~/two")
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: store)
        // "~" filters the palette to folder rows alone (no flag matches),
        // most-recent-first: row 0 is "~/two", row 1 is "~/one".
        vm.input = "/start ~"
        vm.paletteMoveDown()
        vm.paletteMoveDown()
        XCTAssertTrue(vm.confirmPaletteSelection())
        XCTAssertEqual(vm.input, "/start ~/one")
        XCTAssertNil(vm.paletteSelection)
    }

    @MainActor
    func test_paletteSelection_resetsOnUserEdit() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/"
        vm.paletteMoveDown()
        vm.paletteMoveDown()
        XCTAssertEqual(vm.paletteSelection, 1)

        // Typing narrows the row list — a stale index would point at the
        // wrong row, so any edit clears the highlight.
        vm.input = "/sta"
        vm.handleInputChange()
        XCTAssertNil(vm.paletteSelection)
    }

    @MainActor
    func test_paletteMove_noOpDuringHistoryWalk() async {
        // Bugbot (PR #41): a recalled single-token slash line ("/start")
        // pops the palette open; the arrows must keep walking history,
        // not get captured by the palette highlight.
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/start"
        await vm.send()
        vm.recallOlder()
        XCTAssertTrue(vm.isNavigatingHistory)
        XCTAssertEqual(vm.input, "/start")
        XCTAssertTrue(vm.showPalette, "the recalled slash token re-opens the palette")

        vm.paletteMoveDown()
        vm.paletteMoveUp()
        XCTAssertNil(vm.paletteSelection,
                     "palette highlight must not move while a history walk is active")
    }

    @MainActor
    func test_paletteMove_noOpWhenPaletteHidden() {
        let vm = ComposerViewModel(roomID: "!r", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "plain message"
        vm.paletteMoveDown()
        XCTAssertNil(vm.paletteSelection)
        XCTAssertFalse(vm.confirmPaletteSelection())
    }
}
