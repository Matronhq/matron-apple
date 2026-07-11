import XCTest
import MatronJournal
@testable import MatronChat

final class JournalMediaServiceTests: XCTestCase {
    private func makeService() -> JournalMediaService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config))
        return JournalMediaService(api: api)
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
