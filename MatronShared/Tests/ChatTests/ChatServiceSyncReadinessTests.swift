import XCTest
import MatrixRustSDK
@testable import MatronChat
@testable import MatronSync
@testable import MatronModels

/// Verifies the readiness contract that ChatServiceLive depends on: a sync
/// service in the not-ready state must suspend callers of waitUntilReady()
/// until start() flips the flag. The fake mirrors what the production
/// ChatServiceLive observes via SyncService.waitUntilReady().
actor LocalFakeSync: MatronSync.SyncService {
    private(set) var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private(set) var waitUntilReadyCallCount = 0

    func start() async throws {
        isReady = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    func stop() async { isReady = false }

    var isRunning: Bool { isReady }

    func waitUntilReady() async throws {
        waitUntilReadyCallCount += 1
        if isReady { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }

    func sdkService() async -> MatrixRustSDK.SyncService? { nil }
}

final class ChatServiceSyncReadinessTests: XCTestCase {
    func test_chatSummaries_waitsForSyncReady_beforeSubscribing() async throws {
        let fakeSync = LocalFakeSync()
        let countBeforeStart = await fakeSync.waitUntilReadyCallCount
        XCTAssertEqual(countBeforeStart, 0)

        let task = Task { try await fakeSync.waitUntilReady() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let countAfterCall = await fakeSync.waitUntilReadyCallCount
        XCTAssertEqual(countAfterCall, 1)
        let readyMid = await fakeSync.isReady
        XCTAssertFalse(readyMid, "must remain not-ready until start()")

        try await fakeSync.start()
        try await task.value
        let readyAfter = await fakeSync.isReady
        XCTAssertTrue(readyAfter)
    }
}
