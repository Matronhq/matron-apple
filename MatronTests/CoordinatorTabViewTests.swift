import XCTest
@testable import Matron

/// App shell (spec §3): the Coordinator tab's root depends only on the
/// setting — setup view without one, the chat with one.
final class CoordinatorTabViewTests: XCTestCase {
    func test_root_isSetupWithoutASetting_andTheChatWithOne() {
        XCTAssertEqual(CoordinatorTabView.root(for: nil), .setup)
        XCTAssertEqual(CoordinatorTabView.root(for: ""), .setup, "an empty stored value is no coordinator")
        XCTAssertEqual(CoordinatorTabView.root(for: "cv_1"), .chat("cv_1"))
    }
}
