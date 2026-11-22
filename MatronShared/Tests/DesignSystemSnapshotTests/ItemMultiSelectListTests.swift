import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Pins the multi-select tick list: one row per label in the agent's
/// order, ticked as the state says, and the "Answered" line only while the
/// ticks are the latest answer.
final class ItemMultiSelectListTests: XCTestCase {
    private let labels = ["Close the Docs mission", "Close the Billing mission", "Close the Search mission"]

    func testEveryLabelIsARowTickedAsTheStateSays() {
        let state = ItemMultiSelectState(labels: labels, ticked: [labels[0], labels[2]], answered: [], canSend: true)
        let rows = ItemMultiSelectList.rows(state)
        XCTAssertEqual(rows.map(\.label), labels)
        XCTAssertEqual(rows.map(\.isTicked), [true, false, true])
    }

    func testAnsweredShowsOnlyWhileTheTicksAreTheAnswer() {
        let answer: Set<String> = [labels[0]]
        XCTAssertFalse(ItemMultiSelectList.showsAnswered(.init(labels: labels, ticked: [], answered: [], canSend: false)))
        XCTAssertTrue(ItemMultiSelectList.showsAnswered(.init(labels: labels, ticked: answer, answered: answer, canSend: false)))
        XCTAssertFalse(ItemMultiSelectList.showsAnswered(.init(labels: labels, ticked: [labels[1]], answered: answer, canSend: true)),
                       "an unsent change is not the answer")
    }
}
