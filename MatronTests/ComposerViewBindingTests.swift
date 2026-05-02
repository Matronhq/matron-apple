import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Mirrors `MatronShared/Tests/ViewModelTests/FakeTimelineService` — the
/// same plain-final-class pattern is used across the repo's test fakes.
final class FakeTimelineForComposer: TimelineService, @unchecked Sendable {
    var sentText: [String] = []

    func items() -> AsyncStream<[TimelineItem]> {
        AsyncStream { $0.finish() }
    }
    func sendText(_ body: String) async throws { sentText.append(body) }
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {}
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
