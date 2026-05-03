#if os(macOS)
import XCTest
import MatronModels
@testable import MatronMac

/// View-layer smoke tests for `MacPostLoginVerificationView` — the Mac
/// analogue of the onboarding step-2 gate (spec §5.2). Same shape as the
/// iOS `PostLoginVerificationViewTests`; only the host view differs.
@MainActor
final class MacPostLoginVerificationViewTests: XCTestCase {

    func test_bodyComposes() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let view = MacPostLoginVerificationView(
            dependencies: deps,
            session: session,
            onCompleted: { }
        )
        XCTAssertNotNil(view.body)
    }

    func test_pathEnum_isHashable() {
        let set: Set<MacPostLoginVerificationView.Path> = [.generate, .sasWithOtherDevice, .restoreWithRecoveryKey]
        XCTAssertEqual(set.count, 3)
    }

    func test_verifyDoneKey_isScopedByUserID() {
        let session = UserSession(
            userID: "@alice:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        XCTAssertEqual(
            MacPostLoginVerificationView.verifyDoneKey(for: session),
            "matron.verify-done.@alice:s"
        )
    }
}
#endif
