import XCTest
@testable import MatronVerification

final class VerificationServiceFakeTests: XCTestCase {
    func test_startSAS_yieldsScriptedTransitions() async throws {
        let svc = FakeVerificationService()
        var collected: [SasFlowState] = []
        for await state in svc.startSAS(withUser: "@a:s", deviceID: "DEV1") {
            collected.append(state)
        }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected.first, .requested)
        XCTAssertEqual(collected.last, .verified)
    }

    func test_startSAS_recordsCallArgumentsOnActor() async throws {
        let svc = FakeVerificationService()
        // Drain the stream to ensure the recording task has had a chance to run.
        for await _ in svc.startSAS(withUser: "@b:s", deviceID: nil) {}
        // Round-trip through the actor's serial queue to flush the recording task.
        _ = try await svc.isThisDeviceVerified()
        let calls = await svc.didCallStart
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.userID, "@b:s")
        XCTAssertNil(calls.first?.deviceID)
    }

    func test_confirmEmojiMatch_recordsRequestID() async throws {
        let svc = FakeVerificationService()
        try await svc.confirmEmojiMatch(requestID: "req-1")
        let confirmed = await svc.didConfirm
        XCTAssertEqual(confirmed, ["req-1"])
    }

    func test_cancel_recordsReason() async throws {
        let svc = FakeVerificationService()
        try await svc.cancel(requestID: "req-2", reason: "user-cancelled")
        let cancels = await svc.didCancel
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.requestID, "req-2")
        XCTAssertEqual(cancels.first?.reason, "user-cancelled")
    }

    func test_acceptIncoming_emitsRequestedThenFinishes() async throws {
        let svc = FakeVerificationService()
        var collected: [SasFlowState] = []
        for await state in svc.acceptIncoming(requestID: "req-3") {
            collected.append(state)
        }
        XCTAssertEqual(collected, [.requested])
    }

    func test_isThisDeviceVerified_returnsTrueByDefault() async throws {
        let svc = FakeVerificationService()
        let verified = try await svc.isThisDeviceVerified()
        XCTAssertTrue(verified)
    }
}
