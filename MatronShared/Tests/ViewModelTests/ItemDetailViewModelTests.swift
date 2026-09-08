import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class ItemDetailViewModelTests: XCTestCase {
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?; var commentsCont: AsyncStream<[TrackerComment]>.Continuation?
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { self.commentsCont = $0 } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { $0.yield([]) } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        var comments: [(String, String, [TrackerAttachment])] = []; var refetched: [String] = []
        func refresh(scope: ItemsScope) async {}
        func refreshItem(id: String) async { refetched.append(id) }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async { comments.append((itemID, body, attachments)) }
        func enqueueCreate(localID: String, _ new: NewItem) async {}
        func supportedStream() -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }
    private final class API: ItemsProviding, @unchecked Sendable {
        var uploads: [String] = []; var closes: [(ItemResolution, String?)] = []; var reopens = 0
        func uploadMedia(_ data: Data, contentType: String) async throws -> String { uploads.append(contentType); return "blob-\(uploads.count)" }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { closes.append((resolution, comment)); return TrackerItem(id: id, num: 1, kind: .task, state: .closed, title: "", originConvoID: "c1") }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { reopens += 1; return TrackerItem(id: id, num: 1, kind: .task, title: "", originConvoID: "c1") }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }

    func testSubmitUploadsThenEnqueuesAndClearsDraft() async {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = " use A "
        await vm.submitComment(attachments: [(Data([1]), "s.png", "image/png")])
        XCTAssertEqual(api.uploads, ["image/png"])
        XCTAssertEqual(sync.comments.first?.1, "use A")
        XCTAssertEqual(sync.comments.first?.2.first?.blobRef, "blob-1")
        XCTAssertEqual(vm.draft, "")
        await vm.submitComment(attachments: [])
        XCTAssertEqual(sync.comments.count, 1, "empty draft + no attachments is a no-op")
    }

    func testVoiceNoteIsAnAudioAttachmentComment() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data([0, 1, 2]).write(to: url)
        await vm.sendVoiceNote(url: url)
        XCTAssertEqual(api.uploads, ["audio/mp4"])
        XCTAssertEqual(sync.comments.first?.2.first?.mime, "audio/mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCloseReopenReverseAndResolutions() async {
        let api = API(); let sync = Sync(); let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: api, sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .decision, title: "D", originConvoID: "c1"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.availableResolutions, [.decided, .reversed, .cancelled])
        await vm.reverse()
        XCTAssertEqual(api.closes.first?.0, .reversed)
        await vm.reopen()
        XCTAssertEqual(api.reopens, 1)
        XCTAssertEqual(sync.refetched, ["it_1", "it_1"])
    }
}
