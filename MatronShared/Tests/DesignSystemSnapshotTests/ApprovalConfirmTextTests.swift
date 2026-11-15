import XCTest
@testable import MatronDesignSystem

/// What the confirm sheet shows must read exactly as signed: a long hash
/// or path wraps at any character and is never hyphenated.
final class ApprovalConfirmTextTests: XCTestCase {
    private let zeroWidth: Character = "\u{200B}"

    func test_longRunsCanBreakAnywhere_andReadTheSame() {
        let hash = "d6116dc965b1df843cf9c584d4249364ea36ce3d3fc97e50dd75030b0380b865"
        let shown = ApprovalConfirmView.breakable(hash)
        XCTAssertEqual(shown.filter { $0 != zeroWidth }, hash, "nothing visible is added or removed")
        XCTAssertEqual(shown.filter { $0 == zeroWidth }.count, hash.count - 1)
        XCTAssertFalse(shown.contains("-"))
    }

    func test_ordinaryWordsAreLeftAlone() {
        let task = "Run the test suite and report which tests fail."
        XCTAssertEqual(ApprovalConfirmView.breakable(task), task)
        XCTAssertEqual(ApprovalConfirmView.breakable(""), "")
        XCTAssertEqual(ApprovalConfirmView.breakable("production"), "production")
    }

    func test_onlyTheLongRunInASentenceIsMadeBreakable() {
        let text = "in /home/alice/projects/a-very-long-folder-name/app now"
        let shown = ApprovalConfirmView.breakable(text)
        XCTAssertEqual(shown.filter { $0 != zeroWidth }, text)
        XCTAssertTrue(shown.hasPrefix("in /"))
        XCTAssertTrue(shown.hasSuffix(" now"))
        XCTAssertTrue(shown.contains(zeroWidth))
    }
}
