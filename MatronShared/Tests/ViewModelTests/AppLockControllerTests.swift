import XCTest
@testable import MatronViewModels

private final class FakeAuthenticator: BiometricAuthenticating, @unchecked Sendable {
    var method: String? = "Face ID"
    var result: Result<Bool, Error> = .success(true)
    /// When true, authenticate() parks on a continuation until release()
    /// — models the system prompt sitting on screen.
    var hold = false
    private(set) var authenticateCalls = 0
    private var waiters: [CheckedContinuation<Bool, Error>] = []

    func availableMethodName() -> String? { method }

    func authenticate(reason: String) async throws -> Bool {
        authenticateCalls += 1
        if hold {
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        return try result.get()
    }

    func release(_ value: Bool = true) {
        waiters.forEach { $0.resume(returning: value) }
        waiters.removeAll()
    }
}

@MainActor
final class AppLockControllerTests: XCTestCase {
    private var auth = FakeAuthenticator()
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        auth = FakeAuthenticator()
        defaults = UserDefaults(suiteName: "AppLockControllerTests-\(UUID().uuidString)")
    }

    private func makeController() -> AppLockController {
        AppLockController(auth: auth, defaults: defaults) { [self] in clock }
    }

    func test_disabled_byDefault_andUnlocked() {
        let lock = makeController()
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func test_coldLaunch_whileEnabled_startsLocked() {
        defaults.set(true, forKey: AppLockController.enabledKey)
        XCTAssertTrue(makeController().isLocked)
    }

    func test_enable_authenticatesFirst_andPersists() async {
        let lock = makeController()
        await lock.setEnabled(true)
        XCTAssertEqual(auth.authenticateCalls, 1)
        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: AppLockController.enabledKey))
        XCTAssertFalse(lock.isLocked, "enabling must not lock the app the user is holding")
    }

    func test_enable_authFailure_leavesDisabled() async {
        auth.result = .failure(NSError(domain: "test", code: 1))
        let lock = makeController()
        await lock.setEnabled(true)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: AppLockController.enabledKey))
        XCTAssertNotNil(lock.unlockError)
    }

    func test_disable_needsNoAuth_andClearsLock() async {
        defaults.set(true, forKey: AppLockController.enabledKey)
        let lock = makeController()
        XCTAssertTrue(lock.isLocked)
        await lock.setEnabled(false)
        XCTAssertEqual(auth.authenticateCalls, 0)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func test_backgroundShorterThanTimeout_doesNotLock() async {
        let lock = makeController()
        await lock.setEnabled(true)
        lock.timeout = .fiveMinutes
        lock.noteResignedActive()
        clock = clock.addingTimeInterval(299)
        lock.noteBecameActive()
        XCTAssertFalse(lock.isLocked)
    }

    func test_backgroundLongerThanTimeout_locks() async {
        let lock = makeController()
        await lock.setEnabled(true)
        lock.timeout = .fiveMinutes
        lock.noteResignedActive()
        clock = clock.addingTimeInterval(301)
        lock.noteBecameActive()
        XCTAssertTrue(lock.isLocked)
    }

    func test_immediately_locksOnAnyRoundTrip() async {
        let lock = makeController()
        await lock.setEnabled(true)
        lock.timeout = .immediately
        lock.noteResignedActive()
        lock.noteBecameActive()
        XCTAssertTrue(lock.isLocked)
    }

    func test_repeatedResign_keepsEarliestTimestamp() async {
        // .inactive then .background both call noteResignedActive; the
        // countdown must run from the FIRST departure, not the last.
        let lock = makeController()
        await lock.setEnabled(true)
        lock.timeout = .fiveMinutes
        lock.noteResignedActive()
        clock = clock.addingTimeInterval(200)
        lock.noteResignedActive()
        clock = clock.addingTimeInterval(101)
        lock.noteBecameActive()
        XCTAssertTrue(lock.isLocked)
    }

    func test_becameActive_withoutResign_doesNotLock() async {
        let lock = makeController()
        await lock.setEnabled(true)
        lock.timeout = .immediately
        lock.noteBecameActive()
        XCTAssertFalse(lock.isLocked)
    }

    func test_unlock_success_clearsLock() async {
        defaults.set(true, forKey: AppLockController.enabledKey)
        let lock = makeController()
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.unlockError)
    }

    func test_unlock_failure_staysLockedWithError() async {
        defaults.set(true, forKey: AppLockController.enabledKey)
        auth.result = .success(false)
        let lock = makeController()
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertNotNil(lock.unlockError)
    }

    func test_unlock_whenNotLocked_doesNotAuthenticate() async {
        let lock = makeController()
        await lock.unlock()
        XCTAssertEqual(auth.authenticateCalls, 0)
    }

    func test_timeout_persistsAndRestores() {
        let lock = makeController()
        lock.timeout = .oneHour
        XCTAssertEqual(makeController().timeout, .oneHour)
    }

    func test_timeout_defaultsToFiveMinutes() {
        XCTAssertEqual(makeController().timeout, .fiveMinutes)
    }

    func test_disableDuringEnableAuthPrompt_wins() async {
        // The user flips the toggle on, the system prompt sits on screen,
        // they change their mind and flip it off — the enable completing
        // afterwards must NOT re-enable behind their back.
        auth.hold = true
        let lock = makeController()
        let enable = Task { await lock.setEnabled(true) }
        for _ in 0..<200 where auth.authenticateCalls == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(auth.authenticateCalls, 1, "enable is parked in its prompt")
        await lock.setEnabled(false)
        auth.release(true)
        await enable.value
        XCTAssertFalse(lock.isEnabled, "the later disable intent wins")
        XCTAssertFalse(defaults.bool(forKey: AppLockController.enabledKey))
    }

    func test_unlockAttempt_stampsLastAuthEndedAt() async {
        defaults.set(true, forKey: AppLockController.enabledKey)
        auth.result = .success(false)
        let lock = makeController()
        XCTAssertNil(lock.lastAuthEndedAt)
        await lock.unlock()
        XCTAssertEqual(lock.lastAuthEndedAt, clock,
                       "hosts use this stamp to tell auth-dialog churn from a real app switch")
    }

    func test_resignWhileAlreadyLocked_thenQuickReturn_staysLocked() async {
        defaults.set(true, forKey: AppLockController.enabledKey)
        let lock = makeController()
        lock.noteResignedActive()
        lock.noteBecameActive()
        XCTAssertTrue(lock.isLocked)
    }
}
