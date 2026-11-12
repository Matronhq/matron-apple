import Foundation
@testable import MatronChat

/// Test-only fake. Records each requested `mxc://` URL and returns
/// pre-stubbed bytes. Used by `MediaServiceSizedImageTests`; the
/// `ChatViewModel` tests in `ViewModelTests` re-declare it to stay inside
/// that test target's module.
final class FakeMediaService: MediaService, @unchecked Sendable {
    var stubData: [URL: Data] = [:]
    private(set) var requested: [URL] = []
    private let lock = NSLock()
    func image(for mxc: URL) async -> Data? {
        lock.withLock { requested.append(mxc) }
        return stubData[mxc]
    }
}
