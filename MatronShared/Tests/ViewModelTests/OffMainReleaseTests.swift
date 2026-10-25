import XCTest
import MatronModels

final class OffMainReleaseTests: XCTestCase {
    private final class Tracer: Sendable {
        let freed: @Sendable (Bool) -> Void
        init(freed: @escaping @Sendable (Bool) -> Void) { self.freed = freed }
        deinit { freed(Thread.isMainThread) }
    }

    @MainActor
    func test_theOldValueIsFreedOffMain() {
        let freed = expectation(description: "freed")
        let onMain = LockedFlag()
        var array = [Tracer { isMain in onMain.set(isMain); freed.fulfill() }]
        OffMainRelease.replace(&array, with: [])
        wait(for: [freed], timeout: 5)
        XCTAssertFalse(onMain.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true
    var value: Bool { lock.withLock { flag } }
    func set(_ newValue: Bool) { lock.withLock { flag = newValue } }
}
