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
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        var comments: [(String, String, [TrackerAttachment])] = []; var refetched: [String] = []
        func refresh(scope: ItemsScope) async {}
        func refreshItem(id: String) async { refetched.append(id) }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async { comments.append((itemID, body, attachments)) }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }
    private final class API: ItemsProviding, @unchecked Sendable {
        var uploads: [String] = []; var closes: [(ItemResolution, String?)] = []; var reopens = 0
        var failUpload = false
        func uploadMedia(_ data: Data, contentType: String) async throws -> String {
            if failUpload { throw JournalAPIError.transport("upload failed") }
            uploads.append(contentType); return "blob-\(uploads.count)"
        }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { closes.append((resolution, comment)); return TrackerItem(id: id, num: 1, kind: .task, state: .closed, title: "", originConvoID: "c1") }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { reopens += 1; return TrackerItem(id: id, num: 1, kind: .task, title: "", originConvoID: "c1") }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }

    func testStartFlipsHasLoadedThreadOnceTheOpeningRefetchCompletes() async throws {
        let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: sync)
        XCTAssertFalse(vm.hasLoadedThread)
        vm.start()
        try await waitUntil { vm.hasLoadedThread }
        XCTAssertEqual(sync.refetched, ["it_1"])
        // Restarting re-arms the guard until the new refetch lands.
        vm.stop()
        vm.start()
        try await waitUntil { sync.refetched.count == 2 && vm.hasLoadedThread }
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

    func testCloseReopenReverseAndResolutions() async throws {
        let api = API(); let sync = Sync(); let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: api, sync: sync)
        vm.start()
        // Opening the detail sheet must itself trigger a refetch (that's
        // the only path comments reach the local cache) — poll for it
        // instead of sleeping blindly, since it races the store streams'
        // subscription.
        try await waitUntil { sync.refetched == ["it_1"] }
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .decision, title: "D", originConvoID: "c1"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.availableResolutions, [.decided, .reversed, .cancelled])
        await vm.reverse()
        XCTAssertEqual(api.closes.first?.0, .reversed)
        await vm.reopen()
        XCTAssertEqual(api.reopens, 1)
        XCTAssertEqual(sync.refetched, ["it_1", "it_1", "it_1"])
    }

    func testSubmitUploadFailureSetsErrorAndDoesNotEnqueue() async {
        let api = API(); let sync = Sync()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "keep me"
        await vm.submitComment(attachments: [(Data([1]), "s.png", "image/png")])
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.draft, "keep me")
        XCTAssertTrue(sync.comments.isEmpty)
    }

    /// Fix wave, item B: attaching a file/photo must not post whatever's
    /// sitting half-written in `draft`, and must not clear it.
    func testSubmitAttachmentsLeavesDraftIntactAndEnqueuesEmptyBody() async {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "still composing this"
        let ok = await vm.submitAttachments([(Data([1]), "s.png", "image/png")])
        XCTAssertTrue(ok)
        XCTAssertEqual(api.uploads, ["image/png"])
        XCTAssertEqual(sync.comments.first?.1, "", "attachment-only comment has an empty body, not the draft text")
        XCTAssertEqual(sync.comments.first?.2.first?.blobRef, "blob-1")
        XCTAssertEqual(vm.draft, "still composing this", "the in-progress draft is left alone")
    }

    /// Fix wave, item B: a voice note is an attachment-only comment — same
    /// draft-preserving contract as `submitAttachments` directly.
    func testSendVoiceNoteLeavesDraftIntact() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "still composing this"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data([0, 1, 2]).write(to: url)
        await vm.sendVoiceNote(url: url)
        XCTAssertEqual(sync.comments.first?.1, "")
        XCTAssertEqual(vm.draft, "still composing this")
    }

    /// Fix wave, item F: an upload failure must not destroy the only copy
    /// of the recording — the old `defer`-based cleanup deleted the temp
    /// file unconditionally, so a failed upload both showed an error AND
    /// left nothing to retry.
    func testSendVoiceNoteUploadFailureKeepsFileAndSetsError() async throws {
        let api = API(); let sync = Sync()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data([0, 1, 2]).write(to: url)
        await vm.sendVoiceNote(url: url)
        XCTAssertNotNil(vm.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the recording survives a failed upload")
        XCTAssertTrue(sync.comments.isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    /// Fix wave, item I4: unlike an upload failure (which keeps the file
    /// so the SAME data can be retried), an empty/unreadable recording
    /// will read the same way again — there's nothing worth keeping the
    /// temp file around for, and the old early return orphaned it.
    func testSendVoiceNoteEmptyRecordingDeletesFileAndSetsError() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data().write(to: url)
        await vm.sendVoiceNote(url: url)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an empty recording's temp file must not be orphaned")
        XCTAssertTrue(sync.comments.isEmpty)
        XCTAssertTrue(api.uploads.isEmpty)
    }

    func testCloseWithCommentPassesCommentThrough() async {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.close(resolution: .done, comment: "why")
        XCTAssertEqual(api.closes.first?.0, .done)
        XCTAssertEqual(api.closes.first?.1, "why")
    }
}

/// Polls `condition` until it's true or `timeout` elapses, throwing on
/// timeout instead of failing via a fixed sleep — used where a fixed sleep
/// would either be flaky (too short) or slow the suite down (too long).
private struct WaitTimeoutError: Error, CustomStringConvertible {
    var description: String { "condition not met before timeout" }
}
private func waitUntil(timeout: TimeInterval = 2.0, pollInterval: UInt64 = 5_000_000,
                       _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw WaitTimeoutError() }
        try await Task.sleep(nanoseconds: pollInterval)
    }
}
