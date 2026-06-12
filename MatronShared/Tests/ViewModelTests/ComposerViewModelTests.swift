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
        if let err = nextSendError { nextSendError = nil; throw err }
        sentText.append(body)
        sentInReplyTo.append(inReplyTo)
    }
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {
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
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
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
        let vm = ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineService(), commands: BotCommandCatalog.claudeBridge)
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
}
