import XCTest
import SwiftUI
import MatronChat
import MatronEvents
import MatronModels
import MatronStorage
@testable import MatronViewModels

/// Test-only fake for `MediaService`. Mirrors the shape declared in
/// `MatronShared/Tests/ChatTests/MediaServiceFakeTests.swift` but lives
/// inside the `ViewModelTests` SPM target so it's visible to the
/// `ChatViewModel` tests below.
final class FakeMediaService: MediaService, @unchecked Sendable {
    var stubData: [URL: Data] = [:]
    private(set) var requested: [URL] = []
    private let lock = NSLock()
    func image(for mxc: URL) async -> Data? {
        lock.withLock { requested.append(mxc) }
        return stubData[mxc]
    }
}

/// Test-only fake for `focus(seq:)`'s paginate-until-loaded loop. The
/// shared `FakeTimelineService` (see `ComposerViewModelTests.swift`)
/// serves a fixed `snapshotsToEmit` list and its `paginateBackward`
/// always returns `false` without growing `items` — fine for the
/// existing "was paginate called" tests, but `focus(seq:)` needs a
/// fake where each `paginateBackward` call actually prepends an older
/// page and re-delivers it through the same `items()` subscription
/// `ChatViewModel.start()` holds open, so its poll-for-growth loop
/// observes real growth (or genuine no-growth, to exercise the
/// `reachedHistoryStart` latch).
final class PagingFakeTimelineService: TimelineService, @unchecked Sendable {
    private var currentItems: [TimelineItem]
    private var olderPages: [[TimelineItem]]
    private(set) var paginateCalls = 0
    private var continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation?

    init(loaded: [TimelineItem], olderPages: [[TimelineItem]]) {
        self.currentItems = loaded
        self.olderPages = olderPages
    }

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(self.currentItems)
        }
    }

    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}

    /// Pops the next queued older page (if any) and prepends it to the
    /// currently-loaded items, re-yielding the grown snapshot. Returns
    /// `true` once no pages remain — mirroring the SDK's "reached start"
    /// signal, though (like the live impl) `ChatViewModel` doesn't trust
    /// that return value alone; it derives `reachedHistoryStart` from
    /// consecutive no-growth calls, which this fake's empty-queue
    /// no-op naturally produces.
    func paginateBackward(requestSize: UInt16) async throws -> Bool {
        paginateCalls += 1
        guard !olderPages.isEmpty else { return true }
        let page = olderPages.removeFirst()
        currentItems = page + currentItems
        continuation?.yield(currentItems)
        return olderPages.isEmpty
    }

    func markAsRead() async throws {}
}

/// Yields an initial snapshot, then lets the test push appended snapshots
/// through the SAME `items()` subscription — the shape a live stream
/// commit takes. `FakeTimelineService` can't do this (it finishes its
/// stream after the queued snapshots).
final class AppendingFakeTimelineService: TimelineService, @unchecked Sendable {
    private var current: [TimelineItem]
    private var continuation: AsyncThrowingStream<[TimelineItem], Error>.Continuation?
    init(initial: [TimelineItem]) { self.current = initial }
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { c in
            self.continuation = c
            c.yield(self.current)
        }
    }
    func append(_ item: TimelineItem) {
        current.append(item)
        continuation?.yield(current)
    }
    func remove(id: String) {
        current.removeAll { $0.id == id }
        continuation?.yield(current)
    }
    // The tests never tear the stream down explicitly on every path —
    // finish on deallocation so the VM's observation task can't outlive
    // the test run (review 2026-08-21).
    deinit { continuation?.finish() }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { true }
    func markAsRead() async throws {}
}

/// Drives `ChatViewModel` against the same `FakeTimelineService` that the
/// `ComposerViewModelTests` already exposes in this target. Because both test
/// files compile into the same `ViewModelTests` SPM target, sharing the fake
/// avoids duplication and keeps the recorded behaviours (snapshotsToEmit,
/// paginateCalls, markReadCalls) consistent between the two suites.
final class ChatViewModelTests: XCTestCase {
    @MainActor
    func test_streamReceivedItems_appearInState() async throws {
        let fake = FakeTimelineService()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true
        )
        fake.snapshotsToEmit = [[item]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())

        // Deterministic: `start()` is async and returns once the first
        // snapshot has been applied (round-3 bugbot fix #3). The fake's
        // AsyncStream finishes after yielding all snapshots, so awaiting
        // the returned task's `.value` is still the precise
        // "processing complete" signal — no sleep needed.
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.id, "1")
    }

    @MainActor
    func test_streamCompletion_isObservableViaTask() async throws {
        // Same wiring; tighter assertion on the deterministic-completion property
        // so future regressions of the contract are caught here.
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        // Bound the wait so a misbehaving stream surfaces as a test failure
        // rather than hanging the suite.
        let outcome = await Task.detached {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await task.value; return true }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return false
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
        }.value
        XCTAssertTrue(outcome, "observation task did not complete within 2s")
    }

    @MainActor
    func test_contentToEmptySnapshot_triggersHistoryRefill() async throws {
        // A snapshot_required wipe empties the store underneath an open
        // timeline — the events vanish mid-view and nothing else refetches
        // them (paginate only fires on open and scroll-up). The VM must
        // notice the content → empty transition and refetch one page.
        let fake = FakeTimelineService()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        fake.snapshotsToEmit = [[item], []]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        // The refill runs on a detached one-shot Task; poll briefly.
        let deadline = Date().addingTimeInterval(2)
        while fake.paginateCalls == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(fake.paginateCalls, 1,
            "content → empty must refetch the newest history page")
    }

    @MainActor
    func test_rowAnchorIDs_retiredEcho_leavesTheAnchorNamespace() async throws {
        // `rowAnchorIDs` is what the views validate remembered scroll
        // positions against — a retired id (e.g. a send echo replaced by
        // the delivered row) must drop out of the set with its snapshot,
        // so a stale restore falls back to open-at-tail instead of
        // scrolling to nothing.
        let fake = FakeTimelineService()
        let older = TimelineItem(
            id: "1", sender: "@me:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true
        )
        let echo = TimelineItem(
            id: "echo:abc", sender: "@me:s", timestamp: .now,
            kind: .text(body: "new msg", formattedHTML: nil), isOwn: true
        )
        let delivered = TimelineItem(
            id: "2", sender: "@me:s", timestamp: .now,
            kind: .text(body: "new msg", formattedHTML: nil), isOwn: true
        )
        // Snapshot 1: echo appended. Snapshot 2: echo retired, real row
        // in its place.
        fake.snapshotsToEmit = [[older, echo], [older, delivered]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertTrue(vm.rowAnchorIDs.contains("2"))
        XCTAssertFalse(
            vm.rowAnchorIDs.contains("echo:abc"),
            "a retired echo must leave the anchor namespace with its snapshot"
        )
    }

    @MainActor
    func test_windowedRows_capTheRenderedTail_andExtendReveals() async throws {
        // The views render `windowedRows`, not `rows` — a full timeline
        // in one LazyVStack is what destabilized the scroll layer
        // (content-height estimate churn; see `ChatViewModel.windowedRows`).
        let fake = FakeTimelineService()
        let items = (0..<200).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: .now,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.rows.count, 201, "200 same-day messages + 1 separator")
        // Window: 120-row tail + the re-synthesized leading separator.
        XCTAssertEqual(vm.windowedRows.count, 121)
        if case .message(let lastItem)? = vm.windowedRows.last {
            XCTAssertEqual(lastItem.id, "m199", "window must be the TAIL slice")
        } else {
            XCTFail("window must end on the newest message")
        }
        if case .separator? = vm.windowedRows.first {} else {
            XCTFail("a window cut mid-day must re-synthesize its leading date separator")
        }
        await vm.extendHistoryWindow()
        XCTAssertEqual(
            vm.windowedRows.count, 201,
            "extending must reveal older local rows without a network fetch"
        )

        vm.resetHistoryWindow()
        XCTAssertEqual(
            vm.windowedRows.count, 121,
            "returning to the tail must snap the window back to its steady-state size"
        )
        if case .message(let lastItem)? = vm.windowedRows.last {
            XCTAssertEqual(lastItem.id, "m199", "a reset window is still the TAIL slice")
        } else {
            XCTFail("a reset window must end on the newest message")
        }
    }

    @MainActor
    func test_ensureWindowContains_widensToCoverARestoreTarget() async throws {
        let fake = FakeTimelineService()
        let items = (0..<200).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: .now,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertNil(
            vm.windowedRows.first { if case .message(let i) = $0 { return i.id == "m5" } ; return false },
            "precondition: the restore target starts outside the tail window"
        )
        vm.ensureWindowContains("m5")
        XCTAssertNotNil(
            vm.windowedRows.first { if case .message(let i) = $0 { return i.id == "m5" } ; return false },
            "restoring a remembered position must widen the window to cover it"
        )
        XCTAssertTrue(
            vm.isExtendingWindow,
            """
            the restore widening must hold isExtendingWindow through its \
            layout pass — restore runs with follow-tail off, and without \
            the flag the views' .sizeChanges anchor is nil while the \
            prepend lands, letting the viewport jump before the restore \
            scrollTo positions it
            """
        )
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(
            vm.isExtendingWindow,
            "the flag must release once the widening's layout pass is covered"
        )
    }

    /// 600 same-day messages — enough to exercise the cap (360) and the
    /// slide beyond it. Shared fixture for the sliding-window tests.
    @MainActor
    private func makeLongTimelineVM(count: Int = 600) async throws -> ChatViewModel {
        let fake = FakeTimelineService()
        // One timestamp for the whole fixture: per-item `.now` across a
        // midnight boundary would synthesize an extra day separator and
        // flake the exact row-count asserts (CodeRabbit, PR #166).
        let timestamp = Date.now
        let items = (0..<count).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: timestamp,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value
        return vm
    }

    @MainActor
    func test_extendHistoryWindow_capsAtMax_thenSlidesUpThroughHistory() async throws {
        let vm = try await makeLongTimelineVM()

        // 600 same-day messages + 1 separator; default window = tail 120.
        XCTAssertEqual(vm.rows.count, 601)
        XCTAssertEqual(vm.windowedRows.count, 121)
        XCTAssertTrue(vm.windowContainsTail)

        await vm.extendHistoryWindow()   // 240
        await vm.extendHistoryWindow()   // 360 = cap
        XCTAssertEqual(vm.windowedRows.count, 361, "growth stops at maxWindowSize")
        XCTAssertTrue(vm.windowContainsTail, "a capped-but-unslid window still ends at the tail")
        if case .message(let last)? = vm.windowedRows.last {
            XCTAssertEqual(last.id, "m599")
        } else { XCTFail("window must end on the newest message") }

        await vm.extendHistoryWindow()   // cap reached → slide up by 120
        XCTAssertEqual(vm.windowedRows.count, 361, "sliding must not grow the mounted row count")
        XCTAssertFalse(vm.windowContainsTail, "a slid window has detached from the live tail")
        if case .message(let last)? = vm.windowedRows.last {
            XCTAssertEqual(last.id, "m479", "slide drops the newest 120 rows off the bottom")
        } else { XCTFail("slid window must end on a message row") }
        if case .separator? = vm.windowedRows.first {} else {
            XCTFail("a mid-day window cut still re-synthesizes its leading separator")
        }
        // The revealed side: m120 must now be mounted (window m120...m479).
        XCTAssertNotNil(vm.windowedRows.first {
            if case .message(let i) = $0 { return i.id == "m120" }; return false
        })
    }

    @MainActor
    func test_revealNewerHistory_slidesDown_andReattachesAtTail() async throws {
        let vm = try await makeLongTimelineVM()

        for _ in 0..<4 { await vm.extendHistoryWindow() }  // 240, 360, slide→m479, slide→m359
        XCTAssertFalse(vm.windowContainsTail)
        if case .message(let last)? = vm.windowedRows.last { XCTAssertEqual(last.id, "m359") }
        else { XCTFail("expected a doubly-slid window") }

        vm.revealNewerHistory()   // slide down → anchored at m479
        XCTAssertFalse(vm.windowContainsTail)
        if case .message(let last)? = vm.windowedRows.last { XCTAssertEqual(last.id, "m479") }
        else { XCTFail("expected a partially-returned window") }
        XCTAssertEqual(vm.windowedRows.count, 361, "sliding down keeps the cap")

        // Each slide holds `isExtendingWindow` for 150ms as its dedup /
        // mutual-exclusion cover — a real second gesture arrives later.
        await waitFor(!vm.isExtendingWindow)
        vm.revealNewerHistory()   // next step reaches the tail → reattach
        XCTAssertTrue(vm.windowContainsTail)
        if case .message(let last)? = vm.windowedRows.last { XCTAssertEqual(last.id, "m599") }
        else { XCTFail("reattached window must end at the tail") }
    }

    @MainActor
    func test_revealNewerHistory_dedupsInsideTheExtendHold() async throws {
        let vm = try await makeLongTimelineVM()

        for _ in 0..<4 { await vm.extendHistoryWindow() }  // detached, twice slid
        XCTAssertFalse(vm.windowContainsTail)
        let anchorBefore = vm.windowTailAnchorID

        vm.revealNewerHistory()                       // slide #1 — raises the hold
        let anchorAfterFirst = vm.windowTailAnchorID
        XCTAssertNotEqual(anchorAfterFirst, anchorBefore, "the first slide must land")
        vm.revealNewerHistory()                       // same approach's second trigger
        XCTAssertEqual(vm.windowTailAnchorID, anchorAfterFirst,
            "a second slide inside the 150ms hold would skip 240 rows per approach " +
            "(geometry trigger + gesture settle both firing — review 2026-08-21)")
        await waitFor(!vm.isExtendingWindow)
    }

    @MainActor
    func test_revealNewerHistory_holdsWhenOnlyTransientRowsFollow() async throws {
        // 480 real messages, then 240 echo rows — an active turn's worth
        // of transient tail. A slide-down whose whole step lands in the
        // transient run must HOLD the current anchor, not clear it: a nil
        // anchor reattaches at the tail, teleporting the reader and
        // re-arming follow (CodeRabbit, PR #166).
        let timestamp = Date.now
        var items = (0..<480).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: timestamp,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        items += (0..<240).map { i in
            TimelineItem(
                id: "echo:\(i)", sender: "@me:s", timestamp: timestamp,
                kind: .text(body: "echo \(i)", formattedHTML: nil), isOwn: true
            )
        }
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        for _ in 0..<3 { await vm.extendHistoryWindow() }  // 240, 360, slide
        XCTAssertEqual(vm.windowTailAnchorID, "msg:m479",
            "the slide's anchor scan must skip the transient run down to the last real row")

        vm.revealNewerHistory()
        XCTAssertEqual(vm.windowTailAnchorID, "msg:m479",
            "no anchorable row strictly newer than the current anchor → hold, don't reattach")
        XCTAssertFalse(vm.windowContainsTail)
    }

    @MainActor
    func test_vanishedAnchor_rescuesToNearestSurvivingRow() async throws {
        let timestamp = Date.now   // one fixture timestamp — see makeLongTimelineVM
        let items = (0..<600).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: timestamp,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        let fake = AppendingFakeTimelineService(initial: items)
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        _ = await vm.start()

        for _ in 0..<3 { await vm.extendHistoryWindow() }  // cap, then slide → anchor m479
        XCTAssertEqual(vm.windowTailAnchorID, "msg:m479")  // anchors live in ROW-id space

        fake.remove(id: "m479")                            // redaction takes the anchor row
        await waitFor(vm.rows.count == 600)                // 599 messages + separator
        XCTAssertFalse(vm.windowContainsTail,
            "losing the anchor row must not teleport a deep reader to the tail " +
            "(and silently re-arm follow — review 2026-08-21)")
        XCTAssertEqual(vm.windowTailAnchorID, "msg:m478",
            "re-anchors on the nearest surviving neighbour of the old anchor")
        vm.stop()
    }

    @MainActor
    func test_newerRevealPinTarget_fallsBackToNewestPreSlideMessage() async throws {
        let vm = try await makeLongTimelineVM(count: 10)
        // No usable visible ids (mid-layout, separators only): the
        // fallback must be the NEWEST pre-slide message — the oldest
        // (reveal-older's fallback) is precisely the row a slide toward
        // the tail is guaranteed to drop.
        let pin = ChatViewModel.newerRevealPinTarget(
            visibleIDs: ["sep:2026-08-21"],
            preSlideRows: vm.windowedRows
        )
        XCTAssertEqual(pin, "m9")
    }

    @MainActor
    func test_ensureWindowContains_deepTarget_capsTheWindowAroundIt() async throws {
        let vm = try await makeLongTimelineVM()

        vm.ensureWindowContains("m5")
        XCTAssertNotNil(vm.windowedRows.first {
            if case .message(let i) = $0 { return i.id == "m5" }; return false
        }, "the restore target must be mounted")
        XCTAssertLessThanOrEqual(vm.windowedRows.count, 361,
            "a deep restore must not mount an unbounded window (old behavior: 597 rows)")
        XCTAssertFalse(vm.windowContainsTail, "a capped deep window cannot include the tail")
        XCTAssertTrue(vm.isExtendingWindow, "restore widening still holds the anchor flag")
    }

    @MainActor
    func test_streamAppends_doNotMoveAnAnchoredWindow() async throws {
        let timestamp = Date.now   // one fixture timestamp — see makeLongTimelineVM
        let items = (0..<600).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: timestamp,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        let fake = AppendingFakeTimelineService(initial: items)
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        _ = await vm.start()

        for _ in 0..<3 { await vm.extendHistoryWindow() } // cap then slide → detached
        XCTAssertFalse(vm.windowContainsTail)
        let before = vm.windowedRows.map(\.id)

        fake.append(TimelineItem(
            id: "m600", sender: "@a:s", timestamp: timestamp,
            kind: .text(body: "new msg", formattedHTML: nil), isOwn: false
        ))
        await waitFor(vm.rows.count == 602)
        XCTAssertEqual(vm.rows.count, 602, "the append must have landed in rows")
        XCTAssertEqual(vm.windowedRows.map(\.id), before,
            "an identity-anchored window must not shift under stream appends — " +
            "this is what makes deep reading cheap during an active turn")
        vm.stop()
    }

    @MainActor
    func test_identicalSnapshot_isSkippedWithoutRecommit() async throws {
        // The journal re-yields the full timeline on events that change
        // nothing visible; each no-op reassignment of the @Observable
        // arrays forced a full re-render of the visible window (the
        // 2026-08-05 chat-switch hang). Identical snapshots must not
        // touch `items`.
        let fake = FakeTimelineService()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        fake.snapshotsToEmit = [[item], [item]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(
            vm.appliedSnapshotCount, 1,
            "an identical re-yield must be skipped, not recommitted"
        )
    }

    @MainActor
    func test_streamBurst_coalescesToLatestSnapshot() async throws {
        // A streaming turn delivers snapshots several times a second.
        // Inside the coalesce window only the FIRST commits immediately;
        // later arrivals supersede each other and the freshest one lands
        // via the end-of-stream flush — nothing may be lost, and the
        // middle of the burst must never commit.
        func item(_ i: Int) -> TimelineItem {
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: .now,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [
            [item(0)],
            [item(0), item(1)],
            [item(0), item(1), item(2)],
        ]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        // Widen the window so the whole burst deterministically falls
        // inside it regardless of test-host scheduling.
        vm.snapshotCoalesceInterval = .seconds(5)
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.items.count, 3, "the burst's final snapshot must win")
        XCTAssertEqual(
            vm.appliedSnapshotCount, 2,
            "first snapshot immediate + flushed latest; the superseded middle must not commit"
        )
    }

    @MainActor
    func test_entryWindow_smallFirstPaint_thenSettles() async throws {
        // Room entry paints a short tail (one cheap layout transaction —
        // the 120-row build was the bulk of the chat-switch stall), then
        // settles to steady state behind the extend anchor.
        let fake = FakeTimelineService()
        let items = (0..<200).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: .now,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        vm.beginEntryWindow()   // views call this before start()
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.windowedRows.count, 41, "entry paint = 40-row tail + leading separator")
        if case .message(let lastItem)? = vm.windowedRows.last {
            XCTAssertEqual(lastItem.id, "m199", "the entry window is still the TAIL slice")
        } else {
            XCTFail("the entry window must end on the newest message")
        }

        await vm.settleEntryWindow()
        XCTAssertEqual(vm.windowedRows.count, 121, "settling must reach the steady-state window")
        XCTAssertFalse(
            vm.isExtendingWindow,
            "the settle hold must release before settleEntryWindow returns"
        )
    }

    @MainActor
    func test_beginEntryWindow_neverShrinksAGrownWindow() async throws {
        // A restore (ensureWindowContains) or a reader left up in history
        // owns a window wider than steady state; the entry shrink must
        // yield to it in either call order.
        let fake = FakeTimelineService()
        let items = (0..<200).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s", timestamp: .now,
                kind: .text(body: "msg \(i)", formattedHTML: nil), isOwn: false
            )
        }
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        vm.ensureWindowContains("m5")
        vm.beginEntryWindow()
        XCTAssertNotNil(
            vm.windowedRows.first { if case .message(let i) = $0 { return i.id == "m5" }; return false },
            "entry shrink must not yank a restore target out of the window"
        )
    }

    // MARK: isTurnRunning (floating stop button)

    /// Polls until `condition` holds (2s deadline) — the sessionState
    /// observation task runs concurrently with the drained items stream,
    /// so the flag lands a beat after `start()` returns.
    @MainActor
    private func waitFor(_ condition: @autoclosure @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func test_sessionStateRunning_setsIsTurnRunning() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        fake.sessionStatesToEmit = ["running"]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value
        await waitFor(vm.isTurnRunning)
        XCTAssertTrue(vm.isTurnRunning, "a 'running' session_state must arm the stop button")
        vm.stop()
    }

    @MainActor
    func test_sessionStateWaiting_clearsIsTurnRunning() async {
        // The turn-end signal: running → waiting must drop the flag even
        // though no timeline snapshot changed.
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        fake.sessionStatesToEmit = ["running", "waiting"]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value
        await waitFor(!vm.isTurnRunning)
        XCTAssertFalse(vm.isTurnRunning, "'waiting' (turn end) must disarm the stop button")
        vm.stop()
    }

    // MARK: historyPinTarget

    // The views pin the viewport to this target across a history-window
    // extension (non-animated proxy.scrollTo, anchor .top). The declarative
    // .sizeChanges bottom anchor only covers the prepend while
    // isExtendingWindow is up (150ms) — at a few hundred rows the eager
    // stack's layout pass outlives it, the viewport parks at the NEW head,
    // and the "first row visible" trigger re-fires: 2026-07-15 Mac trace,
    // 240→1920 rows in 14s, contentH 180Kpt, escaped only via the jump
    // button. The pin makes re-arming deterministic instead of timing-based.

    func test_historyPinTarget_picksTopmostVisibleMessageRow() {
        let pin = ChatViewModel.historyPinTarget(
            visibleIDs: ["42", "43", "44"],
            preExtendRows: []
        )
        XCTAssertEqual(pin, "42", "the topmost visible row is the pin — zero visual jump")
    }

    func test_historyPinTarget_skipsSeparatorIDs() {
        // Separator ids are day-keyed ("sep:<epoch>") and RELOCATE when the
        // window head moves: the same-day separator synthesized at the old
        // cut point re-materializes at the new head after an extension, so
        // pinning one scrolls to the wrong place — the exact jump this
        // helper exists to prevent.
        let pin = ChatViewModel.historyPinTarget(
            visibleIDs: ["sep:1752537600", "7", "8"],
            preExtendRows: []
        )
        XCTAssertEqual(pin, "7")
    }

    func test_historyPinTarget_fallsBackToFirstMessageRowOfWindow() {
        let item = TimelineItem(
            id: "m3", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        let pin = ChatViewModel.historyPinTarget(
            visibleIDs: ["sep:1752537600"],
            preExtendRows: [.separator(date: .now), .message(item)]
        )
        XCTAssertEqual(pin, "m3",
            "with no visible message row, pin the pre-extend window's first message")
    }

    func test_historyPinTarget_nilWhenNothingToPin() {
        XCTAssertNil(ChatViewModel.historyPinTarget(
            visibleIDs: ["sep:1752537600"],
            preExtendRows: [.separator(date: .now)]
        ))
        XCTAssertNil(ChatViewModel.historyPinTarget(visibleIDs: [], preExtendRows: []))
    }

    @MainActor
    func test_activityIndicator_excludedFromRows_exposedAsFooterLabel() async throws {
        // The trailing activity row is rendered as a fixed footer, not a
        // timeline row: as a row it became the scroll anchor during every
        // bot turn and died on completion — the single most routine
        // dead-anchor source in the 2026-07-13 device traces.
        let fake = FakeTimelineService()
        let msg = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        let activity = TimelineItem(
            id: "activity", sender: "agent", timestamp: .now,
            kind: .activityIndicator(label: "thinking…"), isOwn: false
        )
        fake.snapshotsToEmit = [[msg, activity]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.activityLabel, "thinking…")
        XCTAssertEqual(vm.lastRenderableItemID, "1",
            "the activity indicator must never be the anchorable tail")
        XCTAssertFalse(vm.rowAnchorIDs.contains("activity"))
        XCTAssertFalse(vm.rows.contains { row in
            if case .message(let item) = row, case .activityIndicator = item.kind { return true }
            return false
        })
    }

    @MainActor
    func test_activityLabel_clears_whenIndicatorLeavesSnapshot() async throws {
        let fake = FakeTimelineService()
        let msg = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        let activity = TimelineItem(
            id: "activity", sender: "agent", timestamp: .now,
            kind: .activityIndicator(label: "thinking…"), isOwn: false
        )
        fake.snapshotsToEmit = [[msg, activity], [msg]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertNil(vm.activityLabel)
    }

    @MainActor
    func test_scrollMemory_dropsTransientIDs() {
        ChatScrollPositionMemory._resetForTesting()
        // Transient rows (send echoes, the old in-list activity row) must
        // never be remembered as a scroll position: restoring one on
        // re-entry pins the viewport to a row that no longer exists and
        // the chat opens blank (2026-07-13 room-switch traces).
        ChatScrollPositionMemory.store(roomID: "!r:s", itemID: "echo:ABC")
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!r:s"))

        ChatScrollPositionMemory.store(roomID: "!r:s", itemID: "42")
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!r:s"), "42")
        // A transient id doesn't just fail to store — it clears the stale
        // entry, so the next open lands at the tail (where the user was).
        ChatScrollPositionMemory.store(roomID: "!r:s", itemID: "activity")
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!r:s"))

        // Streaming rows (`eph:`) are replaced by the journal row on
        // finalize — equally transient (2026-07-13 23:10 device trace).
        ChatScrollPositionMemory.store(roomID: "!r:s", itemID: "eph:msg_011abc")
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!r:s"))
    }

    func test_fileLog_appendsTimestampedLines_withSessionHeader() throws {
        MatronFileLog._resetForTesting()
        defer { MatronFileLog._resetForTesting() }

        MatronFileLog.append("first line")
        MatronFileLog.append("second line")
        MatronFileLog._flushForTesting()

        let contents = try String(contentsOf: MatronFileLog.url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "session header + two appends")
        XCTAssertTrue(lines[0].contains("=== session start pid="))
        XCTAssertTrue(lines[1].hasSuffix("first line"))
        XCTAssertTrue(lines[2].hasSuffix("second line"))
        // Every line carries a parseable timestamp prefix.
        XCTAssertTrue(lines[1].count > "yyyy-MM-dd HH:mm:ss.SSS ".count)
    }

    @MainActor
    func test_paginate_invokesService() async throws {
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.paginateBackward()
        XCTAssertEqual(fake.paginateCalls, 1)
    }

    @MainActor
    func test_markAsRead_invokesService() async throws {
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.markAsRead()
        XCTAssertEqual(fake.markReadCalls, 1)
    }

    @MainActor
    func test_start_returnsAfterFirstSnapshot_so_markAsRead_seesItems() async throws {
        // Round 3 bugbot finding #3: the View's `.task { viewModel.start();
        // await viewModel.markAsRead() }` previously raced — `start()`
        // returned the observation Task synchronously and `markAsRead()`
        // fired before any snapshot had been applied, so the SDK marked
        // an empty room as read on first open. `start()` is now `async`
        // and returns once the first snapshot has landed; this test
        // pins that ordering by asserting `items` is populated *before*
        // `markAsRead()` runs.
        let fake = FakeTimelineService()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )
        fake.snapshotsToEmit = [[item]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())

        // Mirror the View's `.task` body exactly.
        await vm.start()
        // At this point the first snapshot must already be visible so
        // `markAsRead()` marks the head of a populated timeline.
        XCTAssertEqual(vm.items.count, 1,
                       "start() must return only after the first snapshot has been applied")
        await vm.markAsRead()
        XCTAssertEqual(fake.markReadCalls, 1)
    }

    @MainActor
    func test_start_returnsPromptly_evenWhenStreamYieldsNoSnapshots() async throws {
        // Defence against `start()` hanging forever on a freshly-joined
        // room whose live timeline never emits a snapshot. The fake's
        // empty `snapshotsToEmit` mirrors that case: the AsyncStream
        // finishes without ever yielding a value. `start()` must still
        // return so the View's chained `markAsRead()` runs.
        let fake = FakeTimelineService()
        // Default `snapshotsToEmit = []` → stream finishes immediately
        // without yielding.
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())

        let outcome = await Task.detached {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { @MainActor in
                    _ = await vm.start()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return false
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
        }.value
        XCTAssertTrue(outcome,
                      "start() must return within 2s even when the stream yields no snapshots")
    }

    @MainActor
    func test_refresh_invokesPaginateBackward() async throws {
        // Mac toolbar refresh + ⌘R menu shortcut go through `refresh()`.
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.refresh()
        XCTAssertEqual(fake.paginateCalls, 1)
    }

    @MainActor
    func test_paginateError_isRecorded() async throws {
        // We don't have a `nextPaginateError` knob on the fake; instead,
        // exercise the happy path here and rely on the live impl + UI tests
        // to surface error display. This guards against the error field
        // accidentally getting set on success.
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.paginateBackward()
        XCTAssertNil(vm.error)
    }

    @MainActor
    func test_imageRequest_populatesCacheViaMediaService() async {
        // Verifies the side-effect path: calling `image(for:)` returns nil
        // synchronously (cache miss) but kicks off a fetch through
        // `MediaService` whose call we can observe on the fake. Once the
        // bytes arrive the cache populates.
        let timeline = FakeTimelineService()
        let media = FakeMediaService()
        let url = URL(string: "mxc://example/abc")!
        // 1×1 transparent PNG so `swiftUIImage(for:)` decodes successfully.
        media.stubData[url] = Self.tinyPNG
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)

        XCTAssertNil(vm.image(for: url))

        // Drain the side-effect Task. Bound by 2s so a regression surfaces
        // as a failed test rather than a hang.
        let start = Date()
        while vm.resolvedImage(for: url) == nil && Date().timeIntervalSince(start) < 2 {
            await Task.yield()
        }
        XCTAssertEqual(media.requested, [url])
        XCTAssertNotNil(vm.resolvedImage(for: url), "image cache should populate after fetch")
    }

    @MainActor
    func test_imageRequest_doesNotLoop_whenMediaServiceReturnsNil() async {
        // Regression for bugbot finding #8. When `MediaService.image(for:)`
        // returns nil (decode failure / 404), the URL was removed from
        // `inFlightRequests` but never recorded as resolved. `@Observable`
        // would re-render → `image(for:url)` re-called → cache miss, no
        // in-flight guard → another fetch fires. Forever.
        let timeline = FakeTimelineService()
        let media = FakeMediaService()
        let url = URL(string: "mxc://example/never-decodes")!
        // Stub no data → MediaServiceFake returns nil → swiftUIImage(for:)
        // returns nil too.
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)

        XCTAssertNil(vm.image(for: url))
        // Drain the first fetch.
        let start = Date()
        while media.requested.count < 1 && Date().timeIntervalSince(start) < 2 {
            await Task.yield()
        }
        // Now simulate SwiftUI re-rendering: call `image(for:)` repeatedly.
        // Each call should bail without firing another fetch.
        for _ in 0..<5 {
            XCTAssertNil(vm.image(for: url))
            await Task.yield()
        }
        // Give any erroneous in-flight task a chance to finish.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(media.requested.count, 1,
                       "failed fetch should be remembered; image(for:) must not loop")
    }

    @MainActor
    func test_imageRequest_isCoalescedWhileInFlight() async {
        // Repeated calls for the same URL while the fetch is in flight
        // should coalesce to a single MediaService request, not N.
        let timeline = FakeTimelineService()
        let media = FakeMediaService()
        let url = URL(string: "mxc://example/abc")!
        media.stubData[url] = Self.tinyPNG
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)

        _ = vm.image(for: url)
        _ = vm.image(for: url)
        _ = vm.image(for: url)

        let start = Date()
        while vm.resolvedImage(for: url) == nil && Date().timeIntervalSince(start) < 2 {
            await Task.yield()
        }
        XCTAssertEqual(media.requested.count, 1, "multiple synchronous calls should coalesce")
    }

    @MainActor
    func test_imagePixelSize_availableOnceResolved() async {
        // The Mac fullscreen viewer sizes its sheet from the bitmap's
        // native pixel size; the VM must expose it alongside the cached
        // `Image` (both come from the same decode).
        let timeline = FakeTimelineService()
        let media = FakeMediaService()
        let url = URL(string: "mxc://example/abc")!
        media.stubData[url] = Self.tinyPNG
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)

        XCTAssertNil(vm.imagePixelSize(for: url), "unresolved URL has no size")
        XCTAssertNil(vm.image(for: url))

        let start = Date()
        while vm.resolvedImage(for: url) == nil && Date().timeIntervalSince(start) < 2 {
            await Task.yield()
        }
        XCTAssertEqual(vm.imagePixelSize(for: url), CGSize(width: 1, height: 1))
    }

    /// 1×1 transparent PNG. Smallest valid PNG that decodes on both
    /// platforms. Embedded as bytes so the test target doesn't need a
    /// resource bundle.
    private static let tinyPNG: Data = {
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        return Data(bytes)
    }()

    @MainActor
    func test_upstreamStreamError_populates_errorField() async throws {
        // QA finding #10: `TimelineServiceLive.items()` previously called
        // `continuation.finish()` on any thrown error → user saw an
        // infinite spinner that never resolved into a populated timeline.
        // The stream now rethrows; the VM catches and surfaces the
        // message via `error` so the View can render an overlay.
        let fake = FakeTimelineService()
        struct StreamError: LocalizedError { var errorDescription: String? { "no timeline for room" } }
        fake.streamError = StreamError()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.start()
        // `start()` returns once the first signal fires (snapshot OR
        // error path). The error should already be populated by then,
        // but bound with a short wait for the @MainActor hop to
        // complete.
        let start = Date()
        while vm.error == nil && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.error, "no timeline for room",
                       "upstream stream error must populate error field")
    }

    @MainActor
    func test_resolvedImageCache_evicts_oldestEntry_whenLimitExceeded() async {
        // QA finding #4: a long session in a media-heavy room previously
        // accumulated `Image` references in `resolvedImages` for the
        // lifetime of the room push, separate from `MediaServiceLive`'s
        // NSCache (which evicts opaquely on memory pressure). Capping the
        // backing storage at `mediaCacheLimit` (100) bounds the upper
        // memory cost of a long-lived chat. This test pins the eviction
        // boundary so a future refactor that removes the LRU lid surfaces
        // here.
        let timeline = FakeTimelineService()
        let media = FakeMediaService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)
        // Stub `mediaCacheLimit + 1` distinct URLs with valid image bytes
        // so each one fully populates the cache, then assert the count is
        // capped and the oldest URL was evicted.
        let limit = ChatViewModel.mediaCacheLimit
        var urls: [URL] = []
        for i in 0...limit {
            let url = URL(string: "mxc://example/\(i)")!
            urls.append(url)
            media.stubData[url] = Self.tinyPNG
        }
        // Serialise the fetches so cache-insertion order matches request
        // order — `image(for:)` kicks off a background Task whose completion
        // order isn't deterministic across runtimes (the failing CI run
        // exposed it). Wait for each individual URL's fetch to land before
        // kicking off the next, so "oldest in cache" == "first requested"
        // by construction. Per-URL polling (rather than count-based) is
        // robust to LRU evictions silently dropping the count target.
        for url in urls {
            _ = vm.image(for: url)
            let start = Date()
            while vm.resolvedImage(for: url) == nil && Date().timeIntervalSince(start) < 5 {
                await Task.yield()
            }
        }
        XCTAssertEqual(vm.resolvedImageCount, limit,
                       "resolved image cache must stay bounded at mediaCacheLimit")
        XCTAssertNil(vm.resolvedImage(for: urls.first!),
                     "least-recently-used URL must be evicted once the limit is exceeded")
        XCTAssertNotNil(vm.resolvedImage(for: urls.last!),
                        "newest URL must remain cached")
    }

    @MainActor
    func test_failedRequestCache_evicts_oldestEntry_whenLimitExceeded() async {
        // Mirror of the resolved-image LRU test for the failure path —
        // a session that hits many decode failures (e.g. broken
        // thumbnails) previously remembered every URL forever via the
        // raw `Set<URL>`. Capping `failedRequests` at the same lid
        // bounds the upper memory cost (QA finding #4). Stubbing no
        // data → `MediaService.image(for:)` returns nil →
        // `swiftUIImage(for:)` returns nil → URL lands in
        // `failedRequests`.
        let timeline = FakeTimelineService()
        let media = FakeMediaService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: media)
        let limit = ChatViewModel.mediaCacheLimit
        var urls: [URL] = []
        for i in 0...limit {
            urls.append(URL(string: "mxc://example/fail/\(i)")!)
        }
        for url in urls {
            _ = vm.image(for: url)
        }
        let start = Date()
        while vm.failedRequestCount < limit && Date().timeIntervalSince(start) < 5 {
            await Task.yield()
        }
        XCTAssertEqual(vm.failedRequestCount, limit,
                       "failed-request cache must stay bounded at mediaCacheLimit")
    }

    @MainActor
    func test_hasReceivedFirstSnapshot_initiallyFalse() async {
        // Before `start()` runs the flag is false so the empty-state
        // placeholder stays hidden during sliding-sync warm-up.
        let timeline = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaService())
        XCTAssertFalse(vm.hasReceivedFirstSnapshot)
    }

    @MainActor
    func test_hasReceivedFirstSnapshot_flipsTrue_afterEmptySnapshot() async {
        // A genuinely-empty room must still flip the flag — that's the
        // signal the placeholder uses to disambiguate "still loading"
        // from "settled empty room".
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value
        XCTAssertTrue(vm.hasReceivedFirstSnapshot,
                      "first applied snapshot must flip the gate, even when empty")
    }

    @MainActor
    func test_hasReceivedFirstSnapshot_flipsTrue_evenWhenStreamYieldsNothing() async {
        // The fallback branch fires when the upstream stream finishes
        // without yielding any snapshot. Without this, freshly-joined
        // rooms whose live timeline never warms up would leave the
        // placeholder hidden forever.
        let fake = FakeTimelineService()
        // Default: no snapshots → stream finishes empty.
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value
        XCTAssertTrue(vm.hasReceivedFirstSnapshot)
    }

    @MainActor
    func test_rows_isEmpty_whenItemsEmpty() async {
        // `rows` short-circuits on empty input so an empty chat
        // doesn't render a stray separator with `now`'s date. Pinning
        // explicitly so a refactor that drops the guard surfaces here.
        let timeline = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaService())
        XCTAssertTrue(vm.rows.isEmpty)
    }

    @MainActor
    func test_rows_interleavesSeparators_betweenCalendarDays() async {
        // Three messages spanning two calendar days → two separators
        // (one at the head, one at the day boundary). The bucketing
        // is calendar-aware so we inject a fixed UTC calendar to keep
        // the assertion stable across CI timezones.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = 2026; dc.month = 3; dc.day = 1; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        let day1 = cal.date(from: dc)!
        let day1Later = cal.date(byAdding: .hour, value: 4, to: day1)!
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!

        let fake = FakeTimelineService()
        let items: [TimelineItem] = [
            TimelineItem(id: "a", sender: "@a:s", timestamp: day1,
                         kind: .text(body: "morning", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "b", sender: "@a:s", timestamp: day1Later,
                         kind: .text(body: "afternoon", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "c", sender: "@a:s", timestamp: day2,
                         kind: .text(body: "next day", formattedHTML: nil), isOwn: false),
        ]
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        vm.calendar = cal
        let task = await vm.start()
        await task.value

        let rows = vm.rows
        XCTAssertEqual(rows.count, 5,
                       "expected: separator, msg, msg, separator, msg")
        // Head separator → first cluster's day.
        if case .separator = rows[0] {} else {
            XCTFail("expected leading separator, got \(rows[0])")
        }
        // Two messages on day 1.
        if case .message(let m) = rows[1] {
            XCTAssertEqual(m.id, "a")
        } else { XCTFail("expected message a at index 1") }
        if case .message(let m) = rows[2] {
            XCTAssertEqual(m.id, "b")
        } else { XCTFail("expected message b at index 2") }
        // Boundary separator before the day-2 cluster.
        if case .separator = rows[3] {} else {
            XCTFail("expected boundary separator, got \(rows[3])")
        }
        if case .message(let m) = rows[4] {
            XCTAssertEqual(m.id, "c")
        } else { XCTFail("expected message c at index 4") }
    }

    @MainActor
    func test_rows_singleSeparator_whenAllItemsSameDay() async {
        // Sanity: three messages on the same calendar day → one head
        // separator, no day-boundary separator. Guards against the
        // bucketing logic emitting a separator on every item.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = 2026; dc.month = 3; dc.day = 1; dc.hour = 9
        dc.timeZone = TimeZone(identifier: "UTC")
        let base = cal.date(from: dc)!

        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [(0..<3).map { i in
            TimelineItem(
                id: "m\(i)", sender: "@a:s",
                timestamp: cal.date(byAdding: .hour, value: i, to: base)!,
                kind: .text(body: "msg \(i)", formattedHTML: nil),
                isOwn: false
            )
        }]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        vm.calendar = cal
        let task = await vm.start()
        await task.value

        let separators = vm.rows.filter {
            if case .separator = $0 { return true }
            return false
        }
        XCTAssertEqual(separators.count, 1,
                       "items inside one calendar day must share a single separator")
    }

    @MainActor
    func test_retrySend_forwardsToTimelineService() async throws {
        // The "Tap to retry" affordance must actually reach the service
        // layer (it shipped as a logging-only stub once — the button did
        // nothing).
        let timeline = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaService())
        vm.retrySend(itemID: "echo:abc")
        for _ in 0..<100 where timeline.retrySendCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(timeline.retrySendCalls, ["echo:abc"])
    }

    @MainActor
    func test_discardSend_forwardsToTimelineService() async throws {
        let timeline = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaService())
        vm.discardSend(itemID: "echo:abc")
        for _ in 0..<100 where timeline.discardSendCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(timeline.discardSendCalls, ["echo:abc"])
    }

    @MainActor
    func test_stop_cancelsObservationTask() async throws {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        vm.stop()
        // After `stop()`, the existing task is cancelled. Awaiting it should
        // return promptly (the fake's stream finishes anyway).
        await task.value
        // `stop()` is idempotent — calling it twice is a no-op.
        vm.stop()
    }

    // MARK: - Empty-state debounce (transient timeline-reset flash)

    @MainActor
    func test_settledEmpty_falseAfterTransientClear() async {
        // populated → empty → populated within the grace: the empty is a
        // transient sliding-sync reset, so the "no messages yet"
        // placeholder must never surface — the repopulation cancels the
        // pending flip, and settledEmpty stays false even past the grace.
        let populated = [TimelineItem(
            id: "$1", sender: "@bot:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false
        )]
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [populated, [], populated]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        vm.emptyPlaceholderGraceMs = 30
        let task = await vm.start()
        await task.value
        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(vm.settledEmpty, "a transient clear+repopulate must not flash the empty placeholder")
    }

    @MainActor
    func test_settledEmpty_trueForGenuinelyEmptyRoom() async {
        // Empty and stays empty past the grace → the placeholder settles
        // in (a real empty room still shows "no messages yet").
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        vm.emptyPlaceholderGraceMs = 30
        let task = await vm.start()
        await task.value
        await waitUntil { vm.settledEmpty }
        XCTAssertTrue(vm.settledEmpty, "a room still empty past the grace shows the placeholder")
    }

    /// Polls until `predicate` is true or the timeout elapses — deterministic
    /// replacement for fixed `Task.sleep`-then-assert, which flakes for
    /// "becomes true after a debounce" assertions under CI load. Exits the
    /// moment the predicate passes, so the happy path stays fast.
    @MainActor
    private func waitUntil(timeoutMs: Int = 2000, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Foreground resume (lock→unlock re-sync; bug repro 2026-06-13)

    @MainActor
    func test_handleForeground_suppressesPlaceholderDuringResync() async {
        // App returns from background; the timeline rebuild clears for
        // longer than the normal empty grace. The placeholder must stay
        // hidden through that window, then content arrival keeps it hidden.
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: FakeMediaService())
        vm.emptyPlaceholderGraceMs = 20
        vm.resumeGraceMs = 600
        vm.handleForeground()
        vm.updateSettledEmpty(isEmpty: true)         // the resync clear
        try? await Task.sleep(for: .milliseconds(60)) // past empty grace, within ceiling
        XCTAssertFalse(vm.settledEmpty, "no placeholder while resuming/re-syncing")
        vm.updateSettledEmpty(isEmpty: false)        // messages came back
        XCTAssertFalse(vm.settledEmpty)
    }

    @MainActor
    func test_handleForeground_showsPlaceholderForGenuinelyEmptyRoom_afterCeiling() async {
        // A genuinely empty room: no content arrives during the resume
        // window, so once the ceiling elapses the placeholder settles in.
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: FakeMediaService())
        vm.emptyPlaceholderGraceMs = 20
        vm.resumeGraceMs = 60
        vm.handleForeground()
        vm.updateSettledEmpty(isEmpty: true)
        // Poll (not a fixed sleep) so the chained ceiling+grace timers can
        // land under CI load without flaking.
        await waitUntil { vm.settledEmpty }
        XCTAssertTrue(vm.settledEmpty, "empty room shows placeholder once re-sync ceiling passes")
    }

    @MainActor
    func test_handleForeground_contentArrivalEndsResumeWindow() async {
        // Once content returns, the resume suppression ends — a LATER
        // empty timeline clear debounces normally (not held by a stale
        // resume window).
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: FakeMediaService())
        vm.emptyPlaceholderGraceMs = 20
        vm.resumeGraceMs = 5_000
        vm.handleForeground()
        vm.updateSettledEmpty(isEmpty: false)        // content back → window ends
        vm.updateSettledEmpty(isEmpty: true)         // a later normal clear
        await waitUntil { vm.settledEmpty }
        XCTAssertTrue(vm.settledEmpty, "after content ended the resume window, normal empty debounce resumes")
    }

    // MARK: - pendingAsk (Phase 5 Task 11)

    private static let askDefaultsKey = "matron.answeredPrompts.!ask-room:s"

    @MainActor
    private func makeAskVM(items: [TimelineItem]) async -> ChatViewModel {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!ask-room:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value
        return vm
    }

    private func askItem(id: String, expiresAt: Date? = nil) -> TimelineItem {
        TimelineItem(
            id: id, sender: "@bot:s", timestamp: .now,
            kind: .askUser(
                eventID: id,
                AskUserEvent(prompt: "Q?", kind: .text, expiresAt: expiresAt)
            ),
            isOwn: false
        )
    }

    /// A bridge queued_release card: choice buttons plus the bridge prompt
    /// id releases resolve against.
    private func queuedCardItem(id: String, promptID: String) -> TimelineItem {
        TimelineItem(
            id: id, sender: "@bot:s", timestamp: .now,
            kind: .askUser(
                eventID: id,
                AskUserEvent(
                    prompt: "Send all 2 queued messages now, or cancel this one?",
                    kind: .choice(options: [
                        .init(id: "send", label: "⚡ Send all now", value: "send"),
                        .init(id: "cancel", label: "✕ Cancel this", value: "cancel"),
                    ], allowOther: false),
                    expiresAt: nil, replyChannel: .buttonResponse,
                    queuedReleasePromptID: promptID
                )
            ),
            isOwn: false
        )
    }

    /// The bridge's release row as the mapper hides it: a namespaced
    /// answer that is NOT ours (the bridge authored it).
    private func releaseItem(id: String, promptID: String, action: String = "send") -> TimelineItem {
        TimelineItem(
            id: id, sender: "agent:bridge", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "qr:\(promptID)", selectedValues: [action]),
            isOwn: false
        )
    }

    // MARK: - queued_release resolution (stale buttons after a flush)

    @MainActor
    func test_isPromptAnswered_viaQueuedRelease_despiteNotOwn() async {
        // A "Send all now" tap on ONE card flushes the whole queue; the
        // bridge emits a release per flushed card. Those releases are
        // bridge-authored (not isOwn) and must still retire the buttons —
        // the queue action happened regardless of which device tapped.
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            releaseItem(id: "$9", promptID: "pr_a"),
        ])
        XCTAssertTrue(vm.isPromptAnswered("$1"))
    }

    @MainActor
    func test_queuedRelease_leavesSiblingCardsLive() async {
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            queuedCardItem(id: "$2", promptID: "pr_b"),
            releaseItem(id: "$9", promptID: "pr_a"),
        ])
        XCTAssertTrue(vm.isPromptAnswered("$1"))
        XCTAssertFalse(vm.isPromptAnswered("$2"),
                       "a release names one prompt; other queued cards stay actionable")
    }

    @MainActor
    func test_answerSummary_mapsReleaseActionThroughCardOptions() async {
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            releaseItem(id: "$9", promptID: "pr_a", action: "send"),
        ])
        XCTAssertEqual(vm.answerSummary(forPrompt: "$1"), "⚡ Send all now")
    }

    @MainActor
    func test_answerSummary_expiredRelease_isNil() async {
        // Boot reconcile emits terminal `expired` releases for orphaned
        // cards. No option matches; the card shows its generic resolved
        // state rather than "You chose: expired".
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            releaseItem(id: "$9", promptID: "pr_a", action: "expired"),
        ])
        XCTAssertTrue(vm.isPromptAnswered("$1"))
        XCTAssertNil(vm.answerSummary(forPrompt: "$1"))
    }

    @MainActor
    func test_pendingAsk_skipsReleaseResolvedCard() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            releaseItem(id: "$9", promptID: "pr_a"),
        ])
        XCTAssertNil(vm.pendingAsk())
    }

    @MainActor
    func test_queuedRelease_earliestWins_sendThenExpired() async {
        // The realistic double-release: a committed `send` that was never
        // acked, then boot reconcile's terminal `expired` for the same
        // prompt_id. The earliest release wins — the queue really was
        // flushed, so the card keeps reporting the send that happened
        // rather than downgrading to the generic resolved state.
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            releaseItem(id: "$8", promptID: "pr_a", action: "send"),
            releaseItem(id: "$9", promptID: "pr_a", action: "expired"),
        ])
        XCTAssertTrue(vm.isPromptAnswered("$1"))
        XCTAssertEqual(vm.answerSummary(forPrompt: "$1"), "⚡ Send all now")
    }

    @MainActor
    func test_releaseRow_neverEntersRows() async {
        // The whole design rests on release rows being invisible: they
        // must not become rows, day separators, or scroll anchors.
        let vm = await makeAskVM(items: [
            queuedCardItem(id: "$1", promptID: "pr_a"),
            releaseItem(id: "$9", promptID: "pr_a"),
        ])
        let messageIDs = vm.rows.compactMap { row -> String? in
            if case .message(let item) = row { return item.id }
            return nil
        }
        XCTAssertEqual(messageIDs, ["$1"], "the hidden release row must not render")
        let separators = vm.rows.filter { if case .separator = $0 { return true } else { return false } }
        XCTAssertEqual(separators.count, 1, "a release must not mint its own day separator")
    }

    @MainActor
    func test_pendingAsk_returnsMostRecentUnansweredPrompt() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let vm = await makeAskVM(items: [askItem(id: "$1"), askItem(id: "$2")])
        XCTAssertEqual(vm.pendingAsk()?.id, "$2")
    }

    @MainActor
    func test_pendingAsk_excludesAnsweredPrompts_evenAfterRedelivery() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let vm = await makeAskVM(items: [askItem(id: "$1")])
        XCTAssertNotNil(vm.pendingAsk())

        vm.markPromptAnswered("$1")

        // Simulate push re-decrypt: a fresh VM (new launch) receives
        // the same event again — the UserDefaults persistence is what
        // stops the re-pop.
        let vm2 = await makeAskVM(items: [askItem(id: "$1")])
        XCTAssertNil(vm2.pendingAsk(), "answered prompt must not re-pop")
    }

    @MainActor
    func test_pendingAsk_surfacesOlderPrompt_onceNewestIsAnswered() async {
        // Contract behind the sheet's `onDismiss` re-query (PR #6
        // bugbot pass 1): with two unanswered prompts in the timeline,
        // closing/answering the newest must surface the older one on
        // the next query — not leave it hidden until a later snapshot.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let vm = await makeAskVM(items: [askItem(id: "$1"), askItem(id: "$2")])
        XCTAssertEqual(vm.pendingAsk()?.id, "$2")

        vm.markPromptAnswered("$2")
        XCTAssertEqual(vm.pendingAsk()?.id, "$1", "older unanswered prompt must surface next")
    }

    @MainActor
    func test_pendingAsk_clearedBy_buttonResponseInTimeline() async {
        // Cross-device: the answer arrives as a chat.matron.
        // button_response event in the timeline, not via this
        // device's UserDefaults.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let answer = TimelineItem(
            id: "$2", sender: "@me:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "$1", selectedValues: ["yes"]),
            isOwn: true
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), answer])
        XCTAssertNil(vm.pendingAsk())
    }

    @MainActor
    func test_pendingAsk_clearedBy_ownReplyInTimeline() async {
        // Cross-device for the ask_user text channel: one of the
        // user's own messages replying (m.in_reply_to) to the prompt.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let reply = TimelineItem(
            id: "$2", sender: "@me:s", timestamp: .now,
            kind: .text(body: "answer", formattedHTML: nil),
            isOwn: true,
            inReplyToEventID: "$1"
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), reply])
        XCTAssertNil(vm.pendingAsk())
    }

    @MainActor
    func test_pendingAsk_persistsCrossDeviceAnswer_acrossSnapshots() async {
        // Bugbot PR #6 finding "cross-device answers not persisted":
        // once a snapshot shows the answer event, the answered state
        // must be folded into UserDefaults — a later snapshot (or a
        // fresh timeline whose encrypted answer lags decryption) that
        // contains the prompt WITHOUT the answer must not re-pop it.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let answer = TimelineItem(
            id: "$2", sender: "@me:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "$1", selectedValues: ["yes"]),
            isOwn: true
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), answer])
        XCTAssertNil(vm.pendingAsk(), "answer visible in timeline")

        // Fresh VM, prompt present but answer event missing (decrypt
        // lag / re-delivery window) — persisted knowledge must hold.
        let vm2 = await makeAskVM(items: [askItem(id: "$1")])
        XCTAssertNil(vm2.pendingAsk(), "cross-device answer must survive the snapshot losing the answer event")
    }

    @MainActor
    func test_persistVisibleAnswers_keepsInlineCardResolved_acrossSnapshots() async {
        // Bugbot PR #10 finding "cross-device answers not persisted":
        // the inline AskUserCard reads answered-state via
        // `isPromptAnswered`, not `pendingAsk()`. The views call
        // `persistVisibleAnswers()` on every snapshot, so once the answer
        // event is seen it's folded into UserDefaults. A later snapshot
        // that drops the answer event (or a fresh launch whose encrypted
        // answer lags decryption) must keep the card resolved rather than
        // re-enabling a duplicate reply.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let answer = TimelineItem(
            id: "$2", sender: "@me:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "$1", selectedValues: ["yes"]),
            isOwn: true
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), answer])
        vm.persistVisibleAnswers()
        XCTAssertTrue(vm.isPromptAnswered("$1"), "answer visible in timeline")

        // Fresh VM, prompt present but answer event missing — only the
        // persisted fold keeps the card resolved.
        let vm2 = await makeAskVM(items: [askItem(id: "$1")])
        XCTAssertTrue(
            vm2.isPromptAnswered("$1"),
            "inline card must stay resolved after the answer event drops from the snapshot"
        )
    }

    @MainActor
    func test_pendingAsk_notClearedBy_othersReplies() async {
        // A reply from someone ELSE (e.g. the bot threading a follow-
        // up onto its own prompt) must not count as the user's answer.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let botReply = TimelineItem(
            id: "$2", sender: "@bot:s", timestamp: .now,
            kind: .text(body: "any thoughts?", formattedHTML: nil),
            isOwn: false,
            inReplyToEventID: "$1"
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), botReply])
        XCTAssertEqual(vm.pendingAsk()?.id, "$1")
    }

    @MainActor
    func test_pendingAsk_notClearedBy_othersButtonResponse() async {
        // A `button_response` from ANOTHER member (isOwn=false) in a
        // multi-user room must not suppress the prompt for us (bugbot
        // "Others' button answers dismiss sheet").
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let othersAnswer = TimelineItem(
            id: "$2", sender: "@someone-else:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "$1", selectedValues: ["yes"]),
            isOwn: false
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), othersAnswer])
        XCTAssertEqual(vm.pendingAsk()?.id, "$1", "another user's button answer must not count as ours")
    }

    @MainActor
    func test_pendingAsk_skipsExpiredPrompts() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let vm = await makeAskVM(items: [
            askItem(id: "$1", expiresAt: Date.now.addingTimeInterval(-10))
        ])
        XCTAssertNil(vm.pendingAsk(), "expired prompt must not pop a dead sheet")
    }

    // MARK: - isPromptAnswered (open-sheet close decision; bugbot PR #6)

    @MainActor
    func test_isPromptAnswered_trueOnlyWhenAnsweredHereOrCrossDevice() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let answer = TimelineItem(
            id: "$2", sender: "@me:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "$x", selectedValues: ["yes"]),
            isOwn: true
        )
        // Another member's button answer (isOwn=false) for $other must
        // NOT count (bugbot "Others' button answers dismiss sheet").
        let othersAnswer = TimelineItem(
            id: "$3", sender: "@someone-else:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "$other", selectedValues: ["no"]),
            isOwn: false
        )
        let vm = await makeAskVM(items: [askItem(id: "$1"), askItem(id: "$x"), askItem(id: "$other"), answer, othersAnswer])
        // $1 unanswered → false (an open sheet for it must NOT close).
        XCTAssertFalse(vm.isPromptAnswered("$1"))
        // $x answered by us cross-device (own button_response) → true.
        XCTAssertTrue(vm.isPromptAnswered("$x"))
        // $other answered only by someone else → still false for us.
        XCTAssertFalse(vm.isPromptAnswered("$other"))
        // Marking $1 answered on this device flips it.
        vm.markPromptAnswered("$1")
        XCTAssertTrue(vm.isPromptAnswered("$1"))
    }

    @MainActor
    func test_isPromptAnswered_falseWhenItemsTransientlyEmpty() async {
        // Finding "Ask sheet drops on clear": during a sliding-sync clear
        // `items` is momentarily empty. An unanswered prompt must read as
        // NOT answered so the view keeps the open sheet (and its
        // in-progress input) rather than dismissing it.
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let vm = await makeAskVM(items: [])
        XCTAssertFalse(vm.isPromptAnswered("$1"))
    }

    @MainActor
    func test_answeredPromptIDs_persistAcrossInstances() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        do {
            let vm = await makeAskVM(items: [askItem(id: "$persist-1")])
            vm.markPromptAnswered("$persist-1")
        }
        // New ViewModel instance, same room → loads from UserDefaults.
        let vm2 = await makeAskVM(items: [askItem(id: "$persist-1")])
        XCTAssertNil(vm2.pendingAsk())
    }

    // MARK: - Inline ask-user cards (askViewModel cache + answerSummary)

    @MainActor
    func test_askViewModel_isStablePerPrompt() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let prompt = TimelineItem(
            id: "p1", sender: "@bot:s", timestamp: .now,
            kind: .askUser(eventID: "p1", AskUserEvent(
                prompt: "Q", kind: .choice(options: [
                    AskUserEvent.Option(id: "s", label: "Send", value: "send:0")
                ], allowOther: false), expiresAt: nil, replyChannel: .buttonResponse)),
            isOwn: false
        )
        let vm = await makeAskVM(items: [prompt])
        let first = vm.askViewModel(forPrompt: "p1")
        let second = vm.askViewModel(forPrompt: "p1")
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "same prompt must return the same cached VM")
        XCTAssertNil(vm.askViewModel(forPrompt: "missing"))
    }

    @MainActor
    func test_answerSummary_buttons_mapsValuesToLabels() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let prompt = TimelineItem(
            id: "p1", sender: "@bot:s", timestamp: .now,
            kind: .askUser(eventID: "p1", AskUserEvent(
                prompt: "Q", kind: .choice(options: [
                    AskUserEvent.Option(id: "s", label: "Send", value: "send:0"),
                    AskUserEvent.Option(id: "c", label: "Cancel", value: "cancel:0"),
                ], allowOther: false), expiresAt: nil, replyChannel: .buttonResponse)),
            isOwn: false
        )
        let answer = TimelineItem(
            id: "a1", sender: "@me:s", timestamp: .now,
            kind: .askUserAnswer(promptEventID: "p1", selectedValues: ["send:0"]),
            isOwn: true
        )
        let vm = await makeAskVM(items: [prompt, answer])
        XCTAssertEqual(vm.answerSummary(forPrompt: "p1"), "Send")
        XCTAssertNil(vm.answerSummary(forPrompt: "p1-unanswered"))
    }

    @MainActor
    func test_answerSummary_textReply_returnsReplyBody() async {
        UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.askDefaultsKey) }
        let prompt = TimelineItem(
            id: "p2", sender: "@bot:s", timestamp: .now,
            kind: .askUser(eventID: "p2", AskUserEvent(prompt: "Workdir?", kind: .text, expiresAt: nil)),
            isOwn: false
        )
        let reply = TimelineItem(
            id: "r1", sender: "@me:s", timestamp: .now,
            kind: .text(body: "src/", formattedHTML: nil), isOwn: true,
            sendState: .sent, inReplyToEventID: "p2"
        )
        let vm = await makeAskVM(items: [prompt, reply])
        XCTAssertEqual(vm.answerSummary(forPrompt: "p2"), "src/")
    }

    @MainActor
    func testSessionStatusSubscriptionMergesPartialFrames() async throws {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        defer { vm.stop() }
        await task.value

        fake.statusContinuation.yield(SessionStatusUpdate(
            convoID: "!r:s", model: nil,
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil, email: nil, taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
        for _ in 0..<200 {
            if vm.sessionStatus?.context != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.sessionStatus?.context?.pct, 10)

        // A model-only frame must not clear the held context.
        fake.statusContinuation.yield(SessionStatusUpdate(
            convoID: "!r:s", model: "claude-fable-5", context: nil, limits: nil, email: nil, taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
        for _ in 0..<200 {
            if vm.sessionStatus?.model != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.sessionStatus?.model, "claude-fable-5")
        XCTAssertEqual(vm.sessionStatus?.context?.pct, 10)
    }

    /// `start()` must drop held meters: they're only as fresh as the
    /// engine's status replay cache, which yields valid data back
    /// immediately on re-subscribe — but after a mirror wipe cleared that
    /// cache, carrying the old merge across stop()/start() would present
    /// pre-wipe usage as current.
    @MainActor
    func testSessionStatusClearedOnRestart() async throws {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        defer { vm.stop() }
        await task.value

        fake.statusContinuation.yield(SessionStatusUpdate(
            convoID: "!r:s", model: nil,
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil, email: nil, taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
        for _ in 0..<200 {
            if vm.sessionStatus?.context != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.sessionStatus?.context?.pct, 10)

        vm.stop()
        fake.snapshotsToEmit = [[]]
        let task2 = await vm.start()
        await task2.value
        XCTAssertNil(vm.sessionStatus,
                     "restart must drop held meters; no frame has arrived on the new subscription yet")
    }

    /// The Compact buttons (Mac header, iOS session sheet) send "/compact"
    /// through the view model rather than the composer — a button-triggered
    /// command must not touch the composer's draft, history, or tray.
    @MainActor
    func test_sendCommand_sendsBodyAsPlainText() async {
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())

        await vm.sendCommand("/compact")

        XCTAssertEqual(fake.sentText, ["/compact"])
        XCTAssertEqual(fake.sentInReplyTo, [nil])
    }

    /// Repeated taps on a Compact affordance (banner or button) must not
    /// queue a second bare /compact while the first is still in flight —
    /// the second call returns without sending.
    @MainActor
    func test_sendCommand_ignoresSecondCallWhileFirstInFlight() async throws {
        let fake = FakeTimelineService()
        let gate = SendGate()
        fake.sendGate = gate
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())

        let first = Task { await vm.sendCommand("/compact") }
        for _ in 0..<200 where !(await gate.isStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await gate.isStarted()
        XCTAssertTrue(started, "first send never reached the service")

        // Second tap while the first send is parked at the gate.
        await vm.sendCommand("/compact")

        await gate.open()
        await first.value
        XCTAssertEqual(fake.sentText, ["/compact"],
                       "the in-flight guard must swallow the second tap")
    }

    /// The guard is a latch only for the in-flight window — once the first
    /// command completes, the next tap sends again.
    @MainActor
    func test_sendCommand_allowsNextCommandAfterCompletion() async {
        let fake = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())

        await vm.sendCommand("/compact")
        await vm.sendCommand("/compact")

        XCTAssertEqual(fake.sentText, ["/compact", "/compact"])
    }

    // MARK: - Summary TOC entries

    /// `summaryEntriesStream()` frames flow through to published state
    /// unchanged (order, newest-first, preserved from the service).
    @MainActor
    func testSummaryEntriesFlowFromServiceToViewModel() async {
        let fake = FakeTimelineService()
        fake.summaryEntriesToEmit = [
            ConversationSummaryEntry(seq: 40, toc: "Newer", detail: "d2", date: .init(timeIntervalSince1970: 2)),
            ConversationSummaryEntry(seq: 10, toc: "Older", detail: "d1", date: .init(timeIntervalSince1970: 1)),
        ]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.start()
        await waitUntil { vm.summaryEntries.count == 2 }
        XCTAssertEqual(vm.summaryEntries.map(\.seq), [40, 10])
        vm.stop()
    }

    // MARK: - focus(seq:) jump-to-message

    /// Seeds a VM with one fully-loaded snapshot of text messages whose
    /// ids are `String(seq)` for each seq in `seqs` (ascending, matching
    /// `JournalTimelineMapper`'s convention) — the plain case, no
    /// pagination involved.
    @MainActor
    private func makeVMWithMessages(seqs: [Int]) async -> ChatViewModel {
        let items = seqs.map { seq in
            TimelineItem(
                id: String(seq), sender: "@a:s", timestamp: .now,
                kind: .text(body: "msg \(seq)", formattedHTML: nil), isOwn: false
            )
        }
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.start()
        return vm
    }

    /// Seeds a VM on `PagingFakeTimelineService`: `loaded` is the
    /// initially-available window, `olderPages` is the queue of pages a
    /// `paginateBackward()` call reveals one at a time (oldest page
    /// last, matching pagination order). Every seq across every range
    /// becomes a text message row with id `String(seq)`.
    @MainActor
    private func makeVMWithPagedHistory(
        loaded: [ClosedRange<Int>], olderPages: [[ClosedRange<Int>]]
    ) async -> ChatViewModel {
        func items(for ranges: [ClosedRange<Int>]) -> [TimelineItem] {
            ranges.flatMap { range in
                range.map { seq in
                    TimelineItem(
                        id: String(seq), sender: "@a:s", timestamp: .now,
                        kind: .text(body: "msg \(seq)", formattedHTML: nil), isOwn: false
                    )
                }
            }
        }
        let fake = PagingFakeTimelineService(
            loaded: items(for: loaded),
            olderPages: olderPages.map(items(for:))
        )
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        await vm.start()
        return vm
    }

    @MainActor
    func testFocusPicksNearestRowAtOrBeforeSeq() async {
        let vm = await makeVMWithMessages(seqs: [10, 20, 30, 40])
        await vm.focus(seq: 35)
        XCTAssertEqual(vm.pendingFocusID, "30")   // nearest message with seq <= 35
    }

    @MainActor
    func testFocusPaginatesBackwardUntilTargetLoaded() async {
        // Target seq 150 only appears after two paginateBackward calls
        // (page 200...299, then page 100...199).
        let vm = await makeVMWithPagedHistory(
            loaded: [300...340], olderPages: [[200...299], [100...199]]
        )
        await vm.focus(seq: 150)
        XCTAssertEqual(vm.pendingFocusID, "150")
    }

    @MainActor
    func testFocusLandsOnOldestWhenRegionUnavailable() async {
        // No older pages queued, so every paginateBackward() call is a
        // genuine (uncontended) no-growth no-op. focus()'s loop bails to
        // the oldest-row fallback on the first such call rather than
        // waiting out `reachedHistoryStart`'s full 2-consecutive-call
        // latch — see the no-progress-bail branch in `focus(seq:)`.
        let vm = await makeVMWithPagedHistory(loaded: [300...340], olderPages: [])
        await vm.focus(seq: 5)
        XCTAssertEqual(vm.pendingFocusID, "300")   // oldest available row
    }

    /// Regression pin for the reentrancy-guard finding on commit 1beb4a9:
    /// `ChatViewModel.paginateBackward()`'s reentrancy guard
    /// (`if isPaginatingBackward { return }`) early-returns with no
    /// suspension point, so a `focus(seq:)` loop that just called
    /// `await paginateBackward()` in a bare `while` — trusting it to
    /// always grow `items` or advance `reachedHistoryStart` — could spin
    /// the MainActor forever the moment ANY call (contended or, as here,
    /// a fake that never grows and never latches) fails to move either.
    /// This fake models that: no older pages are ever queued, so every
    /// `paginateBackward()` call is a permanent no-op — the loop must
    /// still terminate (via the no-contention no-progress bail) and land
    /// on the oldest row, not hang. Bounded by an explicit timeout so a
    /// regression fails the assertion instead of hanging the test run.
    @MainActor
    func testFocusBailsWithoutSpinning_whenPaginationNeverProgressesOrLatches() async {
        let vm = await makeVMWithPagedHistory(loaded: [300...340], olderPages: [])

        let finished = await Task.detached {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { @MainActor in
                    await vm.focus(seq: 5)
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    return false
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
        }.value

        XCTAssertTrue(finished, "focus(seq:) must bail rather than spin when pagination never progresses")
        XCTAssertEqual(vm.pendingFocusID, "300", "falls back to the oldest loaded row")
    }

    /// Single-flight guard: a second `focus(seq:)` call must supersede an
    /// in-flight first call rather than race it. Seq 150 needs two
    /// `paginateBackward()` calls to load (exercising the while-loop this
    /// test wants cancelled mid-flight); seq 320 is already in the
    /// initial window, so its call resolves immediately once it gets the
    /// MainActor. Without the `focusTask` single-flight guard, both calls
    /// could independently write `pendingFocusID`, and whichever happened
    /// to finish last — not whichever was requested last — would win.
    @MainActor
    func testFocusSingleFlight_secondCallSupersedesFirst() async {
        let vm = await makeVMWithPagedHistory(
            loaded: [300...340], olderPages: [[200...299], [100...199]]
        )
        let first = Task { await vm.focus(seq: 150) }
        let second = Task { await vm.focus(seq: 320) }
        await first.value
        await second.value
        XCTAssertEqual(vm.pendingFocusID, "320", "second call supersedes the first; exactly one pending focus survives")
    }

    /// Regression pin for the post-loop cancellation check (re-review R3):
    /// `performFocus`'s paginate loop can also exit via the uncontended
    /// `break` (no growth, nothing else in flight) rather than the
    /// loop-top `Task.isCancelled` check — that path used to fall
    /// straight through to the unconditional `pendingFocusID` write with
    /// no cancellation check in between, letting a superseded task land
    /// its fallback target over a newer call's. Seq 150 sits outside the
    /// loaded window with NO older pages queued, so the first call's
    /// `paginateBackward()` makes no progress and its loop exits via
    /// `break`. `Task.yield()` after starting the first call gives it a
    /// chance to actually begin (and reach its own suspension points)
    /// before the second call cancels it.
    @MainActor
    func testFocusSingleFlight_cancelledBreakPath_doesNotLandFallback() async {
        let vm = await makeVMWithPagedHistory(loaded: [300...340], olderPages: [])
        let first = Task { await vm.focus(seq: 150) }
        await Task.yield()
        let second = Task { await vm.focus(seq: 320) }
        await first.value
        await second.value
        XCTAssertEqual(
            vm.pendingFocusID, "320",
            "the cancelled first call's break-path fallback must not land over the second call's target")
    }

    // MARK: - hasMultipleSenders

    /// A 1:1 chat — everything from a single bot sender plus the user's
    /// own messages — must NOT flip the flag. Own messages are excluded
    /// from the distinct-sender count even though there's only one of
    /// them here; the point is the single bot sender alone isn't enough.
    @MainActor
    func testHasMultipleSenders_singleNonOwnSender_isFalse() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[
            TimelineItem(id: "1", sender: "matron", timestamp: .now,
                         kind: .text(body: "hi", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "2", sender: "matron", timestamp: .now,
                         kind: .text(body: "again", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "3", sender: "me", timestamp: .now,
                         kind: .text(body: "ok", formattedHTML: nil), isOwn: true),
        ]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertFalse(vm.hasMultipleSenders)
    }

    /// No messages at all — the degenerate 0-sender case must not crash
    /// or false-positive.
    @MainActor
    func testHasMultipleSenders_noItems_isFalse() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertFalse(vm.hasMultipleSenders)
    }

    /// The agent-chat case this whole feature exists for: two distinct
    /// non-own senders (e.g. "dev-2" and "dan-mac" both replying) must
    /// flip the flag.
    @MainActor
    func testHasMultipleSenders_twoDistinctNonOwnSenders_isTrue() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[
            TimelineItem(id: "1", sender: "dev-2", timestamp: .now,
                         kind: .text(body: "on it", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "2", sender: "dan-mac", timestamp: .now,
                         kind: .text(body: "roger", formattedHTML: nil), isOwn: false),
        ]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertTrue(vm.hasMultipleSenders)
    }

    /// Own messages must not count toward the distinct-sender total even
    /// when their `sender` string differs from the single bot's — the
    /// flag is specifically about attributing NON-own bubbles.
    @MainActor
    func testHasMultipleSenders_ownMessagesExcludedFromCount() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[
            TimelineItem(id: "1", sender: "matron", timestamp: .now,
                         kind: .text(body: "hi", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "2", sender: "dan", timestamp: .now,
                         kind: .text(body: "hey", formattedHTML: nil), isOwn: true),
        ]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertFalse(vm.hasMultipleSenders,
                       "the own sender must not count toward the distinct non-own total")
    }

    /// Regression for the mid-turn false positive: an ordinary 1:1 chat
    /// (single real bot sender "matron") plus the ephemeral
    /// `.activityIndicator` and `.toolStreamLive` overlay rows the mapper
    /// synthesises during a turn — both hardcode `sender: "agent"` — must
    /// NOT flip the flag. Only `.text` / `.image` / `.file` durable kinds
    /// count.
    @MainActor
    func testHasMultipleSenders_ephemeralActivityAndToolStreamRows_areExcluded() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[
            TimelineItem(id: "1", sender: "matron", timestamp: .now,
                         kind: .text(body: "hi", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "activity", sender: "agent", timestamp: .now,
                         kind: .activityIndicator(label: "Thinking…"), isOwn: false),
            TimelineItem(id: "toolstream:1", sender: "agent", timestamp: .now,
                         kind: .toolStreamLive(messageRef: "1", command: "ls", text: "", headTruncated: false),
                         isOwn: false),
        ]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertFalse(vm.hasMultipleSenders,
                       "activityIndicator / toolStreamLive ephemeral rows must not count as senders")
    }

    /// The mid-turn streaming placeholder row (`JournalTimelineMapper
    /// .streamingItem`) borrows the real `.text` kind so it renders as a
    /// normal bubble while a reply streams in — but it hardcodes
    /// `sender: "agent"` and its id is prefixed `"eph:"`. A pure kind
    /// filter would still miscount it; it must be excluded by id too.
    @MainActor
    func testHasMultipleSenders_ephemeralStreamingTextRow_isExcluded() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[
            TimelineItem(id: "1", sender: "matron", timestamp: .now,
                         kind: .text(body: "hi", formattedHTML: nil), isOwn: false),
            JournalTimelineMapper.streamingItem(messageRef: "1", text: "partial reply…", convoTS: .now),
        ]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertFalse(vm.hasMultipleSenders,
                       "the 'eph:' streaming placeholder row must not count as a second sender")
    }

    /// Two REAL distinct bot text senders plus ephemeral overlay rows
    /// still flip the flag — the ephemeral exclusion must not mask a
    /// genuine agent-chat multi-sender room.
    @MainActor
    func testHasMultipleSenders_twoRealSendersPlusEphemerals_isTrue() async {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[
            TimelineItem(id: "1", sender: "dev-2", timestamp: .now,
                         kind: .text(body: "on it", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "2", sender: "dan-mac", timestamp: .now,
                         kind: .text(body: "roger", formattedHTML: nil), isOwn: false),
            TimelineItem(id: "activity", sender: "agent", timestamp: .now,
                         kind: .activityIndicator(label: "Thinking…"), isOwn: false),
            TimelineItem(id: "toolstream:1", sender: "agent", timestamp: .now,
                         kind: .toolStreamLive(messageRef: "1", command: "ls", text: "", headTruncated: false),
                         isOwn: false),
        ]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertTrue(vm.hasMultipleSenders)
    }
}
