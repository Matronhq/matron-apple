import XCTest
import MatronJournal
@testable import MatronChat

final class JournalMediaServiceTests: XCTestCase {
    private func makeService(cache: MediaDiskCache? = nil) -> JournalMediaService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config))
        return JournalMediaService(api: api, cache: cache)
    }

    func testImageForKnownBlobReturnsBytes() async throws {
        MediaStubURLProtocol.responses = ["/media/b1": (200, "PNGDATA")]
        let service = makeService()
        let result = await service.image(for: URL(string: "https://chat.example.com/media/b1")!)
        let data = try XCTUnwrap(result)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PNGDATA")
    }

    func testImageForMissingBlobReturnsNil() async throws {
        MediaStubURLProtocol.responses = ["/media/b1": (404, #"{"error":"not_found"}"#)]
        let service = makeService()
        let data = await service.image(for: URL(string: "https://chat.example.com/media/b1")!)
        XCTAssertNil(data)
    }

    func testSecondFetchOfABlobIsServedFromTheDiskCache() async throws {
        MediaStubURLProtocol.responses = ["/media/b1": (200, "PNGDATA")]
        MediaStubURLProtocol.requestCount = 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalMediaServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://chat.example.com/media/b1")!

        let first = await makeService(cache: MediaDiskCache(directory: directory)).image(for: url)
        XCTAssertEqual(first, Data("PNGDATA".utf8))
        // A fresh service (a relaunch, or the chat reopened) with the same
        // cache directory doesn't go to the network again.
        let second = await makeService(cache: MediaDiskCache(directory: directory)).fetchOutcome(mxcURL: url)
        guard case .data(let data) = second else { return XCTFail("expected cached bytes") }
        XCTAssertEqual(data, Data("PNGDATA".utf8))
        XCTAssertEqual(MediaStubURLProtocol.requestCount, 1)
    }

    func testFailedFetchIsNotCached() async throws {
        MediaStubURLProtocol.responses = ["/media/b1": (404, #"{"error":"not_found"}"#)]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalMediaServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaDiskCache(directory: directory)
        let url = URL(string: "https://chat.example.com/media/b1")!
        _ = await makeService(cache: cache).image(for: url)
        let cached = await cache.data(for: "b1")
        XCTAssertNil(cached)
    }

    func testImageForURLNotUnderMediaPathReturnsNilWithoutRequest() async throws {
        MediaStubURLProtocol.responses = [:]
        MediaStubURLProtocol.requestCount = 0
        let service = makeService()
        let data = await service.image(for: URL(string: "mxc://matrix.example.com/abc123")!)
        XCTAssertNil(data)
        XCTAssertEqual(MediaStubURLProtocol.requestCount, 0)
    }
}

/// Minimal stub `URLProtocol` for `JournalMediaService`'s underlying
/// `JournalAPI.mediaData(blobRef:)` call, mirroring the pattern used by
/// `PaginateStubURLProtocol` in `JournalTimelineServiceTests` (JournalTests'
/// own `StubURLProtocol` lives in a separate test target and isn't
/// importable here).
private final class MediaStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let path = request.url!.path
        let (status, body) = Self.responses[path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
