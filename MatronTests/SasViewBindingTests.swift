import XCTest
import MatronVerification
import MatronViewModels
@testable import Matron

/// View-layer smoke tests for `SasView` — `SasViewModel`'s state machine is
/// covered by the SPM `SasViewModelTests`. Here we just prove the SwiftUI
/// body composes for each branch of the state machine.
final class SasViewBindingTests: XCTestCase {

    @MainActor
    func test_bodyComposes_forIdleState() {
        let stream = AsyncStream<SasFlowState> { c in c.finish() }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        let view = SasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func test_bodyComposes_forReadyForEmojiState() async {
        let emojis = [SasEmoji(symbol: "🐢", description: "Turtle")]
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.readyForEmoji(emojis))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let view = SasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }

    @MainActor
    func test_bodyComposes_forCancelledState() async {
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.cancelled(reason: "mismatch"))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let view = SasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }
}
