import XCTest
@testable import MatronVoice
@testable import MatronViewModels
@testable import Matron

private final class FakeUnlocker: BiometricAuthenticating, @unchecked Sendable {
    var method: String? = "Face ID"
    var answer = true
    func availableMethodName() -> String? { method }
    func authenticate(reason: String) async throws -> Bool { answer }
}

/// The app lock on the car's display: while Matron is locked the car shows
/// only the locked screen, with no conversation list and no voice mode, and
/// it moves on as soon as Matron is unlocked on the iPhone.
@MainActor
final class CarPlayLockGateTests: XCTestCase {
    typealias Screen = CarPlayVoiceScreen

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "carplay-lock-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func controller(enabled: Bool, auth: FakeUnlocker = FakeUnlocker()) -> AppLockController {
        defaults.set(enabled, forKey: AppLockController.enabledKey)
        return AppLockController(auth: auth, defaults: defaults)
    }

    private func sitting() -> VoiceModeEngine.State {
        var state = VoiceModeEngine.State()
        state.phase = .listening
        state.convoID = "c1"
        state.convoTitle = "Auth refactor"
        state.boxName = "box-a"
        return state
    }

    func test_coldLaunch_withTheLockOn_showsTheLockedScreen() {
        // The car can start the app before the iPhone has ever been
        // unlocked: that launch is locked like any other.
        let gate = CarPlayLockGate(lock: controller(enabled: true))
        XCTAssertTrue(gate.isLocked)
        XCTAssertEqual(gate.model(sitting: nil, idle: .ready), Screen.model(.locked))
        XCTAssertEqual(gate.model(sitting: sitting(), idle: .ready), Screen.model(.locked),
                       "no conversation shows while locked, whatever else is going on")
    }

    func test_lockOff_showsTheUsualScreens() {
        let gate = CarPlayLockGate(lock: controller(enabled: false))
        XCTAssertFalse(gate.isLocked)
        XCTAssertEqual(gate.model(sitting: nil, idle: .ready), Screen.model(.ready))
        XCTAssertEqual(gate.model(sitting: nil, idle: .signedOut), Screen.model(.signedOut))
        XCTAssertEqual(gate.model(sitting: sitting(), idle: .ready), Screen.model(sitting()))
    }

    func test_lockOn_butNothingCanUnlockIt_isNotLocked() {
        let auth = FakeUnlocker()
        auth.method = nil
        let gate = CarPlayLockGate(lock: controller(enabled: true, auth: auth))
        XCTAssertFalse(gate.isLocked, "the app stands an unopenable lock down, and the car follows it")
    }

    func test_unlockingOnTheIPhone_tellsTheCar() async throws {
        let lock = controller(enabled: true)
        let gate = CarPlayLockGate(lock: lock)
        let told = expectation(description: "told of the unlock")
        var changes: [Bool] = []
        gate.observe { locked in
            changes.append(locked)
            told.fulfill()
        }

        await lock.unlock()
        await fulfillment(of: [told], timeout: 2)

        XCTAssertEqual(changes, [false])
        XCTAssertFalse(gate.isLocked)
        XCTAssertEqual(gate.model(sitting: nil, idle: .ready), Screen.model(.ready))
    }

    func test_afterStop_nothingMoreIsTold() async throws {
        let lock = controller(enabled: true)
        let gate = CarPlayLockGate(lock: lock)
        var changes: [Bool] = []
        gate.observe { changes.append($0) }
        gate.stop()

        await lock.unlock()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(changes, [])
    }

    func test_lockedScreen_asksForTheIPhone_andOffersNothing() {
        let locked = Screen.model(.locked)
        XCTAssertEqual(locked.active, .ready)
        XCTAssertEqual(locked.layout.titles[.ready], ["Locked", "Unlock Matron on your iPhone to continue."])
        XCTAssertEqual(locked.layout.buttons[.ready], [], "no Talk while locked")
        XCTAssertFalse(locked.layout.offersChats, "no conversation list while locked")
        XCTAssertTrue(Screen.model(.ready).layout.offersChats)
        XCTAssertTrue(Screen.model(sitting()).layout.offersChats)
    }
}
