#if os(macOS)
import XCTest
import SnapshotTesting
import MatronViewModels
@testable import MatronMac

/// Phase 3 Task 12: snapshot coverage for `MacRecoveryKeyView`. The shared
/// `RecoveryKeyViewModel` state machine is covered by SPM
/// `RecoveryKeyViewModelTests`; here we lock the rendered chrome for each
/// visually-distinct phase the user actually sees:
///
///   - `.show`      — key visible + Copy button + "I've saved this" toggle.
///   - `.reenter`   — re-entry field with a wrong value, "Doesn't match" warning.
///   - `.confirmed` — green checkmark success state.
///   - `.restore`   — restore-mode entry field + Restore / Done buttons.
///
/// `assertVariants(of:named:)` is the Mac-side mirror of the SPM helper
/// (see `SnapshotHelpers.swift`). It records light × dark × accessibility5
/// baselines per state, gated by `MATRON_SKIP_SNAPSHOT_TESTS=1` for CI.
///
/// The `.confirmed` phase view has a 600ms `.task` that calls `onFinished`
/// — that fires after the initial render, so the snapshot captures the
/// success affordance before auto-dismiss.
@MainActor
final class MacRecoveryKeyViewSnapshotTests: XCTestCase {

    func test_show_phase() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "MOCK-KEY-1234-5678" },
            restore: { _ in }
        )
        vm.generatedKey = "MOCK-KEY-1234-5678"
        vm.generatePhase = .show
        assertVariants(
            of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
            named: "MacRecoveryKeyView_show"
        )
    }

    func test_reenter_phase_mismatch() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "MOCK-KEY-1234-5678" },
            restore: { _ in }
        )
        vm.generatedKey = "MOCK-KEY-1234-5678"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter
        vm.reenteredKey = "WRONG"
        assertVariants(
            of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
            named: "MacRecoveryKeyView_reenterMismatch"
        )
    }

    func test_confirmed_phase() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "MOCK-KEY-1234-5678" },
            restore: { _ in }
        )
        vm.generatedKey = "MOCK-KEY-1234-5678"
        vm.userAcknowledgedSaved = true
        vm.reenteredKey = "MOCK-KEY-1234-5678"
        vm.generatePhase = .confirmed
        assertVariants(
            of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
            named: "MacRecoveryKeyView_confirmed"
        )
    }

    func test_restore_mode() {
        let vm = RecoveryKeyViewModel(
            mode: .restore,
            generate: { "" },
            restore: { _ in }
        )
        vm.enteredKey = "MOCK-KEY-1234-5678"
        assertVariants(
            of: MacRecoveryKeyView(viewModel: vm, onFinished: {}),
            named: "MacRecoveryKeyView_restore"
        )
    }
}
#endif
