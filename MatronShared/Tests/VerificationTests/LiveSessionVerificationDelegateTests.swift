import Foundation
import XCTest
import MatrixRustSDK
@testable import MatronVerification

/// Routing-shape tests for `LiveSessionVerificationDelegate`. Each SDK
/// callback (`didReceiveVerificationRequest`, `didStartSasVerification`,
/// `didReceiveVerificationData`, `didFinish`, `didCancel`, `didFail`)
/// must dispatch to the correct `routeSas…` entry point on the
/// `SessionVerificationFlowRouting` protocol so the live impl's
/// FlowStore + open continuations advance through the SAS state machine.
///
/// We don't drive a real `MatrixRustSDK.SessionVerificationController`
/// here — that requires a live `Client`. The delegate's constructor takes
/// the SDK type so we manufacture a `noHandle` fake (the SDK's documented
/// test seam — the FFI lower funcs would crash but we never invoke them
/// because the routing methods don't talk back to the controller).
final class LiveSessionVerificationDelegateTests: XCTestCase {

    /// Minimal in-memory implementation of `SessionVerificationFlowRouting`.
    /// Records the (requestID, otherUserID, otherDeviceID) tuple every
    /// `routeIncomingRequest` call delivers, plus a count for each
    /// lifecycle entry-point call. Backed by an actor for Swift-6
    /// concurrency.
    actor FakeRouter: SessionVerificationFlowRouting {
        struct IncomingCall: Equatable {
            let requestID: String
            let otherUserID: String
            let otherDeviceID: String?
        }

        private(set) var incomingCalls: [IncomingCall] = []
        private(set) var sasStartedCount = 0
        private(set) var sasDataPayloads: [SessionVerificationData] = []
        private(set) var sasFinishedCount = 0
        private(set) var sasCancelledCount = 0
        private(set) var sasFailedCount = 0

        func routeIncomingRequest(
            requestID: String,
            otherUserID: String,
            otherDeviceID: String?,
            controller: SessionVerificationControlling
        ) async {
            incomingCalls.append(IncomingCall(
                requestID: requestID,
                otherUserID: otherUserID,
                otherDeviceID: otherDeviceID
            ))
        }

        func routeSasStarted() async { sasStartedCount += 1 }
        func routeSasData(_ data: SessionVerificationData) async { sasDataPayloads.append(data) }
        func routeSasFinished() async { sasFinishedCount += 1 }
        func routeSasCancelled() async { sasCancelledCount += 1 }
        func routeSasFailed() async { sasFailedCount += 1 }
    }

    /// Build the delegate against a no-handle SDK controller (test seam the
    /// SDK explicitly provides via `SessionVerificationController(noHandle:)`).
    /// The routing methods don't call back into the controller, so the
    /// missing FFI handle is safe.
    private func makeDelegate(router: FakeRouter) -> LiveSessionVerificationDelegate {
        let sdkController = MatrixRustSDK.SessionVerificationController(noHandle: .init())
        return LiveSessionVerificationDelegate(router: router, sharedController: sdkController)
    }

    private func makeDetails(
        flowID: String = "flow-1",
        userID: String = "@alice:s",
        deviceID: String = "DEV1"
    ) -> SessionVerificationRequestDetails {
        SessionVerificationRequestDetails(
            senderProfile: UserProfile(userId: userID, displayName: nil, avatarUrl: nil),
            flowId: flowID,
            deviceId: deviceID,
            deviceDisplayName: nil,
            firstSeenTimestamp: 0
        )
    }

    func test_didReceiveVerificationRequest_routesIncomingWithFlowIDAndUserAndDevice() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)

        delegate.didReceiveVerificationRequest(details: makeDetails(
            flowID: "flow-abc", userID: "@bob:s", deviceID: "BOBDEV"
        ))

        try await waitUntil { await router.incomingCalls.count == 1 }
        let calls = await router.incomingCalls
        XCTAssertEqual(calls.first, FakeRouter.IncomingCall(
            requestID: "flow-abc",
            otherUserID: "@bob:s",
            otherDeviceID: "BOBDEV"
        ))
    }

    /// SDK's `SessionVerificationRequestDetails.deviceId` is non-optional in
    /// v26.04.01 but our router protocol exposes `String?` — empty string is
    /// translated to `nil` so callers can branch on "no device binding"
    /// without string-matching `""`.
    func test_didReceiveVerificationRequest_emptyDeviceIDBecomesNil() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)

        delegate.didReceiveVerificationRequest(details: makeDetails(
            flowID: "flow-no-dev", userID: "@carol:s", deviceID: ""
        ))

        try await waitUntil { await router.incomingCalls.count == 1 }
        let calls = await router.incomingCalls
        XCTAssertNil(calls.first?.otherDeviceID)
    }

    func test_didStartSasVerification_routesSasStarted() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)
        delegate.didStartSasVerification()
        try await waitUntil { await router.sasStartedCount == 1 }
    }

    func test_didReceiveVerificationData_routesSasData_withPayload() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)
        // .decimals is the variant we can construct from Swift without an FFI
        // handle (SessionVerificationEmoji wraps a uniffi handle). The route
        // method receives the same enum case the delegate forwarded, which is
        // what we're asserting.
        delegate.didReceiveVerificationData(data: .decimals(values: [1, 2, 3]))

        try await waitUntil { await router.sasDataPayloads.count == 1 }
        let payloads = await router.sasDataPayloads
        if case let .decimals(values) = payloads.first {
            XCTAssertEqual(values, [1, 2, 3])
        } else {
            XCTFail("expected .decimals payload, got \(String(describing: payloads.first))")
        }
    }

    func test_didFinish_routesSasFinished() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)
        delegate.didFinish()
        try await waitUntil { await router.sasFinishedCount == 1 }
    }

    func test_didCancel_routesSasCancelled() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)
        delegate.didCancel()
        try await waitUntil { await router.sasCancelledCount == 1 }
    }

    func test_didFail_routesSasFailed() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)
        delegate.didFail()
        try await waitUntil { await router.sasFailedCount == 1 }
    }

    /// `didAcceptVerificationRequest` is intentionally a no-op on our
    /// delegate — the SDK fires it after request acceptance but before SAS
    /// transitions, and the next user-visible state comes from
    /// `didStartSasVerification` / `didReceiveVerificationData`. Asserting
    /// that it doesn't reach the router locks the silence in.
    func test_didAcceptVerificationRequest_doesNotReachRouter() async throws {
        let router = FakeRouter()
        let delegate = makeDelegate(router: router)
        delegate.didAcceptVerificationRequest()
        // Give any erroneously-spawned task a chance to land.
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = await router.sasStartedCount
        let finished = await router.sasFinishedCount
        let cancelled = await router.sasCancelledCount
        let failed = await router.sasFailedCount
        let dataCount = await router.sasDataPayloads.count
        XCTAssertEqual(started, 0)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(dataCount, 0)
    }

    /// Bounded poll — drives the runloop in 5ms slices for up to 1s so the
    /// `Task { await router.routeX }` hop the delegate spawns gets a chance
    /// to land. `Task.sleep` gives the actor a chance to run.
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !predicate() {
            if Date() >= deadline {
                XCTFail("waitUntil timed out after \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
