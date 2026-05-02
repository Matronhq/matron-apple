import XCTest
@testable import MatronSync

actor FakeSyncService: SyncService {
    var startCallCount = 0
    var stopCallCount = 0
    private var running = false
    private(set) var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []

    func start() async throws {
        startCallCount += 1
        running = true
        isReady = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    func stop() async {
        stopCallCount += 1
        running = false
        isReady = false
    }

    var isRunning: Bool { running }

    func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }
}

final class SyncServiceProtocolTests: XCTestCase {
    func test_startSetsRunningTrue() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        let running = await svc.isRunning
        XCTAssertTrue(running)
    }

    func test_stopSetsRunningFalse() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        await svc.stop()
        let running = await svc.isRunning
        XCTAssertFalse(running)
    }

    func test_waitUntilReady_resumesAfterStart() async throws {
        let svc = FakeSyncService()
        let waitTask = Task { try await svc.waitUntilReady() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let readyBefore = await svc.isReady
        XCTAssertFalse(readyBefore)
        try await svc.start()
        try await waitTask.value
        let readyAfter = await svc.isReady
        XCTAssertTrue(readyAfter)
    }

    func test_waitUntilReady_returnsImmediately_ifAlreadyReady() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        try await svc.waitUntilReady()
    }
}
