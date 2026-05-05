#if os(macOS)
import XCTest
import MatronVerification
import MatronViewModels
@testable import MatronMac

/// Mac-side smoke tests for `MacSasView`. The shared `SasViewModel` state
/// machine is covered by the SPM `SasViewModelTests`; here we just prove
/// the SwiftUI body composes for each branch and that re-rendering with
/// different states doesn't trip a guard.
@MainActor
final class MacSasViewTests: XCTestCase {

    func test_bodyComposes_forIdleState() {
        let stream = AsyncStream<SasFlowState> { c in c.finish() }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        let view = MacSasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }

    func test_bodyComposes_forReadyForEmojiState() async {
        let emojis: [SasEmoji] = [
            SasEmoji(symbol: "🐢", description: "Turtle"),
            SasEmoji(symbol: "🐈", description: "Cat"),
            SasEmoji(symbol: "🍌", description: "Banana"),
            SasEmoji(symbol: "🍎", description: "Apple"),
            SasEmoji(symbol: "🚀", description: "Rocket"),
            SasEmoji(symbol: "🎩", description: "Hat"),
            SasEmoji(symbol: "🦋", description: "Butterfly"),
        ]
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.readyForEmoji(emojis))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let view = MacSasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }

    func test_bodyComposes_forVerifiedState() async {
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.verified)
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let view = MacSasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }

    func test_bodyComposes_forCancelledState() async {
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.cancelled(reason: "mismatch"))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "req-1", confirm: {}, cancel: { _ in })
        await vm.observe()
        let view = MacSasView(viewModel: vm, title: "Verify this device")
        XCTAssertNotNil(view.body)
    }
}
#endif
