import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Mirrors `MatronShared/Tests/ViewModelTests/FakeTimelineService` — the
/// same plain-final-class pattern is used across the repo's test fakes.
final class FakeTimelineForComposer: TimelineService, @unchecked Sendable {
    var sentText: [String] = []
    /// Each `sendImage` / `sendFile` invocation records `(filename, mimeType)`.
    /// Used by `test_stagePhotoData_*` to confirm whether `attachFiles(_:)`
    /// was reached: a successful write should result in a `sendImage` /
    /// `sendFile` record; a failed write should leave this empty.
    var sentAttachments: [(filename: String, mimeType: String)] = []

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String) async throws { sentText.append(body) }
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        sentAttachments.append((filename, mimeType))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        sentAttachments.append((filename, mimeType))
    }
    func paginateBackward(requestSize: UInt16) async throws {}
    func markAsRead() async throws {}
}

final class ComposerViewBindingTests: XCTestCase {

    @MainActor
    func test_view_observesViewModelInput_andSendsThroughTimeline() async throws {
        let fake = FakeTimelineForComposer()
        let vm = ComposerViewModel(timeline: fake, commands: BotCommandCatalog.claudeBridge)

        // Instantiating the view exercises the @State + binding wiring at
        // compile time; the view itself isn't rendered in this unit test.
        let _ = ComposerView(viewModel: vm)

        vm.input = "hello"
        await vm.send()

        XCTAssertEqual(fake.sentText, ["hello"])
        XCTAssertEqual(vm.input, "")
    }

    @MainActor
    func test_view_initialisesWithProvidedCommands_forPalette() {
        let fake = FakeTimelineForComposer()
        let vm = ComposerViewModel(timeline: fake, commands: BotCommandCatalog.claudeBridge)
        let _ = ComposerView(viewModel: vm)

        vm.input = "/sta"
        XCTAssertTrue(vm.showPalette)
        XCTAssertTrue(vm.filteredCommands.contains { $0.trigger == "/start" })
    }

    @MainActor
    func test_photoTempURL_producesDistinctURLs_forSameExtension() {
        // Round 2 bugbot finding #4: the photo path used a fixed
        // `"photo.\(ext)"` filename. Two photos picked in quick
        // succession shared the same URL, so the second `data.write(to:)`
        // clobbered the first file before `attachFiles(_:)` had finished
        // reading it. `photoTempURL(ext:)` now embeds a `UUID` so each
        // call is unique.
        let a = ComposerView.photoTempURL(ext: "heic")
        let b = ComposerView.photoTempURL(ext: "heic")
        XCTAssertNotEqual(a, b, "two photo selections must land at distinct temp URLs")
        XCTAssertTrue(a.lastPathComponent.hasSuffix(".heic"))
        XCTAssertTrue(b.lastPathComponent.hasSuffix(".heic"))
        // Sanity: still in the temp dir.
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(a.path.hasPrefix(tmp))
    }

    @MainActor
    func test_stagedTempURL_producesDistinctPaths_forSameLastPathComponent() {
        // Round 3 bugbot finding #1: `stageAndAttach` wrote each picked
        // file to `temporaryDirectory/<url.lastPathComponent>`. Two source
        // files in different parent dirs but with the same filename (e.g.
        // both named `report.pdf`) wrote to the same temp path — the
        // second `data.write(to:)` clobbered the first before
        // `attachFiles(_:)` had finished reading it. `stagedTempURL(for:)`
        // now embeds a `UUID` per call so each staging lands at its own
        // path. Mirrors `photoTempURL(ext:)` (round-2 fix #4).
        let dirA = URL(fileURLWithPath: "/Users/example/folderA")
            .appendingPathComponent("report.pdf")
        let dirB = URL(fileURLWithPath: "/Users/example/folderB")
            .appendingPathComponent("report.pdf")
        let stagedA = ComposerView.stagedTempURL(for: dirA)
        let stagedB = ComposerView.stagedTempURL(for: dirB)
        XCTAssertNotEqual(stagedA, stagedB,
                          "two source files with the same lastPathComponent must stage to distinct temp URLs")
        XCTAssertTrue(stagedA.lastPathComponent.hasSuffix("report.pdf"),
                      "preserves the original filename suffix so MIME inference still works")
        XCTAssertTrue(stagedB.lastPathComponent.hasSuffix("report.pdf"))
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(stagedA.path.hasPrefix(tmp))
    }

    @MainActor
    func test_stagePhotoData_failedWrite_surfacesViaReportAttachmentError_andSkipsAttach() async {
        // Round 5 bugbot finding #1: the photo `onChange` previously did
        // `try? data.write(to: tmp)` and unconditionally called
        // `attachFiles([tmp])`. If the disk write failed, `attachFiles`
        // then `Data(contentsOf:)`-failed with a misleading "No such
        // file" error instead of the real cause (full disk, quota, sandbox
        // denial). `stagePhotoData(_:to:viewModel:)` now uses do/catch:
        // surfaces the write error via `reportAttachmentError(_:)` and
        // skips the doomed `attachFiles` call entirely.
        let fake = FakeTimelineForComposer()
        let vm = ComposerViewModel(timeline: fake, commands: [])
        XCTAssertNil(vm.sendError)

        // Path inside a non-existent parent dir → write throws
        // NSCocoaErrorDomain. UUID keeps this hermetic across re-runs.
        let nonExistent = URL(fileURLWithPath: "/var/folders/__matron_does_not_exist_\(UUID().uuidString)__/photo.jpg")
        let data = Data("doesn't matter".utf8)

        await ComposerView.stagePhotoData(data, to: nonExistent, viewModel: vm)

        XCTAssertNotNil(vm.sendError, "failed write must surface via reportAttachmentError(_:)")
        XCTAssertTrue(fake.sentAttachments.isEmpty,
                      "attachFiles must be skipped when the write failed — otherwise the user sees a confusing 'No such file' error from Data(contentsOf:) instead of the real write failure")
        // The temp file was never created — confirm no stray side effect.
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonExistent.path))
    }

    @MainActor
    func test_stagePhotoData_successfulWrite_proceedsToAttachFiles_andLeavesNoError() async {
        // Companion to the failure-branch test: a successful write must
        // hand the resulting URL to `attachFiles(_:)`, surface no error,
        // and produce a `sendFile` invocation on the timeline. Together
        // these two tests pin the do/catch split that fixes the round-5
        // finding without regressing the happy path.
        let fake = FakeTimelineForComposer()
        let vm = ComposerViewModel(timeline: fake, commands: [])

        // Use a `.txt` extension so `attachFiles` routes to `sendFile` (no
        // image-specific MIME setup needed). UUID keeps the path unique.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-stage-photo-\(UUID().uuidString).txt")
        let data = Data("hello".utf8)

        await ComposerView.stagePhotoData(data, to: tmp, viewModel: vm)

        XCTAssertNil(vm.sendError, "successful write must not surface an attachment error")
        XCTAssertEqual(fake.sentAttachments.count, 1,
                       "successful write must reach attachFiles → sendFile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
        // Cleanup so the temp dir doesn't accumulate across re-runs.
        try? FileManager.default.removeItem(at: tmp)
    }

    @MainActor
    func test_isSendable_matchesSendBehaviour_forWhitespaceOnly() async {
        // Regression for bugbot finding #3. Previously the disable
        // predicate was `viewModel.input.isEmpty`, which lit up the send
        // button for "   " — but `send()` trims first and no-ops, leaving
        // the user with an active button that does nothing. The view's
        // `isSendable` must mirror the model's trim.
        let fake = FakeTimelineForComposer()
        let vm = ComposerViewModel(timeline: fake, commands: [])
        let view = ComposerView(viewModel: vm)

        vm.input = ""
        XCTAssertFalse(view.isSendable)

        vm.input = "   \t\n   "
        XCTAssertFalse(view.isSendable, "whitespace-only input must not enable the send button")

        vm.input = "  hi  "
        XCTAssertTrue(view.isSendable, "non-whitespace content (after trim) must enable the send button")

        // And the model agrees: send() with whitespace-only is a no-op.
        vm.input = "   "
        await vm.send()
        XCTAssertTrue(fake.sentText.isEmpty, "send() must no-op for whitespace-only input")
    }
}
