import SwiftUI
import XCTest
import MatronJournal
@testable import Matron

/// Bugbot "Sign-in path skips database suspension": the background edge used
/// to be driven only from the signed-in view's scene-phase handler, so a
/// process backgrounded on the sign-in screen (mid sign-out teardown
/// included) never suspended its App Group databases. The app-level
/// handler routes every phase change through `DatabaseLifecycle`.
@MainActor
final class DatabaseLifecycleTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _transitions: [Bool] = []
        var transitions: [Bool] { lock.withLock { _transitions } }
        func record(_ suspend: Bool) { lock.withLock { _transitions.append(suspend) } }
    }

    func testBackgroundWithNoSessionWorkSuspends() {
        let recorder = Recorder()
        let controller = DatabaseSuspensionController(apply: { recorder.record($0) })
        DatabaseLifecycle.sceneDidChange(to: .background, controller: controller, beforeSuspending: {})
        XCTAssertTrue(controller.isSuspended)
        DatabaseLifecycle.sceneDidChange(to: .inactive, controller: controller, beforeSuspending: {})
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [true, false])
    }

    func testBackgroundWorkIsClaimedBeforeTheSuspensionDecision() {
        // The outbox grace claims its activity in `beforeSuspending`; it must
        // run first, or the databases blip suspended under its first write.
        let recorder = Recorder()
        let controller = DatabaseSuspensionController(apply: { recorder.record($0) })
        var grace: DatabaseSuspensionController.Activity?
        DatabaseLifecycle.sceneDidChange(to: .background, controller: controller) {
            grace = controller.beginActivity(named: "outbox-grace")
        }
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [], "no suspend/resume blip")
        grace?.end()
        XCTAssertTrue(controller.isSuspended)
    }

    func testForegroundPhasesNeverRunTheBackgroundWork() {
        let controller = DatabaseSuspensionController(apply: { _ in })
        var ran = false
        DatabaseLifecycle.sceneDidChange(to: .active, controller: controller) { ran = true }
        DatabaseLifecycle.sceneDidChange(to: .inactive, controller: controller) { ran = true }
        XCTAssertFalse(ran)
        XCTAssertFalse(controller.isSuspended)
    }
}
