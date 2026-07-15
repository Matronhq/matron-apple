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

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        let snapshots = snapshotsToEmit
        return AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { paginateCalls += 1; return false }
    func markAsRead() async throws { markReadCalls += 1 }
}

/// No-op MediaService for tests that don't exercise image resolution. The
/// view-model tests in `MatronShared/Tests/ViewModelTests/` cover the
/// `MediaService → resolvedImages` path; the view-binding tests here only
/// need the protocol satisfied to construct a `ChatViewModel`.
private final class FakeMediaForChat: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

/// Minimal ChatService so the view-binding tests can construct the
/// `SubChatStripViewModel` that `ChatView` now requires. The strip's
/// behavior is covered in `SubChatStripViewModelTests`; here the stream
/// just finishes immediately.
private final class FakeChatForStrip: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
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
        let composerVM = ComposerViewModel(roomID: "!r:s", timeline: fake, commands: [])

        // Instantiating the view exercises the @State + binding wiring at
        // compile time. The view itself isn't rendered in this unit test.
        let _ = ChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            stripViewModel: SubChatStripViewModel(chat: FakeChatForStrip(), parentConvoID: "!r:s"),
            chatTitle: "Test Room"
        )

        // Drive the same start() the view's `.task` would. This proves the
        // view-model contract the view depends on.
        let task = await chatVM.start()
        await task.value

        XCTAssertEqual(chatVM.items.count, 1)
        XCTAssertEqual(chatVM.items.first?.id, "1")
    }

    @MainActor
    func test_view_initialises_withProvidedTitle() {
        let fake = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(roomID: "!r:s", timeline: fake, commands: [])

        let view = ChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            stripViewModel: SubChatStripViewModel(chat: FakeChatForStrip(), parentConvoID: "!r:s"),
            chatTitle: "Demo"
        )

        XCTAssertEqual(view.chatTitle, "Demo")
    }

    @MainActor
    func test_eventSourceSheet_compiles_andRendersDTOJSON() {
        // Task 16: long-press "View source" presents an `EventSourceSheet`
        // whose body is `item.prettyJSON()`. Constructing the sheet here
        // exercises the binding wiring; the underlying JSON shape is
        // verified at the SPM level in `TimelineItemTests`.
        let item = TimelineItem(
            id: "$evt:1",
            sender: "@bot:s",
            timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: false
        )
        let sheet = EventSourceSheet(item: item)
        XCTAssertEqual(sheet.item.id, "$evt:1")
        // The sheet renders `item.prettyJSON()` — keep this assertion in
        // sync with the SPM tests so a refactor of either side trips here.
        XCTAssertTrue(item.prettyJSON().contains("$evt:1"))
    }

    @MainActor
    func test_lastItemID_changesAcrossSnapshots_evenWhenCountIsConstant() async throws {
        // Round-3 bugbot finding #5: `ChatView`'s scroll-to-bottom keys on
        // `viewModel.items.last?.id`, not `items.count`. The count-keyed
        // version missed two cases:
        //   (a) `.set` diff swapping a local-echo id for a remote-event id
        //       (count constant; last id moves)
        //   (b) a remove + add in the same diff batch (count constant;
        //       last id moves)
        // Without rendering the view we can't exercise `.onChange`
        // directly, but we can pin the underlying `last?.id` change that
        // the modifier observes. If a future regression replaces the
        // `last?.id` key with `count` again, this test stays green —
        // that's why the modifier-key choice is also documented inline
        // in `ChatView.swift`. The value of this test is asserting that
        // `ChatViewModel.items.last?.id` does in fact differ between two
        // same-count snapshots; if `items` were ever de-duped to ignore
        // tail mutations, the scroll modifier would silently break.
        let fake = FakeTimelineForChat()
        let local = TimelineItem(
            id: "local-echo", sender: "@me:s", timestamp: .now,
            kind: .text(body: "hello", formattedHTML: nil), isOwn: true
        )
        let remote = TimelineItem(
            id: "$event:s", sender: "@me:s", timestamp: .now,
            kind: .text(body: "hello", formattedHTML: nil), isOwn: true
        )
        // Two snapshots of equal length, but the tail item id changes —
        // this is the exact diff shape that the count-keyed onChange
        // missed. Both snapshots are emitted by the fake stream in
        // order; awaiting the observation Task drains them.
        fake.snapshotsToEmit = [[local], [remote]]
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaForChat())

        let task = await chatVM.start()
        await task.value

        XCTAssertEqual(chatVM.items.count, 1, "tail mutation kept count constant")
        XCTAssertEqual(chatVM.items.last?.id, "$event:s",
                       "last item id must reflect the latest snapshot — the value the scroll modifier keys on")
    }

}
