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
/// drives the model's `reenteredKey` and auto-advances to `.confirmed`
/// when the clipboard matches the generated key.
@MainActor
final class MacRecoveryKeyViewTests: XCTestCase {

    func test_pasteOfMatchingKey_autoAdvancesToConfirmed() {
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
        XCTAssertEqual(vm.generatePhase, .confirmed)
        // `canFinish` returns `false` once `generatePhase` advances out of
        // `.reenter` — the gate is by design (it's the "primary action
        // enabled?" predicate, and after auto-advance the Confirm button
        // is gone). Plan test asserts `canFinish == true` here, which only
        // holds momentarily inside `PasteDetector.checkClipboardAndApply`
        // before the advance fires.
        XCTAssertFalse(vm.canFinish)
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
}
#endif
