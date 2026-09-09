import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class ItemDetailViewModelTests: XCTestCase {
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?; var commentsCont: AsyncStream<[TrackerComment]>.Continuation?
        var outboxCont: AsyncStream<[ItemOutboxRecord]>.Continuation?
        /// What the synchronous read returns — the "store after the refetch".
        var storedComments: [TrackerComment] = []
        func comments(itemID: String) throws -> [TrackerComment] { storedComments }
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { self.commentsCont = $0 } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { self.outboxCont = $0; $0.yield([]) } }
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        var comments: [(String, String, [TrackerAttachment])] = []; var refetched: [String] = []
        /// When set, `refreshItem` suspends until `releaseRefresh()`.
        var holdRefresh = false
        private var refreshGate: CheckedContinuation<Void, Never>?
        var isHeld: Bool { refreshGate != nil }
        func releaseRefresh() { let c = refreshGate; refreshGate = nil; c?.resume() }
        func refresh(scope: ItemsScope) async {}
        func refreshItem(id: String) async {
            if holdRefresh { holdRefresh = false; await withCheckedContinuation { refreshGate = $0 } }
            refetched.append(id)
        }
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

    func testLoadedCommentCountIsSetFromTheStoreOnceTheOpeningRefetchCompletes() async throws {
        let sync = Sync(); let store = Store()
        // The refetch has landed in the store but its stream delivery is
        // still in flight: the count must not run ahead of the thread.
        store.storedComments = [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "x")]
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync)
        XCTAssertNil(vm.loadedCommentCount)
        vm.start()
        try await waitUntil { vm.loadedCommentCount != nil }
        XCTAssertEqual(sync.refetched, ["it_1"])
        XCTAssertEqual(vm.comments.map(\.id), ["ic_1"], "comments are read from the store before the count is set")
        XCTAssertEqual(vm.loadedCommentCount, 1)
        // Restarting re-arms the gate until the new refetch lands.
        vm.stop()
        vm.start()
        try await waitUntil { sync.refetched.count == 2 && vm.loadedCommentCount == 1 }
    }

    /// Bugbot (PR #198, round 4): the comments subscription taken at
    /// `start()` may still hold a pre-refetch snapshot when the refetch
    /// completes; it is dropped and re-taken, so that snapshot can never
    /// overwrite the loaded thread.
    func testStaleSubscriptionCannotOverwriteTheLoadedThread() async throws {
        let sync = Sync(); let store = Store()
        store.storedComments = [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "x"),
                                TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "y")]
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync)
        sync.holdRefresh = true
        vm.start()
        try await waitUntil { store.commentsCont != nil && sync.isHeld }
        let stale = store.commentsCont!                      // the subscription taken at start()
        store.commentsCont = nil
        sync.releaseRefresh()
        try await waitUntil { vm.loadedCommentCount == 2 }
        try await waitUntil { store.commentsCont != nil }   // the fresh subscription
        stale.yield([])                                      // the old one's late, empty snapshot
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.comments.map(\.id), ["ic_1", "ic_2"], "the stale subscription must be ignored")
        store.commentsCont?.yield(store.storedComments + [TrackerComment(id: "ic_3", itemID: "it_1", author: .user, body: "z")])
        try await waitUntil { vm.comments.count == 3 }
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

    func testQuestionOffersAnsweredOnlyOnceTheUserHasReplied() {
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .question, userHasReplied: false), [.cancelled])
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .question, userHasReplied: true), [.answered, .cancelled])
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .task, userHasReplied: false), [.done, .cancelled])
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: nil, userHasReplied: true), [])
    }

    func testUserHasRepliedCountsOnlyTheirOwnComments() async throws {
        let api = API(); let sync = Sync(); let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: api, sync: sync)
        vm.start()
        try await waitUntil { sync.refetched == ["it_1"] }
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1"))
        try await waitUntil { vm.item?.kind == .question }
        XCTAssertEqual(vm.availableResolutions, [.cancelled])
        // An agent comment and a status row are not a reply from the user.
        store.commentsCont?.yield([
            TrackerComment(id: "a", itemID: "it_1", author: .agent, body: "Options are…", createdAt: Date()),
            TrackerComment(id: "s", itemID: "it_1", author: .user, kind: .status, body: "", createdAt: Date()),
        ])
        try await waitUntil { vm.comments.count == 2 }
        XCTAssertEqual(vm.availableResolutions, [.cancelled])
        store.commentsCont?.yield([TrackerComment(id: "u", itemID: "it_1", author: .user, body: "Keep it.", createdAt: Date())])
        try await waitUntil { vm.comments.count == 1 }
        XCTAssertEqual(vm.availableResolutions, [.answered, .cancelled])
    }

    /// Bugbot: a reply the user just sent sits in the outbox until the
    /// thread catches up — it is still their reply, so the question must
    /// not read as unanswered in the meantime.
    func testAPendingReplyCountsAsHavingReplied() async throws {
        let api = API(); let sync = Sync(); let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: api, sync: sync)
        vm.start()
        try await waitUntil { sync.refetched == ["it_1"] }
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1"))
        try await waitUntil { vm.item?.kind == .question }
        XCTAssertEqual(vm.availableResolutions, [.cancelled])
        store.outboxCont?.yield([ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{\"body\":\"Keep it.\",\"attachments\":[]}",
                                                  createdAt: 0, attempts: 0, lastError: nil)])
        try await waitUntil { vm.pendingComments.count == 1 }
        XCTAssertEqual(vm.availableResolutions, [.answered, .cancelled])
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
        XCTAssertEqual(vm.availableResolutions, [.reversed, .decided, .cancelled])
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
