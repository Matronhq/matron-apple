import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Local fake mirrors `MatronShared/Tests/ViewModelTests/FakeTimelineService` —
/// the same plain-final-class pattern used across the repo's test fakes
/// (see also `FakeTimelineForComposer` in `ComposerViewBindingTests.swift`).
private final class FakeTimelineForChat: TimelineService, @unchecked Sendable {
    var snapshotsToEmit: [[TimelineItem]] = []
    var paginateCalls: Int = 0
    var markReadCalls: Int = 0

    func items() -> AsyncStream<[TimelineItem]> {
        let snapshots = snapshotsToEmit
        return AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
    func sendText(_ body: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {}
    func paginateBackward(requestSize: UInt16) async throws { paginateCalls += 1 }
    func markAsRead() async throws { markReadCalls += 1 }
}

/// No-op MediaService for tests that don't exercise image resolution. The
/// view-model tests in `MatronShared/Tests/ViewModelTests/` cover the
/// `MediaService → resolvedImages` path; the view-binding tests here only
/// need the protocol satisfied to construct a `ChatViewModel`.
private final class FakeMediaForChat: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

final class ChatViewBindingTests: XCTestCase {

    @MainActor
    func test_view_observesViewModelItems_afterStreamYield() async throws {
        let fake = FakeTimelineForChat()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        fake.snapshotsToEmit = [[item]]
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: fake, commands: [])

        // Instantiating the view exercises the @State + binding wiring at
        // compile time. The view itself isn't rendered in this unit test.
        let _ = ChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Test Room",
            onShowBotProfile: {}
        )

        // Drive the same start() the view's `.task` would. This proves the
        // view-model contract the view depends on.
        let task = chatVM.start()
        await task.value

        XCTAssertEqual(chatVM.items.count, 1)
        XCTAssertEqual(chatVM.items.first?.id, "1")
    }

    @MainActor
    func test_view_initialises_withProvidedTitle_andCallback() {
        let fake = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: fake, commands: [])

        var profileTaps = 0
        let view = ChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Demo",
            onShowBotProfile: { profileTaps += 1 }
        )

        XCTAssertEqual(view.chatTitle, "Demo")
        // Invoke the closure directly to verify the binding is plumbed through.
        view.onShowBotProfile()
        XCTAssertEqual(profileTaps, 1)
    }
}
