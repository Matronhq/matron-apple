import XCTest
@testable import Matron

/// App shell (spec §3): the Coordinator sheet's root depends only on the
/// setting — setup view without one, the chat with one.
final class CoordinatorSheetTests: XCTestCase {
    func test_root_isSetupWithoutASetting_andTheChatWithOne() {
        XCTAssertEqual(CoordinatorSheet.root(for: nil), .setup)
        XCTAssertEqual(CoordinatorSheet.root(for: ""), .setup, "an empty stored value is no coordinator")
        XCTAssertEqual(CoordinatorSheet.root(for: "cv_1"), .chat("cv_1"))
    }
}
