import XCTest
import MatronModels
@testable import Matron

/// View-layer smoke tests for `PostLoginVerificationView` — the onboarding
/// step-2 gate (spec §5.2). Verifies the SwiftUI body composes without
/// touching the SDK, and that the `Path` enum is `Hashable` (required by
/// `NavigationStack(path:)`).
@MainActor
final class PostLoginVerificationViewTests: XCTestCase {

    func test_bodyComposes() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        let view = PostLoginVerificationView(
            dependencies: deps,
            session: session,
            onCompleted: { }
        )
        XCTAssertNotNil(view.body)
    }

    /// `NavigationStack(path:)` requires the path element to be `Hashable`.
    /// Compile-time guard: if someone accidentally drops `Hashable` from
    /// `Path`, this test won't compile.
    func test_pathEnum_isHashable() {
        let set: Set<PostLoginVerificationView.Path> = [.generate, .sasWithOtherDevice, .restoreWithRecoveryKey]
        XCTAssertEqual(set.count, 3)
    }

    /// The `verifyDone` gate is keyed by `session.userID` so multi-account
    /// scenarios don't interfere. Locks the key shape so a future rename
    /// can't silently break the persisted-flag check on either app.
    func test_verifyDoneKey_isScopedByUserID() {
        let session = UserSession(
            userID: "@alice:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )
        XCTAssertEqual(
            PostLoginVerificationView.verifyDoneKey(for: session),
            "matron.verify-done.@alice:s"
        )
    }
}
