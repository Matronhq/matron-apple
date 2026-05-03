import XCTest
@testable import MatronViewModels
import MatronVerification

/// Spec §7.1: SAS verification flow. The view-model is a thin adapter over
/// the `AsyncStream<SasFlowState>` returned by `VerificationService.startSAS`,
/// re-publishing each new state for SwiftUI to render. Confirm/cancel route
/// back to the service via injected closures (so this VM is testable
/// standalone without an SDK).
final class SasViewModelTests: XCTestCase {
    @MainActor
    func test_consumesStreamAndMovesThroughStates() async {
        let states: [SasFlowState] = [
            .requested,
            .readyForEmoji([SasEmoji(symbol: "🐢", description: "Turtle")]),
            .awaitingConfirmation,
            .verified,
        ]
        let stream = AsyncStream<SasFlowState> { c in
            for s in states { c.yield(s) }
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        XCTAssertEqual(vm.state, .verified)
    }

    @MainActor
    func test_confirm_invokesCallback() async {
        var confirmed = false
        let stream = AsyncStream<SasFlowState> { c in c.finish() }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: { confirmed = true }, cancel: { _ in })
        await vm.confirm()
        XCTAssertTrue(confirmed)
    }

    @MainActor
    func test_cancel_invokesCallback_withReason() async {
        var receivedReason: String?
        let stream = AsyncStream<SasFlowState> { c in c.finish() }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { reason in receivedReason = reason })
        await vm.cancel(reason: "mismatch")
        XCTAssertEqual(receivedReason, "mismatch")
    }

    @MainActor
    func test_observe_isIdempotent_underDoubleCall() async {
        // Two calls to observe() must NOT re-consume the stream. The second call must
        // early-return immediately because `isObserving` is already true. This pins the
        // re-entrancy guard so SwiftUI's `.task(id:)` re-firing doesn't double-iterate.
        var yielded = 0
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.requested); yielded += 1
            c.yield(.verified);  yielded += 1
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let yieldedAfterFirst = yielded
        await vm.observe()  // must be a no-op, not re-iterate the (already-finished) stream
        XCTAssertEqual(yielded, yieldedAfterFirst, "observe() must be guarded against double-call")
        XCTAssertEqual(vm.state, .verified)
    }

    @MainActor
    func test_emojiOrder_isPreservedFromStream() async {
        // Bugbot watches: never re-sort emojis by ID/symbol/description. The SDK's
        // delivery order is the canonical SAS order — re-sorting would silently
        // produce the wrong short-auth-string and break the verify.
        let canonical: [SasEmoji] = [
            SasEmoji(symbol: "🐢", description: "Turtle"),
            SasEmoji(symbol: "🐈", description: "Cat"),
            SasEmoji(symbol: "🍌", description: "Banana"),
            SasEmoji(symbol: "🍎", description: "Apple"),
            SasEmoji(symbol: "🚀", description: "Rocket"),
            SasEmoji(symbol: "🎩", description: "Hat"),
            SasEmoji(symbol: "🦋", description: "Butterfly"),
        ]
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.readyForEmoji(canonical))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        guard case .readyForEmoji(let received) = vm.state else {
            return XCTFail("expected .readyForEmoji, got \(vm.state)")
        }
        XCTAssertEqual(received, canonical, "emoji order must mirror the stream's delivery order")
    }
}
