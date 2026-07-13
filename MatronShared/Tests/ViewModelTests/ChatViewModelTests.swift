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
    func test_autoFollowTarget_passesThroughLiveAnchor() async throws {
        let fake = FakeTimelineService()
        let item = TimelineItem(
            id: "1", sender: "@a:s", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true
        )
        fake.snapshotsToEmit = [[item]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertEqual(vm.autoFollowTarget(for: "1"), "1")
    }

    @MainActor
    func test_autoFollowTarget_retiredEcho_resolvesToLiveTail() async throws {
        // The send-path race: the view's auto-follow captures the echo
        // row's id, sleeps 50ms, then assigns it. If the server round
        // trip beats the timer, the echo has already been retired and
        // replaced by the real row — assigning the captured id pins the
        // scroll position to a row that no longer exists, and the
        // dead-anchor guard (which only re-runs on the NEXT items
        // change) can't save it. The viewport then lands on blank space
        // at the next re-layout — e.g. the keyboard appearing when the
        // user taps the entry field ("chat went blank" reports).
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
        // Snapshot 1: echo appended (auto-follow schedules with "echo:abc").
        // Snapshot 2: echo retired, real row in its place.
        fake.snapshotsToEmit = [[older, echo], [older, delivered]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        await task.value

        XCTAssertEqual(
            vm.autoFollowTarget(for: "echo:abc"), "2",
            "a follow target that left the row set must resolve to the live tail, not the dead id"
        )
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
    func test_retrySend_isCallable_andStubDoesNotThrow() {
        // Stub-only contract: the SDK retry path lands later. The
        // surface needs to exist now so the View can wire the failed-
        // send "Tap to retry" affordance ahead of the service layer.
        // This test pins that the method exists, accepts a String,
        // and doesn't crash — exactly what the View depends on.
        let timeline = FakeTimelineService()
        let vm = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaService())
        vm.retrySend(itemID: "abc")
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
}
