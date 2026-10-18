import XCTest
@testable import MatronAuth

private struct StubAuthenticator: BiometricAuthenticating {
    var method: String?
    func availableMethodName() -> String? { method }
    func authenticate(reason: String) async throws -> Bool { true }
}

/// Where the app lock's settings live: the share extension reads the same
/// switch the app writes, and a setting saved before it moved is kept.
final class AppLockSettingsTests: XCTestCase {
    private var legacy: UserDefaults!
    private var shared: UserDefaults!
    private var names: [String] = []

    override func setUp() {
        let a = "app-lock-legacy-\(UUID().uuidString)"
        let b = "app-lock-shared-\(UUID().uuidString)"
        names = [a, b]
        legacy = UserDefaults(suiteName: a)
        shared = UserDefaults(suiteName: b)
    }

    override func tearDown() {
        names.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }

    func test_migrate_carriesAnEnabledLockOver() {
        legacy.set(true, forKey: AppLockSettings.enabledKey)
        legacy.set(60, forKey: AppLockSettings.timeoutKey)

        AppLockSettings.migrate(from: legacy, to: shared)

        XCTAssertTrue(shared.bool(forKey: AppLockSettings.enabledKey))
        XCTAssertEqual(shared.integer(forKey: AppLockSettings.timeoutKey), 60)
    }

    func test_migrate_keepsWhatTheSharedDefaultsAlreadyHold() {
        legacy.set(true, forKey: AppLockSettings.enabledKey)
        shared.set(false, forKey: AppLockSettings.enabledKey)

        AppLockSettings.migrate(from: legacy, to: shared)

        XCTAssertFalse(shared.bool(forKey: AppLockSettings.enabledKey), "a newer choice is not overwritten")
    }

    func test_migrate_withNothingSaved_writesNothing() {
        AppLockSettings.migrate(from: legacy, to: shared)
        XCTAssertNil(shared.object(forKey: AppLockSettings.enabledKey))
        XCTAssertNil(shared.object(forKey: AppLockSettings.timeoutKey))
    }

    func test_requiresUnlock_onlyWhenEnabledAndTheDeviceCanCheck() {
        let faceID = StubAuthenticator(method: "Face ID")
        XCTAssertFalse(AppLockSettings.requiresUnlock(in: shared, auth: faceID))
        shared.set(true, forKey: AppLockSettings.enabledKey)
        XCTAssertTrue(AppLockSettings.requiresUnlock(in: shared, auth: faceID))
        XCTAssertFalse(AppLockSettings.requiresUnlock(in: shared, auth: StubAuthenticator(method: nil)),
                       "with no passcode left the app stands its lock down too")
    }
}
