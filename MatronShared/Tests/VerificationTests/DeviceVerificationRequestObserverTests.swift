import Foundation
import XCTest
@testable import MatronVerification

/// Test fake conforming to `IncomingVerificationListening`. Records every
/// callback the observer forwards.
///
/// `onUpdate` is synchronous (matching the protocol contract) and writes into
/// an `os_unfair_lock`-guarded buffer so tests can read straight back without
/// having to flush an actor's serial queue.
final class FakeIncomingVerificationListener: IncomingVerificationListening, @unchecked Sendable {
    typealias Entry = (
        requestID: String,
        summary: VerificationRequestSummary,
        controller: SessionVerificationControlling
    )

    private let lock = NSLock()
    private var buffer: [Entry] = []

    var received: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func onUpdate(
        requestID: String,
        summary: VerificationRequestSummary,
        controller: SessionVerificationControlling
    ) {
        lock.lock()
        buffer.append((requestID, summary, controller))
        lock.unlock()
    }
}

final class DeviceVerificationRequestObserverTests: XCTestCase {
    func test_handleIncomingRequest_forwardsSummaryAndControllerToListener() throws {
        let listener = FakeIncomingVerificationListener()
        let observer = DeviceVerificationRequestObserver(listener: listener)
        let controller = FakeSessionVerificationController()

        observer.handleIncomingRequest(
            requestID: "req-1",
            otherUserID: "@alice:s",
            otherDeviceID: "DEV1",
            controller: controller
        )

        let received = listener.received
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.requestID, "req-1")
        XCTAssertEqual(received.first?.summary.id, "req-1")
        XCTAssertEqual(received.first?.summary.otherUserID, "@alice:s")
        XCTAssertEqual(received.first?.summary.otherDeviceID, "DEV1")
        XCTAssertTrue(received.first?.controller === controller)
    }

    func test_handleIncomingRequest_propagatesNilDeviceID() throws {
        let listener = FakeIncomingVerificationListener()
        let observer = DeviceVerificationRequestObserver(listener: listener)
        let controller = FakeSessionVerificationController()

        observer.handleIncomingRequest(
            requestID: "req-2",
            otherUserID: "@bob:s",
            otherDeviceID: nil,
            controller: controller
        )

        let received = listener.received
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received.first?.summary.otherDeviceID)
    }

    func test_handleIncomingRequest_summaryUsesProvidedRequestIDAsIdentifier() throws {
        let listener = FakeIncomingVerificationListener()
        let observer = DeviceVerificationRequestObserver(listener: listener)
        let controller = FakeSessionVerificationController()

        // Caller passes the SDK's flow ID as the requestID; the observer must use it
        // verbatim as the summary's `id` so downstream consumers can correlate.
        observer.handleIncomingRequest(
            requestID: "flow-abc-123",
            otherUserID: "@carol:s",
            otherDeviceID: "DEV2",
            controller: controller
        )

        let received = listener.received
        XCTAssertEqual(received.first?.summary.id, "flow-abc-123")
    }
}
