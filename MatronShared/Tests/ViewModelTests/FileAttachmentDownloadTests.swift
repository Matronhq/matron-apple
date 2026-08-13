import XCTest
import SwiftUI
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Test-only `MediaService` whose fetch suspends until the test releases
/// it — lets the tests observe `ChatViewModel`'s in-flight download state
/// (the chip spinner + tap-dedup contract) deterministically instead of
/// racing a fast fake.
private final class GatedMediaService: MediaService, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Data?
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private(set) var requestCount = 0

    init(result: Data?) {
        self.result = result
    }

    func image(for mxc: URL) async -> Data? {
        lock.withLock { requestCount += 1 }
        return await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }

    /// Releases every suspended fetch with the stubbed result.
    func release() {
        let (resumed, value): ([CheckedContinuation<Data?, Never>], Data?) =
            lock.withLock {
                defer { waiters.removeAll() }
                return (waiters, result)
            }
        for waiter in resumed { waiter.resume(returning: value) }
    }
}

/// Test-only `MediaService` serving distinct stubbed bytes per URL,
/// without the gating — for tests where only the byte→path mapping
/// matters, not in-flight observation.
private final class DistinctBlobMediaService: MediaService, @unchecked Sendable {
    private let blobs: [URL: Data]
    init(blobs: [URL: Data]) { self.blobs = blobs }
    func image(for mxc: URL) async -> Data? { blobs[mxc] }
}

/// Pins the file-attachment download contract on `ChatViewModel`:
/// `writeTempFile` must expose an observable "downloading" flag while the
/// (possibly multi-second) blob fetch is in flight, ignore re-taps for a
/// URL that's already downloading, and serve repeat opens from the temp
/// file it already wrote instead of re-downloading. All three existed for
/// image attachments from day one; file attachments shipped without them,
/// which is why tapping a large PDF looked like a dead tap (Dan,
/// 2026-08-13).
final class FileAttachmentDownloadTests: XCTestCase {
    private let mxc = URL(string: "https://journal.example/media/abc123")!

    /// Polls until `condition` is true (or the timeout lapses) — the
    /// downloading flag flips on the main actor sometime after the
    /// detached fetch suspends, so the test needs a settle loop rather
    /// than a fixed sleep.
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func test_writeTempFile_exposesDownloadingState_whileFetchInFlight() async throws {
        let media = GatedMediaService(result: Data("pdf-bytes".utf8))
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: media)
        XCTAssertFalse(vm.isDownloadingFile(mxc))

        let download = Task { await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf") }
        await waitUntil { vm.isDownloadingFile(self.mxc) }
        XCTAssertTrue(vm.isDownloadingFile(mxc), "flag must be up while the fetch is suspended")

        media.release()
        let url = await download.value
        XCTAssertNotNil(url)
        XCTAssertFalse(vm.isDownloadingFile(mxc), "flag must clear once the fetch completes")
    }

    @MainActor
    func test_writeTempFile_secondTapWhileDownloading_isIgnored() async throws {
        let media = GatedMediaService(result: Data("pdf-bytes".utf8))
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: media)

        let first = Task { await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf") }
        await waitUntil { vm.isDownloadingFile(self.mxc) }

        let second = await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf")
        XCTAssertNil(second, "re-tap during an in-flight download must be a no-op")
        XCTAssertEqual(media.requestCount, 1, "re-tap must not start a second fetch")

        media.release()
        let firstURL = await first.value
        XCTAssertNotNil(firstURL)
    }

    @MainActor
    func test_writeTempFile_repeatOpen_servedFromCache_withoutRefetch() async throws {
        let media = GatedMediaService(result: Data("pdf-bytes".utf8))
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: media)

        let download = Task { await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf") }
        await waitUntil { vm.isDownloadingFile(self.mxc) }
        media.release()
        let firstURL = await download.value
        XCTAssertNotNil(firstURL)

        let secondURL = await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf")
        XCTAssertEqual(secondURL, firstURL, "second open must reuse the written temp file")
        XCTAssertEqual(media.requestCount, 1, "second open must not re-download the blob")
    }

    @MainActor
    func test_writeTempFile_sameFilenameDifferentURLs_dontCollide() async throws {
        // Two attachments can share a display filename ("report.pdf" from
        // two rooms). The temp path must be unique per attachment or the
        // second write clobbers the first and a later cache hit serves
        // the wrong bytes (Bugbot, PR #138).
        let urlA = URL(string: "https://journal.example/media/blob-a")!
        let urlB = URL(string: "https://journal.example/media/blob-b")!
        let media = DistinctBlobMediaService(blobs: [
            urlA: Data("bytes-A".utf8),
            urlB: Data("bytes-B".utf8),
        ])
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: media)

        let pathA = await vm.writeTempFile(mxcURL: urlA, filename: "report.pdf")
        let pathB = await vm.writeTempFile(mxcURL: urlB, filename: "report.pdf")
        let reopenedA = await vm.writeTempFile(mxcURL: urlA, filename: "report.pdf")

        XCTAssertNotEqual(pathA, pathB, "same display name must not share a temp path")
        XCTAssertEqual(reopenedA, pathA)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopenedA)), Data("bytes-A".utf8),
                       "re-opening A after downloading B must serve A's bytes")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pathB)), Data("bytes-B".utf8))
    }

    @MainActor
    func test_writeTempFile_failedFetch_returnsNil_andClearsDownloading() async throws {
        let media = GatedMediaService(result: nil)
        let vm = ChatViewModel(roomID: "!r:s", timeline: FakeTimelineService(), media: media)

        let download = Task { await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf") }
        await waitUntil { vm.isDownloadingFile(self.mxc) }
        media.release()

        let url = await download.value
        XCTAssertNil(url)
        XCTAssertFalse(vm.isDownloadingFile(mxc),
                       "a failed fetch must clear the flag so a retry tap works")

        // And the retry actually retries (no poisoned in-flight state).
        let retry = Task { await vm.writeTempFile(mxcURL: mxc, filename: "a.pdf") }
        await waitUntil { media.requestCount == 2 }
        XCTAssertEqual(media.requestCount, 2)
        media.release()
        _ = await retry.value
    }
}
