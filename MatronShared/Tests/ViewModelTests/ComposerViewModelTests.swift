import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Local mirror of `Tests/ChatTests/FakeTimelineService`. Kept in this file
/// because `ViewModelTests` doesn't depend on `ChatTests` — the same plain
/// final-class pattern is used for all in-test fakes (see `FakeChatService`,
/// `FakeAuthForVM`).
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
    var sentImages: [(filename: String, mime: String, sizeBytes: Int)] = []
    var sentFiles: [(filename: String, mime: String, sizeBytes: Int)] = []
    var paginateCalls: Int = 0
    var markReadCalls: Int = 0
    /// When set, the next `sendText`/`sendImage`/`sendFile` call throws this error.
    var nextSendError: Error?
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

    func sendText(_ body: String, inReplyTo: String?) async throws {
        if sendDelayNanos > 0 { try? await Task.sleep(nanoseconds: sendDelayNanos) }
        if let err = nextSendError { nextSendError = nil; throw err }
        sentText.append(body)
        sentInReplyTo.append(inReplyTo)
    }
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {
        if sendDelayNanos > 0 { try? await Task.sleep(nanoseconds: sendDelayNanos) }
        if let err = nextSendError { nextSendError = nil; throw err }
        sentButtonResponses.append((selectedValues, promptEventID))
    }
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        if let err = nextSendError { nextSendError = nil; throw err }
        sentImages.append((filename, mimeType, data.count))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        if let err = nextSendError { nextSendError = nil; throw err }
        sentFiles.append((filename, mimeType, data.count))
    }
    func paginateBackward(requestSize: UInt16) async throws -> Bool { paginateCalls += 1; return false }
    func markAsRead() async throws { markReadCalls += 1 }

    private let statusPair = AsyncStream<SessionStatusUpdate>.makeStream()
    var statusContinuation: AsyncStream<SessionStatusUpdate>.Continuation { statusPair.continuation }
    func sessionStatus() -> AsyncStream<SessionStatusUpdate> { statusPair.stream }
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
        // to "/start " (trailing space). The palette's old check trimmed
        // whitespace, collapsing the input back to a single token starting
        // with `/`, which re-opened the palette immediately.
        //
        // With recent-folder completion, "/start " enters folder-suggestion
        // mode, so an *empty* store is injected to pin the "no suggestions →
        // palette stays closed" outcome deterministically.
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        let cmd = BotCommand(trigger: "/start", summary: "x", argHint: "[workdir]")
        vm.selectCommand(cmd)
        XCTAssertEqual(vm.input, "/start ")
        XCTAssertFalse(vm.showPalette,
                       "palette should stay closed once a command has been chosen and the trailing space is in place")
    }

    @MainActor
    func test_palette_isHiddenForCommandWithTrailingSpace() {
        // Tightened version of the regression above: typing the command
        // followed by a space (without the user even hitting an argument)
        // should hide the palette so it doesn't cover the next character.
        // An empty recent-folder store keeps folder-suggestion mode from
        // opening the palette here (folder completion has its own tests).
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(),
                                   commands: BotCommandCatalog.claudeBridge,
                                   recentFolders: emptyRecentFolders())
        vm.input = "/start "
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

    @MainActor
    func test_attachFiles_readsURLBytesAndDispatchesToTimeline() async {
        // Round-3 bugbot finding #4 dropped the security-scoped wrap
        // from `attachFiles(_:)` itself. Callers (iOS `stageAndAttach`,
        // iOS `PhotosPicker` temp-staging, Mac `ComposerDropDelegate`)
        // are responsible for ensuring the URLs they pass don't need a
        // security-scoped wrap (or have already opened one and read the
        // bytes into a temp URL). The Mac sandbox grants drop URLs
        // transparent read access, and both iOS staging paths convert
        // to a tmp URL before reaching `attachFiles`.
        //
        // This test pins the contract: given a non-scoped URL with real
        // bytes on disk, `attachFiles` reads them and dispatches to the
        // timeline as the right kind based on MIME.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-scope-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let url = tmpDir.appendingPathComponent("hello.txt")
        try? Data("hi".utf8).write(to: url)

        let fake = FakeTimelineService()
        let vm = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        await vm.attachFiles([url])

        // Outcome: the file was read and dispatched to `sendFile`
        // (text/plain isn't an image MIME). A no-op (zero bytes, no
        // dispatch) would mean the read failed silently.
        XCTAssertEqual(fake.sentFiles.count, 1, "attachFiles should dispatch one file")
        XCTAssertEqual(fake.sentFiles.first?.sizeBytes, 2, "the 2-byte payload should reach the timeline intact")
        XCTAssertNil(vm.sendError, "non-scoped tmp URL should round-trip cleanly")
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
        // A second token before the partial (flag) doesn't qualify either.
        vm.input = "/start --browser ~/p"
        XCTAssertTrue(vm.folderSuggestions.isEmpty)
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
        vm.input = "/start "
        // Most-recent-first: row 0 is "~/two", row 1 is "~/one".
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
