import XCTest
import SwiftUI
@testable import MatronChat

/// Test-only fake. Records each requested `mxc://` URL and returns
/// pre-stubbed bytes. Used by both `MediaServiceFakeTests` here and the
/// `ChatViewModel` tests in `ViewModelTests` (re-declared there to stay
/// inside that test target's module).
final class FakeMediaService: MediaService, @unchecked Sendable {
    var stubData: [URL: Data] = [:]
    private(set) var requested: [URL] = []
    private let lock = NSLock()
    func image(for mxc: URL) async -> Data? {
        lock.withLock { requested.append(mxc) }
        return stubData[mxc]
    }
}

final class MediaServiceFakeTests: XCTestCase {
    func test_returnsStubbedDataForKnownURL() async {
        let svc = FakeMediaService()
        let url = URL(string: "mxc://example.com/abc")!
        svc.stubData[url] = Data([0x01, 0x02])
        let data = await svc.image(for: url)
        XCTAssertEqual(data, Data([0x01, 0x02]))
        XCTAssertEqual(svc.requested, [url])
    }

    func test_returnsNilForUnknownURL() async {
        let svc = FakeMediaService()
        let data = await svc.image(for: URL(string: "mxc://unknown/xyz")!)
        XCTAssertNil(data)
    }

    func test_recordsMultipleRequestsInOrder() async {
        let svc = FakeMediaService()
        let a = URL(string: "mxc://a/1")!
        let b = URL(string: "mxc://b/2")!
        _ = await svc.image(for: a)
        _ = await svc.image(for: b)
        XCTAssertEqual(svc.requested, [a, b])
    }
}
