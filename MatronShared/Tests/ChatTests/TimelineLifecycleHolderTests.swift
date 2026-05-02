import XCTest
@testable import MatronChat

/// Pins the race-and-leak fix for bugbot finding #6. The previous
/// `TimelineServiceLive.items()` re-assigned `continuation.onTermination`
/// twice — once before `addListener` ran, once after. If the consumer
/// terminated between those two assignments, the first closure would
/// fire (cancelling the setup task), but the freshly-attached SDK
/// listener handle was never cancelled because it was assigned to
/// `onTermination` only after the termination had already occurred.
///
/// `TimelineLifecycleHolder` collapses both cancellables into a single
/// atomic registration so both are guaranteed to be cancelled — whether
/// they're set before or after termination is requested.
final class TimelineLifecycleHolderTests: XCTestCase {

    func test_cancelAll_cancelsBoth_whenSetBeforeTermination() {
        let holder = TimelineLifecycleHolder()
        var taskCancelled = false
        var handleCancelled = false
        holder.setTaskCancel { taskCancelled = true }
        holder.setHandleCancel { handleCancelled = true }

        holder.cancelAll()

        XCTAssertTrue(taskCancelled)
        XCTAssertTrue(handleCancelled)
    }

    func test_setHandleCancel_afterTermination_cancelsImmediately() {
        // The exact race that bug #6 describes: consumer terminates
        // between `setTask` and `setHandle`. The handle registration
        // arrives late but must still be cancelled, otherwise the SDK
        // listener leaks.
        let holder = TimelineLifecycleHolder()
        var taskCancelled = false
        var handleCancelled = false
        holder.setTaskCancel { taskCancelled = true }

        holder.cancelAll()
        XCTAssertTrue(taskCancelled)
        XCTAssertFalse(handleCancelled, "handle wasn't registered yet at cancel time")

        // Late-arriving handle: must self-cancel because the holder is
        // already in the cancelled state.
        holder.setHandleCancel { handleCancelled = true }
        XCTAssertTrue(handleCancelled, "late-registered handle must self-cancel")
    }

    func test_setTaskCancel_afterTermination_cancelsImmediately() {
        // Symmetric case: termination arrives before any registration.
        let holder = TimelineLifecycleHolder()
        var taskCancelled = false
        holder.cancelAll()
        holder.setTaskCancel { taskCancelled = true }
        XCTAssertTrue(taskCancelled)
    }

    func test_cancelAll_isIdempotent() {
        let holder = TimelineLifecycleHolder()
        var cancelCount = 0
        holder.setTaskCancel { cancelCount += 1 }
        holder.cancelAll()
        holder.cancelAll()
        XCTAssertEqual(cancelCount, 1, "cancel closure must run at most once")
    }
}
