import XCTest
import SwiftUI
import MatronChat
import MatronJournal
@testable import MatronViewModels

private struct FakeBrowserStore: MediaBrowserStoreReading {
    var attachments: [JournalEvent] = []
    var linkCandidates: [JournalEvent] = []
    var throwOnRead = false
    struct Boom: Error {}
    func attachmentEvents(convoID: String) throws -> [JournalEvent] {
        if throwOnRead { throw Boom() }
        return attachments
    }
    func linkCandidateEvents(convoID: String) throws -> [JournalEvent] {
        if throwOnRead { throw Boom() }
        return linkCandidates
    }
}

/// Media service whose outcome is fixed — mirrors FileAttachmentDownloadTests'
/// FixedOutcomeMediaService (private there, so re-declared).
private final class FixedOutcomeMedia: MediaService, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: MediaFetchOutcome
    private(set) var requestCount = 0
    init(outcome: MediaFetchOutcome) { self.outcome = outcome }
    func image(for mxc: URL) async -> Data? { nil }
    func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome {
        lock.withLock { requestCount += 1 }
        return outcome
    }
}

final class MediaBrowserViewModelTests: XCTestCase {
    private let server = URL(string: "https://journal.example")!

    private func event(_ seq: Int64, type: String, payload: [String: Any],
                       ts: TimeInterval? = nil) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1",
                     ts: Date(timeIntervalSince1970: ts ?? Double(seq)),
                     sender: "agent:dev-2", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    @MainActor
    private func makeVM(store: FakeBrowserStore,
                        media: MediaService = FixedOutcomeMedia(outcome: .failure)) -> MediaBrowserViewModel {
        MediaBrowserViewModel(store: store, convoID: "c1", serverURL: server, media: media)
    }

    @MainActor
    func test_load_mapsAttachmentsThroughPayloadContract() async {
        let store = FakeBrowserStore(attachments: [
            event(5, type: "image", payload: ["expired": true]),                    // tombstone
            event(3, type: "file", payload: ["blob_ref": "b3", "name": "a.pdf",
                                             "size": 1234, "caption": "the report"]),
            event(1, type: "image", payload: ["blob_ref": "b1"]),
        ])
        let vm = makeVM(store: store)
        await vm.load()
        XCTAssertEqual(vm.mediaItems.map(\.id), [5, 1])
        XCTAssertTrue(vm.mediaItems[0].expired)
        XCTAssertNil(vm.mediaItems[0].url, "tombstone has no blob_ref → no URL")
        XCTAssertEqual(vm.mediaItems[1].url,
                       server.appendingPathComponent("media").appendingPathComponent("b1"))
        XCTAssertEqual(vm.fileItems.map(\.id), [3])
        XCTAssertEqual(vm.fileItems[0].name, "a.pdf")
        XCTAssertEqual(vm.fileItems[0].sizeBytes, 1234)
        XCTAssertFalse(vm.loadFailed)
    }

    @MainActor
    func test_load_extractsDedupesAndOrdersLinks() async {
        let store = FakeBrowserStore(linkCandidates: [   // store returns newest first
            event(9, type: "text", payload: ["body": "again https://a.example/x\nsecond line"]),
            event(7, type: "text", payload: ["body": "https://b.example and https://a.example/x"]),
        ])
        let vm = makeVM(store: store)
        await vm.load()
        XCTAssertEqual(vm.links.map(\.url.absoluteString),
                       ["https://a.example/x", "https://b.example"],
                       "dedup keeps the NEWEST occurrence; order is newest event first")
        XCTAssertEqual(vm.links[0].context, "again https://a.example/x",
                       "context is the first line of the containing message")
        XCTAssertEqual(vm.links[0].timestamp, Date(timeIntervalSince1970: 9))
    }

    @MainActor
    func test_load_storeFailure_setsLoadFailed() async {
        let vm = makeVM(store: FakeBrowserStore(throwOnRead: true))
        await vm.load()
        XCTAssertTrue(vm.loadFailed)
        XCTAssertEqual(vm.mediaItems, [])
    }

    @MainActor
    func test_thumbnail_notFound_marksUnavailableAndExpires_withoutRefetch() async {
        let media = FixedOutcomeMedia(outcome: .notFound)
        let url = server.appendingPathComponent("media").appendingPathComponent("b1")
        let store = FakeBrowserStore(attachments: [
            event(1, type: "image", payload: ["blob_ref": "b1"]),
        ])
        let vm = makeVM(store: store, media: media)
        await vm.load()
        let first = await vm.thumbnail(for: url)
        XCTAssertNil(first)
        XCTAssertTrue(vm.isUnavailable(url))
        XCTAssertTrue(vm.mediaItems[0].expired, "a 404 flips the grid cell to expired")
        let second = await vm.thumbnail(for: url)
        XCTAssertNil(second)
        XCTAssertEqual(media.requestCount, 1, "permanently-gone blob must not be re-fetched")
    }

    @MainActor
    func test_thumbnail_transientFailure_staysRetryable() async {
        let media = FixedOutcomeMedia(outcome: .failure)
        let url = server.appendingPathComponent("media").appendingPathComponent("b1")
        let vm = makeVM(store: FakeBrowserStore(), media: media)
        let first = await vm.thumbnail(for: url)
        XCTAssertNil(first)
        XCTAssertFalse(vm.isUnavailable(url))
        let second = await vm.thumbnail(for: url)
        XCTAssertNil(second)
        XCTAssertEqual(media.requestCount, 2, "transient failure retries")
    }

    @MainActor
    func test_thumbnail_decodesAndCaches() async {
        // 1×1 red PNG, generated platform-side so the test carries no fixture.
        let png = Self.tinyPNG()
        final class DataMedia: MediaService, @unchecked Sendable {
            private let lock = NSLock()
            let data: Data
            private(set) var requestCount = 0
            init(data: Data) { self.data = data }
            func image(for mxc: URL) async -> Data? { data }
            func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome {
                lock.withLock { requestCount += 1 }
                return .data(data)
            }
        }
        let media = DataMedia(data: png)
        let url = server.appendingPathComponent("media").appendingPathComponent("b1")
        let vm = makeVM(store: FakeBrowserStore(), media: media)
        let first = await vm.thumbnail(for: url)
        XCTAssertNotNil(first)
        _ = await vm.thumbnail(for: url)
        XCTAssertEqual(media.requestCount, 1, "second ask must hit the cache")
    }

    private static func tinyPNG() -> Data {
        #if canImport(UIKit) && !os(macOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #else
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        #endif
    }
}
