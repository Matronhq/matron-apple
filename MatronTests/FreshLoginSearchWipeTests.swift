import XCTest
import GRDB
import MatronJournal
import MatronSearch
import UIKit
@testable import Matron

/// Bugbot round 4 "Background login skips search wipe": the fresh-login wipe
/// must hold the databases for the delete and must not give up on a failure
/// — the session is published only after it has landed.
@MainActor
final class FreshLoginSearchWipeTests: XCTestCase {
    /// Fails the first `failures` wipes the way a suspended database does,
    /// and records whether the hold was in force at each attempt.
    private actor FlakyIndex: SearchService {
        var failures: Int
        var attempts = 0
        var wiped = false
        private let isHeld: @Sendable () -> Bool
        var heldAtAttempt: [Bool] = []
        init(failures: Int, isHeld: @escaping @Sendable () -> Bool) {
            self.failures = failures
            self.isHeld = isHeld
        }
        func wipe() async throws {
            attempts += 1
            heldAtAttempt.append(isHeld())
            if failures > 0 {
                failures -= 1
                throw DatabaseError(resultCode: .SQLITE_ABORT, message: "Database is suspended")
            }
            wiped = true
        }
        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
        func remove(eventID: String) async throws {}
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
        func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
        func backfillComplete(roomID: String) async throws -> Bool { false }
        func backfillOldestEventID(roomID: String) async throws -> String? { nil }
        func resetBackfill() async throws {}
        func eventCount(roomID: String) async throws -> Int { 0 }
        func contains(eventID: String) async throws -> Bool { false }
    }

    private final class HoldCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _held = 0
        private var _taken = 0
        var held: Bool { lock.withLock { _held > 0 } }
        var taken: Int { lock.withLock { _taken } }
        func take() -> () -> Void {
            lock.withLock { _held += 1; _taken += 1 }
            return { [self] in lock.withLock { _held -= 1 } }
        }
    }

    func testFailedWipeIsRetriedUnderAHoldUntilItLands() async {
        let holds = HoldCounter()
        let index = FlakyIndex(failures: 2, isHeld: { holds.held })
        var waits = 0
        await FreshLoginSearchWipe.run(
            waitForProtectedData: { waits += 1 },
            openSearch: { index },
            hold: { _ in holds.take() },
            retryDelays: [.zero])
        let attempts = await index.attempts
        let wiped = await index.wiped
        let heldAtAttempt = await index.heldAtAttempt
        XCTAssertEqual(attempts, 3, "a refused wipe must be retried, not swallowed")
        XCTAssertTrue(wiped)
        XCTAssertEqual(heldAtAttempt, [true, true, true], "every attempt runs under the database hold")
        XCTAssertFalse(holds.held, "the hold is released after each attempt")
        XCTAssertEqual(holds.taken, 3)
        XCTAssertEqual(waits, 3, "each attempt re-checks protected data first")
    }

    /// Bugbot "Denied background task keeps locks": no grant while
    /// backgrounded means no hold, and no wipe attempt without one.
    func testNoHoldMeansNoAttemptUntilOneIsGranted() async {
        let holds = HoldCounter()
        let index = FlakyIndex(failures: 0, isHeld: { holds.held })
        var offers = 0
        await FreshLoginSearchWipe.run(
            waitForProtectedData: {},
            openSearch: { index },
            hold: { _ in offers += 1; return offers < 3 ? nil : holds.take() },
            retryDelays: [.zero])
        let attempts = await index.attempts
        let heldAtAttempt = await index.heldAtAttempt
        XCTAssertEqual(offers, 3)
        XCTAssertEqual(attempts, 1, "the wipe only runs once a hold is granted")
        XCTAssertEqual(heldAtAttempt, [true])
    }

    private final class TaskLog: @unchecked Sendable {
        var begun = 0
        var ended: [UIBackgroundTaskIdentifier] = []
        var expiration: (@MainActor @Sendable () -> Void)?
    }

    func testDeniedTaskInTheBackgroundTakesNoActivity() {
        let controller = DatabaseSuspensionController(apply: { _ in })
        controller.setInBackground(true)
        let log = TaskLog()
        let release = FreshLoginSearchWipe.holdDatabases(
            named: "fresh-login-wipe", controller: controller, isInBackground: { true },
            beginTask: { _, _ in log.begun += 1; return .invalid },
            endTask: { log.ended.append($0) })
        XCTAssertNil(release)
        XCTAssertTrue(controller.isSuspended, "a denied grant must not resume the databases")
        XCTAssertEqual(controller.activeActivityNames, [])
    }

    func testDeniedTaskInTheForegroundStillHolds() {
        let controller = DatabaseSuspensionController(apply: { _ in })
        let release = FreshLoginSearchWipe.holdDatabases(
            named: "fresh-login-wipe", controller: controller, isInBackground: { false },
            beginTask: { _, _ in .invalid }, endTask: { _ in })
        XCTAssertNotNil(release)
        XCTAssertEqual(controller.activeActivityNames, ["fresh-login-wipe"])
        release?()
        XCTAssertEqual(controller.activeActivityNames, [])
    }

    func testGrantedTaskHoldsAndItsExpirationReleasesBoth() {
        let controller = DatabaseSuspensionController(apply: { _ in })
        controller.setInBackground(true)
        let log = TaskLog()
        let release = FreshLoginSearchWipe.holdDatabases(
            named: "fresh-login-wipe", controller: controller, isInBackground: { true },
            beginTask: { _, expiration in log.expiration = expiration; return UIBackgroundTaskIdentifier(rawValue: 7) },
            endTask: { log.ended.append($0) })
        XCTAssertNotNil(release)
        XCTAssertFalse(controller.isSuspended, "resumed for the wipe while the task runs")
        log.expiration?()
        XCTAssertTrue(controller.isSuspended, "expiry suspends before iOS does")
        XCTAssertEqual(log.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
        release?() // the normal end after an expiry is a no-op
        XCTAssertEqual(log.ended.count, 1)
    }

    func testAnUnopenableIndexIsRetriedToo() async {
        let holds = HoldCounter()
        let index = FlakyIndex(failures: 0, isHeld: { holds.held })
        var opens = 0
        await FreshLoginSearchWipe.run(
            waitForProtectedData: {},
            openSearch: { opens += 1; return opens < 3 ? nil : index },
            hold: { _ in holds.take() },
            retryDelays: [.zero])
        let wiped = await index.wiped
        XCTAssertTrue(wiped)
        XCTAssertEqual(opens, 3)
        XCTAssertFalse(holds.held)
    }
}
