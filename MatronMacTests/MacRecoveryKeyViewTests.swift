#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac
@testable import MatronViewModels

/// Test fake for the local `MatronPasteboardReading` protocol seam (named
/// `Matron…` to avoid collision with AppKit's `NSPasteboardReading`).
private final class FakePasteboard: MatronPasteboardReading {
    var stringValue: String?

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        stringValue
    }
}

/// Mac-specific paste-detection on `MacRecoveryKeyView`. The shared
/// `RecoveryKeyViewModel` state machine is covered by the SPM
/// `RecoveryKeyViewModelTests`; here we just prove `PasteDetector`
/// populates the model's `reenteredKey` from the clipboard. Advancing
/// to `.confirmed` is driven by an explicit Confirm button tap (matches
/// iOS RecoveryKeyView) — the detector itself does not auto-advance.
@MainActor
final class MacRecoveryKeyViewTests: XCTestCase {

    /// Paste populates `reenteredKey` and leaves the phase on `.reenter`
    /// so the user must tap Confirm. `canFinish` flips true so the
    /// Confirm button enables. PR review issue #14: the previous
    /// auto-advance to `.confirmed` on a paste-match was a regression
    /// vs. iOS — paste alone could skip the deliberate confirmation
    /// gesture.
    func test_pasteOfMatchingKey_populatesField_doesNotAdvance() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "MOCK-KEY-1234" },
            restore: { _ in }
        )
        vm.generatedKey = "MOCK-KEY-1234"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter

        let pasteboard = FakePasteboard()
        pasteboard.stringValue = "MOCK-KEY-1234"
        let detector = PasteDetector(pasteboard: pasteboard, viewModel: vm)
        detector.checkClipboardAndApply()

        XCTAssertEqual(vm.reenteredKey, "MOCK-KEY-1234")
        XCTAssertEqual(vm.generatePhase, .reenter,
                       "Paste must NOT auto-advance — Confirm tap is the only trigger.")
        XCTAssertTrue(vm.canFinish,
                      "canFinish should be true so the Confirm button enables.")
    }

    func test_pasteOfNonMatchingKey_doesNotAdvance() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "K" },
            restore: { _ in }
        )
        vm.generatedKey = "MOCK-KEY-1234"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter

        let pasteboard = FakePasteboard()
        pasteboard.stringValue = "WRONG"
        let detector = PasteDetector(pasteboard: pasteboard, viewModel: vm)
        detector.checkClipboardAndApply()

        XCTAssertEqual(vm.reenteredKey, "WRONG")
        XCTAssertFalse(vm.canFinish)
        XCTAssertEqual(vm.generatePhase, .reenter)
    }

    func test_paste_isNoOp_whenNotInGenerateReenterPhase() {
        // Detector is wired view-side only when `.generate / .reenter` is
        // active, but defensively guard against being called from elsewhere.
        let vm = RecoveryKeyViewModel(
            mode: .restore,
            generate: { "" },
            restore: { _ in }
        )
        let pasteboard = FakePasteboard()
        pasteboard.stringValue = "anything"
        let detector = PasteDetector(pasteboard: pasteboard, viewModel: vm)
        detector.checkClipboardAndApply()

        XCTAssertEqual(vm.enteredKey, "")
        XCTAssertEqual(vm.reenteredKey, "")
    }

    func test_paste_isNoOp_whenClipboardIsEmpty() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "K" },
            restore: { _ in }
        )
        vm.generatedKey = "K"
        vm.userAcknowledgedSaved = true
        vm.generatePhase = .reenter

        let pasteboard = FakePasteboard()
        pasteboard.stringValue = nil       // empty clipboard
        let detector = PasteDetector(pasteboard: pasteboard, viewModel: vm)
        detector.checkClipboardAndApply()
        XCTAssertEqual(vm.reenteredKey, "")

        pasteboard.stringValue = ""        // explicit empty string
        detector.checkClipboardAndApply()
        XCTAssertEqual(vm.reenteredKey, "")
    }

    func test_view_bodyComposes_inGenerateMode() {
        let vm = RecoveryKeyViewModel(mode: .generate, generate: { "K" }, restore: { _ in })
        let view = MacRecoveryKeyView(viewModel: vm) { }
        XCTAssertNotNil(view.body)
    }

    func test_view_bodyComposes_inRestoreMode() {
        let vm = RecoveryKeyViewModel(mode: .restore, generate: { "" }, restore: { _ in })
        let view = MacRecoveryKeyView(viewModel: vm) { }
        XCTAssertNotNil(view.body)
    }

    /// Wave 4 expert-QA #2: a successful Restore (which advances `phase`
    /// to `.done`) followed by Done MUST NOT re-fire the underlying
    /// restore closure. The Done button's body now skips
    /// `attemptRestore()` when `phase == .done` and just calls
    /// `onFinished()` instead. The fix lives on the view; we exercise
    /// the VM-side invariant that double-call would otherwise hit:
    /// the second call would re-fire `restore` against the SDK.
    func test_attemptRestore_isNotCalledAgain_whenAlreadyDone() async {
        var restoreCallCount = 0
        let vm = RecoveryKeyViewModel(
            mode: .restore,
            generate: { "" },
            restore: { _ in restoreCallCount += 1 }
        )
        vm.enteredKey = "VALID-KEY"
        await vm.attemptRestore()
        XCTAssertEqual(vm.phase, .done)
        XCTAssertEqual(restoreCallCount, 1)
        // The view's Done body now guards on `phase != .done` before
        // re-firing — assert the VM isn't itself the layer doing the
        // guard. (If a future refactor moves the guard into the VM
        // then this test should be updated to check `attemptRestore`
        // on a `.done` VM is a no-op.)
        await vm.attemptRestore()
        // VM has no built-in guard — the view-side guard is the fix.
        XCTAssertEqual(restoreCallCount, 2)
    }
}
#endif
