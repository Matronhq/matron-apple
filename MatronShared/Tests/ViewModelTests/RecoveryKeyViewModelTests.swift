import XCTest
@testable import MatronViewModels

/// Test-double for the recovery-key manager. The view-model is *agnostic*
/// of `RecoveryKeyManager` (which lives in `MatronVerification`, not a
/// dependency of `MatronViewModels`) — it consumes `generate` / `restore`
/// closures so it can compile + test standalone in this target.
private final class FakeRecoveryKeyManager: @unchecked Sendable {
    var generated: String = "MOCK-RECOVERY-KEY-1234-5678"
    var generatedCount = 0
    var restoredKeys: [String] = []

    func generateAndPersist() async throws -> String {
        generatedCount += 1
        return generated
    }

    func restore(usingKey key: String) async throws {
        restoredKeys.append(key)
    }
}

/// Spec §7.2 Scenario A: first-device flow generates a key, shows it once,
/// asks the user to acknowledge then re-enter it. Plus the restore-mode
/// branch and a constant-time-comparison guard for the re-enter check.
final class RecoveryKeyViewModelTests: XCTestCase {
    @MainActor
    func test_generate_setsGeneratedKey_andEntersPhaseShow() async {
        let fake = FakeRecoveryKeyManager()
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { try await fake.generateAndPersist() },
            restore: { _ in }
        )
        await vm.generate()
        XCTAssertEqual(vm.generatedKey, "MOCK-RECOVERY-KEY-1234-5678")
        XCTAssertEqual(fake.generatedCount, 1)
        XCTAssertEqual(vm.generatePhase, .show)
    }

    @MainActor
    func test_acknowledgeSaved_advancesToReenterPhase() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "K"
        vm.generatePhase = .show
        XCTAssertFalse(vm.canFinish)        // can't finish from show phase
        vm.userAcknowledgedSaved = true
        vm.advanceFromShow()
        XCTAssertEqual(vm.generatePhase, .reenter)
        XCTAssertFalse(vm.canFinish)        // still can't — must re-enter
    }

    @MainActor
    func test_canFinish_isFalseUntilReenteredKeyMatches() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "MOCK-RECOVERY-KEY-1234-5678"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter
        vm.reenteredKey = ""
        XCTAssertFalse(vm.canFinish)
        vm.reenteredKey = "WRONG"
        XCTAssertFalse(vm.canFinish)
        vm.reenteredKey = "MOCK-RECOVERY-KEY-1234-5678"
        XCTAssertTrue(vm.canFinish)
    }

    @MainActor
    func test_advanceFromShow_isNoOp_withoutAcknowledgement() {
        // Guard against accidentally bypassing the "I've saved this" toggle.
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        vm.generatedKey = "K"
        vm.generatePhase = .show
        vm.userAcknowledgedSaved = false
        vm.advanceFromShow()
        XCTAssertEqual(vm.generatePhase, .show)
    }

    @MainActor
    func test_restore_callsManager() async {
        let fake = FakeRecoveryKeyManager()
        let vm = RecoveryKeyViewModel.restoring(
            restore: { try await fake.restore(usingKey: $0) }
        )
        vm.enteredKey = "abc"
        await vm.attemptRestore()
        XCTAssertEqual(fake.restoredKeys, ["abc"])
    }

    @MainActor
    func test_restore_canFinish_reflectsEntry() {
        let vm = RecoveryKeyViewModel.restoring(restore: { _ in })
        XCTAssertFalse(vm.canFinish)
        vm.enteredKey = "abc"
        XCTAssertTrue(vm.canFinish)
    }

    // MARK: - Constant-time key compare (`keysMatch`)

    func test_keysMatch_unequalLengths_rejectGracefully() {
        // Equal-length compare uses bytewise XOR; the unequal-length branch
        // must short-circuit cleanly without an out-of-bounds read or trap.
        XCTAssertFalse(RecoveryKeyViewModel.keysMatch("AAAA", "AAA"))
        XCTAssertFalse(RecoveryKeyViewModel.keysMatch("AAA", "AAAA"))
    }

    func test_keysMatch_equalLengths_distinguishMatchVsMismatch() {
        XCTAssertTrue(RecoveryKeyViewModel.keysMatch("MATCHING-KEY-VALUE", "MATCHING-KEY-VALUE"))
        XCTAssertFalse(RecoveryKeyViewModel.keysMatch("MATCHING-KEY-VALUE", "MATCHING-KEY-VALUF"))
        // Mismatch in the *first* byte must still be detected (would slip
        // past a naive XOR-with-early-return implementation if buggy).
        XCTAssertFalse(RecoveryKeyViewModel.keysMatch("XATCHING-KEY-VALUE", "MATCHING-KEY-VALUE"))
    }

    func test_keysMatch_emptyStrings_areEqual() {
        XCTAssertTrue(RecoveryKeyViewModel.keysMatch("", ""))
    }
}
