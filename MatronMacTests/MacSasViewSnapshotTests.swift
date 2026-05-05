#if os(macOS)
import XCTest
import SnapshotTesting
import MatronVerification
import MatronViewModels
@testable import MatronMac

/// Phase 3 Task 12: snapshot coverage for `MacSasView`. The shared
/// `SasViewModel` state machine is covered by SPM `SasViewModelTests`;
/// here we lock the rendered chrome for the two visually-distinct
/// states the user actually sees mid-flow:
///
///   - `.readyForEmoji` — the emoji-compare grid (4-up + 3-down) with
///     "They match" / "They don't match" buttons.
///   - `.verified` — the green-shield success state.
///
/// `assertVariants(of:named:)` is the Mac-side mirror of the SPM helper
/// (see `SnapshotHelpers.swift`). It records light × dark × accessibility5
/// baselines per state, gated by `MATRON_SKIP_SNAPSHOT_TESTS=1` for CI.
///
/// The plan snippet (§Task 12 Step 1) used `expectation` + `Task { ... }`
/// to drive the VM into its target state before snapshotting; we mirror
/// the cleaner async-test pattern from `MacSasViewTests` instead, where
/// the producer's `.finish()` lets `await vm.observe()` return as soon
/// as the state has been published.
@MainActor
final class MacSasViewSnapshotTests: XCTestCase {

    func test_emojiCompareState() async {
        let emojis: [SasEmoji] = [
            SasEmoji(symbol: "🐢", description: "Turtle"),
            SasEmoji(symbol: "🚀", description: "Rocket"),
            SasEmoji(symbol: "🍎", description: "Apple"),
            SasEmoji(symbol: "🐱", description: "Cat"),
            SasEmoji(symbol: "🌟", description: "Star"),
            SasEmoji(symbol: "🔥", description: "Fire"),
            SasEmoji(symbol: "🦄", description: "Unicorn"),
        ]
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.readyForEmoji(emojis))
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "snap", confirm: {}, cancel: { _ in })
        await vm.observe()
        assertVariants(
            of: MacSasView(viewModel: vm, title: "Verify this device"),
            named: "MacSasView_emojiCompare"
        )
    }

    func test_verifiedState() async {
        let stream = AsyncStream<SasFlowState> { c in
            c.yield(.verified)
            c.finish()
        }
        let vm = SasViewModel(stream: stream, requestID: "snap", confirm: {}, cancel: { _ in })
        await vm.observe()
        assertVariants(
            of: MacSasView(viewModel: vm, title: "Verify this device"),
            named: "MacSasView_verified"
        )
    }
}
#endif
