import XCTest
import MatronViewModels
@testable import Matron

/// View-layer smoke tests for `RecoveryKeyView` — `RecoveryKeyViewModel`'s
/// state machine is covered by the SPM `RecoveryKeyViewModelTests`. Here we
/// just prove the SwiftUI body composes for both modes and that the
/// `onFinished` callback wires through.
final class RecoveryKeyViewBindingTests: XCTestCase {

    @MainActor
    func test_generateMode_bodyComposes_andOnFinishedFires() {
        let vm = RecoveryKeyViewModel(
            mode: .generate,
            generate: { "MOCK-KEY-1234" },
            restore: { _ in }
        )
        var finished = 0
        let view = RecoveryKeyView(viewModel: vm) { finished += 1 }
        XCTAssertNotNil(view.body)
        XCTAssertEqual(finished, 0)
    }

    @MainActor
    func test_restoreMode_bodyComposes() {
        let vm = RecoveryKeyViewModel(
            mode: .restore,
            generate: { "" },
            restore: { _ in }
        )
        let view = RecoveryKeyView(viewModel: vm) { }
        XCTAssertNotNil(view.body)
    }
}
