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
        /// What the synchronous item / outbox reads return — the store as
        /// it is, ahead of whatever the streams have delivered so far.
        var storedItem: TrackerItem?
        var storedOutbox: [ItemOutboxRecord] = []
        func item(id: String) throws -> TrackerItem? { storedItem }
        func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { storedOutbox }
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
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async {
            if holdRefresh { holdRefresh = false; await withCheckedContinuation { refreshGate = $0 } }
            refetched.append(id)
        }
        /// The `action` each enqueued comment carried, in order.
        var actions: [String?] = []
        /// The `replyTo` each enqueued comment carried, in order.
        var replyTos: [String?] = []
        /// Runs inside `enqueueComment` with the row's localID — lets a
        /// test put the queued row into the store the way `ItemsSync` does.
        var onEnqueue: ((String) -> Void)?
        /// When set, the next `enqueueComment` suspends until `releaseEnqueue()`.
        var holdEnqueue = false
        private var enqueueGate: CheckedContinuation<Void, Never>?
        var isEnqueueHeld: Bool { enqueueGate != nil }
        func releaseEnqueue() { let c = enqueueGate; enqueueGate = nil; c?.resume() }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {
            comments.append((itemID, body, attachments)); actions.append(action); replyTos.append(replyTo)
            onEnqueue?(localID)
            if holdEnqueue { holdEnqueue = false; await withCheckedContinuation { enqueueGate = $0 } }
        }
        /// Queued-only: records the row like `enqueueComment` but, like the
        /// real `ItemsSync`, never waits on delivery (the enqueue gate
        /// models a drain in flight, which this must not block on).
        var queueFails = false
        func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool {
            if queueFails { return false }
            comments.append((itemID, body, attachments)); actions.append(nil); replyTos.append(nil)
            onEnqueue?(localID)
            return true
        }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }
    private final class API: ItemsProviding, @unchecked Sendable {
        var uploads: [String] = []; var closes: [(ItemResolution, String?)] = []; var reopens = 0
        var failUpload = false
        /// When set, the next `uploadMedia` suspends until `releaseUpload()`.
        var holdUpload = false
        private var uploadGate: CheckedContinuation<Void, Never>?
        var isUploadHeld: Bool { uploadGate != nil }
        func releaseUpload() { let c = uploadGate; uploadGate = nil; c?.resume() }
        func uploadMedia(_ data: Data, contentType: String) async throws -> String {
            if holdUpload { holdUpload = false; await withCheckedContinuation { uploadGate = $0 } }
            if failUpload { throw JournalAPIError.transport("upload failed") }
            uploads.append(contentType); return "blob-\(uploads.count)"
        }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { closes.append((resolution, comment)); return TrackerItem(id: id, num: 1, kind: .task, state: .closed, title: "", originConvoID: "c1") }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { reopens += 1; return TrackerItem(id: id, num: 1, kind: .task, title: "", originConvoID: "c1") }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }

    // MARK: Read state

    private final class SentOps: @unchecked Sendable {
        private let lock = NSLock(); private var ops: [ClientOp] = []
        func append(_ op: ClientOp) { lock.lock(); ops.append(op); lock.unlock() }
        var all: [ClientOp] { lock.lock(); defer { lock.unlock() }; return ops }
    }

    /// Spec 2026-09-30: an item open on screen counts as seen through its
    /// newest rendered comment, and each newer comment is reported as it
    /// arrives. Covered (a Mac push) or closed, nothing more is reported.
    func testAnItemOnScreenReportsItemSeenThroughItsNewestComment() async throws {
        let sent = SentOps()
        let seen = SeenTracker { sent.append($0) }
        let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), seen: seen)
        vm.start()
        vm.setOnScreen(true)
        try await waitUntil { store.itemCont != nil && store.commentsCont != nil }
        XCTAssertTrue(sent.all.isEmpty, "nothing until the item itself has loaded")
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .question, title: "Q", originConvoID: "c1"))
        try await waitUntil { sent.all.count == 1 }
        XCTAssertEqual(sent.all, [.itemSeen(itemID: "it_1", throughCommentAt: 0)])

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_060)
        store.commentsCont?.yield([
            TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: "b", createdAt: t2),
            TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a", createdAt: t1),
        ])
        try await waitUntil { sent.all.count == 2 }
        XCTAssertEqual(sent.all.last, .itemSeen(itemID: "it_1", throughCommentAt: 1_700_000_060_000))

        vm.setOnScreen(false)
        store.commentsCont?.yield([TrackerComment(id: "ic_3", itemID: "it_1", author: .user, body: "c",
                                                  createdAt: t2.addingTimeInterval(60))])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.all.count, 2, "a covered item reports nothing new")
        vm.stop()
    }

    /// Bugbot (PR 279): a Mac width-crossing remount shows the same view
    /// model from a new host, and the old host's disappear can land after
    /// the new host's appear. The item must stay on screen.
    func testAnOldHostLeavingAfterTheNewOneAppearsKeepsTheItemOnScreen() async throws {
        let sent = SentOps()
        let seen = SeenTracker { sent.append($0) }
        let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), seen: seen)
        vm.start()
        let old = UUID(), new = UUID()
        vm.setOnScreen(true, host: old)
        vm.setOnScreen(true, host: new)
        vm.setOnScreen(false, host: old)
        try await waitUntil { store.itemCont != nil && store.commentsCont != nil }
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .question, title: "Q", originConvoID: "c1"))
        try await waitUntil { sent.all.count == 1 }
        store.commentsCont?.yield([TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a",
                                                  createdAt: Date(timeIntervalSince1970: 1_700_000_000))])
        try await waitUntil { sent.all.count == 2 }
        XCTAssertEqual(sent.all.last, .itemSeen(itemID: "it_1", throughCommentAt: 1_700_000_000_000))
        vm.stop()
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

    /// A file on disk to stage, as a picker/paste/drop would hand over.
    private func makeFile(_ name: String, bytes: [UInt8] = [1]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("item-vm-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testSubmitUploadsThenEnqueuesAndClearsDraft() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = " use A "
        await vm.attachFiles([try makeFile("s.png")])
        await vm.submitComment()
        XCTAssertEqual(api.uploads, ["image/png"])
        XCTAssertEqual(sync.comments.first?.1, "use A")
        XCTAssertEqual(sync.comments.first?.2.first?.blobRef, "blob-1")
        XCTAssertEqual(vm.draft, "")
        await vm.submitComment()
        XCTAssertEqual(sync.comments.count, 1, "empty draft + no attachments is a no-op")
    }

    /// Dropping, pasting or picking a file stages it — nothing uploads, no
    /// comment is queued, and the half-written reply is left alone (a dropped image posted on its own at once).
    func testAttachingStagesWithoutSending() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "still composing"
        let source = try makeFile("shot.png", bytes: [9, 9, 9])
        await vm.attachFiles([source])
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["shot.png"])
        XCTAssertEqual(vm.stagedAttachments.first?.mimeType, "image/png")
        XCTAssertEqual(vm.stagedAttachments.first?.sizeBytes, 3)
        XCTAssertNotEqual(vm.stagedAttachments.first?.url, source, "the tray holds OUR copy, not the caller's URL")
        XCTAssertTrue(api.uploads.isEmpty)
        XCTAssertTrue(sync.comments.isEmpty)
        XCTAssertEqual(vm.draft, "still composing")
        XCTAssertTrue(vm.canSubmit)
    }

    /// Send: the text and every staged attachment leave as ONE comment, in
    /// the order they were staged; the tray empties and its copies go.
    func testSendIsOneCommentCarryingTextAndEveryStagedAttachment() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("a.png"), try makeFile("b.pdf", bytes: [1, 2])])
        vm.draft = "Here are both"
        let copies = vm.stagedAttachments.map(\.url)
        await vm.submitComment()
        XCTAssertEqual(sync.comments.count, 1)
        XCTAssertEqual(sync.comments.first?.1, "Here are both")
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["a.png", "b.pdf"])
        XCTAssertEqual(sync.comments.first?.2.map(\.mime), ["image/png", "application/pdf"])
        XCTAssertEqual(sync.comments.first?.2.map(\.size), [1, 2])
        XCTAssertEqual(sync.comments.first?.2.map(\.blobRef), ["blob-1", "blob-2"])
        XCTAssertEqual(vm.draft, "")
        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertFalse(vm.canSubmit)
        for url in copies { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "sent copies are deleted") }
    }

    /// An attachment on its own is a reply, as in chat.
    func testAttachmentOnlySendHasAnEmptyBody() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("s.png")])
        XCTAssertTrue(vm.canSubmit)
        await vm.submitComment()
        XCTAssertEqual(sync.comments.count, 1)
        XCTAssertEqual(sync.comments.first?.1, "")
        XCTAssertEqual(sync.comments.first?.2.count, 1)
    }

    /// A file staged while the send's uploads are in flight is not part of
    /// that send: it stays in the tray for the next reply.
    func testAttachmentStagedDuringASendStaysForTheNextReply() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("first.png")])
        vm.draft = "one"
        api.holdUpload = true
        let send = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        await vm.attachFiles([try makeFile("second.png")])
        api.releaseUpload()
        await send.value
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["first.png"])
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["second.png"])
    }

    /// The Mac reply field stays editable while a send uploads: text
    /// typed then is the next reply. A successful send must not wipe it,
    /// and a failed one must not overwrite it with the old text.
    func testTextTypedDuringASendIsNeverWiped() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("a.png")])
        vm.draft = "first"
        api.holdUpload = true
        let send = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        XCTAssertEqual(vm.draft, "", "the field clears at the tap")
        XCTAssertTrue(vm.stagedAttachments.isEmpty, "the tray clears at the tap")
        vm.draft = "second"
        api.releaseUpload()
        await send.value
        XCTAssertEqual(sync.comments.first?.1, "first")
        XCTAssertEqual(vm.draft, "second")

        await vm.attachFiles([try makeFile("b.png")])
        api.failUpload = true
        api.holdUpload = true
        let failing = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        vm.draft = "third"
        api.releaseUpload()
        await failing.value
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.draft, "third", "a failed send's restore must not overwrite newer text")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["b.png"], "the unsent attachment is back in the tray")
    }

    /// Bugbot, PR #274: Send clears the field at the tap, so while the
    /// uploads run the reply must still be visible — as a sending row in
    /// the thread (text + attachment count) until the outbox row replaces
    /// it; a failed upload takes the row away and puts the reply back.
    func testTheReplyShowsAsSendingWhileItUploads() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("a.png"), try makeFile("b.png")])
        vm.draft = "Here you go"
        XCTAssertNil(vm.sendingReplies.last)
        api.holdUpload = true
        let send = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        XCTAssertEqual(vm.sendingReplies.last?.body, "Here you go")
        XCTAssertEqual(vm.sendingReplies.last?.attachmentCount, 2)
        api.releaseUpload()
        await send.value
        XCTAssertNil(vm.sendingReplies.last, "the outbox row takes over once enqueued")
        XCTAssertEqual(sync.comments.count, 1)

        await vm.attachFiles([try makeFile("c.png")])
        vm.draft = "again"
        api.failUpload = true
        api.holdUpload = true
        let failing = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        XCTAssertEqual(vm.sendingReplies.last?.body, "again")
        api.releaseUpload()
        await failing.value
        XCTAssertNil(vm.sendingReplies.last)
        XCTAssertEqual(vm.draft, "again")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["c.png"])
    }

    /// Bugbot, PR #274 (round 2): the sending row must go the moment the
    /// reply is durably in the outbox — not after the drain posts it. The
    /// drain deletes the outbox row and stores the posted comment (server
    /// id) in one transaction, so a row still shown by then duplicates the
    /// comment. The fake's enqueue gate stands in for a drain in flight.
    func testTheSendingRowGoesOnceTheReplyIsQueued_notAfterItPosts() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "posted fast"
        sync.holdEnqueue = true
        let send = Task { await vm.submitComment() }
        try await waitUntil { sync.comments.count == 1 }
        // Let the send reach its next step if it isn't blocked on delivery.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(vm.sendingReplies.last, "queued is enough: the outbox row (or the posted comment) shows the reply")
        sync.releaseEnqueue()
        await send.value
        XCTAssertNil(vm.sendingReplies.last)
    }

    private func outboxRow(_ localID: String) -> ItemOutboxRecord {
        ItemOutboxRecord(localID: localID, itemID: "it_1", op: "comment", payloadJSON: "{\"body\":\"x\",\"attachments\":[]}",
                         createdAt: 0, attempts: 0, lastError: nil)
    }

    /// Bugbot, PR #274 (round 3): queued is durable, but the thread shows
    /// the outbox only via its stream. The sending row stays until the
    /// stream delivers the row — a stale pre-insert snapshot must not make
    /// the reply vanish in between.
    func testTheSendingRowStaysUntilTheOutboxStreamShowsTheRow() async throws {
        let sync = Sync(); let store = Store()
        sync.onEnqueue = { store.storedOutbox = [self.outboxRow($0)] }
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync)
        vm.start()
        try await waitUntil { store.outboxCont != nil }
        vm.draft = "keep me visible"
        await vm.submitComment()
        let localID = try XCTUnwrap(store.storedOutbox.first?.localID)
        XCTAssertEqual(vm.sendingReplies.last?.localID, localID, "queued, but the thread can't show it yet")
        store.outboxCont?.yield([])                      // stale, from before the insert
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(vm.sendingReplies.last, "a stale snapshot must not make the reply vanish")
        store.outboxCont?.yield(store.storedOutbox)      // the row arrives
        try await waitUntil { vm.pendingComments.map(\.localID) == [localID] }
        XCTAssertNil(vm.sendingReplies.last, "the outbox row now shows the reply")
        vm.stop()
    }

    /// The drain can post before the stream ever shows the row (the row's
    /// delete and the comment's insert are one transaction). Once the
    /// store has neither the row nor needs it, the thread shows the posted
    /// comment and the sending row goes — at the same moment.
    func testTheSendingRowHandsOverToThePostedComment() async throws {
        let sync = Sync(); let store = Store()
        sync.onEnqueue = { store.storedOutbox = [self.outboxRow($0)] }
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync)
        vm.start()
        try await waitUntil { store.outboxCont != nil && sync.refetched == ["it_1"] }
        vm.draft = "posted fast"
        await vm.submitComment()
        XCTAssertNotNil(vm.sendingReplies.last)
        // The drain posts: row deleted, comment stored, in one go.
        store.storedOutbox = []
        store.storedComments = [TrackerComment(id: "ic_srv", itemID: "it_1", author: .user, body: "posted fast")]
        store.outboxCont?.yield([])
        try await waitUntil { vm.sendingReplies.isEmpty }
        XCTAssertEqual(vm.comments.map(\.id), ["ic_srv"], "the posted comment is on screen as the row goes")
        vm.stop()
    }

    /// Bugbot, PR #274 (round 4): a second reply can start while the
    /// first is queued but not yet on screen. Each shows its own sending
    /// row, and each is settled by its OWN id — the first's row arriving
    /// must not clear the second mid-upload, nor the second hide the first.
    func testTwoRepliesInFlightEachKeepTheirOwnRow() async throws {
        let api = API(); let sync = Sync(); let store = Store()
        sync.onEnqueue = { store.storedOutbox.append(self.outboxRow($0)) }
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: api, sync: sync)
        vm.start()
        try await waitUntil { store.outboxCont != nil }
        vm.draft = "first"
        await vm.submitComment()
        let firstID = try XCTUnwrap(store.storedOutbox.first?.localID)
        XCTAssertEqual(vm.sendingReplies.map(\.body), ["first"])

        await vm.attachFiles([try makeFile("b.png")])
        vm.draft = "second"
        api.holdUpload = true
        let second = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        XCTAssertEqual(vm.sendingReplies.map(\.body), ["first", "second"], "the second must not hide the first")

        store.outboxCont?.yield(store.storedOutbox)       // the FIRST row arrives
        try await waitUntil { vm.pendingComments.map(\.localID) == [firstID] }
        XCTAssertEqual(vm.sendingReplies.map(\.body), ["second"], "only the first hands over; the second is still uploading")

        api.releaseUpload()
        await second.value
        XCTAssertEqual(vm.sendingReplies.map(\.body), ["second"], "queued, stream not caught up")
        store.outboxCont?.yield(store.storedOutbox)
        try await waitUntil { vm.sendingReplies.isEmpty }
        vm.stop()
    }

    func testStopClearsTheSendingRow() async throws {
        let sync = Sync(); let store = Store()
        sync.onEnqueue = { store.storedOutbox = [self.outboxRow($0)] }
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync)
        vm.draft = "x"
        await vm.submitComment()
        XCTAssertNotNil(vm.sendingReplies.last)
        vm.stop()
        XCTAssertNil(vm.sendingReplies.last)
    }

    /// Bugbot, PR #274 (round 3): if nothing could be queued, the
    /// attachments come back too — their staged copies still on disk.
    func testAQueueFailureRestoresTheTray() async throws {
        let sync = Sync(); sync.queueFails = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: sync)
        await vm.attachFiles([try makeFile("keep.png")])
        let staged = vm.stagedAttachments
        vm.draft = "with a picture"
        await vm.submitComment()
        XCTAssertEqual(vm.stagedAttachments, staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].url.path))
        XCTAssertEqual(vm.draft, "with a picture")
        XCTAssertNotNil(vm.error)
    }

    /// Nothing queued (sync stopped / local write failed): the words come
    /// back to the composer with an error rather than vanishing.
    func testAReplyThatCouldNotBeQueuedComesBack() async {
        let sync = Sync(); sync.queueFails = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: sync)
        vm.draft = "don't lose me"
        await vm.submitComment()
        XCTAssertEqual(vm.draft, "don't lose me")
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.sendingReplies.last)
    }

    /// Review, PR #274: a second Send while one is still uploading is a
    /// no-op — no second comment, and the text typed meanwhile stays put.
    func testASecondSendWhileOneIsInFlightDoesNothing() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("a.png")])
        vm.draft = "first"
        api.holdUpload = true
        let send = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        XCTAssertTrue(vm.isBusy)
        vm.draft = "second"
        await vm.submitComment()
        XCTAssertEqual(vm.draft, "second", "the in-flight guard leaves the new text alone")
        api.releaseUpload()
        await send.value
        XCTAssertEqual(sync.comments.map(\.1), ["first"])
        XCTAssertEqual(api.uploads.count, 1)
    }

    /// Review, PR #274: a temp file the app wrote (paste, picked photo) is
    /// MOVED into the tray — one file on disk, not a temp plus a copy.
    func testTemporaryFilesAreMovedNotCopied() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        let temp = try makeFile("pasted.png", bytes: [7, 7])
        await vm.attachTemporaryFiles([temp])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "the temp source is taken over")
        let staged = try XCTUnwrap(vm.stagedAttachments.first)
        XCTAssertEqual(try Data(contentsOf: staged.url), Data([7, 7]))
        XCTAssertEqual(staged.sizeBytes, 2)
        XCTAssertEqual(staged.mimeType, "image/png")
    }

    /// The user's own file (a Finder drop, a panel pick) is copied and left alone.
    func testCallerOwnedFilesAreCopiedAndKept() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        let original = try makeFile("mine.pdf")
        await vm.attachFiles([original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(vm.stagedAttachments.count, 1)
    }

    func testOversizedTemporaryFileIsRefusedAndDeleted() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        let big = try makeFile("huge.mov")
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ItemDetailViewModel.maxAttachmentBytes + 1))
        try handle.close()
        await vm.attachTemporaryFiles([big])
        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path), "a refused temp file is ours to delete")
        XCTAssertEqual(vm.error, ItemDetailViewModel.oversizeMessage(filename: "huge.mov"))
    }

    /// Review, PR #274: closing the item deletes the tray's staged copies.
    func testStopDiscardsTheTray() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        vm.start()
        await vm.attachFiles([try makeFile("a.png"), try makeFile("b.png")])
        let copies = vm.stagedAttachments.map(\.url)
        vm.stop()
        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        for url in copies { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    /// `start()` restarts the streams without touching the tray.
    func testStartKeepsTheTray() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        await vm.attachFiles([try makeFile("a.png")])
        vm.start()
        XCTAssertEqual(vm.stagedAttachments.count, 1)
        vm.stop()
    }

    /// A send that fails after the item closed deletes its attachments
    /// instead of restoring them into a tray nobody will see.
    func testAFailedSendAfterStopDeletesInsteadOfRestoring() async throws {
        let api = API(); let sync = Sync()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("a.png")])
        let copy = try XCTUnwrap(vm.stagedAttachments.first?.url)
        api.holdUpload = true
        let send = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }
        vm.stop()
        api.releaseUpload()
        await send.value
        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testRemovingAStagedAttachmentDeletesItsCopy() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        await vm.attachFiles([try makeFile("a.png"), try makeFile("b.png")])
        let removed = try XCTUnwrap(vm.stagedAttachments.first)
        vm.removeAttachment(id: removed.id)
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["b.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.url.path))
    }

    /// Over the tracker's upload cap: refused at attach time, with the
    /// reason, while any other files in the same batch still stage.
    func testOversizedFileIsRefusedAtAttachTime() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        let big = try makeFile("huge.mov")
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ItemDetailViewModel.maxAttachmentBytes + 1))
        try handle.close()
        await vm.attachFiles([big, try makeFile("ok.png")])
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["ok.png"])
        XCTAssertEqual(vm.error, "huge.mov is larger than 25 MB and wasn't attached.")
    }

    func testUnreadableFileReportsAndStagesNothing() async throws {
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: Sync())
        await vm.attachFiles([URL(fileURLWithPath: "/nonexistent/\(UUID()).png")])
        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertNotNil(vm.error)
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

    /// A note started on an item can be stopped after the user
    /// has left that item's page (its view model already stopped) — it
    /// must still be posted there, and report success to the session.
    func testVoiceNoteSendsAfterTheItemPageClosed() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.start()
        vm.stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data([0, 1, 2]).write(to: url)
        let error = await vm.sendVoiceNote(url: url)
        XCTAssertNil(error)
        XCTAssertEqual(sync.comments.first?.2.first?.mime, "audio/mp4")
    }

    func testQuestionOffersAnsweredOnlyOnceTheUserHasReplied() {
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .question, userHasReplied: false), [.cancelled])
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .question, userHasReplied: true), [.answered, .cancelled])
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .task, userHasReplied: false), [.done, .cancelled])
        XCTAssertEqual(ItemDetailViewModel.resolutions(for: .notice, userHasReplied: false), [.done, .cancelled])
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

    /// Offline at Send: the upload fails before anything is queued, so the
    /// draft AND the tray survive intact for a retry — and the retry then
    /// sends them together.
    func testSubmitUploadFailureKeepsDraftAndTrayForARetry() async throws {
        let api = API(); let sync = Sync()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "keep me"
        await vm.attachFiles([try makeFile("s.png")])
        let staged = vm.stagedAttachments
        await vm.submitComment()
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.draft, "keep me")
        XCTAssertEqual(vm.stagedAttachments, staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[0].url.path), "the staged copy survives a failed upload")
        XCTAssertTrue(sync.comments.isEmpty)
        api.failUpload = false
        await vm.submitComment()
        XCTAssertEqual(sync.comments.count, 1)
        XCTAssertEqual(sync.comments.first?.1, "keep me")
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["s.png"])
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

    /// A recording on disk, as `VoiceRecorder` leaves it.
    private func makeRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data("AUDIO".utf8).write(to: url)
        return url
    }

    /// A voice note on an item goes out with the reply —
    /// ONE comment, the typed text as its body, the note as the first
    /// attachment and the tray after it — so the agent gets the text, the
    /// transcript and the photo in one 📌 turn. The field and tray clear.
    func testVoiceNoteCarriesTheDraftAndLeadsTheTray() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = " use A "
        await vm.attachFiles([try makeFile("s.png")])
        let photo = try XCTUnwrap(vm.stagedAttachments.first)
        let recording = try makeRecording()

        let message = await vm.sendVoiceNote(url: recording)

        XCTAssertNil(message)
        XCTAssertEqual(sync.comments.count, 1, "one comment, not one per attachment")
        XCTAssertEqual(sync.comments.first?.1, "use A")
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["voice-note.m4a", "s.png"])
        XCTAssertEqual(sync.comments.first?.2.map(\.mime), ["audio/mp4", "image/png"])
        XCTAssertEqual(sync.comments.first?.2.first?.size, Int64("AUDIO".utf8.count))
        XCTAssertEqual(api.uploads, ["audio/mp4", "image/png"])
        XCTAssertEqual(vm.draft, "")
        XCTAssertTrue(vm.stagedAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.url.path), "sent staged copies are deleted")
    }

    /// The field and tray clear as the send starts, not when the upload
    /// returns — the same optimistic clear as Send — and the reply shows
    /// as "Sending…" meanwhile.
    func testVoiceNoteClearsTheDraftAndTrayWhileTheUploadIsInFlight() async throws {
        let api = API(); let sync = Sync()
        api.holdUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "typed"
        await vm.attachFiles([try makeFile("s.png")])

        let sending = Task { await vm.sendVoiceNote(url: try makeRecording()) }
        try await waitUntil { api.isUploadHeld }

        XCTAssertEqual(vm.draft, "", "the field must be empty WHILE the note uploads")
        XCTAssertTrue(vm.stagedAttachments.isEmpty, "…and so must the tray")
        XCTAssertTrue(vm.isBusy)
        XCTAssertEqual(vm.sendingReplies.map(\.body), ["typed"])
        XCTAssertEqual(vm.sendingReplies.first?.attachmentCount, 2)

        api.releaseUpload()
        let message = try await sending.value
        XCTAssertNil(message)
        XCTAssertEqual(sync.comments.first?.1, "typed")
        XCTAssertFalse(vm.isBusy)
    }

    /// A note that doesn't go out puts the reply back as it was composed:
    /// the text in the field, the note at the head of the tray with the
    /// photo behind it, so Send re-sends the same one comment. Reported
    /// once, by `VoiceNoteSession`'s row; the recording now lives in the
    /// tray, so the session has no file left to Retry.
    func testVoiceNoteUploadFailurePutsTheTextAndTheNoteBackInTheReply() async throws {
        let api = API(); let sync = Sync()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "typed"
        await vm.attachFiles([try makeFile("s.png")])
        let recording = try makeRecording()

        let message = await vm.sendVoiceNote(url: recording)

        XCTAssertTrue(message?.hasSuffix("— it's back in the reply.") ?? false, message ?? "nil")
        XCTAssertNil(vm.error, "reported once, by VoiceNoteSession's failure row")
        XCTAssertEqual(vm.draft, "typed")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["voice-note.m4a", "s.png"])
        XCTAssertEqual(vm.stagedAttachments.first?.mimeType, "audio/mp4")
        XCTAssertEqual(try vm.stagedAttachments.first.map { try Data(contentsOf: $0.url) }, Data("AUDIO".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path),
                       "the session's copy is gone, so its row offers Dismiss rather than a second Retry")
        XCTAssertTrue(vm.sendingReplies.isEmpty)
        XCTAssertTrue(sync.comments.isEmpty)

        // Back online, Send sends the same reply as one comment.
        api.failUpload = false
        await vm.submitComment()
        XCTAssertEqual(sync.comments.count, 1)
        XCTAssertEqual(sync.comments.first?.1, "typed")
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["voice-note.m4a", "s.png"])
    }

    /// Nothing queued (the local write failed): the same restore as an
    /// upload failure.
    func testVoiceNoteQueueFailurePutsTheReplyBack() async throws {
        let sync = Sync()
        sync.queueFails = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: API(), sync: sync)
        vm.draft = "typed"

        let message = await vm.sendVoiceNote(url: try makeRecording())

        XCTAssertEqual(message, "Couldn't queue your reply. — it's back in the reply.")
        XCTAssertEqual(vm.draft, "typed")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["voice-note.m4a"])
        vm.discardAttachments()
    }

    /// A late failure must not overwrite what the user started typing
    /// after the note went off — the same guard as Send.
    func testVoiceNoteFailureDoesNotOverwriteNewTyping() async throws {
        let api = API(); let sync = Sync()
        api.holdUpload = true
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = "first reply"

        let sending = Task { await vm.sendVoiceNote(url: try makeRecording()) }
        try await waitUntil { api.isUploadHeld }
        vm.draft = "second reply"
        api.releaseUpload()
        let message = try await sending.value

        XCTAssertNotNil(message)
        XCTAssertEqual(vm.draft, "second reply")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["voice-note.m4a"], "the note still comes back")
        vm.discardAttachments()
    }

    /// A note can be stopped after its item's page has gone.
    /// If it then fails there is no tray to go back to, so the recording
    /// is moved back to the recorder's file — the session's row keeps
    /// Retry — and the retry still carries the typed text.
    func testVoiceNoteFailingAfterTheItemClosedKeepsTheRecordingForRetry() async throws {
        let api = API(); let sync = Sync()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.start()
        vm.draft = "typed"
        vm.stop()
        let recording = try makeRecording()

        let message = await vm.sendVoiceNote(url: recording)

        XCTAssertEqual(message?.hasPrefix("Couldn't upload an attachment"), true, message ?? "nil")
        XCTAssertFalse(message?.contains("back in the reply") ?? true, "a closed item has no reply to go back to")
        XCTAssertEqual(try Data(contentsOf: recording), Data("AUDIO".utf8), "the recording is back for Retry")
        XCTAssertTrue(vm.stagedAttachments.isEmpty)

        api.failUpload = false
        let retried = await vm.sendVoiceNote(url: recording)
        XCTAssertNil(retried)
        XCTAssertEqual(sync.comments.first?.1, "typed")
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["voice-note.m4a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
    }

    /// If the recording can't be staged (a full disk), it still goes out —
    /// on its own, straight from the recorder's file, leaving the draft and
    /// tray alone. A failure there keeps that file for Retry, as before.
    func testVoiceNoteWhenStagingFailsSendsTheRecordingAloneAndKeepsTheReply() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.stageVoiceNote = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        vm.draft = "typed"
        await vm.attachFiles([try makeFile("s.png")])
        let recording = try makeRecording()

        let message = await vm.sendVoiceNote(url: recording)

        XCTAssertNil(message)
        XCTAssertEqual(sync.comments.first?.1, "")
        XCTAssertEqual(sync.comments.first?.2.map(\.name), ["voice-note.m4a"])
        XCTAssertEqual(sync.comments.first?.2.map(\.mime), ["audio/mp4"])
        XCTAssertEqual(vm.draft, "typed")
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["s.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))

        let again = try makeRecording()
        api.failUpload = true
        let failed = await vm.sendVoiceNote(url: again)
        XCTAssertNotNil(failed)
        XCTAssertNil(vm.error, "reported once, by VoiceNoteSession's failure row")
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path),
                      "the unstaged recording survives a failed send so it can be retried")
        try? FileManager.default.removeItem(at: again)
        vm.discardAttachments()
    }

    /// A note stopped from the app-wide indicator can upload while a typed
    /// reply still is: the first to finish must not report the other as
    /// done.
    func testVoiceNoteFinishingDuringATypedReplyLeavesTheItemBusy() async throws {
        let api = API(); let sync = Sync()
        api.holdUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        await vm.attachFiles([try makeFile("s.png")])

        let typed = Task { await vm.submitComment() }
        try await waitUntil { api.isUploadHeld }

        let message = await vm.sendVoiceNote(url: try makeRecording())

        XCTAssertNil(message)
        XCTAssertTrue(vm.isBusy, "the typed reply is still uploading")
        api.releaseUpload()
        await typed.value
        XCTAssertFalse(vm.isBusy)
        XCTAssertEqual(sync.comments.count, 2)
    }

    /// End to end with the app-wide session: a failed note is in the
    /// reply's tray, and the session's row has nothing of its own to
    /// retry — Dismiss only, so the note can't be sent twice.
    func testVoiceNoteSessionFailedNoteGoesToTheTrayAndTheRowOffersDismissOnly() async throws {
        final class Silent: AudioRecording {
            func record() -> Bool { true }
            func stop() {}
        }
        let session = VoiceNoteSession(recorder: VoiceRecorder(
            requestPermission: { true },
            makeRecorder: { _ in Silent() },
            observeInterruptions: { _ in {} }))
        let api = API()
        api.failUpload = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: Sync())
        vm.draft = "typed"

        try await session.start(.init(kind: .item("it_1"), title: "Item")) { url, _ in
            // The fake recorder writes nothing; stand in for its file.
            try? Data("AUDIO".utf8).write(to: url)
            return await vm.sendVoiceNote(url: url)
        }
        XCTAssertEqual(vm.draft, "typed", "recording leaves the draft where it is")
        await session.stopAndSend()?.value

        XCTAssertEqual(session.failures.count, 1)
        XCTAssertEqual(session.failures.first?.canRetry, false)
        XCTAssertEqual(vm.stagedAttachments.map(\.filename), ["voice-note.m4a"])
        XCTAssertEqual(vm.draft, "typed")
        vm.discardAttachments()
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
        let message = await vm.sendVoiceNote(url: url)
        XCTAssertEqual(message, "Voice note was empty.")
        XCTAssertNil(vm.error, "reported once, by VoiceNoteSession's failure row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an empty recording's temp file must not be orphaned")
        XCTAssertTrue(sync.comments.isEmpty)
        XCTAssertTrue(api.uploads.isEmpty)
    }

    // MARK: Item action buttons (contract 2026-09-24)

    private func startedWithItem(_ item: TrackerItem, sync: Sync, store: Store) async throws -> ItemDetailViewModel {
        let vm = ItemDetailViewModel(itemID: item.id, store: store, api: API(), sync: sync)
        vm.start()
        try await waitUntil { sync.refetched == [item.id] && store.itemCont != nil }
        store.itemCont?.yield(item)
        try await waitUntil { vm.item == item }
        return vm
    }

    private func question(state: ItemState = .open, actions: [String] = ["Go", "Wait"], chosen: String? = nil) -> TrackerItem {
        TrackerItem(id: "it_1", num: 1, kind: .question, state: state, awaiting: .user, title: "Q", originConvoID: "c1",
                    actions: actions, chosenAction: chosen)
    }

    func testTappingAnActionQueuesItsLabelAsTheBodyAndTheAction() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        vm.draft = "half-written"
        XCTAssertEqual(vm.offeredActions, ["Go", "Wait"])
        await vm.chooseAction("Go")
        XCTAssertEqual(sync.comments.map(\.1), ["Go"])
        XCTAssertEqual(sync.actions, ["Go"])
        XCTAssertEqual(sync.comments.first?.0, "it_1")
        XCTAssertEqual(vm.draft, "half-written", "a tap never touches the reply being typed")
    }

    func testClosedItemOffersNoActionsAndIgnoresATap() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(state: .closed), sync: sync, store: store)
        XCTAssertEqual(vm.offeredActions, [])
        await vm.chooseAction("Go")
        XCTAssertTrue(sync.comments.isEmpty)
    }

    func testUnknownActionIsIgnored() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        await vm.chooseAction("Maybe")
        XCTAssertTrue(sync.comments.isEmpty)
    }

    func testItemWithoutActionsOffersNone() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(actions: []), sync: sync, store: store)
        XCTAssertEqual(vm.offeredActions, [])
        XCTAssertNil(vm.selectedAction)
    }

    /// The journal's `chosen_action` shows as selected; a tap still
    /// waiting in the outbox outranks it (the user just changed their
    /// mind), and re-tapping the selected one sends nothing.
    func testSelectedActionFollowsTheJournalThenAPendingTap() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(chosen: "Go"), sync: sync, store: store)
        XCTAssertEqual(vm.selectedAction, "Go")
        await vm.chooseAction("Go")
        XCTAssertTrue(sync.comments.isEmpty, "the already-chosen action is not re-sent")

        store.outboxCont?.yield([
            ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{\"body\":\"hi\",\"attachments\":[]}",
                             createdAt: 1, attempts: 0, lastError: nil),
            ItemOutboxRecord(localID: "L2", itemID: "it_1", op: "comment",
                             payloadJSON: "{\"body\":\"Wait\",\"attachments\":[],\"action\":\"Wait\"}",
                             createdAt: 2, attempts: 0, lastError: nil),
            ItemOutboxRecord(localID: "L3", itemID: "it_1", op: "comment", payloadJSON: "{\"body\":\"later\",\"attachments\":[]}",
                             createdAt: 3, attempts: 0, lastError: nil),
        ])
        try await waitUntil { vm.pendingComments.count == 3 }
        XCTAssertEqual(vm.selectedAction, "Wait", "the latest queued tap wins, typed replies don't clear it")
    }

    /// A pending tap on an action the item no longer offers (the agent
    /// changed `actions`) must not show a stale selection.
    func testPendingTapOnAWithdrawnActionIsNotSelected() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(actions: ["Yes"]), sync: sync, store: store)
        store.outboxCont?.yield([
            ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment",
                             payloadJSON: "{\"body\":\"Go\",\"attachments\":[],\"action\":\"Go\"}",
                             createdAt: 1, attempts: 0, lastError: nil),
        ])
        try await waitUntil { vm.pendingComments.count == 1 }
        XCTAssertNil(vm.selectedAction)
    }

    private func tapRow(_ localID: String, _ label: String) -> ItemOutboxRecord {
        ItemOutboxRecord(localID: localID, itemID: "it_1", op: "comment",
                         payloadJSON: "{\"body\":\"\(label)\",\"attachments\":[],\"action\":\"\(label)\"}",
                         createdAt: 1, attempts: 0, lastError: nil)
    }

    /// Review (PR #242): the tap queued offline stays selected from the
    /// moment it is enqueued — the outbox stream reports the row a hop
    /// later, and in that gap the button must neither flicker back to
    /// unselected nor accept a second, duplicate tap.
    func testAQueuedTapStaysSelectedAndARepeatTapSendsNothing() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        sync.onEnqueue = { store.storedOutbox = [self.tapRow($0, "Go")] }   // offline: the row stays queued
        await vm.chooseAction("Go")
        XCTAssertEqual(vm.selectedAction, "Go", "selected before the outbox stream has reported the row")
        await vm.chooseAction("Go")
        XCTAssertEqual(sync.actions, ["Go"], "a repeat tap on the pending label queues nothing")
    }

    /// Two taps landing while the first is still being enqueued: the
    /// second, on the same label, is ignored.
    func testADoubleTapWhileTheFirstIsEnqueueingQueuesOnce() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        sync.onEnqueue = { store.storedOutbox = [self.tapRow($0, "Go")] }
        sync.holdEnqueue = true
        let first = Task { await vm.chooseAction("Go") }
        try await waitUntil { sync.isEnqueueHeld }
        XCTAssertEqual(vm.selectedAction, "Go")
        await vm.chooseAction("Go")
        sync.releaseEnqueue()
        await first.value
        XCTAssertEqual(sync.actions, ["Go"])
        XCTAssertEqual(vm.selectedAction, "Go")
    }

    /// A tap that was posted before the enqueue returned (online) shows
    /// the journal's answer at once, and the in-flight marker does not
    /// outlive it: when the agent later withdraws the choice, nothing
    /// stays selected.
    func testATapPostedAtOnceHandsOverToTheJournalsChoice() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        sync.onEnqueue = { _ in store.storedItem = self.question(chosen: "Go") }  // row already drained
        await vm.chooseAction("Go")
        XCTAssertEqual(vm.selectedAction, "Go")
        store.itemCont?.yield(question(chosen: "Go"))                        // the stream confirms the tap
        try await waitUntil { vm.item?.chosenAction == "Go" }
        store.itemCont?.yield(question(actions: ["Go", "Wait"], chosen: nil))
        try await waitUntil { vm.item?.chosenAction == nil }
        XCTAssertNil(vm.selectedAction, "no stale in-flight marker once the tap has settled")
    }

    /// CodeRabbit (PR #242): snapshots the streams already had in flight —
    /// an empty outbox, the item from before the tap — can land after
    /// `chooseAction` read the store. The choice must survive them until a
    /// newer item snapshot confirms it.
    func testStaleSnapshotsAfterATapKeepItSelected() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        sync.onEnqueue = { _ in store.storedItem = self.question(chosen: "Go") }  // posted at once
        await vm.chooseAction("Go")
        store.outboxCont?.yield([])                   // stale: before the row
        store.itemCont?.yield(question())             // stale: before the choice
        try await waitUntil { vm.item?.chosenAction == nil }
        XCTAssertEqual(vm.selectedAction, "Go", "a stale snapshot never unselects the tap")
        await vm.chooseAction("Go")
        XCTAssertEqual(sync.actions, ["Go"], "and never lets a duplicate through")
        store.itemCont?.yield(question(chosen: "Go"))
        try await waitUntil { vm.item?.chosenAction == "Go" }
        XCTAssertEqual(vm.selectedAction, "Go")
    }

    /// Bugbot (PR #242): a queued tap the drain drops as poison deletes
    /// only its outbox row — no item write — so the button must not stay
    /// selected, and the label must be tappable again.
    func testADroppedQueuedTapIsNoLongerSelected() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        sync.onEnqueue = { store.storedOutbox = [self.tapRow($0, "Go")] }   // offline: queued
        await vm.chooseAction("Go")
        let row = store.storedOutbox
        store.outboxCont?.yield(row)                                     // the stream shows the row
        try await waitUntil { !vm.pendingComments.isEmpty }
        store.storedOutbox = []
        store.outboxCont?.yield([])                                      // dropped: no item write
        try await waitUntil { vm.pendingComments.isEmpty }
        XCTAssertNil(vm.selectedAction, "a dropped tap is not shown as chosen")
        await vm.chooseAction("Go")
        XCTAssertEqual(sync.actions, ["Go", "Go"], "the label can be tapped again")
    }

    // MARK: Comment action buttons (contract 2026-10-04)

    private func asking(_ id: String = "ic_ask", actions: [String] = ["Go", "Wait"], chosen: String? = nil) -> TrackerComment {
        TrackerComment(id: id, itemID: "it_1", author: .agent, body: "Ship it?", createdAt: Date(timeIntervalSince1970: 1),
                       actions: actions, chosenAction: chosen)
    }

    /// A view model on `item` whose loaded thread is `thread`.
    private func startedWithThread(_ thread: [TrackerComment], item: TrackerItem? = nil, sync: Sync, store: Store) async throws -> ItemDetailViewModel {
        store.storedComments = thread
        let vm = try await startedWithItem(item ?? question(actions: []), sync: sync, store: store)
        try await waitUntil { vm.loadedCommentCount == thread.count }
        return vm
    }

    private func commentTapRow(_ localID: String, _ label: String, replyTo: String) -> ItemOutboxRecord {
        ItemOutboxRecord(localID: localID, itemID: "it_1", op: "comment",
                         payloadJSON: "{\"body\":\"\(label)\",\"attachments\":[],\"action\":\"\(label)\",\"replyTo\":\"\(replyTo)\"}",
                         createdAt: 1, attempts: 0, lastError: nil)
    }

    func testTappingACommentsButtonQueuesTheLabelWithTheAskingCommentsID() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        vm.draft = "half-written"
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        XCTAssertEqual(sync.comments.map(\.1), ["Go"])
        XCTAssertEqual(sync.actions, ["Go"])
        XCTAssertEqual(sync.replyTos, ["ic_ask"])
        XCTAssertEqual(vm.draft, "half-written", "a tap never touches the reply being typed")
    }

    /// The item's own tap still names no comment.
    func testTappingTheItemsButtonSendsNoReplyTo() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithItem(question(), sync: sync, store: store)
        await vm.chooseAction("Go")
        XCTAssertEqual(sync.replyTos, [nil])
    }

    func testCommentTapIsIgnoredForAnUnknownCommentOrLabelAndOnAClosedItem() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Maybe")
        await vm.chooseCommentAction(commentID: "ic_missing", label: "Go")
        XCTAssertTrue(sync.comments.isEmpty)

        let closedSync = Sync()
        let closed = try await startedWithThread([asking(chosen: "Go")], item: question(state: .closed, actions: []), sync: closedSync, store: Store())
        XCTAssertEqual(closed.selectedCommentActions, [:], "a closed item draws no buttons, so marks none")
        await closed.chooseCommentAction(commentID: "ic_ask", label: "Wait")
        XCTAssertTrue(closedSync.comments.isEmpty)
    }

    /// Each question keeps its own answer: the journal's `chosen_action`
    /// per comment, a queued tap outranking it for ITS comment only, and
    /// the item's own selection untouched by either.
    func testEachCommentShowsItsOwnChoiceAndAQueuedTapOutranksTheJournal() async throws {
        let sync = Sync(); let store = Store()
        let thread = [asking("ic_a", chosen: "Go"), asking("ic_b", chosen: "Wait"), asking("ic_c"),
                      TrackerComment(id: "ic_d", itemID: "it_1", author: .user, body: "hello")]
        let vm = try await startedWithThread(thread, item: question(actions: ["Go", "Wait"]), sync: sync, store: store)
        XCTAssertEqual(vm.selectedCommentActions, ["ic_a": "Go", "ic_b": "Wait"])
        await vm.chooseCommentAction(commentID: "ic_a", label: "Go")
        XCTAssertTrue(sync.comments.isEmpty, "the already-chosen label is not re-sent")

        store.outboxCont?.yield([commentTapRow("L1", "Wait", replyTo: "ic_a")])
        try await waitUntil { vm.pendingComments.count == 1 }
        XCTAssertEqual(vm.selectedCommentActions, ["ic_a": "Wait", "ic_b": "Wait"])
        XCTAssertNil(vm.selectedAction, "a tap on a comment's button is never the item's own choice")
    }

    /// And the other way round: a queued tap on the item's own buttons
    /// marks no comment, even one offering the same label.
    func testAQueuedItemTapMarksNoComment() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], item: question(actions: ["Go", "Wait"]), sync: sync, store: store)
        store.outboxCont?.yield([tapRow("L1", "Go")])
        try await waitUntil { vm.pendingComments.count == 1 }
        XCTAssertEqual(vm.selectedAction, "Go")
        XCTAssertEqual(vm.selectedCommentActions, [:])
    }

    /// A choice or a queued tap naming a label the comment doesn't offer
    /// never shows.
    func testAChoiceTheCommentDoesNotOfferIsNotSelected() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking(actions: ["Yes"], chosen: "Go")], sync: sync, store: store)
        store.outboxCont?.yield([commentTapRow("L1", "Wait", replyTo: "ic_ask")])
        try await waitUntil { vm.pendingComments.count == 1 }
        XCTAssertEqual(vm.selectedCommentActions, [:])
    }

    /// Queued offline: selected from the moment it is enqueued, before the
    /// outbox stream reports the row, and a repeat tap queues nothing.
    func testAQueuedCommentTapStaysSelectedAndARepeatTapSendsNothing() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        sync.onEnqueue = { store.storedOutbox = [self.commentTapRow($0, "Go", replyTo: "ic_ask")] }
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        XCTAssertEqual(vm.selectedCommentActions, ["ic_ask": "Go"])
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        XCTAssertEqual(sync.actions, ["Go"])
    }

    func testADoubleCommentTapWhileTheFirstIsEnqueueingQueuesOnce() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        sync.onEnqueue = { store.storedOutbox = [self.commentTapRow($0, "Go", replyTo: "ic_ask")] }
        sync.holdEnqueue = true
        let first = Task { await vm.chooseCommentAction(commentID: "ic_ask", label: "Go") }
        try await waitUntil { sync.isEnqueueHeld }
        XCTAssertEqual(vm.selectedCommentActions, ["ic_ask": "Go"])
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        sync.releaseEnqueue()
        await first.value
        XCTAssertEqual(sync.actions, ["Go"])
        XCTAssertEqual(vm.selectedCommentActions, ["ic_ask": "Go"])
    }

    /// Posted before the enqueue returned (online): the store's thread
    /// already carries the choice. Stale snapshots still in flight — an
    /// empty outbox, the thread from before the tap — never unselect it or
    /// let a duplicate through, and once the stream confirms the choice the
    /// in-flight marker is gone: a later change of mind made elsewhere
    /// shows as the journal reports it.
    func testAPostedCommentTapSurvivesStaleSnapshotsThenFollowsTheJournal() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        sync.onEnqueue = { _ in store.storedComments = [self.asking(chosen: "Go")] }   // row already drained
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        XCTAssertEqual(vm.comments.first?.chosenAction, "Go", "the store's thread is taken at once")

        store.outboxCont?.yield([])                       // stale: before the row
        store.commentsCont?.yield([asking()])             // stale: before the choice
        try await waitUntil { vm.comments.first?.chosenAction == nil }
        XCTAssertEqual(vm.selectedCommentActions, ["ic_ask": "Go"], "a stale snapshot never unselects the tap")
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        XCTAssertEqual(sync.actions, ["Go"], "and never lets a duplicate through")

        store.commentsCont?.yield([asking(chosen: "Go")])     // the stream confirms the tap
        try await waitUntil { vm.comments.first?.chosenAction == "Go" }
        store.commentsCont?.yield([asking(chosen: "Wait")])   // tapped again on another device
        try await waitUntil { vm.comments.first?.chosenAction == "Wait" }
        XCTAssertEqual(vm.selectedCommentActions, ["ic_ask": "Wait"], "no stale in-flight marker once the tap has settled")
    }

    /// A queued tap the drain drops (or re-sends as a typed reply) leaves
    /// the outbox without marking the asking comment: the button must not
    /// stay selected, and the label is tappable again.
    func testADroppedQueuedCommentTapIsNoLongerSelected() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        sync.onEnqueue = { store.storedOutbox = [self.commentTapRow($0, "Go", replyTo: "ic_ask")] }
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        store.outboxCont?.yield(store.storedOutbox)                      // the stream shows the row
        try await waitUntil { !vm.pendingComments.isEmpty }
        store.storedOutbox = []
        store.outboxCont?.yield([])                                      // dropped: nothing marked
        try await waitUntil { vm.pendingComments.isEmpty }
        XCTAssertEqual(vm.selectedCommentActions, [:])
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        XCTAssertEqual(sync.actions, ["Go", "Go"], "the label can be tapped again")
    }

    /// The agent replaced the comment's buttons while the tap was on its
    /// way: the in-flight marker yields to the thread.
    func testAnInFlightCommentTapYieldsWhenItsLabelIsWithdrawn() async throws {
        let sync = Sync(); let store = Store()
        let vm = try await startedWithThread([asking()], sync: sync, store: store)
        sync.onEnqueue = { _ in store.storedComments = [self.asking(chosen: "Go")] }
        await vm.chooseCommentAction(commentID: "ic_ask", label: "Go")
        store.commentsCont?.yield([asking(actions: ["Yes", "No"])])
        try await waitUntil { vm.comments.first?.actions == ["Yes", "No"] }
        XCTAssertEqual(vm.selectedCommentActions, [:])
        store.commentsCont?.yield([asking()])
        try await waitUntil { vm.comments.first?.actions == ["Go", "Wait"] }
        XCTAssertEqual(vm.selectedCommentActions, [:], "the marker did not outlive the withdrawal")
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
